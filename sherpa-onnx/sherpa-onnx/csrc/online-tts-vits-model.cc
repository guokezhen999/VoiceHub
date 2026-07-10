// sherpa-onnx/csrc/offline-tts-vits-model.cc
//
// Copyright (c)  2023  Xiaomi Corporation

#include "sherpa-onnx/csrc/online-tts-vits-model.h"
#include "sherpa-onnx/csrc/ort-env.h"

#include <algorithm>
#include <memory>
#include <string>
#include <utility>
#include <vector>
#include <cassert>
#include <cstring>
#include <sstream>

#if __ANDROID_API__ >= 9
#include "android/asset_manager.h"
#include "android/asset_manager_jni.h"
#endif

#if __OHOS__
#include "rawfile/raw_file_manager.h"
#endif

#include "sherpa-onnx/csrc/file-utils.h"
#include "sherpa-onnx/csrc/macros.h"
#include "sherpa-onnx/csrc/onnx-utils.h"
#include "sherpa-onnx/csrc/session.h"
#include "sherpa-onnx/csrc/text-utils.h"

#define CHUNK_SIZE 32
#define CACHE_FADE_LEN 256

namespace sherpa_onnx {

class OnlineTtsVitsModel::Impl {
 public:
  explicit Impl(const OfflineTtsModelConfig &config)
      : config_(config),
        env_(CreateOrtEnv()),
        sess_opts_(GetSessionOptions(config)),
        allocator_{} {
    std::string model_dir = config.online_vits.model_dir;
    std::string model_path = config.online_vits.model;

    // Detect if model is actually a directory containing encoder/decoder
    if (model_dir.empty() && !model_path.empty()) {
      if (FileExists(model_path + "/encoder.onnx") &&
          FileExists(model_path + "/decoder.onnx")) {
        model_dir = model_path;
        model_path = "";
      }
    }

    if (!model_dir.empty()) {
      is_split_model_ = true;
      std::string encoder_onnx_path = model_dir + "/encoder.onnx";
      std::string decoder_onnx_path = model_dir + "/decoder.onnx";

      auto bufEncode = ReadFile(encoder_onnx_path);
      InitEncode(bufEncode.data(), bufEncode.size());

      auto bufDecode = ReadFile(decoder_onnx_path);
      InitDecode(bufDecode.data(), bufDecode.size());
    } else {
      sess_ = std::make_unique<Ort::Session>(
          env_, SHERPA_ONNX_TO_ORT_PATH(model_path), sess_opts_);
      Init(nullptr, 0);
    }
  }

  template <typename Manager>
  Impl(Manager *mgr, const OfflineTtsModelConfig &config)
      : config_(config),
        env_(CreateOrtEnv()),
        sess_opts_(GetSessionOptions(config)),
        allocator_{} {
    std::string model_dir = config.online_vits.model_dir;
    std::string model_path = config.online_vits.model;

    // Detect if model is actually a directory containing encoder/decoder
    if (model_dir.empty() && !model_path.empty()) {
      if (FileExists(model_path + "/encoder.onnx") &&
          FileExists(model_path + "/decoder.onnx")) {
        model_dir = model_path;
        model_path = "";
      }
    }

    if (!model_dir.empty()) {
      is_split_model_ = true;
      std::string encoder_onnx_path = model_dir + "/encoder.onnx";
      std::string decoder_onnx_path = model_dir + "/decoder.onnx";

      auto bufEncode = ReadFile(mgr, encoder_onnx_path);
      InitEncode(bufEncode.data(), bufEncode.size());

      auto bufDecode = ReadFile(mgr, decoder_onnx_path);
      InitDecode(bufDecode.data(), bufDecode.size());
    } else {
      auto buf = ReadFile(mgr, model_path);
      Init(buf.data(), buf.size());
    }
  }

  Ort::Value Run(Ort::Value x, int64_t sid, float speed) {
    if (meta_data_.is_piper || meta_data_.is_coqui) {
      return RunVitsPiperOrCoqui(std::move(x), sid, speed);
    }

    return RunVits(std::move(x), sid, speed);
  }

  GeneratedAudio Run(Ort::Value x, int64_t sid, float speed,
                     GeneratedAudioCallbackInnel callback) {
    if (is_split_model_) {
      if (meta_data_.is_piper || meta_data_.is_coqui) {
        return RunVitsPiperOrCoquiSplit(std::move(x), sid, speed, callback);
      }
      return RunVitsSplit(std::move(x), sid, speed, callback);
    } else {
      Ort::Value audio = Run(std::move(x), sid, speed);
      GeneratedAudio ans = GetAudio(std::move(audio));
      if (callback) {
        callback(ans, 1.0);
      }
      return ans;
    }
  }

