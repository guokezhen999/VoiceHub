#include "llama_gguf_decoder.h"

#include <algorithm>
#include <cstdio>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <vector>

#include "ggml.h"
#include "gguf.h"
#include "llama.h"

namespace simulst {
namespace {

static const char* kSentEnd = ".?!。？！";

}  // namespace

LlamaGgufModel::~LlamaGgufModel() {
  if (model_) {
    llama_model_free(model_);
    model_ = nullptr;
  }
}

bool LlamaGgufModel::LoadTokenEmbdTable(const std::string& gguf_path, std::string* error) {
  token_embd_.clear();

  ggml_context* ctx_meta = nullptr;
  gguf_init_params params{};
  params.no_alloc = true;
  params.ctx = &ctx_meta;
  gguf_context* ctx_gguf = gguf_init_from_file(gguf_path.c_str(), params);
  if (!ctx_gguf) {
    if (error) *error = "failed to open GGUF for token_embd: " + gguf_path;
    return false;
  }

  const int64_t tensor_id = gguf_find_tensor(ctx_gguf, "token_embd.weight");
  if (tensor_id < 0) {
    gguf_free(ctx_gguf);
    ggml_free(ctx_meta);
    if (error) *error = "token_embd.weight not found in " + gguf_path;
    return false;
  }

  ggml_tensor* tensor = ggml_get_tensor(ctx_meta, "token_embd.weight");
  const int64_t n_rows = tensor->ne[1] > 0 ? tensor->ne[1] : n_vocab_;
  const int64_t n_cols = tensor->ne[0] > 0 ? tensor->ne[0] : n_embd_;
  if (n_rows != n_vocab_ || n_cols != n_embd_) {
    gguf_free(ctx_gguf);
    ggml_free(ctx_meta);
    if (error) {
      *error = "unexpected token_embd.weight shape in " + gguf_path;
    }
    return false;
  }

  const size_t nbytes = gguf_get_tensor_size(ctx_gguf, tensor_id);
  std::vector<uint8_t> raw(nbytes);
  std::ifstream in(gguf_path, std::ios::binary);
  if (!in) {
    gguf_free(ctx_gguf);
    ggml_free(ctx_meta);
    if (error) *error = "failed to read GGUF file: " + gguf_path;
    return false;
  }
  const size_t offset =
      gguf_get_data_offset(ctx_gguf) + gguf_get_tensor_offset(ctx_gguf, tensor_id);
  in.seekg(static_cast<std::streamoff>(offset));
  in.read(reinterpret_cast<char*>(raw.data()), static_cast<std::streamsize>(nbytes));
  if (!in) {
    gguf_free(ctx_gguf);
    ggml_free(ctx_meta);
    if (error) *error = "failed to read token_embd.weight from " + gguf_path;
    return false;
  }

  token_embd_.resize(static_cast<size_t>(n_vocab_) * static_cast<size_t>(n_embd_));
  const auto tensor_type = gguf_get_tensor_type(ctx_gguf, tensor_id);
  if (tensor_type == GGML_TYPE_F16) {
    const auto* src = reinterpret_cast<const ggml_fp16_t*>(raw.data());
    for (int64_t i = 0; i < n_vocab_ * n_embd_; ++i) {
      token_embd_[static_cast<size_t>(i)] = ggml_fp16_to_fp32(src[i]);
    }
  } else if (tensor_type == GGML_TYPE_F32) {
    std::memcpy(token_embd_.data(), raw.data(),
                static_cast<size_t>(n_vocab_) * static_cast<size_t>(n_embd_) *
                    sizeof(float));
  } else {
    gguf_free(ctx_gguf);
    ggml_free(ctx_meta);
    if (error) *error = "unsupported token_embd dtype in " + gguf_path;
    return false;
  }

  gguf_free(ctx_gguf);
  ggml_free(ctx_meta);
  return true;
}

std::shared_ptr<LlamaGgufModel> LlamaGgufModel::Load(const std::string& gguf_path,
                                                     const SpeechLlmMeta& meta,
                                                     int32_t n_gpu_layers,
                                                     std::string* error) {
  auto model = std::shared_ptr<LlamaGgufModel>(new LlamaGgufModel());

  llama_model_params model_params = llama_model_default_params();
  model_params.n_gpu_layers = n_gpu_layers;
  model_params.use_mmap = true;
  model_params.use_mlock = false;

  model->model_ = llama_model_load_from_file(gguf_path.c_str(), model_params);
  if (!model->model_) {
    if (error) *error = "failed to load GGUF: " + gguf_path;
    return nullptr;
  }

  model->vocab_ = llama_model_get_vocab(model->model_);
  model->n_embd_ = llama_model_n_embd(model->model_);
  model->n_vocab_ = llama_vocab_n_tokens(model->vocab_);

  if (model->n_embd_ != meta.llm_dim) {
    if (error) {
      *error = "GGUF n_embd=" + std::to_string(model->n_embd_) +
               " does not match llm_dim=" + std::to_string(meta.llm_dim);
    }
    return nullptr;
  }
  if (!model->LoadTokenEmbdTable(gguf_path, error)) {
    return nullptr;
  }
  return model;
}

LlamaGgufDecoder::~LlamaGgufDecoder() {
  if (ctx_) {
    llama_free(ctx_);
    ctx_ = nullptr;
  }
  owned_model_.reset();
  shared_model_.reset();
}

bool LlamaGgufDecoder::InitContext(const SpeechLlmMeta& meta, int32_t n_ctx,
                                   int32_t n_batch, int32_t n_threads,
                                   std::string* error) {
  meta_ = meta;
  n_ctx_ = n_ctx;
  n_batch_ = n_batch;

  if (!shared_model_ || !shared_model_->model()) {
    if (error) *error = "shared GGUF model is not loaded";
    return false;
  }

  n_embd_ = shared_model_->n_embd();
  n_vocab_ = shared_model_->n_vocab();

  if (static_cast<int32_t>(meta_.emb_a.size()) != meta_.llm_dim ||
      static_cast<int32_t>(meta_.emb_a_end.size()) != meta_.llm_dim) {
    if (error) *error = "invalid <A>/</A> patch embedding size";
    return false;
  }

  if (ctx_) {
    llama_free(ctx_);
    ctx_ = nullptr;
  }

  llama_context_params ctx_params = llama_context_default_params();
  ctx_params.n_ctx = n_ctx;
  ctx_params.n_batch = n_batch;
  ctx_params.n_ubatch = n_batch;
  ctx_params.n_seq_max = 1;

  ctx_ = llama_init_from_model(shared_model_->model(), ctx_params);
  if (!ctx_) {
    if (error) *error = "failed to create llama context";
    return false;
  }

  if (n_threads > 0) {
    llama_set_n_threads(ctx_, n_threads, n_threads);
  }

  Reset();
  return true;
}

bool LlamaGgufDecoder::Init(const std::string& gguf_path, const SpeechLlmMeta& meta,
                            int32_t n_ctx, int32_t n_batch, int32_t n_threads,
                            int32_t n_gpu_layers, std::string* error) {
  owned_model_ = LlamaGgufModel::Load(gguf_path, meta, n_gpu_layers, error);
  if (!owned_model_) {
    return false;
  }
  shared_model_ = owned_model_;
  return InitContext(meta, n_ctx, n_batch, n_threads, error);
}

bool LlamaGgufDecoder::InitFromSharedModel(const std::shared_ptr<LlamaGgufModel>& model,
                                           const SpeechLlmMeta& meta, int32_t n_ctx,
                                           int32_t n_batch, int32_t n_threads,
                                           std::string* error) {
  if (!model) {
    if (error) *error = "shared GGUF model is null";
    return false;
  }
  shared_model_ = model;
  return InitContext(meta, n_ctx, n_batch, n_threads, error);
}

void LlamaGgufDecoder::Reset() {
  if (ctx_) {
    llama_memory_clear(llama_get_memory(ctx_), true);
  }
  n_past_ = 0;
  prompt_kv_len_ = -1;
  segment_count_ = 0;
}

std::vector<float> LlamaGgufDecoder::EmbedText(const std::string& text) const {
  if (text.empty() || !shared_model_ || shared_model_->token_embd().empty()) {
    return {};
  }

  const llama_vocab* vocab = shared_model_->vocab();
  const auto& token_embd = shared_model_->token_embd();

  std::vector<llama_token> tmp;
  int n = llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()),
                         nullptr, 0, false, true);
  if (n < 0) {
    tmp.resize(static_cast<size_t>(-n));
    n = llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()),
                       tmp.data(), static_cast<int32_t>(tmp.size()), false, true);
    if (n > 0) tmp.resize(static_cast<size_t>(n));
  } else if (n > 0) {
    tmp.resize(static_cast<size_t>(n));
    llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()), tmp.data(),
                   n, false, true);
  }
  if (tmp.empty()) return {};

  std::vector<float> out(tmp.size() * static_cast<size_t>(n_embd_));
  for (size_t i = 0; i < tmp.size(); ++i) {
    const int32_t tok = static_cast<int32_t>(tmp[i]);
    if (tok < 0 || tok >= n_vocab_) continue;
    std::memcpy(out.data() + i * n_embd_,
                token_embd.data() + static_cast<size_t>(tok) * n_embd_,
                static_cast<size_t>(n_embd_) * sizeof(float));
  }
  return out;
}

