#ifndef STREAMING_ASR_PIPELINE_H_
#define STREAMING_ASR_PIPELINE_H_

#include <cstdint>
#include <deque>
#include <string>
#include <vector>

#include "voice_engine_config.h"

// Forward declarations of sherpa-onnx C API opaque types.
struct SherpaOnnxOnlineRecognizer;
struct SherpaOnnxOnlineStream;
struct SherpaOnnxOfflineRecognizer;
struct SherpaOnnxVoiceActivityDetector;
struct SherpaOnnxCircularBuffer;

namespace voice_engine {

// Owns the full streaming ASR state machine: circular buffer + VAD +
// (online stream | offline recognizer), pre-speech sliding window, endpoint
// handling. Mirrors the previous Dart logic in cascade_translation_screen.dart.
class StreamingAsrPipeline {
 public:
  StreamingAsrPipeline() = default;
  ~StreamingAsrPipeline();

  StreamingAsrPipeline(const StreamingAsrPipeline&) = delete;
  StreamingAsrPipeline& operator=(const StreamingAsrPipeline&) = delete;

  bool Init(const VoiceEngineConfig& config);

  // Feed 16kHz mono float32 samples.
  void AcceptWaveform(const float* samples, int32_t n);

  // Called when recording stops: finalize the remaining online result.
  void Flush();

  // Reset for a new utterance session.
  void Reset();

  // Returns JSON: {"speaking":bool,"partial":"..","finalized":["..",...]}.
  // Drains the finalized queue.
  std::string PollJson();

  const std::string& LastError() const { return last_error_; }

 private:
  void Release();
  void RecreateOnlineStream();
  std::string GetOnlineText();

  VoiceEngineConfig config_;

  const SherpaOnnxOnlineRecognizer* online_recognizer_ = nullptr;
  const SherpaOnnxOnlineStream* online_stream_ = nullptr;
  const SherpaOnnxOfflineRecognizer* offline_recognizer_ = nullptr;
  const SherpaOnnxVoiceActivityDetector* vad_ = nullptr;
  const SherpaOnnxCircularBuffer* circular_buffer_ = nullptr;

  // Pre-speech sliding window (replayed on first VAD trigger).
  std::vector<std::vector<float>> pre_speech_;
  int32_t pre_speech_size_ = 0;
  bool vad_ever_detected_ = false;

  // Result state.
  std::string partial_;
  std::deque<std::string> finalized_;
  bool speaking_ = false;

  std::string last_error_;
};

}  // namespace voice_engine

#endif  // STREAMING_ASR_PIPELINE_H_
