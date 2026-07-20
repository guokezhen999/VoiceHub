#ifndef STREAMING_AST_PIPELINE_H_
#define STREAMING_AST_PIPELINE_H_

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "simulst_config.h"
#include "llama_gguf_decoder.h"

struct SherpaOnnxVoiceActivityDetector;
struct SherpaOnnxCircularBuffer;
struct SherpaOnnxSpeechSegment;

namespace simulst {

class OnnxStreamingEncoder;
class FbankExtractor;

struct TaskDecoderState {
  SimulstTaskKind kind = SimulstTaskKind::kTranslate;
  std::string prompt;
  std::unique_ptr<LlamaGgufDecoder> decoder;
  std::string partial;
};

// Streaming speech-to-text pipeline:
// circular buffer + VAD + fbank + ONNX encoder + one or more GGUF decoders.
class StreamingAstPipeline {
 public:
  StreamingAstPipeline();
  ~StreamingAstPipeline();

  StreamingAstPipeline(const StreamingAstPipeline&) = delete;
  StreamingAstPipeline& operator=(const StreamingAstPipeline&) = delete;

  bool Init(const SimulstConfig& config);
  bool SetTasks(const SimulstConfig& config);

  struct FinalizedSegment {
    std::string transcript;
    std::string translation;
    double start_sec = 0.0;
    double end_sec = 0.0;
  };

  void AcceptWaveform(const float* samples, int32_t n);
  void Flush();
  void Reset();

  std::string PollJson();
  const std::string& LastError() const { return last_error_; }
  const SimulstConfig& Config() const { return config_; }

 private:
  void Release();
  bool InitDecoders(std::string* error);
  void ResolveStreamingChunkParams();
  void MaybeEvictLlmKvBySegmentLimit();
  void BeginSegment();
  void EndSegment(FinalizedSegment* out);
  void ProcessSpeechWindow(const float* samples, int32_t n, bool llm_decode = true);
  void DrainCircularBufferTail();
  void PadAudioTailForEncoder();
  void DrainFbankAndEncoder(bool allow_partial = true);
  void MaybeDecodeChunks(bool is_last_chunk, int32_t max_embed_frames = -1);
  void FinalizeVadSegment(const SherpaOnnxSpeechSegment* seg);
  bool LoadMeta(const std::string& export_dir);
  const TaskDecoderState* FindTaskDecoder(SimulstTaskKind kind) const;
  TaskDecoderState* FindTaskDecoder(SimulstTaskKind kind);
  std::string PartialForTask(SimulstTaskKind kind) const;

  SimulstConfig config_;
  std::unique_ptr<OnnxStreamingEncoder> encoder_;
  std::shared_ptr<LlamaGgufModel> shared_llm_;
  std::vector<TaskDecoderState> task_decoders_;
  std::unique_ptr<FbankExtractor> fbank_;

  const SherpaOnnxVoiceActivityDetector* vad_ = nullptr;
  const SherpaOnnxCircularBuffer* circular_buffer_ = nullptr;

  std::vector<std::vector<float>> pre_speech_;
  int32_t pre_speech_size_ = 0;
  int32_t post_speech_size_ = 0;
  bool vad_ever_detected_ = false;
  bool in_segment_ = false;

  int32_t encoder_step_ = 0;
  int32_t last_decoded_embed_idx_ = 0;
  int32_t chunk_index_ = 0;
  bool fbank_finished_ = false;
  int32_t llm_segment_count_ = 0;
  int32_t resolved_embed_chunk_size_ = 0;
  int32_t resolved_max_llm_segments_ = 0;
  int32_t llm_embed_cap_ = -1;

  bool speaking_ = false;
  std::deque<FinalizedSegment> finalized_;

  SpeechLlmMeta llm_meta_;
  std::string gguf_path_;
  std::string last_error_;
  std::vector<float> last_real_samples_;
};

}  // namespace simulst

#endif  // STREAMING_AST_PIPELINE_H_
