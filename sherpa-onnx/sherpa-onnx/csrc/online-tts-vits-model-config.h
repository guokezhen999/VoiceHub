// sherpa-onnx/csrc/online-tts-vits-model-config.h
//
// Copyright (c)  2023  Xiaomi Corporation

#ifndef SHERPA_ONNX_CSRC_ONLINE_TTS_VITS_MODEL_CONFIG_H_
#define SHERPA_ONNX_CSRC_ONLINE_TTS_VITS_MODEL_CONFIG_H_

#include <string>

#include "sherpa-onnx/csrc/parse-options.h"

namespace sherpa_onnx {

struct OnlineTtsVitsModelConfig {
  std::string model;
  std::string lexicon;
  std::string tokens;

  // If data_dir is given, lexicon is ignored
  // data_dir is for piper-phonemize, which uses espeak-ng
  std::string data_dir;

  // Used for Chinese TTS models using jieba
  std::string dict_dir;

  float noise_scale = 0.667;
  float noise_scale_w = 0.8;
  float length_scale = 1;

  std::string model_dir;
  bool stream = false;

  // used only for multi-speaker models, e.g, vctk speech dataset.
  // Not applicable for single-speaker models, e.g., ljspeech dataset

  OnlineTtsVitsModelConfig() = default;

  OnlineTtsVitsModelConfig(const std::string &model,
                                  const std::string &lexicon,
                                  const std::string &tokens,
                                  const std::string &data_dir,
                                  const std::string &dict_dir,
                                  float noise_scale = 0.667,
                                  float noise_scale_w = 0.8, float length_scale = 1,
                                  const std::string &model_dir = "",
                                  bool stream = false)
      : model(model),
        lexicon(lexicon),
        tokens(tokens),
        data_dir(data_dir),
        dict_dir(dict_dir),
        noise_scale(noise_scale),
        noise_scale_w(noise_scale_w),
        length_scale(length_scale),
        model_dir(model_dir),
        stream(stream) {}

  void Register(ParseOptions *po);
  bool Validate() const;

  std::string ToString() const;
};

}  // namespace sherpa_onnx

#endif  // SHERPA_ONNX_CSRC_ONLINE_TTS_VITS_MODEL_CONFIG_H_
