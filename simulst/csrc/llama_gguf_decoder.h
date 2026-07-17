#ifndef LLAMA_GGUF_DECODER_H_
#define LLAMA_GGUF_DECODER_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

struct llama_context;
struct llama_model;
struct llama_vocab;

namespace simulst {

using StreamPartialFn = std::function<void(const std::string&)>;

struct SpeechLlmMeta {
  int32_t llm_dim = 1024;
  int32_t token_a_id = 0;
  int32_t token_a_end_id = 0;
  int32_t token_w_id = 0;
  std::vector<float> emb_a;
  std::vector<float> emb_a_end;
};

// Shared GGUF weights + token embedding table. One instance per export_dir.
class LlamaGgufModel {
 public:
  ~LlamaGgufModel();

  LlamaGgufModel(const LlamaGgufModel&) = delete;
  LlamaGgufModel& operator=(const LlamaGgufModel&) = delete;

  static std::shared_ptr<LlamaGgufModel> Load(const std::string& gguf_path,
                                              const SpeechLlmMeta& meta,
                                              int32_t n_gpu_layers,
                                              std::string* error);

  llama_model* model() const { return model_; }
  const llama_vocab* vocab() const { return vocab_; }
  int32_t n_embd() const { return n_embd_; }
  int32_t n_vocab() const { return n_vocab_; }
  const std::vector<float>& token_embd() const { return token_embd_; }

 private:
  LlamaGgufModel() = default;
  bool LoadTokenEmbdTable(const std::string& gguf_path, std::string* error);

  llama_model* model_ = nullptr;
  const llama_vocab* vocab_ = nullptr;
  int32_t n_embd_ = 0;
  int32_t n_vocab_ = 0;
  std::vector<float> token_embd_;
};

class LlamaGgufDecoder {
 public:
  LlamaGgufDecoder() = default;
  ~LlamaGgufDecoder();

  LlamaGgufDecoder(const LlamaGgufDecoder&) = delete;
  LlamaGgufDecoder& operator=(const LlamaGgufDecoder&) = delete;

  bool Init(const std::string& gguf_path, const SpeechLlmMeta& meta, int32_t n_ctx,
            int32_t n_batch, int32_t n_threads, int32_t n_gpu_layers,
            std::string* error);

  bool InitFromSharedModel(const std::shared_ptr<LlamaGgufModel>& model,
                           const SpeechLlmMeta& meta, int32_t n_ctx, int32_t n_batch,
                           int32_t n_threads, std::string* error);

  void Reset();

  int32_t NPast() const { return n_past_; }

  // Incremental streaming decode matching python_ref/llama_gguf_decoder.feed_chunk().
  // Invokes [on_partial] with cumulative chunk text after each generated token.
  std::string FeedChunk(const std::string& prompt, const float* audio_embeds,
                        int32_t num_frames, int32_t max_new_tokens,
                        float repetition_penalty, float first_token_eos_threshold,
                        int32_t punct_kv_mode, bool is_new_segment,
                        bool is_segment_end, bool eos_penalty_only_last_chunk,
                        bool clear_kv_on_sentence_end,
                        const StreamPartialFn& on_partial = nullptr);

  std::string GenerateChunk(const std::string& prompt, const float* audio_embeds,
                            int32_t num_frames, int32_t max_new_tokens,
                            float repetition_penalty,
                            float first_token_eos_threshold, int32_t punct_kv_mode,
                            bool is_first_chunk, bool is_last_chunk,
                            bool eos_penalty_only_last_chunk);

  static bool EndsWithSentencePunct(const std::string& text);

 private:
  bool InitContext(const SpeechLlmMeta& meta, int32_t n_ctx, int32_t n_batch,
                   int32_t n_threads, std::string* error);
  std::vector<float> EmbedText(const std::string& text) const;
  std::vector<float> EmbedTokenId(int32_t token_id) const;
  void PrefillEmbeddings(const float* embeddings, int32_t num_frames,
                         bool want_logits);
  std::string AutoregressAfterAEnd(int32_t max_new_tokens,
                                   float repetition_penalty,
                                   float first_token_eos_threshold,
                                   int32_t punct_kv_mode,
                                   bool apply_first_token_eos_threshold,
                                   const StreamPartialFn& on_partial = nullptr);
  std::string MaybeEvictCache(std::string text);
  std::vector<float> SampleLogits() const;
  void TruncateKv(int32_t remove_len);
  static int32_t ArgMax(const std::vector<float>& logits);
  static std::vector<float> Softmax(const std::vector<float>& logits);

  std::shared_ptr<LlamaGgufModel> shared_model_;
  std::shared_ptr<LlamaGgufModel> owned_model_;
  llama_context* ctx_ = nullptr;

  SpeechLlmMeta meta_;
  int32_t n_ctx_ = 8192;
  int32_t n_batch_ = 512;
  int32_t n_embd_ = 0;
  int32_t n_vocab_ = 0;
  int32_t n_past_ = 0;
  int32_t prompt_kv_len_ = -1;
  int32_t segment_count_ = 0;
};

}  // namespace simulst

#endif  // LLAMA_GGUF_DECODER_H_
