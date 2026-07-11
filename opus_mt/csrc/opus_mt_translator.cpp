#include "opus_mt_translator.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <numeric>
#include <queue>
#include <sstream>
#include <unordered_map>

#include "nlohmann/json.hpp"
#include "onnxruntime_cxx_api.h"

namespace opus_mt {

// ---- OnnxState: hides ONNX Runtime objects from the public header -------------

struct OpusMtTranslator::OnnxState {
  Ort::Env env{ORT_LOGGING_LEVEL_ERROR, "opus-mt"};
  Ort::SessionOptions session_opts;
  std::unique_ptr<Ort::Session> encoder_session;
  std::unique_ptr<Ort::Session> decoder_session;
  Ort::MemoryInfo memory_info{Ort::MemoryInfo::CreateCpu(
      OrtDeviceAllocator, OrtMemTypeDefault)};
  Ort::AllocatorWithDefaultOptions allocator;

  // Decoder input names, cached for efficiency.
  std::vector<const char*> decoder_input_names;
  std::vector<const char*> decoder_output_names;

  bool decoder_has_kv_cache = false;
  int32_t num_decoder_layers = 6;
  int32_t num_kv_heads = 8;
  int32_t head_dim = 0;  // 0 = not set; infer from config or ONNX model

  Ort::RunOptions run_opts;
};

// ---- Initialization ----------------------------------------------------------

OpusMtTranslator::OpusMtTranslator() = default;

OpusMtTranslator::~OpusMtTranslator() {
  Release();
}

bool OpusMtTranslator::Init(const OpusMtConfig& config) {
  config_ = config;

  if (!InitTokenizer(config)) {
    // last_error_ already set by InitTokenizer.
    return false;
  }
  if (!InitOnnx(config)) {
    // last_error_ already set by InitOnnx.
    return false;
  }

  ready_ = true;
  return true;
}

bool OpusMtTranslator::InitTokenizer(const OpusMtConfig& config) {
  tokenizer_.SetPadId(config.pad_token_id);
  tokenizer_.SetEosId(config.eos_token_id);
  tokenizer_.SetUnkId(config.unk_token_id);

  if (!tokenizer_.LoadVocab(config.vocab_path)) {
    last_error_ = "Failed to load vocab.json: " + config.vocab_path;
    return false;
  }

  if (config.use_sentencepiece) {
    tokenizer_.SetUseSentencePiece(true);
    if (!config.source_spm_path.empty()) {
      tokenizer_.LoadSourceSpm(config.source_spm_path);
    }
    if (!config.target_spm_path.empty()) {
      tokenizer_.LoadTargetSpm(config.target_spm_path);
    }
  }

  return true;
}

bool OpusMtTranslator::InitOnnx(const OpusMtConfig& config) {
  onnx_ = std::make_unique<OnnxState>();

  // Configure session options
  onnx_->session_opts.SetIntraOpNumThreads(config.intra_op_num_threads);
  onnx_->session_opts.SetInterOpNumThreads(config.inter_op_num_threads);
  onnx_->session_opts.SetGraphOptimizationLevel(
      static_cast<GraphOptimizationLevel>(config.graph_optimization_level));

  // NOTE: Disable CPU memory arena and mem pattern for INT8 quantized models.
  // DynamicQuantizeLinear ops interact poorly with arena-based memory reuse,
  // and can cause hangs or extremely slow session creation with large models.
  // onnx_->session_opts.EnableCpuMemArena();
  // onnx_->session_opts.EnableMemPattern();

  // Load encoder
  fprintf(stderr, "[opus-mt] Loading encoder: %s\n", config.encoder_path.c_str());
  try {
    onnx_->encoder_session = std::make_unique<Ort::Session>(
        onnx_->env, config.encoder_path.c_str(), onnx_->session_opts);
    fprintf(stderr, "[opus-mt] Encoder loaded OK\n");
  } catch (const Ort::Exception& e) {
    last_error_ = std::string("Failed to load encoder ONNX: ") + config.encoder_path +
                  " — " + e.what();
    fprintf(stderr, "[opus-mt] Encoder load FAILED: %s\n", e.what());
    return false;
  }

  // Load decoder
  fprintf(stderr, "[opus-mt] Loading decoder: %s\n", config.decoder_path.c_str());
  try {
    onnx_->decoder_session = std::make_unique<Ort::Session>(
        onnx_->env, config.decoder_path.c_str(), onnx_->session_opts);
    fprintf(stderr, "[opus-mt] Decoder loaded OK\n");
  } catch (const Ort::Exception& e) {
    last_error_ = std::string("Failed to load decoder ONNX: ") + config.decoder_path +
                  " — " + e.what();
    fprintf(stderr, "[opus-mt] Decoder load FAILED: %s\n", e.what());
    return false;
  }

  // Cache input/output names for the decoder (used in the generation loop).
  {
    size_t num_inputs = onnx_->decoder_session->GetInputCount();
    onnx_->decoder_input_names.resize(num_inputs);
    for (size_t i = 0; i < num_inputs; i++) {
      auto name = onnx_->decoder_session->GetInputNameAllocated(
          i, onnx_->allocator);
      onnx_->decoder_input_names[i] = name.release();
    }
  }
  {
    size_t num_outputs = onnx_->decoder_session->GetOutputCount();
    onnx_->decoder_output_names.resize(num_outputs);
    for (size_t i = 0; i < num_outputs; i++) {
      auto name = onnx_->decoder_session->GetOutputNameAllocated(
          i, onnx_->allocator);
      onnx_->decoder_output_names[i] = name.release();
    }
  }

  // Detect KV cache: look for "past_key_values" in decoder inputs.
  for (const auto* name : onnx_->decoder_input_names) {
    if (std::strstr(name, "past_key_values") != nullptr) {
      onnx_->decoder_has_kv_cache = true;
      break;
    }
  }

  return true;
}

void OpusMtTranslator::Release() {
  ready_ = false;
  onnx_.reset();
}

// ---- Encoder ----------------------------------------------------------------

std::vector<float> OpusMtTranslator::RunEncoder(
    const std::vector<int64_t>& input_ids,
    const std::vector<int64_t>& attention_mask) {
  int64_t batch_size = 1;
  int64_t seq_len = static_cast<int64_t>(input_ids.size());

  std::vector<int64_t> input_shape = {batch_size, seq_len};

  // Create input_ids tensor (int64 as required by opus-mt ONNX models).
  auto input_tensor = Ort::Value::CreateTensor<int64_t>(
      onnx_->memory_info,
      const_cast<int64_t*>(input_ids.data()),
      input_ids.size(),
      input_shape.data(),
      input_shape.size());

  // Create attention_mask tensor (int64).
  auto mask_tensor = Ort::Value::CreateTensor<int64_t>(
      onnx_->memory_info,
      const_cast<int64_t*>(attention_mask.data()),
      attention_mask.size(),
      input_shape.data(),
      input_shape.size());

  // Encoder input/output names.
  const char* input_names[] = {"input_ids", "attention_mask"};
  const char* output_names[] = {"last_hidden_state"};

  std::vector<Ort::Value> input_tensors;
  input_tensors.reserve(2);
  input_tensors.push_back(std::move(input_tensor));
  input_tensors.push_back(std::move(mask_tensor));

  auto outputs = onnx_->encoder_session->Run(
      onnx_->run_opts, input_names, input_tensors.data(),
      input_tensors.size(), output_names, 1);

  // Extract float data from the output tensor [1, seq_len, d_model].
  auto& output = outputs.front();
  auto type_info = output.GetTensorTypeAndShapeInfo();
  auto shape = type_info.GetShape();
  size_t total_elements = type_info.GetElementCount();
  const float* data = output.GetTensorData<float>();

  return std::vector<float>(data, data + total_elements);
}

// ---- Decoder step ----------------------------------------------------------

std::vector<float> OpusMtTranslator::RunDecoderStep(
    const std::vector<int64_t>& decoder_input_ids,
    const std::vector<float>& encoder_hidden_states,
    const std::vector<int64_t>& encoder_attention_mask) {

  int64_t batch_size = 1;
  int64_t dec_seq_len = static_cast<int64_t>(decoder_input_ids.size());
  int64_t enc_seq_len = static_cast<int64_t>(encoder_attention_mask.size());
  int64_t d_model = config_.d_model;

  // Build tensors keyed by name, then emit in model order.
  std::unordered_map<std::string, Ort::Value> tensor_map;

  // NOTE: All data vectors MUST outlive the Ort::Value tensors created below.
  // Ort::Value::CreateTensor does NOT copy data — it only holds pointers.
  // These are declared here (not in inner scopes) to stay alive through session->Run().

  // input_ids: [1, dec_seq_len] (int64).
  std::vector<int64_t> ids_shape = {batch_size, dec_seq_len};
  std::vector<int64_t> ids_copy = decoder_input_ids;
  tensor_map["input_ids"] = Ort::Value::CreateTensor<int64_t>(
      onnx_->memory_info, ids_copy.data(), ids_copy.size(),
      ids_shape.data(), ids_shape.size());

  // encoder_hidden_states: [1, enc_seq_len, d_model].
  std::vector<int64_t> enc_shape = {batch_size, enc_seq_len, d_model};
  tensor_map["encoder_hidden_states"] = Ort::Value::CreateTensor<float>(
      onnx_->memory_info,
      const_cast<float*>(encoder_hidden_states.data()),
      encoder_hidden_states.size(),
      enc_shape.data(), enc_shape.size());

  // encoder_attention_mask: [1, enc_seq_len] (int64).
  std::vector<int64_t> mask_shape = {batch_size, enc_seq_len};
  std::vector<int64_t> mask_copy = encoder_attention_mask;
  tensor_map["encoder_attention_mask"] = Ort::Value::CreateTensor<int64_t>(
      onnx_->memory_info, mask_copy.data(), mask_copy.size(),
      mask_shape.data(), mask_shape.size());

  // Add empty past_key_values tensors for KV-cache models.
  // These vectors must also outlive the session->Run() call.
  std::vector<int64_t> kv_shape;
  std::vector<float> empty_kv;
  bool use_cache_val = false;
  int64_t use_cache_shape = 1;
  if (onnx_->decoder_has_kv_cache) {
    int32_t num_layers = onnx_->num_decoder_layers > 0
                             ? onnx_->num_decoder_layers
                             : config_.decoder_layers;
    int32_t num_heads = onnx_->num_kv_heads > 0
                            ? onnx_->num_kv_heads
                            : config_.decoder_attention_heads;
    int64_t head_dim = onnx_->head_dim > 0
                           ? onnx_->head_dim
                           : static_cast<int64_t>(config_.d_model) / num_heads;

    kv_shape = {batch_size, num_heads, 0, head_dim};

    for (int32_t layer = 0; layer < num_layers; layer++) {
      auto key_tensor = Ort::Value::CreateTensor<float>(
          onnx_->memory_info, empty_kv.data(), 0,
          kv_shape.data(), kv_shape.size());
      auto value_tensor = Ort::Value::CreateTensor<float>(
          onnx_->memory_info, empty_kv.data(), 0,
          kv_shape.data(), kv_shape.size());

      // Names match opus-mt ONNX export: "past_key_values.{layer}.decoder.key", etc.
      tensor_map["past_key_values." + std::to_string(layer) + ".decoder.key"] =
          std::move(key_tensor);
      tensor_map["past_key_values." + std::to_string(layer) + ".decoder.value"] =
          std::move(value_tensor);
      tensor_map["past_key_values." + std::to_string(layer) + ".encoder.key"] =
          Ort::Value::CreateTensor<float>(onnx_->memory_info, empty_kv.data(), 0,
                                          kv_shape.data(), kv_shape.size());
      tensor_map["past_key_values." + std::to_string(layer) + ".encoder.value"] =
          Ort::Value::CreateTensor<float>(onnx_->memory_info, empty_kv.data(), 0,
                                          kv_shape.data(), kv_shape.size());
    }

    // use_cache_branch: bool tensor, false = first step (no cache).
    tensor_map["use_cache_branch"] = Ort::Value::CreateTensor<bool>(
        onnx_->memory_info,
        &use_cache_val, 1,
        &use_cache_shape, 1);
  }

  // Emit tensors in model input order.
  std::vector<Ort::Value> input_tensors;
  input_tensors.reserve(onnx_->decoder_input_names.size());
  for (size_t i = 0; i < onnx_->decoder_input_names.size(); i++) {
    auto it = tensor_map.find(onnx_->decoder_input_names[i]);
    if (it != tensor_map.end()) {
      input_tensors.push_back(std::move(it->second));
    } else {
      // Unknown input: create a dummy empty float tensor.
      input_tensors.push_back(Ort::Value::CreateTensor<float>(
          onnx_->memory_info, nullptr, 0, nullptr, 0));
    }
  }

  auto outputs = onnx_->decoder_session->Run(
      onnx_->run_opts,
      onnx_->decoder_input_names.data(),
      input_tensors.data(),
      input_tensors.size(),
      onnx_->decoder_output_names.data(),
      onnx_->decoder_output_names.size());

  // The first output is logits: [1, dec_seq_len, vocab_size].
  auto& logits_tensor = outputs.front();
  auto type_info = logits_tensor.GetTensorTypeAndShapeInfo();
  auto shape = type_info.GetShape();
  size_t total_elements = type_info.GetElementCount();
  const float* data = logits_tensor.GetTensorData<float>();

  return std::vector<float>(data, data + total_elements);
}

// ---- Softmax / argmax ------------------------------------------------------

void OpusMtTranslator::Softmax(float* data, int32_t size) {
  float max_val = *std::max_element(data, data + size);
  float sum = 0.0f;
  for (int32_t i = 0; i < size; i++) {
    data[i] = std::exp(data[i] - max_val);
    sum += data[i];
  }
  for (int32_t i = 0; i < size; i++) {
    data[i] /= sum;
  }
}

int32_t OpusMtTranslator::Argmax(const float* data, int32_t size) {
  return static_cast<int32_t>(
      std::distance(data, std::max_element(data, data + size)));
}

// ---- Greedy decoding -------------------------------------------------------

std::vector<int32_t> OpusMtTranslator::GreedyDecode(
    const std::vector<float>& encoder_hidden_states,
    const std::vector<int64_t>& encoder_attention_mask) {

  int32_t vocab_size = config_.vocab_size;
  std::vector<int32_t> generated_ids;

  // Start with the decoder_start_token_id.
  std::vector<int64_t> decoder_input_ids = {static_cast<int64_t>(config_.decoder_start_token_id)};

  for (int32_t step = 0; step < config_.max_length; step++) {
    auto logits = RunDecoderStep(decoder_input_ids, encoder_hidden_states,
                                  encoder_attention_mask);

    if (logits.empty()) break;

    // logits shape: [1, dec_seq_len, vocab_size]
    // Take the last position's logits.
    size_t offset = (decoder_input_ids.size() - 1) * vocab_size;
    if (offset + vocab_size > logits.size()) break;

    float* last_logits = logits.data() + offset;
    Softmax(last_logits, vocab_size);
    int32_t next_token = Argmax(last_logits, vocab_size);

    generated_ids.push_back(next_token);

    if (next_token == config_.eos_token_id) break;

    if (onnx_->decoder_has_kv_cache) {
      decoder_input_ids[0] = static_cast<int64_t>(next_token);
    } else {
      decoder_input_ids.push_back(next_token);
    }
  }

  return generated_ids;
}

// ---- Beam search decoding ---------------------------------------------------

std::vector<int32_t> OpusMtTranslator::BeamSearchDecode(
    const std::vector<float>& encoder_hidden_states,
    const std::vector<int64_t>& encoder_attention_mask) {

  int32_t num_beams = config_.num_beams;
  int32_t vocab_size = config_.vocab_size;

  // Each beam is a Hypothesis.
  using Beam = Hypothesis;

  // Prepare initial hypotheses for each beam.
  // Initialize with decoder_start_token_id.
  auto cmp = [](const Beam& a, const Beam& b) { return a.score < b.score; };
  std::priority_queue<Beam, std::vector<Beam>, decltype(cmp)> pq(cmp);

  // Initial beam: just the start token.
  {
    Beam initial;
    initial.token_ids = {static_cast<int64_t>(config_.decoder_start_token_id)};
    initial.score = 0.0f;
    pq.push(initial);
  }

  std::vector<Beam> finished_beams;
  std::vector<Beam> active_beams;

  for (int32_t step = 0; step < config_.max_length; step++) {
    // Collect beams from priority queue.
    active_beams.clear();
    while (!pq.empty()) {
      active_beams.push_back(pq.top());
      pq.pop();
    }
    std::reverse(active_beams.begin(), active_beams.end());

    if (active_beams.empty()) break;

    // Collect candidates for this step.
    std::vector<Beam> candidates;

    for (const auto& beam : active_beams) {
      if (beam.finished) {
        candidates.push_back(beam);
        continue;
      }

      auto logits = RunDecoderStep(beam.token_ids, encoder_hidden_states,
                                    encoder_attention_mask);
      if (logits.empty()) continue;

      // Last position logits.
      size_t offset = (beam.token_ids.size() - 1) * vocab_size;
      if (offset + vocab_size > logits.size()) continue;

      float* last_logits = logits.data() + offset;
      Softmax(last_logits, vocab_size);

      // Collect top-k tokens for this beam.
      std::vector<std::pair<float, int32_t>> top_k;
      for (int32_t i = 0; i < vocab_size; i++) {
        top_k.push_back({last_logits[i], i});
      }
      std::partial_sort(top_k.begin(), top_k.begin() + num_beams, top_k.end(),
                        [](auto& a, auto& b) { return a.first > b.first; });

      for (int32_t k = 0; k < num_beams; k++) {
        Beam new_beam = beam;
        int32_t token = top_k[k].second;
        float token_score = top_k[k].first;

        new_beam.score += std::log(token_score + 1e-12f);
        new_beam.token_ids.push_back(token);

        if (token == config_.eos_token_id ||
            static_cast<int32_t>(new_beam.token_ids.size()) >= config_.max_length) {
          new_beam.finished = true;
          // Apply length penalty.
          float length = static_cast<float>(new_beam.token_ids.size());
          new_beam.score /= std::pow(length, config_.length_penalty);
        }

        candidates.push_back(new_beam);
      }
    }

    // Separate finished and active.
    std::vector<Beam> still_active;
    for (auto& c : candidates) {
      if (c.finished) {
        finished_beams.push_back(c);
      } else {
        still_active.push_back(c);
      }
    }

    // Keep top num_beams active.
    std::partial_sort(still_active.begin(),
                      still_active.begin() + std::min<size_t>(num_beams, still_active.size()),
                      still_active.end(),
                      [](const Beam& a, const Beam& b) { return a.score > b.score; });

    for (size_t i = 0; i < still_active.size() && i < static_cast<size_t>(num_beams); i++) {
      pq.push(still_active[i]);
    }
  }

  // Choose the best finished beam, or fall back to active.
  std::vector<Beam>* result_set = &finished_beams;
  if (result_set->empty()) {
    while (!pq.empty()) {
      result_set->push_back(pq.top());
      pq.pop();
    }
  }

  if (result_set->empty()) return {};

  // Pick the highest scoring beam.
  auto best = std::max_element(result_set->begin(), result_set->end(),
                                [](const Beam& a, const Beam& b) {
                                  return a.score < b.score;
                                });

  // Strip the start token and EOS from output.
  std::vector<int32_t> output;
  for (size_t i = 1; i < best->token_ids.size(); i++) {
    if (best->token_ids[i] == config_.eos_token_id) break;
    output.push_back(best->token_ids[i]);
  }
  return output;
}

// ---- Full translate pipeline ------------------------------------------------

std::string OpusMtTranslator::Translate(std::string_view source_text) {
  if (!ready_) {
    fprintf(stderr, "[opus-mt] Translate: translator not ready\n");
    return R"({"text":"","encoder_ms":0.0,"decoder_ms":0.0,"decoder_tokens":0})";
  }

  fprintf(stderr, "[opus-mt] Translate: \"%s\"\n", std::string(source_text).c_str());

  // Step 1: Tokenize (returns int32 IDs; convert to int64 for ONNX).
  auto input_ids_32 = tokenizer_.Encode(source_text,
                                         config_.bos_token_id,
                                         config_.eos_token_id);
  if (input_ids_32.empty()) {
    fprintf(stderr, "[opus-mt] Tokenize: empty result\n");
    return R"({"text":"","encoder_ms":0.0,"decoder_ms":0.0,"decoder_tokens":0})";
  }
  std::vector<int64_t> input_ids(input_ids_32.begin(), input_ids_32.end());
  fprintf(stderr, "[opus-mt] Tokenized: %zu tokens\n", input_ids.size());

  // Step 2: Build attention mask (int64 for ONNX).
  std::vector<int64_t> attention_mask(input_ids.size(), 1);

  // Step 3: Run encoder (timed).
  fprintf(stderr, "[opus-mt] Running encoder...\n");
  auto t0 = std::chrono::high_resolution_clock::now();
  auto encoder_hidden_states = RunEncoder(input_ids, attention_mask);
  auto t1 = std::chrono::high_resolution_clock::now();
  if (encoder_hidden_states.empty()) {
    fprintf(stderr, "[opus-mt] Encoder: empty result\n");
    return R"({"text":"","encoder_ms":0.0,"decoder_ms":0.0,"decoder_tokens":0})";
  }
  fprintf(stderr, "[opus-mt] Encoder done, hidden states: %zu floats\n",
          encoder_hidden_states.size());

  // Step 4: Decode (timed).
  std::vector<int32_t> output_ids;
  if (config_.num_beams > 1) {
    fprintf(stderr, "[opus-mt] BeamSearchDecode (beams=%d)...\n", config_.num_beams);
    output_ids = BeamSearchDecode(encoder_hidden_states, attention_mask);
  } else {
    fprintf(stderr, "[opus-mt] GreedyDecode...\n");
    output_ids = GreedyDecode(encoder_hidden_states, attention_mask);
  }
  auto t2 = std::chrono::high_resolution_clock::now();
  fprintf(stderr, "[opus-mt] Decode done, %zu output tokens\n", output_ids.size());

  // Compute timing metrics.
  double encoder_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
  double decoder_ms = std::chrono::duration<double, std::milli>(t2 - t1).count();
  size_t decoder_tokens = output_ids.size();

  if (output_ids.empty()) {
    nlohmann::json err;
    err["text"] = "";
    err["input_tokens"] = input_ids.size();
    err["encoder_ms"] = encoder_ms;
    err["decoder_ms"] = 0.0;
    err["decoder_tokens"] = 0;
    return err.dump();
  }

  // Step 5: Detokenize.
  std::string translated_text = tokenizer_.Decode(output_ids);

  // Build JSON result with timing.
  nlohmann::json result;
  result["text"] = translated_text;
  result["input_tokens"] = input_ids.size();
  result["encoder_ms"] = encoder_ms;
  result["decoder_ms"] = decoder_ms;
  result["decoder_tokens"] = decoder_tokens;
  return result.dump();
}

std::string OpusMtTranslator::TranslateStreaming(
    std::string_view source_text,
    void (*on_token)(const char*, void*),
    void* user_data) {

  if (!ready_) {
    fprintf(stderr, "[opus-mt] TranslateStreaming: translator not ready\n");
    return R"({"text":"","encoder_ms":0.0,"decoder_ms":0.0,"decoder_tokens":0})";
  }

  fprintf(stderr, "[opus-mt] TranslateStreaming: \"%s\"\n", std::string(source_text).c_str());

  // Step 1: Tokenize.
  auto input_ids_32 = tokenizer_.Encode(source_text,
                                         config_.bos_token_id,
                                         config_.eos_token_id);
  if (input_ids_32.empty()) {
    fprintf(stderr, "[opus-mt] Tokenize: empty result\n");
    return R"({"text":"","encoder_ms":0.0,"decoder_ms":0.0,"decoder_tokens":0})";
  }
  std::vector<int64_t> input_ids(input_ids_32.begin(), input_ids_32.end());

  // Step 2: Build attention mask.
  std::vector<int64_t> attention_mask(input_ids.size(), 1);

  // Step 3: Run encoder (timed).
  fprintf(stderr, "[opus-mt] Running encoder...\n");
  auto t0 = std::chrono::high_resolution_clock::now();
  auto encoder_hidden_states = RunEncoder(input_ids, attention_mask);
  auto t1 = std::chrono::high_resolution_clock::now();
  if (encoder_hidden_states.empty()) {
    fprintf(stderr, "[opus-mt] Encoder: empty result\n");
    return R"({"text":"","encoder_ms":0.0,"decoder_ms":0.0,"decoder_tokens":0})";
  }

  // Step 4: Decode (timed). For beam search, fall back to non-streaming.
  std::vector<int32_t> output_ids;
  if (config_.num_beams > 1) {
    fprintf(stderr, "[opus-mt] BeamSearchDecode (no streaming, beams=%d)...\n", config_.num_beams);
    output_ids = BeamSearchDecode(encoder_hidden_states, attention_mask);
  } else {
    // Inline greedy decoding with per-token callbacks.
    fprintf(stderr, "[opus-mt] GreedyDecode (streaming)...\n");
    int32_t vocab_size = config_.vocab_size;
    std::vector<int64_t> decoder_input_ids = {
        static_cast<int64_t>(config_.decoder_start_token_id)};

    for (int32_t step = 0; step < config_.max_length; step++) {
      auto logits = RunDecoderStep(decoder_input_ids, encoder_hidden_states,
                                    attention_mask);
      if (logits.empty()) break;

      size_t offset = (decoder_input_ids.size() - 1) * vocab_size;
      if (offset + vocab_size > logits.size()) break;

      float* last_logits = logits.data() + offset;
      Softmax(last_logits, vocab_size);
      int32_t next_token = Argmax(last_logits, vocab_size);

      output_ids.push_back(next_token);

      // Fire callback with cumulative partial translation.
      if (on_token && !output_ids.empty()) {
        std::string partial = tokenizer_.Decode(output_ids);
        on_token(partial.c_str(), user_data);
      }

      if (next_token == config_.eos_token_id) break;
      if (onnx_->decoder_has_kv_cache) {
        decoder_input_ids[0] = static_cast<int64_t>(next_token);
      } else {
        decoder_input_ids.push_back(next_token);
      }
    }
  }

  auto t2 = std::chrono::high_resolution_clock::now();
  fprintf(stderr, "[opus-mt] Decode done, %zu output tokens\n", output_ids.size());

  // Compute timing.
  double encoder_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
  double decoder_ms = std::chrono::duration<double, std::milli>(t2 - t1).count();
  size_t decoder_tokens = output_ids.size();

  if (output_ids.empty()) {
    nlohmann::json err;
    err["text"] = "";
    err["input_tokens"] = input_ids.size();
    err["encoder_ms"] = encoder_ms;
    err["decoder_ms"] = 0.0;
    err["decoder_tokens"] = 0;
    return err.dump();
  }

  // Step 5: Detokenize.
  std::string translated_text = tokenizer_.Decode(output_ids);

  nlohmann::json result;
  result["text"] = translated_text;
  result["input_tokens"] = input_ids.size();
  result["encoder_ms"] = encoder_ms;
  result["decoder_ms"] = decoder_ms;
  result["decoder_tokens"] = decoder_tokens;
  return result.dump();
}

}  // namespace opus_mt
