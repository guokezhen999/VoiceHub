#ifndef OPUS_MT_CONFIG_H_
#define OPUS_MT_CONFIG_H_

#include <cstdint>
#include <string>

namespace opus_mt {

struct OpusMtConfig {
  // Model paths
  std::string encoder_path;
  std::string decoder_path;
  std::string vocab_path;       // vocab.json
  std::string source_spm_path;  // source.spm (SentencePiece model, optional)
  std::string target_spm_path;  // target.spm (SentencePiece model, optional)

  // Vocabulary special tokens
  int32_t pad_token_id = 65000;
  int32_t eos_token_id = 0;
  int32_t bos_token_id = 0;
  int32_t unk_token_id = 1;
  int32_t decoder_start_token_id = 65000;

  // Generation parameters
  int32_t max_length = 512;
  int32_t min_length = 1;

  // Model architecture (read from config.json)
  int32_t d_model = 512;
  int32_t encoder_layers = 6;
  int32_t decoder_layers = 6;
  int32_t encoder_attention_heads = 8;
  int32_t decoder_attention_heads = 8;
  int32_t decoder_ffn_dim = 2048;
  int32_t vocab_size = 65001;
  bool use_cache = true;

  // ONNX Runtime options
  int32_t intra_op_num_threads = 1;
  int32_t inter_op_num_threads = 1;
  int32_t graph_optimization_level = 1; // ORT_ENABLE_BASIC — safe for INT8 quantized models.
                                        // ORT_ENABLE_ALL (99) can cause hangs with
                                        // DynamicQuantizeLinear / MatMulInteger ops.

  // Whether to use SentencePiece model for tokenization (vs vocab.json max-match)
  bool use_sentencepiece = false;
};

}  // namespace opus_mt

#endif  // OPUS_MT_CONFIG_H_
