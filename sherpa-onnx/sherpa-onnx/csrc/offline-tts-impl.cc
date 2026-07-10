// sherpa-onnx/csrc/offline-tts-impl.cc
//
// Copyright (c)  2023  Xiaomi Corporation

#include "sherpa-onnx/csrc/offline-tts-impl.h"

#include <memory>
#include <vector>

#if __ANDROID_API__ >= 9
#include "android/asset_manager.h"
#include "android/asset_manager_jni.h"
#endif

#if __OHOS__
#include "rawfile/raw_file_manager.h"
#endif

#include "sherpa-onnx/csrc/offline-tts-kitten-impl.h"
#include "sherpa-onnx/csrc/offline-tts-kokoro-impl.h"
#include "sherpa-onnx/csrc/offline-tts-matcha-impl.h"
#include "sherpa-onnx/csrc/offline-tts-pocket-impl.h"
#include "sherpa-onnx/csrc/offline-tts-supertonic-impl.h"
#include "sherpa-onnx/csrc/offline-tts-vits-impl.h"
#include "sherpa-onnx/csrc/online-tts-vits-impl.h"
#include "sherpa-onnx/csrc/offline-tts-zipvoice-impl.h"
#include "sherpa-onnx/csrc/file-utils.h"

namespace sherpa_onnx {

std::vector<int64_t> OfflineTtsImpl::AddBlank(const std::vector<int64_t> &x,
                                              int32_t blank_id /*= 0*/) const {
  // we assume the blank ID is 0
  std::vector<int64_t> buffer(x.size() * 2 + 1, blank_id);
  int32_t i = 1;
  for (auto k : x) {
    buffer[i] = k;
    i += 2;
  }
  return buffer;
}

std::unique_ptr<OfflineTtsImpl> OfflineTtsImpl::Create(
    const OfflineTtsConfig &config) {
  if (!config.model.online_vits.model.empty() || !config.model.online_vits.model_dir.empty()) {
    return std::make_unique<OnlineTtsVitsImpl>(config);
  } else if (!config.model.vits.model.empty()) {
    std::string model_path = config.model.vits.model;
    if (FileExists(model_path + "/encoder.onnx") && FileExists(model_path + "/decoder.onnx")) {
      OfflineTtsConfig new_config = config;
      new_config.model.online_vits.model_dir = model_path;
      new_config.model.online_vits.lexicon = config.model.vits.lexicon;
      new_config.model.online_vits.tokens = config.model.vits.tokens;
      new_config.model.online_vits.data_dir = config.model.vits.data_dir;
      new_config.model.online_vits.dict_dir = config.model.vits.dict_dir;
      new_config.model.online_vits.noise_scale = config.model.vits.noise_scale;
      new_config.model.online_vits.noise_scale_w = config.model.vits.noise_scale_w;
      new_config.model.online_vits.length_scale = config.model.vits.length_scale;
      new_config.model.online_vits.stream = true;
      return std::make_unique<OnlineTtsVitsImpl>(new_config);
    }
    return std::make_unique<OfflineTtsVitsImpl>(config);
  } else if (!config.model.matcha.acoustic_model.empty()) {
    return std::make_unique<OfflineTtsMatchaImpl>(config);
  } else if (!config.model.zipvoice.encoder.empty() &&
             !config.model.zipvoice.decoder.empty()) {
    return std::make_unique<OfflineTtsZipvoiceImpl>(config);
  } else if (!config.model.kokoro.model.empty()) {
    return std::make_unique<OfflineTtsKokoroImpl>(config);
  } else if (!config.model.kitten.model.empty()) {
    return std::make_unique<OfflineTtsKittenImpl>(config);
  } else if (!config.model.pocket.lm_flow.empty()) {
    return std::make_unique<OfflineTtsPocketImpl>(config);
  } else if (!config.model.supertonic.tts_json.empty()) {
    return std::make_unique<OfflineTtsSupertonicImpl>(config);
  }

  SHERPA_ONNX_LOGE("Please provide a tts model.");

  return {};
}

template <typename Manager>
std::unique_ptr<OfflineTtsImpl> OfflineTtsImpl::Create(
    Manager *mgr, const OfflineTtsConfig &config) {
  if (!config.model.online_vits.model.empty() || !config.model.online_vits.model_dir.empty()) {
    return std::make_unique<OnlineTtsVitsImpl>(mgr, config);
  } else if (!config.model.vits.model.empty()) {
    std::string model_path = config.model.vits.model;
    if (FileExists(model_path + "/encoder.onnx") && FileExists(model_path + "/decoder.onnx")) {
      OfflineTtsConfig new_config = config;
      new_config.model.online_vits.model_dir = model_path;
      new_config.model.online_vits.lexicon = config.model.vits.lexicon;
      new_config.model.online_vits.tokens = config.model.vits.tokens;
      new_config.model.online_vits.data_dir = config.model.vits.data_dir;
      new_config.model.online_vits.dict_dir = config.model.vits.dict_dir;
      new_config.model.online_vits.noise_scale = config.model.vits.noise_scale;
      new_config.model.online_vits.noise_scale_w = config.model.vits.noise_scale_w;
      new_config.model.online_vits.length_scale = config.model.vits.length_scale;
      new_config.model.online_vits.stream = true;
      return std::make_unique<OnlineTtsVitsImpl>(mgr, new_config);
    }
    return std::make_unique<OfflineTtsVitsImpl>(mgr, config);
  } else if (!config.model.matcha.acoustic_model.empty()) {
    return std::make_unique<OfflineTtsMatchaImpl>(mgr, config);
  } else if (!config.model.zipvoice.encoder.empty() &&
             !config.model.zipvoice.decoder.empty()) {
    return std::make_unique<OfflineTtsZipvoiceImpl>(mgr, config);
  } else if (!config.model.kokoro.model.empty()) {
    return std::make_unique<OfflineTtsKokoroImpl>(mgr, config);
  } else if (!config.model.kitten.model.empty()) {
    return std::make_unique<OfflineTtsKittenImpl>(mgr, config);
  } else if (!config.model.pocket.lm_flow.empty()) {
    return std::make_unique<OfflineTtsPocketImpl>(mgr, config);
  } else if (!config.model.supertonic.tts_json.empty()) {
    return std::make_unique<OfflineTtsSupertonicImpl>(mgr, config);
  }

  SHERPA_ONNX_LOGE("Please provide a tts model.");
  return {};
}

#if __ANDROID_API__ >= 9
template std::unique_ptr<OfflineTtsImpl> OfflineTtsImpl::Create(
    AAssetManager *mgr, const OfflineTtsConfig &config);
#endif

#if __OHOS__
template std::unique_ptr<OfflineTtsImpl> OfflineTtsImpl::Create(
    NativeResourceManager *mgr, const OfflineTtsConfig &config);
#endif

}  // namespace sherpa_onnx
