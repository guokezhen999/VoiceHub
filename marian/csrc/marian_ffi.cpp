#include "marian_ffi.h"
#include "marian_translator.h"

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
bool LoadConfigJson(const std::string& model_dir, marian::MarianConfig& cfg) {
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

  if (j.contains("pad_token_id")) cfg.pad_token_id = j["pad_token_id"].get<int32_t>();
  if (j.contains("eos_token_id")) cfg.eos_token_id = j["eos_token_id"].get<int32_t>();
  if (j.contains("bos_token_id")) cfg.bos_token_id = j["bos_token_id"].get<int32_t>();
  if (j.contains("decoder_start_token_id")) cfg.decoder_start_token_id = j["decoder_start_token_id"].get<int32_t>();
  if (j.contains("vocab_size")) cfg.vocab_size = j["vocab_size"].get<int32_t>();
  if (j.contains("d_model")) cfg.d_model = j["d_model"].get<int32_t>();
  if (j.contains("encoder_layers")) cfg.encoder_layers = j["encoder_layers"].get<int32_t>();
  if (j.contains("decoder_layers")) cfg.decoder_layers = j["decoder_layers"].get<int32_t>();
  if (j.contains("encoder_attention_heads")) cfg.encoder_attention_heads = j["encoder_attention_heads"].get<int32_t>();
  if (j.contains("decoder_attention_heads")) cfg.decoder_attention_heads = j["decoder_attention_heads"].get<int32_t>();
  if (j.contains("decoder_ffn_dim")) cfg.decoder_ffn_dim = j["decoder_ffn_dim"].get<int32_t>();
  if (j.contains("num_beams")) cfg.num_beams = j["num_beams"].get<int32_t>();
  if (j.contains("max_length")) cfg.max_length = j["max_length"].get<int32_t>();
  if (j.contains("use_cache")) cfg.use_cache = j["use_cache"].get<bool>();
  if (j.contains("max_position_embeddings")) cfg.max_length = j["max_position_embeddings"].get<int32_t>();
  if (j.contains("unk_token_id")) cfg.unk_token_id = j["unk_token_id"].get<int32_t>();

  return true;
}

}  // namespace

// The concrete translator handle wraps the C++ translator.
struct MarianTranslatorHandle {
  marian::MarianTranslator translator;
  marian::MarianConfig config;
  std::string model_dir;
};

MarianTranslatorHandle* marian_create_translator(
    const char* model_dir,
    int32_t num_beams,
    int32_t max_length,
    int32_t num_threads) {

  if (!model_dir) {
    SetError("model_dir is null");
    return nullptr;
  }

  auto* handle = new MarianTranslatorHandle();
  handle->model_dir = model_dir;

  marian::MarianConfig& cfg = handle->config;

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
  cfg.encoder_path = findModelFile({"encoder_model.onnx", "encoder.onnx"});
  cfg.decoder_path = findModelFile({"decoder_model.onnx", "decoder.onnx"});
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
  if (num_beams > 0) cfg.num_beams = num_beams;
  if (max_length > 0) cfg.max_length = max_length;
  if (num_threads > 0) {
    cfg.intra_op_num_threads = num_threads;
    cfg.inter_op_num_threads = num_threads;
  }

  if (!handle->translator.Init(cfg)) {
    const auto& inner = handle->translator.LastError();
    SetError("Failed to init translator for: " + std::string(model_dir) +
             (inner.empty() ? "" : " — " + inner));
    delete handle;
    return nullptr;
  }

  return handle;
}

const char* marian_translate(
    MarianTranslatorHandle* handle,
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

  // Allocate C string that the caller must free with marian_free_string().
  char* cstr = new char[result.size() + 1];
  std::memcpy(cstr, result.c_str(), result.size() + 1);
  return cstr;
}

int32_t marian_is_ready(const MarianTranslatorHandle* handle) {
  if (!handle) return 0;
  return handle->translator.IsReady() ? 1 : 0;
}

void marian_destroy_translator(MarianTranslatorHandle* handle) {
  if (handle) {
    handle->translator.Release();
    delete handle;
  }
}

void marian_free_string(const char* str) {
  delete[] str;
}

const char* marian_last_error() {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  if (g_last_error.empty()) return nullptr;
  return g_last_error.c_str();
}
