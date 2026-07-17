#ifndef SIMULST_CONFIG_H_
#define SIMULST_CONFIG_H_

#include <algorithm>
#include <cstdint>
#include <string>

namespace simulst {

enum class SimulstTaskKind {
  kTranscribe,
  kTranslate,
};

inline bool IsAutoLang(const std::string& lang) {
  return lang.empty() || lang == "auto";
}

inline std::string BuildTranscribePrompt(const std::string& lang) {
  if (IsAutoLang(lang)) {
    return "Transcribe the audio: ";
  }
  return "Transcribe the audio in " + lang + ": ";
}

inline std::string BuildTranslatePrompt(const std::string& lang) {
  return "Translate the audio in " + lang + ": ";
}

struct SimulstConfig {
  // Model export directory containing metadata.json, speechllm_meta.json,
  // encoder ONNX, GGUF, init_states.npz, and special_token_input_patch.npz.
  std::string export_dir;

  // Task toggles: at least one must be enabled.
  bool enable_transcribe = false;
  bool enable_translate = true;

  // Language names as used in training prompts, e.g. "English", "Chinese".
  // transcribe_lang may be "auto" for the generic transcribe prompt.
  std::string transcribe_lang = "auto";
  std::string translate_lang = "English";

  // Legacy single-prompt override. When non-empty and only translate is
  // enabled, this replaces BuildTranslatePrompt(translate_lang).
  std::string prompt;

  // Decoder options.
  int32_t n_ctx = 8192;
  int32_t n_batch = 512;
  int32_t n_threads = 4;
  int32_t n_gpu_layers = -1;
  int32_t max_new_tokens = 32;
  float repetition_penalty = 1.0f;
  float first_token_eos_threshold = 1.0f;
  int32_t punct_kv_mode = 1;
  bool eos_penalty_only_last_chunk = false;

  // When true, LLM KV cache survives VAD segment boundaries so multi-utterance
  // sessions keep decoder context. Pipeline Reset() still clears KV.
  bool keep_kv_across_segments = true;

  // When true, clear LLM KV after a decoded sentence ends with . ? ! 。 ？ ！
  // so the next utterance re-injects the prompt. Independent of
  // keep_kv_across_segments (VAD-boundary KV retention).
  bool clear_kv_on_sentence_punct = false;

  // Optional cap on VAD segments before forcibly clearing LLM KV (0 = unlimited).
  int32_t max_llm_segments = 0;

  // Number of ONNX encoder steps to batch before each LLM prefill (Python num_chunks).
  // embed_chunk_size is derived as num_chunks * encoder_embed_frames_per_step unless
  // embed_chunk_size is set explicitly (> 0).
  int32_t num_chunks = 1;

  // Base segment budget at num_chunks=1. Effective max_llm_segments =
  // max_llm_kv_segments_base / num_chunks (unless max_llm_segments > 0).
  int32_t max_llm_kv_segments_base = 64;

  // Explicit LLM embed-frame chunk size. Leave 0 to derive from num_chunks.
  int32_t embed_chunk_size = 0;

  // ONNX encoder execution provider: "auto", "coreml", or "cpu".
  // On Apple, "auto" tries CoreML first and falls back to CPU.
  std::string encoder_provider = "auto";
  int32_t encoder_num_threads = 1;

  // VAD (silero) - same schema as voice_engine.
  std::string vad_model;
  float vad_threshold = 0.5f;
  float vad_min_silence_duration = 0.5f;
  float vad_min_speech_duration = 0.25f;
  int32_t vad_window_size = 512;
  float vad_max_speech_duration = 20.0f;
  int32_t vad_sample_rate = 16000;
  int32_t vad_num_threads = 1;
  float vad_buffer_size_seconds = 60.0f;

  int32_t circular_buffer_capacity = 480000;
  int32_t max_pre_speech_samples = 8000;
  int32_t max_post_speech_samples = 8000;

  std::string PromptForTask(SimulstTaskKind kind) const {
    if (kind == SimulstTaskKind::kTranscribe) {
      return BuildTranscribePrompt(transcribe_lang);
    }
    if (!prompt.empty()) {
      return prompt;
    }
    return BuildTranslatePrompt(translate_lang);
  }

  int32_t DecoderThreadsPerTask() const {
    const int32_t n_tasks =
        static_cast<int32_t>(enable_transcribe) + static_cast<int32_t>(enable_translate);
    if (n_tasks <= 1 || n_threads <= 0) {
      return n_threads;
    }
    return std::max(1, n_threads / n_tasks);
  }

  bool ClearKvOnSentenceEnd() const { return clear_kv_on_sentence_punct; }

  int32_t EffectiveNumChunks() const { return std::max(1, num_chunks); }

  int32_t EffectiveEmbedChunkSize(int32_t embed_frames_per_encoder_step) const {
    if (embed_chunk_size > 0) return embed_chunk_size;
    return EffectiveNumChunks() * std::max(1, embed_frames_per_encoder_step);
  }

  int32_t EffectiveMaxLlmSegments() const {
    if (max_llm_segments > 0) return max_llm_segments;
    return std::max(1, max_llm_kv_segments_base / EffectiveNumChunks());
  }
};

}  // namespace simulst

#endif  // SIMULST_CONFIG_H_
