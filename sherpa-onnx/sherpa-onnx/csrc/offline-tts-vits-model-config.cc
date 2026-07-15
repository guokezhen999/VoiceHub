// sherpa-onnx/csrc/offline-tts-vits-model-config.cc
//
// Copyright (c)  2023  Xiaomi Corporation

#include "sherpa-onnx/csrc/offline-tts-vits-model-config.h"

#include <string>
#include <vector>
#include <cerrno>
#include <sys/stat.h>

#include "sherpa-onnx/csrc/file-utils.h"
#include "sherpa-onnx/csrc/macros.h"

namespace sherpa_onnx {

void OfflineTtsVitsModelConfig::Register(ParseOptions *po) {
  po->Register("vits-model", &model, "Path to VITS model");
  po->Register("vits-lexicon", &lexicon, "Path to lexicon.txt for VITS models");
  po->Register("vits-tokens", &tokens, "Path to tokens.txt for VITS models");
  po->Register("vits-data-dir", &data_dir,
               "Path to the directory containing dict for espeak-ng. If it is "
               "given, --vits-lexicon is ignored.");
  po->Register("vits-dict-dir", &dict_dir,
               "Not used. You don't need to provide a value for it");
  po->Register("vits-noise-scale", &noise_scale, "noise_scale for VITS models");
  po->Register("vits-noise-scale-w", &noise_scale_w,
               "noise_scale_w for VITS models");
  po->Register("vits-length-scale", &length_scale,
               "Speech speed. Larger->Slower; Smaller->faster.");
}

bool OfflineTtsVitsModelConfig::Validate() const {
  if (model.empty()) {
    SHERPA_ONNX_LOGE("Please provide --vits-model");
    return false;
  }

  // model can be either a single .onnx file or a directory containing
  // encoder.onnx + decoder.onnx (split VITS / Piper models).
  bool model_is_split_dir = false;
  if (FileExists(model + "/encoder.onnx") && FileExists(model + "/decoder.onnx")) {
    model_is_split_dir = true;
  }

  if (!model_is_split_dir) {
    // model is not a split dir — check if it exists as a regular file.
    // We also accept a directory without the expected split files.
    struct stat dir_stat;
    int stat_ret = stat(model.c_str(), &dir_stat);
    if (stat_ret != 0) {
      SHERPA_ONNX_LOGE("--vits-model stat failed (errno=%d): '%s'", errno, model.c_str());
      return false;
    }
    bool is_dir = S_ISDIR(dir_stat.st_mode);
    bool is_file = S_ISREG(dir_stat.st_mode);
    if (!is_dir && !is_file) {
      SHERPA_ONNX_LOGE("--vits-model: '%s' is not a file or directory", model.c_str());
      return false;
    }
    if (is_dir) {
      SHERPA_ONNX_LOGE("--vits-model: '%s' is a directory but missing encoder.onnx/decoder.onnx", model.c_str());
      return false;
    }
  }

  if (tokens.empty()) {
    SHERPA_ONNX_LOGE("Please provide --vits-tokens");
    return false;
  }

  if (!FileExists(tokens)) {
    SHERPA_ONNX_LOGE("--vits-tokens: '%s' does not exist", tokens.c_str());
    return false;
  }

  if (!data_dir.empty()) {
    if (!FileExists(data_dir + "/phontab")) {
      SHERPA_ONNX_LOGE(
          "'%s/phontab' does not exist. Please check --vits-data-dir",
          data_dir.c_str());
      return false;
    }

    if (!FileExists(data_dir + "/phonindex")) {
      SHERPA_ONNX_LOGE(
          "'%s/phonindex' does not exist. Please check --vits-data-dir",
          data_dir.c_str());
      return false;
    }

    if (!FileExists(data_dir + "/phondata")) {
      SHERPA_ONNX_LOGE(
          "'%s/phondata' does not exist. Please check --vits-data-dir",
          data_dir.c_str());
      return false;
    }

    if (!FileExists(data_dir + "/intonations")) {
      SHERPA_ONNX_LOGE(
          "'%s/intonations' does not exist. Please check --vits-data-dir",
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

std::string OfflineTtsVitsModelConfig::ToString() const {
  std::ostringstream os;

  os << "OfflineTtsVitsModelConfig(";
  os << "model=\"" << model << "\", ";
  os << "lexicon=\"" << lexicon << "\", ";
  os << "tokens=\"" << tokens << "\", ";
  os << "data_dir=\"" << data_dir << "\", ";
  os << "noise_scale=" << noise_scale << ", ";
  os << "noise_scale_w=" << noise_scale_w << ", ";
  os << "length_scale=" << length_scale << ")";

  return os.str();
}

}  // namespace sherpa_onnx