std::vector<float> LlamaGgufDecoder::EmbedTokenId(int32_t token_id) const {
  std::vector<float> out(static_cast<size_t>(n_embd_));
  if (!shared_model_ || token_id < 0 || token_id >= n_vocab_ ||
      shared_model_->token_embd().empty()) {
    return out;
  }
  const auto& token_embd = shared_model_->token_embd();
  std::memcpy(out.data(),
              token_embd.data() + static_cast<size_t>(token_id) * n_embd_,
              static_cast<size_t>(n_embd_) * sizeof(float));
  return out;
}

void LlamaGgufDecoder::PrefillEmbeddings(const float* embeddings,
                                         int32_t num_frames, bool want_logits) {
  if (!ctx_ || !embeddings || num_frames <= 0) return;

  int32_t offset = 0;
  const int32_t batch_limit = std::max(1, n_batch_);
  while (offset < num_frames) {
    const int32_t cur = std::min(batch_limit, num_frames - offset);
    llama_batch batch = llama_batch_init(cur, n_embd_, 1);
    batch.n_tokens = cur;
    for (int32_t i = 0; i < cur; ++i) {
      float* dst = batch.embd + static_cast<size_t>(i) * n_embd_;
      std::memcpy(dst, embeddings + static_cast<size_t>(offset + i) * n_embd_,
                  static_cast<size_t>(n_embd_) * sizeof(float));
      batch.pos[i] = static_cast<llama_pos>(n_past_ + i);
      batch.n_seq_id[i] = 1;
      batch.seq_id[i][0] = 0;
      batch.logits[i] = false;
    }
    if (want_logits && offset + cur == num_frames) {
      batch.logits[cur - 1] = true;
    }
    llama_decode(ctx_, batch);
    llama_batch_free(batch);
    n_past_ += cur;
    offset += cur;
  }
}