  Ort::Value Run(Ort::Value x, Ort::Value tones, int64_t sid, float speed) {
    if (meta_data_.num_speakers == 1) {
      // For MeloTTS, we hardcode sid to the one contained in the meta data
      sid = meta_data_.speaker_id;
    }

    auto memory_info =
        Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);

    std::vector<int64_t> x_shape = x.GetTensorTypeAndShapeInfo().GetShape();
    if (x_shape[0] != 1) {
      SHERPA_ONNX_LOGE("Support only batch_size == 1. Given: %d",
                       static_cast<int32_t>(x_shape[0]));
      SHERPA_ONNX_EXIT(-1);
    }

    int64_t len = x_shape[1];
    int64_t len_shape = 1;

    Ort::Value x_length =
        Ort::Value::CreateTensor(memory_info, &len, 1, &len_shape, 1);

    int64_t scale_shape = 1;
    float noise_scale = config_.online_vits.noise_scale;
    float length_scale = config_.online_vits.length_scale;
    float noise_scale_w = config_.online_vits.noise_scale_w;

    if (speed != 1 && speed > 0) {
      length_scale = 1. / speed;
    }

    Ort::Value noise_scale_tensor =
        Ort::Value::CreateTensor(memory_info, &noise_scale, 1, &scale_shape, 1);

    Ort::Value length_scale_tensor = Ort::Value::CreateTensor(
        memory_info, &length_scale, 1, &scale_shape, 1);

    Ort::Value noise_scale_w_tensor = Ort::Value::CreateTensor(
        memory_info, &noise_scale_w, 1, &scale_shape, 1);

    Ort::Value sid_tensor =
        Ort::Value::CreateTensor(memory_info, &sid, 1, &scale_shape, 1);

    std::vector<Ort::Value> inputs;
    inputs.reserve(7);
    inputs.push_back(std::move(x));
    inputs.push_back(std::move(x_length));
    inputs.push_back(std::move(tones));
    inputs.push_back(std::move(sid_tensor));
    inputs.push_back(std::move(noise_scale_tensor));
    inputs.push_back(std::move(length_scale_tensor));
    inputs.push_back(std::move(noise_scale_w_tensor));

    auto out =
        sess_->Run({}, input_names_ptr_.data(), inputs.data(), inputs.size(),
                   output_names_ptr_.data(), output_names_ptr_.size());

    return std::move(out[0]);
  }

  const OfflineTtsVitsModelMetaData &GetMetaData() const { return meta_data_; }

