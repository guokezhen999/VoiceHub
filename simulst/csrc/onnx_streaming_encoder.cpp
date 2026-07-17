#include "onnx_streaming_encoder.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <fstream>
#include <memory>
#include <vector>
#include <filesystem>
#include <unordered_map>

#include "npz_loader.h"
#include "nlohmann/json.hpp"
#include <onnxruntime_cxx_api.h>
#if defined(__APPLE__)
#include "coreml_provider_factory.h"
#endif

namespace simulst {
namespace {

static bool DebugEnabled() {
  const char* v = std::getenv("SIMULST_DEBUG");
  return v && v[0] != '\0' && std::string(v) != "0";
}

static void LogProvider(const char* fmt, ...) {
  if (!DebugEnabled()) return;
  va_list args;
  va_start(args, fmt);
  std::vfprintf(stderr, fmt, args);
  va_end(args);
}

static std::string NormalizeProvider(std::string provider) {
  std::transform(provider.begin(), provider.end(), provider.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (provider.empty()) provider = "auto";
  return provider;
}

static std::string GetDirectoryOf(const std::string& path) {
  size_t last_slash = path.find_last_of("/\\");
  if (last_slash == std::string::npos) {
    return ".";
  }
  return path.substr(0, last_slash);
}

static bool AppendCoreMLProvider(Ort::SessionOptions& options,
                                 const std::string& onnx_path,
                                 std::string* error) {
#if defined(__APPLE__)
  try {
    std::string model_dir = GetDirectoryOf(onnx_path);
    std::string cache_dir = model_dir.empty() ? "coreml_cache" : model_dir + "/coreml_cache";

    // Try to create cache directory
    std::error_code ec;
    std::filesystem::create_directories(cache_dir, ec);

    std::unordered_map<std::string, std::string> coreml_options;
    coreml_options["MLComputeUnits"] = "All";
    coreml_options["EnableOnSubgraphs"] = "1";
    coreml_options["ModelFormat"] = "MLProgram";

    if (!ec) {
      coreml_options["ModelCacheDirectory"] = cache_dir;
      LogProvider("[simulst] CoreML cache directory set to: %s\n", cache_dir.c_str());
    } else {
      LogProvider("[simulst] Warning: failed to create CoreML cache directory: %s\n", ec.message().c_str());
    }

    options.AppendExecutionProvider("CoreML", coreml_options);
    return true;
  } catch (const std::exception& e) {
    if (error) *error = std::string("Append CoreML failed: ") + e.what();
    return false;
  }
#else
  if (error) *error = "CoreML is only available on Apple platforms";
  return false;
#endif
}

static bool AppendExecutionProvider(Ort::SessionOptions& options,
                                    const std::string& provider,
                                    const std::string& onnx_path,
                                    std::string* error) {
  if (provider == "cpu") return true;
  if (provider == "coreml") return AppendCoreMLProvider(options, onnx_path, error);
  if (error) *error = "unsupported encoder provider: " + provider;
  return false;
}

}  // namespace

class OnnxStreamingEncoder::OrtHolder {
 public:
  Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "simulst"};
  Ort::SessionOptions session_options;
  std::unique_ptr<Ort::Session> session;
};

OnnxStreamingEncoder::~OnnxStreamingEncoder() { delete ort_; }

static std::string JoinPath(const std::string& a, const std::string& b) {
  if (a.empty()) return b;
  if (a.back() == '/') return a + b;
  return a + "/" + b;
}

bool OnnxStreamingEncoder::CreateSession(const std::string& onnx_path,
                                         const std::string& provider,
                                         int32_t num_threads, std::string* error) {
  try {
    ort_->session_options = Ort::SessionOptions{};
    ort_->session_options.SetIntraOpNumThreads(std::max(1, num_threads));
    ort_->session_options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

    std::string ep_err;
    if (!AppendExecutionProvider(ort_->session_options, provider, onnx_path, &ep_err)) {
      if (error) *error = ep_err;
      return false;
    }

    ort_->session = std::make_unique<Ort::Session>(
        ort_->env, onnx_path.c_str(), ort_->session_options);
    return true;
  } catch (const Ort::Exception& e) {
    if (error) *error = std::string("onnxruntime session failed (") + provider +
                        "): " + e.what();
    ort_->session.reset();
    return false;
  }
}

bool OnnxStreamingEncoder::WarmupRun(std::string* error) {
  std::vector<float> zeros(static_cast<size_t>(input_time_steps_) * feature_dim_, 0.0f);
  const bool ok = RunSession(zeros.data(), input_time_steps_, error);
  Reset();
  return ok;
}

bool OnnxStreamingEncoder::Init(const std::string& export_dir,
                                const std::string& provider, int32_t num_threads,
                                std::string* error) {
  delete ort_;
  ort_ = new OrtHolder();
  active_provider_ = "cpu";
  embed_storage_.clear();
  total_embed_frames_ = 0;
  states_f32_.clear();
  states_i64_.clear();
  state_input_names_.clear();
  output_names_.clear();
  state_shapes_.clear();

  const std::string want = NormalizeProvider(provider);
  std::vector<std::string> providers;
  if (want == "auto") {
#if defined(__APPLE__)
    providers = {"coreml", "cpu"};
#else
    providers = {"cpu"};
#endif
  } else if (want == "coreml") {
    providers = {"coreml", "cpu"};
  } else {
    providers = {"cpu"};
  }

  const std::string meta_path = JoinPath(export_dir, "metadata.json");
  std::ifstream meta_in(meta_path);
  if (!meta_in) {
    if (error) *error = "metadata.json not found in " + export_dir;
    return false;
  }
  nlohmann::json meta;
  try {
    meta_in >> meta;
  } catch (const std::exception& e) {
    if (error) *error = std::string("failed to parse metadata.json: ") + e.what();
    return false;
  }

  feature_dim_ = meta.value("feature_dim", 80);
  llm_dim_ = meta.value("llm_dim", 1024);
  decode_chunk_len_ = meta.value("decode_chunk_len", 32);
  input_time_steps_ = meta.value("input_time_steps", 45);
  const int32_t encoder_chunk_size = meta.value("chunk_size", 16);
  if (meta.contains("embed_frames_per_step")) {
    embed_frames_per_step_ = meta.value("embed_frames_per_step", 2);
  } else if (encoder_chunk_size > 0) {
    embed_frames_per_step_ = std::max(1, decode_chunk_len_ / encoder_chunk_size);
  } else {
    embed_frames_per_step_ = 2;
  }
  const std::string onnx_file = meta.value("onnx_file", "");

  const std::string onnx_path = JoinPath(export_dir, onnx_file);
  const std::string init_states_path = JoinPath(export_dir, "init_states.npz");

  std::map<std::string, std::vector<int64_t>> init_state_shapes;
  if (!NpzLoader::Load(init_states_path, init_float_states_, init_int_states_, error,
                       &init_state_shapes)) {
    return false;
  }

  std::string last_err;
  bool session_ready = false;
  for (const auto& ep : providers) {
    if (!CreateSession(onnx_path, ep, num_threads, &last_err)) {
      LogProvider("[simulst] encoder provider %s create failed: %s\n", ep.c_str(),
                  last_err.c_str());
      continue;
    }

    try {
      Ort::AllocatorWithDefaultOptions allocator;
      state_input_names_.clear();
      output_names_.clear();
      state_shapes_.clear();

      const size_t num_inputs = ort_->session->GetInputCount();
      for (size_t i = 0; i < num_inputs; ++i) {
        auto name = ort_->session->GetInputNameAllocated(i, allocator);
        const std::string input_name = name.get();
        if (input_name == "x") continue;

        state_input_names_.push_back(input_name);
        auto type_info = ort_->session->GetInputTypeInfo(i).GetTensorTypeAndShapeInfo();
        const auto onnx_shape = type_info.GetShape();
        const auto shape_it = init_state_shapes.find(input_name);
        if (shape_it != init_state_shapes.end()) {
          state_shapes_[input_name] = shape_it->second;
        } else {
          state_shapes_[input_name] = onnx_shape;
        }
      }
      const size_t num_outputs = ort_->session->GetOutputCount();
      for (size_t i = 0; i < num_outputs; ++i) {
        auto name = ort_->session->GetOutputNameAllocated(i, allocator);
        output_names_.push_back(name.get());
      }
    } catch (const Ort::Exception& e) {
      last_err = std::string("onnxruntime io metadata failed: ") + e.what();
      LogProvider("[simulst] encoder provider %s io failed: %s\n", ep.c_str(),
                  last_err.c_str());
      ort_->session.reset();
      continue;
    }

    Reset();
    if (!WarmupRun(&last_err)) {
      LogProvider("[simulst] encoder provider %s warmup failed: %s\n", ep.c_str(),
                  last_err.c_str());
      ort_->session.reset();
      continue;
    }

    active_provider_ = ep;
    session_ready = true;
    std::fprintf(stderr,
                 "simulst encoder using ONNX provider: %s "
                 "(embed_frames_per_step=%d)\n",
                 ep.c_str(), embed_frames_per_step_);
    break;
  }

  if (!session_ready) {
    if (error) {
      *error = last_err.empty() ? "failed to initialize ONNX encoder" : last_err;
    }
    return false;
  }

  return true;
}

void OnnxStreamingEncoder::Reset() {
  states_f32_ = init_float_states_;
  states_i64_ = init_int_states_;
  embed_storage_.clear();
  total_embed_frames_ = 0;
}

bool OnnxStreamingEncoder::GetEmbeddings(int32_t start, int32_t end,
                                         std::vector<float>* out) const {
  if (!out) return false;
  out->clear();
  if (start < 0) start = 0;
  if (end > total_embed_frames_) end = total_embed_frames_;
  if (start >= end) return true;
  const int32_t n = end - start;
  out->resize(static_cast<size_t>(n) * llm_dim_);
  std::memcpy(out->data(),
              embed_storage_.data() + static_cast<size_t>(start) * llm_dim_,
              static_cast<size_t>(n) * llm_dim_ * sizeof(float));
  return true;
}

int32_t OnnxStreamingEncoder::TotalEmbedFrames() const { return total_embed_frames_; }

bool OnnxStreamingEncoder::FeedFeatures(const float* features, int32_t num_frames,
                                        std::string* error) {
  if (!ort_ || !ort_->session) {
    if (error) *error = "encoder not initialized";
    return false;
  }
  if (!features || num_frames <= 0) return true;
  if (num_frames != input_time_steps_) {
    if (error) {
      *error = "FeedFeatures expects " + std::to_string(input_time_steps_) +
               " frames, got " + std::to_string(num_frames);
    }
    return false;
  }

  return RunSession(features, input_time_steps_, error);
}

bool OnnxStreamingEncoder::RunSession(const float* features, int32_t num_frames,
                                      std::string* error) {
  try {
    Ort::AllocatorWithDefaultOptions allocator;
    std::vector<std::string> owned_names;
    owned_names.reserve(state_input_names_.size() + 1);
    owned_names.emplace_back("x");
    for (const auto& name : state_input_names_) {
      owned_names.push_back(name);
    }

    std::vector<const char*> input_names;
    input_names.reserve(owned_names.size());
    for (const auto& name : owned_names) {
      input_names.push_back(name.c_str());
    }

    std::vector<Ort::Value> input_tensors;
    input_tensors.reserve(owned_names.size());

    std::vector<int64_t> x_shape = {1, num_frames, feature_dim_};
    input_tensors.push_back(Ort::Value::CreateTensor<float>(
        allocator.GetInfo(), const_cast<float*>(features),
        static_cast<size_t>(num_frames) * feature_dim_, x_shape.data(), x_shape.size()));

    for (size_t i = 1; i < owned_names.size(); ++i) {
      const std::string& name = owned_names[i];

      auto f_it = states_f32_.find(name);
      if (f_it != states_f32_.end()) {
        std::vector<int64_t> shape = state_shapes_.at(name);
        for (auto& d : shape) {
          if (d <= 0) d = 1;
        }
        input_tensors.push_back(Ort::Value::CreateTensor<float>(
            allocator.GetInfo(), f_it->second.data(), f_it->second.size(),
            shape.data(), shape.size()));
        continue;
      }

      auto i_it = states_i64_.find(name);
      if (i_it != states_i64_.end()) {
        std::vector<int64_t> shape = state_shapes_.at(name);
        for (auto& d : shape) {
          if (d <= 0) d = 1;
        }
        input_tensors.push_back(Ort::Value::CreateTensor<int64_t>(
            allocator.GetInfo(), i_it->second.data(), i_it->second.size(),
            shape.data(), shape.size()));
        continue;
      }

      if (error) *error = "missing ONNX state: " + name;
      return false;
    }

    std::vector<const char*> output_name_ptrs;
    for (const auto& n : output_names_) output_name_ptrs.push_back(n.c_str());

    auto outputs = ort_->session->Run(
        Ort::RunOptions{nullptr}, input_names.data(), input_tensors.data(),
        input_tensors.size(), output_name_ptrs.data(), output_name_ptrs.size());

    if (outputs.empty()) {
      if (error) *error = "ONNX session returned no outputs";
      return false;
    }

  // Output 0: embeddings [1, T, llm_dim]
    float* embed_data = outputs[0].GetTensorMutableData<float>();
    auto embed_info = outputs[0].GetTensorTypeAndShapeInfo();
    auto embed_shape = embed_info.GetShape();
    int64_t t = 1;
    if (embed_shape.size() >= 2) t = embed_shape[1];
    if (t <= 0) t = 1;

    const size_t old_frames = static_cast<size_t>(total_embed_frames_);
    embed_storage_.resize((old_frames + static_cast<size_t>(t)) * llm_dim_);
    std::memcpy(embed_storage_.data() + old_frames * llm_dim_, embed_data,
                static_cast<size_t>(t) * llm_dim_ * sizeof(float));
    total_embed_frames_ += static_cast<int32_t>(t);
    if (embed_frames_per_step_ > 0 &&
        static_cast<int32_t>(t) != embed_frames_per_step_ && DebugEnabled()) {
      std::fprintf(stderr,
                   "[simulst] encoder output T=%lld != embed_frames_per_step=%d\n",
                   static_cast<long long>(t), embed_frames_per_step_);
    }

    for (size_t i = 1; i < outputs.size(); ++i) {
      const std::string& state_name = state_input_names_[i - 1];
      auto type = outputs[i].GetTensorTypeAndShapeInfo().GetElementType();
      if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        float* data = outputs[i].GetTensorMutableData<float>();
        size_t count = outputs[i].GetTensorTypeAndShapeInfo().GetElementCount();
        states_f32_[state_name].assign(data, data + count);
        states_i64_.erase(state_name);
      } else if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
        int64_t* data = outputs[i].GetTensorMutableData<int64_t>();
        size_t count = outputs[i].GetTensorTypeAndShapeInfo().GetElementCount();
        states_i64_[state_name].assign(data, data + count);
        states_f32_.erase(state_name);
      }
    }
    return true;
  } catch (const Ort::Exception& e) {
    if (error) *error = std::string("ONNX run failed: ") + e.what();
    return false;
  }
}

}  // namespace simulst
