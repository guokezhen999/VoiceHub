#ifndef MARIAN_TRANSLATOR_H_
#define MARIAN_TRANSLATOR_H_

#include <memory>
#include <string>
#include <vector>

#include "marian_config.h"
#include "marian_tokenizer.h"

// Forward-declare ONNX Runtime types to avoid leaking headers.
namespace Ort {
class Env;
class Session;
class MemoryInfo;
struct Value;
}  // namespace Ort

namespace marian {

// Beam search hypothesis.
struct Hypothesis {
  std::vector<int64_t> token_ids;
  float score = 0.0f;
  bool finished = false;
};

// Main Marian NMT translator engine.
//
// Pipeline:
//   raw text → [MarianTokenizer::Encode] → token IDs
//   → [EncoderSession::Run] → encoder hidden states
//   → [Decoder autoregressive loop] → predicted IDs
//   → [MarianTokenizer::Decode] → translated text
class MarianTranslator {
 public:
  MarianTranslator();
  ~MarianTranslator();

  MarianTranslator(const MarianTranslator&) = delete;
  MarianTranslator& operator=(const MarianTranslator&) = delete;

  // Initialize with configuration. Loads ONNX models and vocabulary.
  // Returns true on success.
  bool Init(const MarianConfig& config);

  // Translate source text. Returns translated text.
  // Returns empty string on failure.
  std::string Translate(std::string_view source_text);

  // Check if the translator is initialized and ready.
  bool IsReady() const { return ready_; }

  // Get the last error message (set when Init or Translate fails).
  const std::string& LastError() const { return last_error_; }

  // Release all resources.
  void Release();

 private:
  bool InitOnnx(const MarianConfig& config);
  bool InitTokenizer(const MarianConfig& config);

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

  MarianConfig config_;
  MarianTokenizer tokenizer_;
  bool ready_ = false;
  std::string last_error_;

  // ONNX Runtime objects (opaque via unique_ptr).
  struct OnnxState;
  std::unique_ptr<OnnxState> onnx_;
};

}  // namespace marian

#endif  // MARIAN_TRANSLATOR_H_