std::vector<float> LlamaGgufDecoder::SampleLogits() const {
  std::vector<float> logits(static_cast<size_t>(n_vocab_), 0.0f);
  float* src = llama_get_logits_ith(ctx_, -1);
  if (src) {
    std::memcpy(logits.data(), src, static_cast<size_t>(n_vocab_) * sizeof(float));
  }
  return logits;
}

void LlamaGgufDecoder::TruncateKv(int32_t remove_len) {
  if (remove_len <= 0 || n_past_ <= 0 || !ctx_) return;
  const int32_t new_len = std::max(0, n_past_ - remove_len);
  llama_memory_seq_rm(llama_get_memory(ctx_), 0, new_len, n_past_);
  n_past_ = new_len;
}

int32_t LlamaGgufDecoder::ArgMax(const std::vector<float>& logits) {
  return static_cast<int32_t>(
      std::max_element(logits.begin(), logits.end()) - logits.begin());
}

std::vector<float> LlamaGgufDecoder::Softmax(const std::vector<float>& logits) {
  float max_v = *std::max_element(logits.begin(), logits.end());
  std::vector<float> probs(logits.size());
  double sum = 0.0;
  for (size_t i = 0; i < logits.size(); ++i) {
    probs[i] = std::exp(logits[i] - max_v);
    sum += probs[i];
  }
  if (sum > 0.0) {
    for (float& p : probs) p = static_cast<float>(p / sum);
  }
  return probs;
}

bool LlamaGgufDecoder::EndsWithSentencePunct(const std::string& text) {
  size_t end = text.size();
  while (end > 0) {
    const char c = text[end - 1];
    if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
      --end;
      continue;
    }
    break;
  }
  if (end == 0) return false;
  return std::strchr(kSentEnd, text[end - 1]) != nullptr;
}

