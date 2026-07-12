#include "opus_mt_ffi.h"
#include "opus_mt_translator.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>

#include "nlohmann/json.hpp"

namespace {

// Global error string, protected by mutex.
static std::mutex g_error_mutex;
static std::string g_last_error;

void SetError(const std::string& msg) {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  g_last_error = msg;
}

// Build paths relative to a model directory.
std::string JoinPath(const std::string& dir, const std::string& file) {
  if (dir.empty()) return file;
  if (dir.back() == '/' || dir.back() == '\\') return dir + file;
  return dir + "/" + file;
}

// Read config.json from the model directory to get model hyperparameters.
bool LoadConfigJson(const std::string& model_dir, opus_mt::OpusMtConfig& cfg) {
  std::string config_path = JoinPath(model_dir, "config.json");
  std::ifstream file(config_path);
  if (!file.is_open()) {
    // config.json is optional; use defaults from the C++ config.
    return true;
  }

  nlohmann::json j;
  try {
    file >> j;
  } catch (const nlohmann::json::parse_error&) {
    return true;  // Not fatal.
  }

  auto safe_int = [&j](const char* key, int32_t default_val) -> int32_t {
    if (!j.contains(key)) return default_val;
    auto& v = j[key];
    if (v.is_null()) return default_val;
    return v.get<int32_t>();
  };
  auto safe_bool = [&j](const char* key, bool default_val) -> bool {
    if (!j.contains(key)) return default_val;
    auto& v = j[key];
    if (v.is_null()) return default_val;
    return v.get<bool>();
  };

  cfg.pad_token_id = safe_int("pad_token_id", cfg.pad_token_id);
  cfg.eos_token_id = safe_int("eos_token_id", cfg.eos_token_id);
  cfg.bos_token_id = safe_int("bos_token_id", cfg.bos_token_id);
  cfg.decoder_start_token_id = safe_int("decoder_start_token_id", cfg.decoder_start_token_id);
  cfg.vocab_size = safe_int("vocab_size", cfg.vocab_size);
  cfg.d_model = safe_int("d_model", cfg.d_model);
  cfg.encoder_layers = safe_int("encoder_layers", cfg.encoder_layers);
  cfg.decoder_layers = safe_int("decoder_layers", cfg.decoder_layers);
  cfg.encoder_attention_heads = safe_int("encoder_attention_heads", cfg.encoder_attention_heads);
  cfg.decoder_attention_heads = safe_int("decoder_attention_heads", cfg.decoder_attention_heads);
  cfg.decoder_ffn_dim = safe_int("decoder_ffn_dim", cfg.decoder_ffn_dim);
  cfg.max_length = safe_int("max_length", cfg.max_length);
  cfg.use_cache = safe_bool("use_cache", cfg.use_cache);
  cfg.max_length = safe_int("max_position_embeddings", cfg.max_length);
  cfg.unk_token_id = safe_int("unk_token_id", cfg.unk_token_id);

  return true;
}

}  // namespace

// The concrete translator handle wraps the C++ translator.
struct OpusMtTranslatorHandle {
  opus_mt::OpusMtTranslator translator;
  opus_mt::OpusMtConfig config;
  std::string model_dir;
};

