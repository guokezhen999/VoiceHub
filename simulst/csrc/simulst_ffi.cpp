#include "simulst_ffi.h"

#include <cstring>
#include <mutex>
#include <string>

#include "nlohmann/json.hpp"
#include "simulst_config.h"
#include "streaming_ast_pipeline.h"

namespace {

std::mutex g_error_mutex;
std::string g_last_error;

void SetError(const std::string& msg) {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  g_last_error = msg;
}

const char* ToHeap(const std::string& s) {
  char* buf = new char[s.size() + 1];
  std::memcpy(buf, s.c_str(), s.size() + 1);
  return buf;
}

bool ParseBoolField(const nlohmann::json& j, const char* key, bool default_value) {
  if (!j.contains(key)) return default_value;
  if (j[key].is_boolean()) return j[key].get<bool>();
  if (j[key].is_number_integer()) return j[key].get<int>() != 0;
  if (j[key].is_string()) {
    const std::string s = j[key].get<std::string>();
    return s == "1" || s == "true" || s == "True" || s == "TRUE";
  }
  return default_value;
}

void ApplyJsonToConfig(const nlohmann::json& j, simulst::SimulstConfig* cfg,
                       bool allow_legacy_prompt_only) {
  cfg->export_dir = j.value("export_dir", cfg->export_dir);
  cfg->enable_transcribe = ParseBoolField(j, "enable_transcribe", cfg->enable_transcribe);
  cfg->enable_translate = ParseBoolField(j, "enable_translate", cfg->enable_translate);
  cfg->transcribe_lang = j.value("transcribe_lang", cfg->transcribe_lang);
  cfg->translate_lang = j.value("translate_lang", cfg->translate_lang);
  cfg->prompt = j.value("prompt", cfg->prompt);

  cfg->n_ctx = j.value("n_ctx", cfg->n_ctx);
  cfg->n_batch = j.value("n_batch", cfg->n_batch);
  cfg->n_threads = j.value("n_threads", cfg->n_threads);
  cfg->n_gpu_layers = j.value("n_gpu_layers", cfg->n_gpu_layers);
  cfg->max_new_tokens = j.value("max_new_tokens", cfg->max_new_tokens);
  cfg->repetition_penalty = j.value("repetition_penalty", cfg->repetition_penalty);
  cfg->first_token_eos_threshold = j.value("first_token_eos_threshold", cfg->first_token_eos_threshold);
  cfg->punct_kv_mode = j.value("punct_kv_mode", cfg->punct_kv_mode);
  cfg->eos_penalty_only_last_chunk =
      ParseBoolField(j, "eos_penalty_only_last_chunk", cfg->eos_penalty_only_last_chunk);
  cfg->keep_kv_across_segments =
      ParseBoolField(j, "keep_kv_across_segments", cfg->keep_kv_across_segments);
  cfg->clear_kv_on_sentence_punct =
      ParseBoolField(j, "clear_kv_on_sentence_punct", cfg->clear_kv_on_sentence_punct);
  cfg->max_llm_segments = j.value("max_llm_segments", cfg->max_llm_segments);
  cfg->num_chunks = j.value("num_chunks", cfg->num_chunks);
  cfg->max_llm_kv_segments_base = j.value("max_llm_kv_segments_base", cfg->max_llm_kv_segments_base);
  cfg->keep_recent_segments = j.value("keep_recent_segments", cfg->keep_recent_segments);
  cfg->embed_chunk_size = j.value("embed_chunk_size", cfg->embed_chunk_size);
  cfg->encoder_provider = j.value("encoder_provider", cfg->encoder_provider);
  cfg->encoder_num_threads = j.value("encoder_num_threads", cfg->encoder_num_threads);

  if (j.contains("vad")) {
    const auto& v = j["vad"];
    cfg->vad_model = v.value("model", cfg->vad_model);
    cfg->vad_threshold = v.value("threshold", cfg->vad_threshold);
    cfg->vad_min_silence_duration = v.value("min_silence_duration", cfg->vad_min_silence_duration);
    cfg->vad_min_speech_duration = v.value("min_speech_duration", cfg->vad_min_speech_duration);
    cfg->vad_window_size = v.value("window_size", cfg->vad_window_size);
    cfg->vad_max_speech_duration = v.value("max_speech_duration", cfg->vad_max_speech_duration);
    cfg->vad_sample_rate = v.value("sample_rate", cfg->vad_sample_rate);
    cfg->vad_num_threads = v.value("num_threads", cfg->vad_num_threads);
    cfg->vad_buffer_size_seconds = v.value("buffer_size_seconds", cfg->vad_buffer_size_seconds);
  }
  if (j.contains("vad_model")) {
    cfg->vad_model = j.value("vad_model", cfg->vad_model);
  }

  cfg->circular_buffer_capacity = j.value("circular_buffer_capacity", cfg->circular_buffer_capacity);
  cfg->max_pre_speech_samples = j.value("max_pre_speech_samples", cfg->max_pre_speech_samples);
  cfg->max_post_speech_samples = j.value("max_post_speech_samples", cfg->max_post_speech_samples);

  if (allow_legacy_prompt_only && j.contains("prompt") && !j.contains("enable_transcribe") &&
      !j.contains("enable_translate")) {
    cfg->enable_translate = true;
    cfg->enable_transcribe = false;
    if (cfg->prompt.empty()) {
      cfg->prompt = "Translate the audio: ";
    }
  }

  if (!cfg->enable_transcribe && !cfg->enable_translate) {
    cfg->enable_translate = true;
    if (cfg->prompt.empty()) {
      cfg->prompt = "Translate the audio: ";
    }
  }
}

}  // namespace