std::string LlamaGgufDecoder::MaybeEvictCache(std::string text) {
  ++segment_count_;
  if (EndsWithSentencePunct(text)) {
    if (!text.empty() && text.back() != ' ') {
      text.push_back(' ');
    }
    Reset();
    return text;
  }
  return text;
}

std::string LlamaGgufDecoder::AutoregressAfterAEnd(
    int32_t max_new_tokens, float repetition_penalty,
    float first_token_eos_threshold, int32_t punct_kv_mode,
    bool apply_first_token_eos_threshold, const StreamPartialFn& on_partial) {
  std::vector<int32_t> generated_ids;
  const llama_vocab* vocab = shared_model_ ? shared_model_->vocab() : nullptr;

  auto emit_partial = [&]() {
    if (!on_partial || generated_ids.empty() || !vocab) return;
    std::vector<llama_token> out_tokens(generated_ids.begin(), generated_ids.end());
    std::vector<char> buf(generated_ids.size() * 8 + 16, 0);
    int n = llama_detokenize(vocab, out_tokens.data(),
                             static_cast<int32_t>(out_tokens.size()), buf.data(),
                             static_cast<int32_t>(buf.size()), true, true);
    if (n < 0) {
      buf.resize(static_cast<size_t>(-n));
      n = llama_detokenize(vocab, out_tokens.data(),
                           static_cast<int32_t>(out_tokens.size()), buf.data(),
                           static_cast<int32_t>(buf.size()), true, true);
    }
    if (n > 0) {
      on_partial(std::string(buf.data(), static_cast<size_t>(n)));
    }
  };

  for (int step = 0; step < max_new_tokens; ++step) {
    std::vector<float> logits = SampleLogits();

    if (step == 0 && apply_first_token_eos_threshold &&
        first_token_eos_threshold < 1.0f) {
      std::vector<float> probs = Softmax(logits);
      if (probs[static_cast<size_t>(meta_.token_w_id)] > first_token_eos_threshold &&
          ArgMax(logits) == meta_.token_w_id) {
        logits[static_cast<size_t>(meta_.token_w_id)] =
            -std::numeric_limits<float>::infinity();
      }
    }

    if (repetition_penalty != 1.0f && !generated_ids.empty()) {
      for (int32_t tok_id : generated_ids) {
        if (tok_id < 0 || tok_id >= n_vocab_) continue;
        float& v = logits[static_cast<size_t>(tok_id)];
        if (v < 0.0f) v *= repetition_penalty;
        else v /= repetition_penalty;
      }
    }

    const int32_t token_id = ArgMax(logits);
    if (token_id == meta_.token_w_id) {
      if (punct_kv_mode != 0 && !generated_ids.empty() && vocab) {
        std::vector<llama_token> prev = {generated_ids.back()};
        std::vector<char> buf(8, 0);
        int n = llama_detokenize(vocab, prev.data(), 1, buf.data(),
                                 static_cast<int32_t>(buf.size()), false, true);
        if (n < 0) {
          buf.resize(static_cast<size_t>(-n));
          n = llama_detokenize(vocab, prev.data(), 1, buf.data(),
                               static_cast<int32_t>(buf.size()), false, true);
        }
        std::string prev_text(buf.data(), n > 0 ? static_cast<size_t>(n) : 0);
        if (EndsWithSentencePunct(prev_text)) {
          if (punct_kv_mode == 1) {
            TruncateKv(1);
          } else if (punct_kv_mode == 2 && prompt_kv_len_ >= 0 &&
                     n_past_ > prompt_kv_len_) {
            TruncateKv(n_past_ - prompt_kv_len_);
          }
        }
      }
      break;
    }

    generated_ids.push_back(token_id);
    emit_partial();
    const std::vector<float> emb = EmbedTokenId(token_id);
    PrefillEmbeddings(emb.data(), 1, true);
  }

  if (prompt_kv_len_ < 0) {
    prompt_kv_len_ = n_past_ - static_cast<int32_t>(generated_ids.size());
    if (prompt_kv_len_ < 0) prompt_kv_len_ = 0;
  }

  if (generated_ids.empty() || !vocab) return "";

  std::vector<llama_token> out_tokens(generated_ids.begin(), generated_ids.end());
  std::vector<char> buf(generated_ids.size() * 8 + 16, 0);
  int n = llama_detokenize(vocab, out_tokens.data(),
                           static_cast<int32_t>(out_tokens.size()), buf.data(),
                           static_cast<int32_t>(buf.size()), true, true);
  if (n < 0) {
    buf.resize(static_cast<size_t>(-n));
    n = llama_detokenize(vocab, out_tokens.data(),
                         static_cast<int32_t>(out_tokens.size()), buf.data(),
                         static_cast<int32_t>(buf.size()), true, true);
  }
  if (n <= 0) return "";
  return std::string(buf.data(), static_cast<size_t>(n));
}

