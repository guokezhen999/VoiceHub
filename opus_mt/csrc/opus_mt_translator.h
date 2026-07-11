#ifndef OPUS_MT_TRANSLATOR_H_
#define OPUS_MT_TRANSLATOR_H_

#include <memory>
#include <string>
#include <vector>

#include "opus_mt_config.h"
#include "opus_mt_tokenizer.h"

// Forward-declare ONNX Runtime types to avoid leaking headers.
namespace Ort {
class Env;
class Session;
class MemoryInfo;
struct Value;
}  // namespace Ort

namespace opus_mt {

// Beam search hypothesis.
struct Hypothesis {
  std::vector<int64_t> token_ids;
  float score = 0.0f;
  bool finished = false;
};

// Main opus-mt translator engine.
//
// Pipeline:
//   raw text → [OpusMtTokenizer::Encode] → token IDs
//   → [EncoderSession::Run] → encoder hidden states
//   → [Decoder autoregressive loop] → predicted IDs
//   → [OpusMtTokenizer::Decode] → translated text
class OpusMtTranslator {
 public:
  OpusMtTranslator();
  ~OpusMtTranslator();

  OpusMtTranslator(const OpusMtTranslator&) = delete;
  OpusMtTranslator& operator=(const OpusMtTranslator&) = delete;

  // Initialize with configuration. Loads ONNX models and vocabulary.
  // Returns true on success.
  bool Init(const OpusMtConfig& config);

  // Translate source text. Returns translated text.
  // Returns empty string on failure.
  std::string Translate(std::string_view source_text);

  // Translate with per-token streaming callbacks.
  // on_token is called after each decoder step with the cumulative partial
  // detokenized text. user_data is passed through to the callback.
  // Returns a JSON string with the final text and timing metrics.
  // Streaming only works for greedy decoding (num_beams == 1).
  std::string TranslateStreaming(
      std::string_view source_text,
      void (*on_token)(const char*, void*),
      void* user_data);

  // Check if the translator is initialized and ready.
  bool IsReady() const { return ready_; }

  // Get the last error message (set when Init or Translate fails).
  const std::string& LastError() const { return last_error_; }

  // Release all resources.
  void Release();

 private:
  bool InitOnnx(const OpusMtConfig& config);
  bool InitTokenizer(const OpusMtConfig& config);

  // Run the encoder: input_ids → encoder_hidden_states
  std::vector<float> RunEncoder(const std::vector<int64_t>& input_ids,
                                 const std::vector<int64_t>& attention_mask);

  // Run a single decoder step.
  std::vector<float> RunDecoderStep(const std::vector<int64_t>& decoder_input_ids,
                                     const std::vector<float>& encoder_hidden_states,
                                     const std::vector<int64_t>& encoder_attention_mask);

  // Greedy decoding: pick the highest-probability token at each step.
  std::vector<int32_t> GreedyDecode(
      const std::vector<float>& encoder_hidden_states,
      const std::vector<int64_t>& encoder_attention_mask);

  // Beam search decoding.
  std::vector<int32_t> BeamSearchDecode(
      const std::vector<float>& encoder_hidden_states,
      const std::vector<int64_t>& encoder_attention_mask);

  // Softmax over logits.
  static void Softmax(float* data, int32_t size);

  // Top-k sampling from logits.
  static int32_t Argmax(const float* data, int32_t size);

  OpusMtConfig config_;
  OpusMtTokenizer tokenizer_;
  bool ready_ = false;
  std::string last_error_;

  // ONNX Runtime objects (opaque via unique_ptr).
  struct OnnxState;
  std::unique_ptr<OnnxState> onnx_;
};

}  // namespace opus_mt

#endif  // OPUS_MT_TRANSLATOR_H_