 private:
  void ParseMetaData(const Ort::ModelMetadata &meta_data) {
    Ort::AllocatorWithDefaultOptions allocator;  // used in the macro below
    SHERPA_ONNX_READ_META_DATA(meta_data_.sample_rate, "sample_rate");
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.add_blank, "add_blank",
                                            0);

    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.speaker_id, "speaker_id",
                                            0);
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.version, "version", 0);
    SHERPA_ONNX_READ_META_DATA(meta_data_.num_speakers, "n_speakers");
    SHERPA_ONNX_READ_META_DATA_STR_WITH_DEFAULT(meta_data_.punctuations,
                                                "punctuation", "");
    SHERPA_ONNX_READ_META_DATA_STR(meta_data_.language, "language");

    SHERPA_ONNX_READ_META_DATA_STR_WITH_DEFAULT(meta_data_.voice, "voice", "");

    SHERPA_ONNX_READ_META_DATA_STR_WITH_DEFAULT(meta_data_.frontend, "frontend",
                                                "");

    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.jieba, "jieba", 0);
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.blank_id, "blank_id", 0);
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.bos_id, "bos_id", 0);
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.eos_id, "eos_id", 0);
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.use_eos_bos,
                                            "use_eos_bos", 1);
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.pad_id, "pad_id", 0);
    SHERPA_ONNX_READ_META_DATA_WITH_DEFAULT(meta_data_.use_g2pw, "has_g2pw", 0);

    std::string comment;
    SHERPA_ONNX_READ_META_DATA_STR(comment, "comment");

    if (comment.find("piper") != std::string::npos) {
      meta_data_.is_piper = true;
    }

    if (comment.find("coqui") != std::string::npos) {
      meta_data_.is_coqui = true;
    }

    if (comment.find("icefall") != std::string::npos) {
      meta_data_.is_icefall = true;
    }

    if (comment.find("melo") != std::string::npos) {
      meta_data_.is_melo_tts = true;
      int32_t expected_version = 2;
      if (meta_data_.version < expected_version) {
        SHERPA_ONNX_LOGE(
            "Please download the latest MeloTTS model and retry. Current "
            "version: %d. Expected version: %d",
            meta_data_.version, expected_version);
        SHERPA_ONNX_EXIT(-1);
      }
    }
  }

  void Init(void *model_data, size_t model_data_length) {
    if (model_data) {
      sess_ = std::make_unique<Ort::Session>(env_, model_data,
                                             model_data_length, sess_opts_);
    } else if (!sess_) {
      SHERPA_ONNX_LOGE(
          "Please pass model data or initialize the session outside of "
          "this function");
      SHERPA_ONNX_EXIT(-1);
    }

    GetInputNames(sess_.get(), &input_names_, &input_names_ptr_);

    GetOutputNames(sess_.get(), &output_names_, &output_names_ptr_);

    // get meta data
    Ort::ModelMetadata meta_data = sess_->GetModelMetadata();
    if (config_.debug) {
      std::ostringstream os;
      os << "---vits model---\n";
      PrintModelMetadata(os, meta_data);

      os << "----------input names----------\n";
      int32_t i = 0;
      for (const auto &s : input_names_) {
        os << i << " " << s << "\n";
        ++i;
      }
      os << "----------output names----------\n";
      i = 0;
      for (const auto &s : output_names_) {
        os << i << " " << s << "\n";
        ++i;
      }

#if __OHOS__
      SHERPA_ONNX_LOGE("%{public}s\n", os.str().c_str());
#else
      SHERPA_ONNX_LOGE("%s\n", os.str().c_str());
#endif
    }

    ParseMetaData(meta_data);
  }

  void InitEncode(void *model_data, size_t model_data_length) {
    encode_sess_ = std::make_unique<Ort::Session>(
        env_, model_data, model_data_length, sess_opts_);

    GetInputNames(encode_sess_.get(), &encode_input_names_,
                  &encode_input_names_ptr_);

    GetOutputNames(encode_sess_.get(), &encode_output_names_,
                   &encode_output_names_ptr_);

    Ort::ModelMetadata meta_data = encode_sess_->GetModelMetadata();
    if (config_.debug) {
      std::ostringstream os;
      os << "---vits model---\n";
      PrintModelMetadata(os, meta_data);

      os << "----------input names----------\n";
      int32_t i = 0;
      for (const auto &s : encode_input_names_) {
        os << i << " " << s << "\n";
        ++i;
      }
      os << "----------output names----------\n";
      i = 0;
      for (const auto &s : encode_output_names_) {
        os << i << " " << s << "\n";
        ++i;
      }

#if __OHOS__
      SHERPA_ONNX_LOGE("%{public}s\n", os.str().c_str());
#else
      SHERPA_ONNX_LOGE("%s\n", os.str().c_str());
#endif
    }

    ParseMetaData(meta_data);
  }

  void InitDecode(void *model_data, size_t model_data_length) {
    decode_sess_ = std::make_unique<Ort::Session>(
        env_, model_data, model_data_length, sess_opts_);

    GetInputNames(decode_sess_.get(), &decode_input_names_,
                  &decode_input_names_ptr_);

    GetOutputNames(decode_sess_.get(), &decode_output_names_,
                   &decode_output_names_ptr_);

    Ort::ModelMetadata meta_data = decode_sess_->GetModelMetadata();
    if (config_.debug) {
      std::ostringstream os;
      os << "---vits model---\n";
      PrintModelMetadata(os, meta_data);

      os << "----------input names----------\n";
      int32_t i = 0;
      for (const auto &s : decode_input_names_) {
        os << i << " " << s << "\n";
        ++i;
      }
      os << "----------output names----------\n";
      i = 0;
      for (const auto &s : decode_output_names_) {
        os << i << " " << s << "\n";
        ++i;
      }

#if __OHOS__
      SHERPA_ONNX_LOGE("%{public}s\n", os.str().c_str());
#else
      SHERPA_ONNX_LOGE("%s\n", os.str().c_str());
#endif
    }
  }

  GeneratedAudio GetAudio(Ort::Value audio) {
    std::vector<int64_t> audio_shape =
        audio.GetTensorTypeAndShapeInfo().GetShape();

    int64_t total = 1;
    for (auto i : audio_shape) {
      total *= i;
    }

    const float *p = audio.GetTensorData<float>();

    GeneratedAudio ans;
    ans.sample_rate = meta_data_.sample_rate;
    ans.samples = std::vector<float>(p, p + total);

    return ans;
  }

  std::vector<float> crossfade(const std::vector<float> &data1,
                               const std::vector<float> &data2) {
    assert(data1.size() == data2.size() && data1.size() == CACHE_FADE_LEN);
    int len = data1.size();
    std::vector<float> ret(CACHE_FADE_LEN);
    for (int i = 0; i < len; i++) {
      ret[i] =
          (data1[i] * (len - i) +
           data2[i] * i) /
          len;
    }
    return ret;
  }

  Ort::Value RunVitsPiperOrCoqui(Ort::Value x, int64_t sid, float speed) {
    auto memory_info =
        Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);

    std::vector<int64_t> x_shape = x.GetTensorTypeAndShapeInfo().GetShape();
    if (x_shape[0] != 1) {
      SHERPA_ONNX_LOGE("Support only batch_size == 1. Given: %d",
                       static_cast<int32_t>(x_shape[0]));
      SHERPA_ONNX_EXIT(-1);
    }

    int64_t len = x_shape[1];
    int64_t len_shape = 1;

    Ort::Value x_length =
        Ort::Value::CreateTensor(memory_info, &len, 1, &len_shape, 1);

    float noise_scale = config_.online_vits.noise_scale;
    float length_scale = config_.online_vits.length_scale;
    float noise_scale_w = config_.online_vits.noise_scale_w;

    if (speed != 1 && speed > 0) {
      length_scale = 1. / speed;
    }
    std::array<float, 3> scales = {noise_scale, length_scale, noise_scale_w};

    int64_t scale_shape = 3;

    Ort::Value scales_tensor = Ort::Value::CreateTensor(
        memory_info, scales.data(), scales.size(), &scale_shape, 1);

    int64_t sid_shape = 1;
    Ort::Value sid_tensor =
        Ort::Value::CreateTensor(memory_info, &sid, 1, &sid_shape, 1);

    int64_t lang_id_shape = 1;
    int64_t lang_id = 0;
    Ort::Value lang_id_tensor =
        Ort::Value::CreateTensor(memory_info, &lang_id, 1, &lang_id_shape, 1);

    std::vector<Ort::Value> inputs;
    inputs.reserve(5);
    inputs.push_back(std::move(x));
    inputs.push_back(std::move(x_length));
    inputs.push_back(std::move(scales_tensor));

    if (input_names_.size() >= 4 && input_names_[3] == "sid") {
      inputs.push_back(std::move(sid_tensor));
    }

    if (input_names_.size() >= 5 && input_names_[4] == "langid") {
      inputs.push_back(std::move(lang_id_tensor));
    }

    auto out =
        sess_->Run({}, input_names_ptr_.data(), inputs.data(), inputs.size(),
                   output_names_ptr_.data(), output_names_ptr_.size());

    return std::move(out[0]);
  }

  GeneratedAudio RunVitsPiperOrCoquiSplit(Ort::Value x, int64_t sid, float speed,
                                          GeneratedAudioCallbackInnel callback) {
    auto memory_info =
        Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);

    std::vector<int64_t> x_shape = x.GetTensorTypeAndShapeInfo().GetShape();
    if (x_shape[0] != 1) {
      SHERPA_ONNX_LOGE("Support only batch_size == 1. Given: %d",
                       static_cast<int32_t>(x_shape[0]));
      SHERPA_ONNX_EXIT(-1);
    }

    int64_t len = x_shape[1];
    int64_t len_shape = 1;

    Ort::Value x_length =
        Ort::Value::CreateTensor(memory_info, &len, 1, &len_shape, 1);

    float noise_scale = config_.online_vits.noise_scale;
    float length_scale = config_.online_vits.length_scale;
    float noise_scale_w = config_.online_vits.noise_scale_w;

    if (speed != 1 && speed > 0) {
      length_scale = 1. / speed;
    }
    std::array<float, 3> scales = {noise_scale, length_scale, noise_scale_w};

    std::vector<int64_t> scale_shape = {1, static_cast<int64_t>(scales.size())};

    Ort::Value scales_tensor =
        Ort::Value::CreateTensor(memory_info, scales.data(), scales.size(),
                                 scale_shape.data(), scale_shape.size());

    int64_t sid_shape = 1;
    Ort::Value sid_tensor =
        Ort::Value::CreateTensor(memory_info, &sid, 1, &sid_shape, 1);

    int64_t lang_id_shape = 1;
    int64_t lang_id = 0;
    Ort::Value lang_id_tensor =
        Ort::Value::CreateTensor(memory_info, &lang_id, 1, &lang_id_shape, 1);

    std::vector<Ort::Value> encode_inputs;
    encode_inputs.reserve(5);
    encode_inputs.push_back(std::move(x));
    encode_inputs.push_back(std::move(x_length));
    encode_inputs.push_back(std::move(scales_tensor));

    if (encode_input_names_.size() >= 4 && encode_input_names_[3] == "sid") {
      encode_inputs.push_back(std::move(sid_tensor));
    }

    if (encode_input_names_.size() >= 5 && encode_input_names_[4] == "langid") {
      encode_inputs.push_back(std::move(lang_id_tensor));
    }

    auto encode_out = encode_sess_->Run(
        {}, encode_input_names_ptr_.data(), encode_inputs.data(),
        encode_inputs.size(), encode_output_names_ptr_.data(),
        encode_output_names_ptr_.size());

    auto z = std::move(encode_out[0]);
    auto g = std::move(encode_out[1]);

    if (config_.online_vits.stream || callback != nullptr) {
      GeneratedAudio ans;
      auto z_shape = z.GetTensorTypeAndShapeInfo().GetShape();
      auto g_shape = g.GetTensorTypeAndShapeInfo().GetShape();
      int64_t z_len = z_shape[2];
      auto g_data = g.GetTensorMutableData<float>();
      int64_t g_data_len = g_shape[0] * g_shape[1] * g_shape[2];
      std::vector<float> cacheForFadeTail, cacheForFadeHead;
      cacheForFadeTail.reserve(CACHE_FADE_LEN);
      cacheForFadeHead.reserve(CACHE_FADE_LEN);

      size_t num_chunks = (z_shape[2] + CHUNK_SIZE - 1) / CHUNK_SIZE;
      for (size_t i = 0; i < num_chunks; ++i) {
        size_t start_col = i * CHUNK_SIZE;
        size_t end_col =
            std::min(start_col + CHUNK_SIZE, static_cast<size_t>(z_shape[2]));

        size_t chunk_size = z_shape[0] * z_shape[1] * (end_col - start_col);
        std::vector<float> z_chunk_data(chunk_size);

        const float *src = z.GetTensorData<float>() + start_col;
        for (size_t j = 0; j < z_shape[0] * z_shape[1]; ++j) {
          memcpy(z_chunk_data.data() + j * (end_col - start_col),
                 src + j * z_shape[2], (end_col - start_col) * sizeof(float));
        }

        std::vector<int64_t> z_chunk_shape = {
            z_shape[0], z_shape[1], static_cast<int64_t>(end_col - start_col)};
        Ort::Value z_chunk_tensor = Ort::Value::CreateTensor<float>(
            memory_info, z_chunk_data.data(), z_chunk_data.size(),
            z_chunk_shape.data(), z_chunk_shape.size());

        std::vector<Ort::Value> decode_inputs;
        decode_inputs.push_back(std::move(z_chunk_tensor));
        Ort::Value g_copy = Ort::Value::CreateTensor<float>(
            memory_info, g_data, g_data_len, g_shape.data(), g_shape.size());
        decode_inputs.push_back(std::move(g_copy));
        auto decode_out = decode_sess_->Run(
            {}, decode_input_names_ptr_.data(), decode_inputs.data(),
            decode_inputs.size(), decode_output_names_ptr_.data(),
            decode_output_names_ptr_.size());

        auto audio = GetAudio(std::move(decode_out[0]));
        if (num_chunks > 1) {
          assert(audio.samples.size() > CACHE_FADE_LEN);
          if (i != 0 && !cacheForFadeTail.empty()) {
            if (audio.samples.size() > CACHE_FADE_LEN) {
              cacheForFadeHead.assign(audio.samples.begin(),
                                      audio.samples.begin() + CACHE_FADE_LEN);
              audio.samples.erase(audio.samples.begin(),
                                  audio.samples.begin() + CACHE_FADE_LEN);
              auto fadeData = crossfade(cacheForFadeTail, cacheForFadeHead);
              audio.samples.insert(audio.samples.begin(), fadeData.begin(),
                                   fadeData.end());
              cacheForFadeHead.clear();
              cacheForFadeTail.clear();
            } else {
              cacheForFadeTail.clear();
            }
          }

          if (i != num_chunks - 1) {
            if (audio.samples.size() > CACHE_FADE_LEN) {
              cacheForFadeTail.assign(audio.samples.end() - CACHE_FADE_LEN,
                                      audio.samples.end());
              audio.samples.erase(audio.samples.end() - CACHE_FADE_LEN,
                                  audio.samples.end());
            }
          }
        }

        if (callback) {
          if (!callback(audio, end_col * 1.0 / z_shape[2])) {
            break;
          }
        }
        ans.sample_rate = meta_data_.sample_rate;
        ans.samples.insert(ans.samples.end(), audio.samples.begin(),
                           audio.samples.end());
      }
      return ans;
    } else {
      std::vector<Ort::Value> decode_inputs;
      decode_inputs.reserve(2);
      decode_inputs.push_back(std::move(z));
      decode_inputs.push_back(std::move(g));
      auto decode_out = decode_sess_->Run(
          {}, decode_input_names_ptr_.data(), decode_inputs.data(),
          decode_inputs.size(), decode_output_names_ptr_.data(),
          decode_output_names_ptr_.size());
      auto audio = GetAudio(std::move(decode_out[0]));
      if (callback) {
        callback(audio, 1.0);
      }
      return audio;
    }
  }

  Ort::Value RunVits(Ort::Value x, int64_t sid, float speed) {
    auto memory_info =
        Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);

    std::vector<int64_t> x_shape = x.GetTensorTypeAndShapeInfo().GetShape();
    if (x_shape[0] != 1) {
      SHERPA_ONNX_LOGE("Support only batch_size == 1. Given: %d",
                       static_cast<int32_t>(x_shape[0]));
      SHERPA_ONNX_EXIT(-1);
    }

    int64_t len = x_shape[1];
    int64_t len_shape = 1;

    Ort::Value x_length =
        Ort::Value::CreateTensor(memory_info, &len, 1, &len_shape, 1);

    int64_t scale_shape = 1;
    float noise_scale = config_.online_vits.noise_scale;
    float length_scale = config_.online_vits.length_scale;
    float noise_scale_w = config_.online_vits.noise_scale_w;

    if (speed != 1 && speed > 0) {
      length_scale = 1. / speed;
    }

    Ort::Value noise_scale_tensor =
        Ort::Value::CreateTensor(memory_info, &noise_scale, 1, &scale_shape, 1);

    Ort::Value length_scale_tensor = Ort::Value::CreateTensor(
        memory_info, &length_scale, 1, &scale_shape, 1);

    Ort::Value noise_scale_w_tensor = Ort::Value::CreateTensor(
        memory_info, &noise_scale_w, 1, &scale_shape, 1);

    Ort::Value sid_tensor =
        Ort::Value::CreateTensor(memory_info, &sid, 1, &scale_shape, 1);

    std::vector<Ort::Value> inputs;
    inputs.reserve(6);
    inputs.push_back(std::move(x));
    inputs.push_back(std::move(x_length));
    inputs.push_back(std::move(noise_scale_tensor));
    inputs.push_back(std::move(length_scale_tensor));
    inputs.push_back(std::move(noise_scale_w_tensor));

    if (input_names_.size() == 6 &&
        (input_names_.back() == "sid" || input_names_.back() == "speaker")) {
      inputs.push_back(std::move(sid_tensor));
    }

    auto out =
        sess_->Run({}, input_names_ptr_.data(), inputs.data(), inputs.size(),
                   output_names_ptr_.data(), output_names_ptr_.size());

    return std::move(out[0]);
  }

  GeneratedAudio RunVitsSplit(Ort::Value x, int64_t sid, float speed,
                              GeneratedAudioCallbackInnel callback) {
    auto memory_info =
        Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);

    std::vector<int64_t> x_shape = x.GetTensorTypeAndShapeInfo().GetShape();
    if (x_shape[0] != 1) {
      SHERPA_ONNX_LOGE("Support only batch_size == 1. Given: %d",
                       static_cast<int32_t>(x_shape[0]));
      SHERPA_ONNX_EXIT(-1);
    }

    int64_t len = x_shape[1];
    int64_t len_shape = 1;

    Ort::Value x_length =
        Ort::Value::CreateTensor(memory_info, &len, 1, &len_shape, 1);

    float noise_scale = config_.online_vits.noise_scale;
    float length_scale = config_.online_vits.length_scale;
    float noise_scale_w = config_.online_vits.noise_scale_w;

    if (speed != 1 && speed > 0) {
      length_scale = 1. / speed;
    }
    std::vector<float> scales_vec = {noise_scale, length_scale, noise_scale_w};
    std::vector<int64_t> scale_shape = {
        1, static_cast<int64_t>(scales_vec.size())};
    Ort::Value scales = Ort::Value::CreateTensor(
        memory_info, scales_vec.data(), scales_vec.size(), scale_shape.data(),
        scale_shape.size());

    int64_t sid_shape = 1;
    Ort::Value sid_tensor =
        Ort::Value::CreateTensor(memory_info, &sid, 1, &sid_shape, 1);

    std::vector<Ort::Value> encode_inputs;
    encode_inputs.reserve(4);
    encode_inputs.push_back(std::move(x));
    encode_inputs.push_back(std::move(x_length));
    encode_inputs.push_back(std::move(scales));

    if (encode_input_names_.size() == 4 &&
        (encode_input_names_.back() == "sid" ||
         encode_input_names_.back() == "speaker")) {
      encode_inputs.push_back(std::move(sid_tensor));
    }

    auto encode_out = encode_sess_->Run(
        {}, encode_input_names_ptr_.data(), encode_inputs.data(),
        encode_inputs.size(), encode_output_names_ptr_.data(),
        encode_output_names_ptr_.size());

    auto z = std::move(encode_out[0]);
    auto g = std::move(encode_out[1]);

    if (config_.online_vits.stream || callback != nullptr) {
      GeneratedAudio ans;
      auto z_shape = z.GetTensorTypeAndShapeInfo().GetShape();
      auto g_shape = g.GetTensorTypeAndShapeInfo().GetShape();
      int64_t z_len = z_shape[2];
      auto g_data = g.GetTensorMutableData<float>();
      int64_t g_data_len = g_shape[0] * g_shape[1] * g_shape[2];
      std::vector<float> cacheForFadeTail, cacheForFadeHead;
      cacheForFadeTail.reserve(CACHE_FADE_LEN);
      cacheForFadeHead.reserve(CACHE_FADE_LEN);

      size_t num_chunks = (z_shape[2] + CHUNK_SIZE - 1) / CHUNK_SIZE;
      for (size_t i = 0; i < num_chunks; ++i) {
        size_t start_col = i * CHUNK_SIZE;
        size_t end_col =
            std::min(start_col + CHUNK_SIZE, static_cast<size_t>(z_shape[2]));

        size_t chunk_size = z_shape[0] * z_shape[1] * (end_col - start_col);
        std::vector<float> z_chunk_data(chunk_size);

        const float *src = z.GetTensorData<float>() + start_col;
        for (size_t j = 0; j < z_shape[0] * z_shape[1]; ++j) {
          memcpy(z_chunk_data.data() + j * (end_col - start_col),
                 src + j * z_shape[2], (end_col - start_col) * sizeof(float));
        }

        std::vector<int64_t> z_chunk_shape = {
            z_shape[0], z_shape[1], static_cast<int64_t>(end_col - start_col)};
        Ort::Value z_chunk_tensor = Ort::Value::CreateTensor<float>(
            memory_info, z_chunk_data.data(), z_chunk_data.size(),
            z_chunk_shape.data(), z_chunk_shape.size());

        std::vector<Ort::Value> decode_inputs;
        decode_inputs.push_back(std::move(z_chunk_tensor));
        Ort::Value g_copy = Ort::Value::CreateTensor<float>(
            memory_info, g_data, g_data_len, g_shape.data(), g_shape.size());
        decode_inputs.push_back(std::move(g_copy));
        auto decode_out = decode_sess_->Run(
            {}, decode_input_names_ptr_.data(), decode_inputs.data(),
            decode_inputs.size(), decode_output_names_ptr_.data(),
            decode_output_names_ptr_.size());

        auto audio = GetAudio(std::move(decode_out[0]));
        if (num_chunks > 1) {
          assert(audio.samples.size() > CACHE_FADE_LEN);
          if (i != 0 && !cacheForFadeTail.empty()) {
            if (audio.samples.size() > CACHE_FADE_LEN) {
              cacheForFadeHead.assign(audio.samples.begin(),
                                      audio.samples.begin() + CACHE_FADE_LEN);
              audio.samples.erase(audio.samples.begin(),
                                  audio.samples.begin() + CACHE_FADE_LEN);
              auto fadeData = crossfade(cacheForFadeTail, cacheForFadeHead);
              audio.samples.insert(audio.samples.begin(), fadeData.begin(),
                                   fadeData.end());
              cacheForFadeHead.clear();
              cacheForFadeTail.clear();
            } else {
              cacheForFadeTail.clear();
            }
          }

          if (i != num_chunks - 1) {
            if (audio.samples.size() > CACHE_FADE_LEN) {
              cacheForFadeTail.assign(audio.samples.end() - CACHE_FADE_LEN,
                                      audio.samples.end());
              audio.samples.erase(audio.samples.end() - CACHE_FADE_LEN,
                                  audio.samples.end());
            }
          }
        }

        if (callback) {
          if (!callback(audio, end_col * 1.0 / z_shape[2])) {
            break;
          }
        }
        ans.sample_rate = meta_data_.sample_rate;
        ans.samples.insert(ans.samples.end(), audio.samples.begin(),
                           audio.samples.end());
      }
      return ans;
    } else {
      std::vector<Ort::Value> decode_inputs;
      decode_inputs.reserve(2);
      decode_inputs.push_back(std::move(z));
      decode_inputs.push_back(std::move(g));

      auto decode_out = decode_sess_->Run(
          {}, decode_input_names_ptr_.data(), decode_inputs.data(),
          decode_inputs.size(), decode_output_names_ptr_.data(),
          decode_output_names_ptr_.size());

      auto audio = GetAudio(std::move(decode_out[0]));
      if (callback) {
        callback(audio, 1.0);
      }
      return audio;
    }
  }

 private:
  OfflineTtsModelConfig config_;
  Ort::Env env_;
  Ort::SessionOptions sess_opts_;
  Ort::AllocatorWithDefaultOptions allocator_;

  std::unique_ptr<Ort::Session> sess_;
  std::unique_ptr<Ort::Session> encode_sess_;
  std::unique_ptr<Ort::Session> decode_sess_;

  std::vector<std::string> input_names_;
  std::vector<const char *> input_names_ptr_;

  std::vector<std::string> output_names_;
  std::vector<const char *> output_names_ptr_;

  OfflineTtsVitsModelMetaData meta_data_;

  std::vector<std::string> encode_input_names_;
  std::vector<const char *> encode_input_names_ptr_;

  std::vector<std::string> encode_output_names_;
  std::vector<const char *> encode_output_names_ptr_;

  std::vector<std::string> decode_input_names_;
  std::vector<const char *> decode_input_names_ptr_;

  std::vector<std::string> decode_output_names_;
  std::vector<const char *> decode_output_names_ptr_;

  bool is_split_model_ = false;
};

