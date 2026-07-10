// sherpa-onnx/csrc/online-tts-vits-model.h
//
// Copyright (c)  2023  Xiaomi Corporation

#ifndef SHERPA_ONNX_CSRC_ONLINE_TTS_VITS_MODEL_H_
#define SHERPA_ONNX_CSRC_ONLINE_TTS_VITS_MODEL_H_

#include <memory>
#include <string>

#include <functional>
#include "onnxruntime_cxx_api.h"  // NOLINT
#include "sherpa-onnx/csrc/offline-tts-model-config.h"
#include "sherpa-onnx/csrc/offline-tts-vits-model-meta-data.h"
#include "sherpa-onnx/csrc/offline-tts.h"

namespace sherpa_onnx {

class OnlineTtsVitsModel {
 public:
   ~OnlineTtsVitsModel();

  explicit OnlineTtsVitsModel(const OfflineTtsModelConfig &config);

  template <typename Manager>
  OnlineTtsVitsModel(Manager *mgr, const OfflineTtsModelConfig &config);

  using GeneratedAudioCallbackInnel =
      std::function<bool(const GeneratedAudio &audio, float progress)>;

  /** Run the model.
   *
   * @param x A int64 tensor of shape (1, num_tokens)
  // @param sid Speaker ID. Used only for multi-speaker models, e.g., models
  //            trained using the VCTK dataset. It is not used for
  //            single-speaker models, e.g., models trained using the ljspeech
  //            dataset.
   * @return Return a float32 tensor containing audio samples. You can flatten
   *         it to a 1-D tensor.
   */
  Ort::Value Run(Ort::Value x, int64_t sid = 0, float speed = 1.0);

  GeneratedAudio Run(Ort::Value x, int64_t sid, float speed,
                     GeneratedAudioCallbackInnel callback);

  // This is for MeloTTS
  Ort::Value Run(Ort::Value x, Ort::Value tones, int64_t sid = 0,
                 float speed = 1.0) const;

  const OfflineTtsVitsModelMetaData &GetMetaData() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace sherpa_onnx

#endif  // SHERPA_ONNX_CSRC_ONLINE_TTS_VITS_MODEL_H_
