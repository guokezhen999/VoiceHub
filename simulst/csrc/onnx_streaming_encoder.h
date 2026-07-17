#ifndef ONNX_STREAMING_ENCODER_H_
#define ONNX_STREAMING_ENCODER_H_

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace simulst {

class OnnxStreamingEncoder {
 public:
  OnnxStreamingEncoder() = default;
  ~OnnxStreamingEncoder();

  OnnxStreamingEncoder(const OnnxStreamingEncoder&) = delete;
  OnnxStreamingEncoder& operator=(const OnnxStreamingEncoder&) = delete;

  bool Init(const std::string& export_dir, const std::string& provider,
            int32_t num_threads, std::string* error);

  const std::string& ActiveProvider() const { return active_provider_; }

  void Reset();

  // Feed one chunk of fbank features shaped (T, feature_dim).
  bool FeedFeatures(const float* features, int32_t num_frames, std::string* error);

  int32_t TotalEmbedFrames() const;

  // Copy [start, end) embedding frames into out (flattened row-major).
  bool GetEmbeddings(int32_t start, int32_t end, std::vector<float>* out) const;

  int32_t FeatureDim() const { return feature_dim_; }
  int32_t LlmDim() const { return llm_dim_; }
  int32_t DecodeChunkLen() const { return decode_chunk_len_; }
  int32_t InputTimeSteps() const { return input_time_steps_; }
  // Embedding frames produced per ONNX encoder step (from metadata, fixed).
  int32_t EmbedFramesPerStep() const { return embed_frames_per_step_; }

 private:
  bool RunSession(const float* features, int32_t num_frames, std::string* error);
  bool WarmupRun(std::string* error);
  bool CreateSession(const std::string& onnx_path, const std::string& provider,
                     int32_t num_threads, std::string* error);

  int32_t feature_dim_ = 80;
  int32_t llm_dim_ = 1024;
  int32_t decode_chunk_len_ = 32;
  int32_t input_time_steps_ = 45;
  int32_t embed_frames_per_step_ = 0;

  std::map<std::string, std::vector<float>> init_float_states_;
  std::map<std::string, std::vector<int64_t>> init_int_states_;
  std::map<std::string, std::vector<float>> states_f32_;
  std::map<std::string, std::vector<int64_t>> states_i64_;
  std::map<std::string, std::vector<int64_t>> state_shapes_;
  std::vector<std::string> state_input_names_;
  std::vector<std::string> output_names_;

  std::vector<float> embed_storage_;
  int32_t total_embed_frames_ = 0;
  std::string active_provider_ = "cpu";

  class OrtHolder;
  OrtHolder* ort_ = nullptr;
};

}  // namespace simulst

#endif  // ONNX_STREAMING_ENCODER_H_
