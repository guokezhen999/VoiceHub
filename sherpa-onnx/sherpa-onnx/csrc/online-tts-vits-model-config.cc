// sherpa-onnx/csrc/online-tts-vits-model-config.cc
//
// Copyright (c)  2023  Xiaomi Corporation

#include "sherpa-onnx/csrc/online-tts-vits-model-config.h"

#include <string>
#include <vector>

#include "sherpa-onnx/csrc/file-utils.h"
#include "sherpa-onnx/csrc/macros.h"

namespace sherpa_onnx {

void OnlineTtsVitsModelConfig::Register(ParseOptions *po) {
  po->Register("online-vits-model", &model, "Path to VITS model");
  po->Register("online-vits-model-dir", &model_dir, "Path to VITS model directory");
  po->Register("online-vits-stream", &stream, "Enable/disable streaming chunk output");
  po->Register("online-vits-lexicon", &lexicon, "Path to lexicon.txt for VITS models");
  po->Register("online-vits-tokens", &tokens, "Path to tokens.txt for VITS models");
  po->Register("online-vits-data-dir", &data_dir,
               "Path to the directory containing dict for espeak-ng. If it is "
               "given, --online-vits-lexicon is ignored.");
  po->Register("online-vits-dict-dir", &dict_dir,
               "Not used. You don't need to provide a value for it");
  po->Register("online-vits-noise-scale", &noise_scale, "noise_scale for VITS models");
  po->Register("online-vits-noise-scale-w", &noise_scale_w,
               "noise_scale_w for VITS models");
  po->Register("online-vits-length-scale", &length_scale,
               "Speech speed. Larger->Slower; Smaller->faster.");
}

bool OnlineTtsVitsModelConfig::Validate() const {
  if (model.empty() && model_dir.empty()) {
    SHERPA_ONNX_LOGE("Please provide --online-vits-model or --online-vits-model-dir");
    return false;
  }

  bool model_is_split_dir = false;
  if (!model.empty() && FileExists(model + "/encoder.onnx") && FileExists(model + "/decoder.onnx")) {
    model_is_split_dir = true;
  }

  if (!model.empty() && !model_is_split_dir && !FileExists(model)) {
    SHERPA_ONNX_LOGE("--online-vits-model: '%s' does not exist", model.c_str());
    return false;
  }

  if (!model_dir.empty()) {
    if (!FileExists(model_dir + "/encoder.onnx")) {
      SHERPA_ONNX_LOGE("'%s/encoder.onnx' does not exist", model_dir.c_str());
      return false;
    }
    if (!FileExists(model_dir + "/decoder.onnx")) {
      SHERPA_ONNX_LOGE("'%s/decoder.onnx' does not exist", model_dir.c_str());
      return false;
    }
  }

  if (tokens.empty()) {
    SHERPA_ONNX_LOGE("Please provide --online-vits-tokens");
    return false;
  }

  if (!FileExists(tokens)) {
    SHERPA_ONNX_LOGE("--online-vits-tokens: '%s' does not exist", tokens.c_str());
    return false;
  }

  if (!data_dir.empty()) {
    if (!FileExists(data_dir + "/phontab")) {
      SHERPA_ONNX_LOGE(
          "'%s/phontab' does not exist. Please check --online-vits-data-dir",
          data_dir.c_str());
      return false;
    }

    if (!FileExists(data_dir + "/phonindex")) {
      SHERPA_ONNX_LOGE(
          "'%s/phonindex' does not exist. Please check --online-vits-data-dir",
          data_dir.c_str());
      return false;
    }

    if (!FileExists(data_dir + "/phondata")) {
      SHERPA_ONNX_LOGE(
          "'%s/phondata' does not exist. Please check --online-vits-data-dir",
          data_dir.c_str());
      return false;
    }

    if (!FileExists(data_dir + "/intonations")) {
      SHERPA_ONNX_LOGE(
          "'%s/intonations' does not exist. Please check --online-vits-data-dir",
          data_dir.c_str());
      return false;
    }
  }

  if (!dict_dir.empty()) {
    SHERPA_ONNX_LOGE(
        "From sherpa-onnx v1.12.15, you don't need to provide dict_dir for "
        "this model. Ignore it");
  }

  return true;
}

std::string OnlineTtsVitsModelConfig::ToString() const {
  std::ostringstream os;

  os << "OnlineTtsVitsModelConfig(";
  os << "model=\"" << model << "\", ";
  os << "model_dir=\"" << model_dir << "\", ";
  os << "stream=" << (stream ? "true" : "false") << ", ";
  os << "lexicon=\"" << lexicon << "\", ";
  os << "tokens=\"" << tokens << "\", ";
  os << "data_dir=\"" << data_dir << "\", ";
  os << "noise_scale=" << noise_scale << ", ";
  os << "noise_scale_w=" << noise_scale_w << ", ";
  os << "length_scale=" << length_scale << ")";

  return os.str();
}

}  // namespace sherpa_onnx