OnlineTtsVitsModel::OnlineTtsVitsModel(const OfflineTtsModelConfig &config)
    : impl_(std::make_unique<Impl>(config)) {}

template <typename Manager>
OnlineTtsVitsModel::OnlineTtsVitsModel(Manager *mgr,
                                         const OfflineTtsModelConfig &config)
    : impl_(std::make_unique<Impl>(mgr, config)) {}

OnlineTtsVitsModel::~OnlineTtsVitsModel() = default;

Ort::Value OnlineTtsVitsModel::Run(Ort::Value x, int64_t sid /*=0*/,
                                    float speed /*= 1.0*/) {
  return impl_->Run(std::move(x), sid, speed);
}

GeneratedAudio OnlineTtsVitsModel::Run(
    Ort::Value x, int64_t sid, float speed,
    GeneratedAudioCallbackInnel callback) {
  return impl_->Run(std::move(x), sid, speed, callback);
}

Ort::Value OnlineTtsVitsModel::Run(Ort::Value x, Ort::Value tones,
                                    int64_t sid /*= 0*/,
                                    float speed /*= 1.0*/) const {
  return impl_->Run(std::move(x), std::move(tones), sid, speed);
}

const OfflineTtsVitsModelMetaData &OnlineTtsVitsModel::GetMetaData() const {
  return impl_->GetMetaData();
}

#if __ANDROID_API__ >= 9
template OnlineTtsVitsModel::OnlineTtsVitsModel(
    AAssetManager *mgr, const OfflineTtsModelConfig &config);
#endif

#if __OHOS__
template OnlineTtsVitsModel::OnlineTtsVitsModel(
    NativeResourceManager *mgr, const OfflineTtsModelConfig &config);
#endif

}  // namespace sherpa_onnx