OpusMtTranslatorHandle* opus_mt_create_translator(
    const char* model_dir,
    int32_t max_length,
    int32_t num_threads) {

  if (!model_dir) {
    SetError("model_dir is null");
    return nullptr;
  }

  fprintf(stderr, "[opus-mt] create_translator: model_dir=%s max_len=%d threads=%d\n",
          model_dir, max_length, num_threads);

  auto* handle = new OpusMtTranslatorHandle();
  handle->model_dir = model_dir;

  opus_mt::OpusMtConfig& cfg = handle->config;

  // Helper: pick the first existing file from candidates.
  auto findModelFile = [&](std::initializer_list<std::string> names) -> std::string {
    for (const auto& name : names) {
      std::string path = JoinPath(model_dir, name);
      std::ifstream f(path);
      if (f.good()) return path;
    }
    // Default to the first name so the error message mentions it.
    return JoinPath(model_dir, *names.begin());
  };

  // Set model file paths from model_dir.
  // Supports both HuggingFace export names (encoder.onnx) and
  // model-manager-renamed names (encoder_model.onnx).
  cfg.encoder_path = findModelFile({"encoder.onnx", "encoder_model.onnx"});
  cfg.decoder_path = findModelFile({"decoder.onnx", "decoder_model.onnx"});
  cfg.vocab_path = JoinPath(model_dir, "vocab.json");

  // Optional SentencePiece model files.
  std::string source_spm = JoinPath(model_dir, "source.spm");
  std::string target_spm = JoinPath(model_dir, "target.spm");
  {
    std::ifstream f(source_spm);
    if (f.good()) {
      cfg.source_spm_path = source_spm;
      // If source.spm exists, prefer SentencePiece mode.
      cfg.use_sentencepiece = true;
    }
  }
  {
    std::ifstream f(target_spm);
    if (f.good()) cfg.target_spm_path = target_spm;
  }

  // Override from config.json if it exists.
  LoadConfigJson(model_dir, cfg);

  // Override with caller-specified parameters.
  if (max_length > 0) cfg.max_length = max_length;
  if (num_threads > 0) {
    cfg.intra_op_num_threads = num_threads;
    cfg.inter_op_num_threads = num_threads;
  }

  fprintf(stderr, "[opus-mt] Calling translator.Init()...\n");
  if (!handle->translator.Init(cfg)) {
    const auto& inner = handle->translator.LastError();
    SetError("Failed to init translator for: " + std::string(model_dir) +
             (inner.empty() ? "" : " — " + inner));
    fprintf(stderr, "[opus-mt] Init FAILED: %s\n", inner.c_str());
    delete handle;
    return nullptr;
  }
  fprintf(stderr, "[opus-mt] Init OK\n");

  return handle;
}

const char* opus_mt_translate(
    OpusMtTranslatorHandle* handle,
    const char* source_text) {

  if (!handle) {
    SetError("handle is null");
    return nullptr;
  }
  if (!source_text) {
    SetError("source_text is null");
    return nullptr;
  }
  if (!handle->translator.IsReady()) {
    SetError("translator is not ready");
    return nullptr;
  }

  std::string result = handle->translator.Translate(source_text);
  if (result.empty()) {
    SetError("translation produced empty result");
    return nullptr;
  }

  // Allocate C string that the caller must free with opus_mt_free_string().
  char* cstr = new char[result.size() + 1];
  std::memcpy(cstr, result.c_str(), result.size() + 1);
  return cstr;
}

const char* opus_mt_translate_streaming(
    OpusMtTranslatorHandle* handle,
    const char* source_text,
    opus_mt_token_callback on_token,
    void* user_data) {

  if (!handle) {
    SetError("handle is null");
    return nullptr;
  }
  if (!source_text) {
    SetError("source_text is null");
    return nullptr;
  }
  if (!handle->translator.IsReady()) {
    SetError("translator is not ready");
    return nullptr;
  }

  std::string result = handle->translator.TranslateStreaming(
      source_text, on_token, user_data);
  if (result.empty()) {
    SetError("translation produced empty result");
    return nullptr;
  }

  char* cstr = new char[result.size() + 1];
  std::memcpy(cstr, result.c_str(), result.size() + 1);
  return cstr;
}

int32_t opus_mt_is_ready(const OpusMtTranslatorHandle* handle) {
  if (!handle) return 0;
  return handle->translator.IsReady() ? 1 : 0;
}

void opus_mt_destroy_translator(OpusMtTranslatorHandle* handle) {
  if (handle) {
    handle->translator.Release();
    delete handle;
  }
}

void opus_mt_free_string(const char* str) {
  delete[] str;
}

const char* opus_mt_last_error() {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  if (g_last_error.empty()) return nullptr;
  return g_last_error.c_str();
}