struct SimulstHandle {
  simulst::StreamingAstPipeline pipeline;
};

SimulstHandle* simulst_create(const char* json_config) {
  g_last_error.clear();
  if (!json_config) {
    SetError("json_config is null");
    return nullptr;
  }

  simulst::SimulstConfig cfg;
  try {
    nlohmann::json j = nlohmann::json::parse(json_config);
    ApplyJsonToConfig(j, &cfg, true);
  } catch (const std::exception& e) {
    SetError(std::string("invalid json config: ") + e.what());
    return nullptr;
  }

  auto* handle = new SimulstHandle();
  if (!handle->pipeline.Init(cfg)) {
    SetError(handle->pipeline.LastError());
    delete handle;
    return nullptr;
  }
  return handle;
}

int32_t simulst_set_tasks(SimulstHandle* handle, const char* json_tasks) {
  if (!handle) {
    SetError("handle is null");
    return 0;
  }
  if (!json_tasks) {
    SetError("json_tasks is null");
    return 0;
  }

  simulst::SimulstConfig cfg = handle->pipeline.Config();

  try {
    nlohmann::json j = nlohmann::json::parse(json_tasks);
    if (j.contains("enable_transcribe")) {
      cfg.enable_transcribe = ParseBoolField(j, "enable_transcribe", cfg.enable_transcribe);
    }
    if (j.contains("enable_translate")) {
      cfg.enable_translate = ParseBoolField(j, "enable_translate", cfg.enable_translate);
    }
    if (j.contains("transcribe_lang")) {
      cfg.transcribe_lang = j.value("transcribe_lang", cfg.transcribe_lang);
    }
    if (j.contains("translate_lang")) {
      cfg.translate_lang = j.value("translate_lang", cfg.translate_lang);
    }
    if (j.contains("prompt")) {
      cfg.prompt = j.value("prompt", cfg.prompt);
    }
  } catch (const std::exception& e) {
    SetError(std::string("invalid json tasks: ") + e.what());
    return 0;
  }

  if (!cfg.enable_transcribe && !cfg.enable_translate) {
    SetError("at least one of enable_transcribe or enable_translate must be true");
    return 0;
  }

  if (!handle->pipeline.SetTasks(cfg)) {
    SetError(handle->pipeline.LastError());
    return 0;
  }
  return 1;
}

void simulst_accept_waveform(SimulstHandle* handle, const float* samples, int32_t n) {
  if (!handle) return;
  handle->pipeline.AcceptWaveform(samples, n);
}

const char* simulst_poll(SimulstHandle* handle) {
  if (!handle) {
    SetError("handle is null");
    return nullptr;
  }
  return ToHeap(handle->pipeline.PollJson());
}

void simulst_flush(SimulstHandle* handle) {
  if (!handle) return;
  handle->pipeline.Flush();
}

void simulst_reset(SimulstHandle* handle) {
  if (!handle) return;
  handle->pipeline.Reset();
}

void simulst_destroy(SimulstHandle* handle) { delete handle; }

void simulst_free_string(const char* str) { delete[] str; }

const char* simulst_last_error() {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  if (g_last_error.empty()) return nullptr;
  return g_last_error.c_str();
}
