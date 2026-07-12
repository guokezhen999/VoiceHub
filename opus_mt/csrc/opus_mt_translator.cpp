#include "opus_mt_translator.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <unordered_map>

#include "nlohmann/json.hpp"
#include "onnxruntime_cxx_api.h"

namespace opus_mt {

// ---- Float16 I/O helpers --------------------------------------------------------

// Helper: a float tensor + optional float16 backing buffer.
// Ort::Value::CreateTensor does NOT copy data — it only holds pointers.
// This struct keeps the FP16 backing alive alongside the Ort::Value.
struct OrtFloatTensor {
  Ort::Value tensor;
  std::vector<Ort::Float16_t> fp16_data;  // backing buffer for FP16 tensors
};

// Create a float (or float16) tensor from float32 source data.
static OrtFloatTensor CreateFloatTensor(
    Ort::MemoryInfo& memory_info,
    const float* data,
    size_t count,
    const int64_t* shape,
    size_t shape_len,
    bool as_fp16) {
  if (as_fp16) {
    std::vector<Ort::Float16_t> fp16(count);
    for (size_t i = 0; i < count; i++) {
      fp16[i] = Ort::Float16_t(data[i]);
    }
    auto tensor = Ort::Value::CreateTensor<Ort::Float16_t>(
        memory_info, fp16.data(), count, shape, shape_len);
    return {std::move(tensor), std::move(fp16)};
  }
  auto tensor = Ort::Value::CreateTensor<float>(
      memory_info, const_cast<float*>(data), count, shape, shape_len);
  return {std::move(tensor), {}};
}

// Like CreateFloatTensor but uses the data from a std::vector<float>.
static OrtFloatTensor CreateFloatTensorFromVec(
    Ort::MemoryInfo& memory_info,
    const std::vector<float>& data,
    const std::vector<int64_t>& shape,
    bool as_fp16) {
  return CreateFloatTensor(memory_info, data.data(), data.size(),
                           shape.data(), shape.size(), as_fp16);
}

std::vector<float> OpusMtTranslator::ReadTensorAsFloat32(const Ort::Value& tensor) {
  auto type_info = tensor.GetTensorTypeAndShapeInfo();
  size_t n = type_info.GetElementCount();
  auto elem_type = type_info.GetElementType();

  if (elem_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
    const Ort::Float16_t* fp16_data = tensor.GetTensorData<Ort::Float16_t>();
    std::vector<float> result(n);
    for (size_t i = 0; i < n; i++) {
      result[i] = fp16_data[i].ToFloat();
    }
    return result;
  }
  // Default: float32.
  const float* data = tensor.GetTensorData<float>();
  return std::vector<float>(data, data + n);
}

std::vector<float> OpusMtTranslator::ReadFloatTensor(
    const Ort::Value& tensor, size_t total_elements) {
  auto type_info = tensor.GetTensorTypeAndShapeInfo();
  auto elem_type = type_info.GetElementType();

  if (elem_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
    const Ort::Float16_t* fp16_data = tensor.GetTensorData<Ort::Float16_t>();
    std::vector<float> result(total_elements);
    for (size_t i = 0; i < total_elements; i++) {
      result[i] = fp16_data[i].ToFloat();
    }
    return result;
  }
  const float* data = tensor.GetTensorData<float>();
  return std::vector<float>(data, data + total_elements);
}

// ---- OnnxState: hides ONNX Runtime objects from the public header -------------

struct OpusMtTranslator::OnnxState {
  Ort::Env env{ORT_LOGGING_LEVEL_ERROR, "opus-mt"};
  Ort::SessionOptions session_opts;
  std::unique_ptr<Ort::Session> encoder_session;
  std::unique_ptr<Ort::Session> decoder_session;
  std::unique_ptr<Ort::Session> decoder_init_session;  // KV-cache: first-step decoder
  Ort::MemoryInfo memory_info{Ort::MemoryInfo::CreateCpu(
      OrtDeviceAllocator, OrtMemTypeDefault)};
  Ort::AllocatorWithDefaultOptions allocator;

  // Decoder input names, cached for efficiency.
  std::vector<const char*> decoder_input_names;
  std::vector<const char*> decoder_output_names;

  bool decoder_has_kv_cache = false;
  bool decoder_is_fp16 = false;  // true if decoder models expect float16 I/O
  int32_t num_decoder_layers = 6;
  int32_t num_kv_heads = 8;
  int32_t head_dim = 0;  // 0 = not set; infer from config or ONNX model