std::string LlamaGgufDecoder::FeedChunk(
    const std::string& prompt, const float* audio_embeds, int32_t num_frames,
    int32_t max_new_tokens, float repetition_penalty,
    float first_token_eos_threshold, int32_t punct_kv_mode, bool is_new_segment,
    bool is_segment_end, bool eos_penalty_only_last_chunk,
    bool clear_kv_on_sentence_end, const StreamPartialFn& on_partial) {
  const int32_t n_past_at_start = n_past_;
  int32_t prompt_emb_frames = 0;
  int32_t a_token_frames = 0;

  std::vector<float> prefix;
  if (n_past_ == 0) {
    if (!prompt.empty()) {
      std::vector<float> prompt_emb = EmbedText(prompt);
      prompt_emb_frames =
          static_cast<int32_t>(prompt_emb.size() / static_cast<size_t>(n_embd_));
      prefix.insert(prefix.end(), prompt_emb.begin(), prompt_emb.end());
    }
    prefix.insert(prefix.end(), meta_.emb_a.begin(), meta_.emb_a.end());
    a_token_frames = 1;
  }

  const int32_t audio_frames = (audio_embeds && num_frames > 0) ? num_frames : 0;
  if (audio_embeds && num_frames > 0) {
    const size_t audio_bytes =
        static_cast<size_t>(num_frames) * static_cast<size_t>(n_embd_) * sizeof(float);
    const size_t old = prefix.size();
    prefix.resize(old + static_cast<size_t>(num_frames) * static_cast<size_t>(n_embd_));
    std::memcpy(prefix.data() + old, audio_embeds, audio_bytes);
  }

  const int32_t prefill_frames =
      static_cast<int32_t>(prefix.size() / static_cast<size_t>(n_embd_));

  std::fprintf(stderr,
               "[simulst] decode_input: prompt=\"%s\" "
               "prefill=%d(prompt=%d+<A>=%d+audio=%d) new_seg=%d seg_end=%d "
               "n_past=%d",
               prompt.c_str(), prefill_frames, prompt_emb_frames, a_token_frames,
               audio_frames, is_new_segment ? 1 : 0, is_segment_end ? 1 : 0,
               n_past_at_start);

  if (!prefix.empty()) {
    PrefillEmbeddings(prefix.data(), prefill_frames, false);
  }

  std::fprintf(stderr, "->%d", n_past_);

  if (!is_segment_end) {
    std::fprintf(stderr, " (prefill only, no </A>)\n");
    return "";
  }

  PrefillEmbeddings(meta_.emb_a_end.data(), 1, true);
  std::fprintf(stderr, " +</A>->%d max_new_tokens=%d\n", n_past_, max_new_tokens);

  const bool apply_penalty = (!eos_penalty_only_last_chunk) || is_segment_end;
  std::string text = AutoregressAfterAEnd(
      max_new_tokens, repetition_penalty, first_token_eos_threshold, punct_kv_mode,
      apply_penalty, on_partial);
  if (clear_kv_on_sentence_end && !text.empty()) {
    text = MaybeEvictCache(std::move(text));
  }
  std::fprintf(stderr, "[simulst] decode_output: text_len=%zu text=\"%s\"\n",
               text.size(), text.c_str());
  return text;
}

std::string LlamaGgufDecoder::GenerateChunk(
    const std::string& prompt, const float* audio_embeds, int32_t num_frames,
    int32_t max_new_tokens, float repetition_penalty,
    float first_token_eos_threshold, int32_t punct_kv_mode, bool is_first_chunk,
    bool is_last_chunk, bool eos_penalty_only_last_chunk) {
  (void)is_first_chunk;
  return FeedChunk(prompt, audio_embeds, num_frames, max_new_tokens,
                   repetition_penalty, first_token_eos_threshold, punct_kv_mode,
                   true, is_last_chunk, eos_penalty_only_last_chunk, true);
}

}  // namespace simulst
