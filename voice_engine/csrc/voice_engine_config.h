#ifndef VOICE_ENGINE_CONFIG_H_
#define VOICE_ENGINE_CONFIG_H_

#include <cstdint>
#include <string>

namespace voice_engine {

enum class AsrMode { kOnline, kOffline };

struct VoiceEngineConfig {
  AsrMode mode = AsrMode::kOnline;

  // ASR model files (transducer: encoder/decoder/joiner + tokens)
  std::string encoder;
  std::string decoder;
  std::string joiner;
  std::string tokens;
  std::string model_type;                  // e.g. "zipformer2"
  std::string decoding_method = "greedy_search";
  int32_t num_threads = 1;

  // VAD (silero)
  std::string vad_model;
  float vad_threshold = 0.5f;
  float vad_min_silence_duration = 0.5f;
  float vad_min_speech_duration = 0.25f;
  int32_t vad_window_size = 512;
  float vad_max_speech_duration = 20.0f;
  int32_t vad_sample_rate = 16000;
  int32_t vad_num_threads = 1;
  float vad_buffer_size_seconds = 60.0f;

  // Endpoint (online)
  bool enable_endpoint = true;
  float rule1_min_trailing_silence = 2.4f;
  float rule2_min_trailing_silence = 1.0f;

  // Buffers
  int32_t circular_buffer_capacity = 480000;  // 30s * 16k
  int32_t max_pre_speech_samples = 8000;       // 0.5s
};

}  // namespace voice_engine

#endif  // VOICE_ENGINE_CONFIG_H_