  // KV cache state for incremental decoder (new ONNX format).
  // Stores the past KV tensors from the previous step to feed as inputs.
  // Layout: 4 * num_layers: for each layer: sk, sv, ek, ev.
  // sk/sv are updated from step decoder output; ek/ev stay from init step.
  std::vector<std::vector<float>> kv_cache_data;
  std::vector<std::vector<int64_t>> kv_cache_shapes;
  bool kv_cache_first_step = true;  // true until first step decoder run

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

  // Sync config-driven hyperparameters into OnnxState so KV-cache logic
  // uses the actual model dimensions rather than hard-coded defaults.
  onnx_->num_decoder_layers = config.decoder_layers;
  onnx_->num_kv_heads = config.decoder_attention_heads;
  onnx_->head_dim = config.d_model / config.decoder_attention_heads;

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

  // Load init decoder for KV-cache models (first-step decoder).
  if (onnx_->decoder_has_kv_cache) {
    // Build init path from decoder path: dir/decoder_init.onnx
    std::string decoder_path = config.decoder_path;
    auto slash = decoder_path.rfind('/');
    std::string dir = (slash != std::string::npos)
                          ? decoder_path.substr(0, slash)
                          : ".";
    std::string init_path = dir + "/decoder_init.onnx";
    std::ifstream test_init(init_path);
    if (!test_init.good()) {
      init_path = dir + "/decoder_model_init.onnx";
    }
    fprintf(stderr, "[opus-mt] Loading init decoder: %s\n", init_path.c_str());
    try {
      onnx_->decoder_init_session = std::make_unique<Ort::Session>(
          onnx_->env, init_path.c_str(), onnx_->session_opts);
      fprintf(stderr, "[opus-mt] Init decoder loaded OK\n");
    } catch (const Ort::Exception& e) {
      last_error_ = std::string("Failed to load init decoder: ") + init_path
                    + " — " + e.what();
      fprintf(stderr, "[opus-mt] Init decoder load FAILED: %s\n", e.what());
      return false;
    }

    // Detect whether decoder models use FP16 I/O.
    // Check encoder_hidden_states input (index 1) on decoder_init.
    auto init_type_info = onnx_->decoder_init_session->GetInputTypeInfo(1);
    auto init_tensor_info = init_type_info.GetTensorTypeAndShapeInfo();
    if (init_tensor_info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
      onnx_->decoder_is_fp16 = true;
      fprintf(stderr, "[opus-mt] Detected FP16 decoder I/O\n");
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
  // Handles both float32 and float16 output.
  auto& output = outputs.front();
  return ReadTensorAsFloat32(output);
}

// ---- Decoder step (KV-cache: first step via init decoder) ---------------

std::vector<float> OpusMtTranslator::RunDecoderStepInit(
    const std::vector<int64_t>& decoder_input_ids,
    const std::vector<float>& encoder_hidden_states,
    const std::vector<int64_t>& encoder_attention_mask) {

  int64_t batch_size = 1;
  int64_t enc_seq_len = static_cast<int64_t>(encoder_attention_mask.size());
  int64_t d_model = config_.d_model;

  // input_ids: [1, 1]
  std::vector<int64_t> ids_shape = {batch_size, 1};
  std::vector<int64_t> ids_copy = decoder_input_ids;
  auto ids_tensor = Ort::Value::CreateTensor<int64_t>(
      onnx_->memory_info, ids_copy.data(), ids_copy.size(),
      ids_shape.data(), ids_shape.size());

  // encoder_hidden_states: [1, enc_seq_len, d_model]
  // May be float32 or float16 depending on the decoder model.
  std::vector<int64_t> enc_shape = {batch_size, enc_seq_len, d_model};
  auto enc_ft = CreateFloatTensorFromVec(
      onnx_->memory_info, encoder_hidden_states, enc_shape,
      onnx_->decoder_is_fp16);

  // encoder_attention_mask: [1, enc_seq_len]
  std::vector<int64_t> mask_shape = {batch_size, enc_seq_len};
  std::vector<int64_t> mask_copy = encoder_attention_mask;
  auto mask_tensor = Ort::Value::CreateTensor<int64_t>(
      onnx_->memory_info, mask_copy.data(), mask_copy.size(),
      mask_shape.data(), mask_shape.size());

  const char* init_inputs[] = {"input_ids", "encoder_hidden_states",
                               "encoder_attention_mask"};
  Ort::Value init_in_vals[] = {std::move(ids_tensor), std::move(enc_ft.tensor),
                               std::move(mask_tensor)};
  size_t num_init_outputs = onnx_->decoder_init_session->GetOutputCount();
  std::vector<const char*> init_out_names(num_init_outputs);
  for (size_t i = 0; i < num_init_outputs; i++) {
    auto name = onnx_->decoder_init_session->GetOutputNameAllocated(
        i, onnx_->allocator);
    init_out_names[i] = name.release();
  }

  auto outputs = onnx_->decoder_init_session->Run(
      onnx_->run_opts, init_inputs, init_in_vals, 3,
      init_out_names.data(), num_init_outputs);

  // logits: [1, 1, vocab_size]
  // Read as float32 regardless of underlying type (handles FP16).
  auto& logits_tensor = outputs.front();
  auto logits = ReadTensorAsFloat32(logits_tensor);

  // Store ALL 4 KVs per layer from init decoder.
  // Output layout: logits, present.0.dk, present.0.dv, present.0.ek, present.0.ev, ...
  int num_layers = onnx_->num_decoder_layers > 0
                       ? onnx_->num_decoder_layers
                       : config_.decoder_layers;
  onnx_->kv_cache_data.resize(4 * num_layers);
  onnx_->kv_cache_shapes.resize(4 * num_layers);
  for (size_t i = 1; i < outputs.size(); i++) {
    auto& out = outputs[i];
    auto info = out.GetTensorTypeAndShapeInfo();
    onnx_->kv_cache_shapes[i - 1] = info.GetShape();
    // Store as float32 regardless of underlying tensor type.
    onnx_->kv_cache_data[i - 1] = ReadTensorAsFloat32(out);
  }

  onnx_->kv_cache_first_step = false;

  for (size_t i = 0; i < num_init_outputs; i++) {
    free(const_cast<char*>(init_out_names[i]));
  }

  return logits;
}

// ---- Decoder step (main) --------------------------------------------------

std::vector<float> OpusMtTranslator::RunDecoderStep(
    const std::vector<int64_t>& decoder_input_ids,
    const std::vector<float>& encoder_hidden_states,
    const std::vector<int64_t>& encoder_attention_mask) {

  // KV-cache first step: route to init decoder.
  if (onnx_->decoder_has_kv_cache && onnx_->kv_cache_first_step) {
    return RunDecoderStepInit(decoder_input_ids, encoder_hidden_states,
                              encoder_attention_mask);
  }

  int64_t batch_size = 1;
  int64_t dec_seq_len = static_cast<int64_t>(decoder_input_ids.size());
  int64_t enc_seq_len = static_cast<int64_t>(encoder_attention_mask.size());
  int64_t d_model = config_.d_model;

  // Build tensors keyed by name, then emit in model order.
  // Use OrtFloatTensor to keep FP16 backing buffers alive alongside Ort::Value.
  std::unordered_map<std::string, OrtFloatTensor> tensor_map;
  bool fp16 = onnx_->decoder_is_fp16;

  // NOTE: All data vectors MUST outlive the Ort::Value tensors created below.
  // Ort::Value::CreateTensor does NOT copy data — it only holds pointers.
  // These are declared here (not in inner scopes) to stay alive through session->Run().

  // input_ids: [1, dec_seq_len] (int64).
  std::vector<int64_t> ids_shape = {batch_size, dec_seq_len};
  std::vector<int64_t> ids_copy = decoder_input_ids;
  {
    OrtFloatTensor ft;
    ft.tensor = Ort::Value::CreateTensor<int64_t>(
        onnx_->memory_info, ids_copy.data(), ids_copy.size(),
        ids_shape.data(), ids_shape.size());
    tensor_map["input_ids"] = std::move(ft);
  }

  // encoder_hidden_states: [1, enc_seq_len, d_model].
  // May be float32 or float16 depending on the decoder model.
  {
    std::vector<int64_t> enc_shape = {batch_size, enc_seq_len, d_model};
    tensor_map["encoder_hidden_states"] = CreateFloatTensorFromVec(
        onnx_->memory_info, encoder_hidden_states, enc_shape, fp16);
  }

  // encoder_attention_mask: [1, enc_seq_len] (int64).
  std::vector<int64_t> mask_shape = {batch_size, enc_seq_len};
  std::vector<int64_t> mask_copy = encoder_attention_mask;
  {
    OrtFloatTensor ft;
    ft.tensor = Ort::Value::CreateTensor<int64_t>(
        onnx_->memory_info, mask_copy.data(), mask_copy.size(),
        mask_shape.data(), mask_shape.size());
    tensor_map["encoder_attention_mask"] = std::move(ft);
  }

  // past_key_values tensors for KV-cache models.
  // First step: empty. Subsequent steps: reuse KVs from previous output.
  // KV cache is always stored as float32; we convert to FP16 if the model
  // requires it.
  std::vector<int64_t> kv_shape;
  std::vector<float> empty_kv;
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

    bool has_cache = !onnx_->kv_cache_data.empty();
    int kv_count = static_cast<int>(onnx_->kv_cache_data.size());

    for (int32_t layer = 0; layer < num_layers; layer++) {
      for (int ki = 0; ki < 4; ki++) {
        const char* ktype = (ki == 0) ? "decoder.key"
                          : (ki == 1) ? "decoder.value"
                          : (ki == 2) ? "encoder.key"
                          :             "encoder.value";
        std::string name =
            "past_key_values." + std::to_string(layer) + "." + ktype;

        int kv_idx = layer * 4 + ki;
        if (has_cache && kv_idx < kv_count) {
          auto& data = onnx_->kv_cache_data[kv_idx];
          auto& shape = onnx_->kv_cache_shapes[kv_idx];
          tensor_map[name] = CreateFloatTensorFromVec(
              onnx_->memory_info, data, shape, fp16);
        } else {
          kv_shape = {batch_size, num_heads, 0, head_dim};
          tensor_map[name] = CreateFloatTensor(
              onnx_->memory_info, nullptr, 0,
              kv_shape.data(), kv_shape.size(), fp16);
        }
      }
    }
  }

  // Emit tensors in model input order.
  std::vector<Ort::Value> input_tensors;
  input_tensors.reserve(onnx_->decoder_input_names.size());
  for (size_t i = 0; i < onnx_->decoder_input_names.size(); i++) {
    auto it = tensor_map.find(onnx_->decoder_input_names[i]);
    if (it != tensor_map.end()) {
      input_tensors.push_back(std::move(it->second.tensor));
    } else {
      // Unknown input: create a dummy empty tensor of the correct float type.
      if (fp16) {
        std::vector<Ort::Float16_t> dummy;
        input_tensors.push_back(Ort::Value::CreateTensor<Ort::Float16_t>(
            onnx_->memory_info, dummy.data(), 0, nullptr, 0));
      } else {
        input_tensors.push_back(Ort::Value::CreateTensor<float>(
            onnx_->memory_info, nullptr, 0, nullptr, 0));
      }
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
  // Read as float32 regardless of underlying type.
  auto& logits_tensor = outputs.front();
  auto logits = ReadTensorAsFloat32(logits_tensor);

  // Store updated KVs for next step (always float32 internally).
  if (onnx_->decoder_has_kv_cache && outputs.size() > 1) {
    onnx_->kv_cache_data.resize(outputs.size() - 1);
    onnx_->kv_cache_shapes.resize(outputs.size() - 1);
    for (size_t i = 1; i < outputs.size(); i++) {
      auto& out = outputs[i];
      auto info = out.GetTensorTypeAndShapeInfo();
      onnx_->kv_cache_shapes[i - 1] = info.GetShape();
      onnx_->kv_cache_data[i - 1] = ReadTensorAsFloat32(out);
    }
  }

  return logits;
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

  // Reset KV cache for a fresh decode.
  onnx_->kv_cache_data.clear();
  onnx_->kv_cache_shapes.clear();
  onnx_->kv_cache_first_step = true;

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

  // Step 4: Greedy decode (timed).
  fprintf(stderr, "[opus-mt] GreedyDecode...\n");
  auto output_ids = GreedyDecode(encoder_hidden_states, attention_mask);
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

  // Step 4: Greedy decode with per-token callbacks (timed).
  fprintf(stderr, "[opus-mt] GreedyDecode (streaming)...\n");
  onnx_->kv_cache_data.clear();
  onnx_->kv_cache_shapes.clear();
  onnx_->kv_cache_first_step = true;
  std::vector<int32_t> output_ids;
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
