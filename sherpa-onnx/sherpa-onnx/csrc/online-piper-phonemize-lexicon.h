// sherpa-onnx/csrc/online-piper-phonemize-lexicon.h

#ifndef SHERPA_ONNX_CSRC_ONLINE_PIPER_PHONEMIZE_LEXICON_H_
#define SHERPA_ONNX_CSRC_ONLINE_PIPER_PHONEMIZE_LEXICON_H_

#include <string>
#include <unordered_map>
#include <vector>

#include "sherpa-onnx/csrc/offline-tts-frontend.h"
#include "sherpa-onnx/csrc/offline-tts-vits-model-meta-data.h"

#if __ANDROID_API__ >= 9
#include "android/asset_manager.h"
#endif

namespace sherpa_onnx {

class OnlinePiperPhonemizeLexicon : public OfflineTtsFrontend {
 public:
  OnlinePiperPhonemizeLexicon(const std::string &tokens, const std::string &data_dir,
                              const OfflineTtsVitsModelMetaData &meta_data, bool debug = false);

  template <typename Manager>
  OnlinePiperPhonemizeLexicon(Manager *mgr, const std::string &tokens,
                              const std::string &data_dir,
                              const OfflineTtsVitsModelMetaData &meta_data, bool debug = false);

#if __ANDROID_API__ >= 9
  OnlinePiperPhonemizeLexicon(AAssetManager *mgr, const std::string &tokens,
                              const std::string &data_dir,
                              const OfflineTtsVitsModelMetaData &meta_data, bool debug = false);
#endif

  std::vector<TokenIDs> ConvertTextToTokenIds(
      const std::string &text, const std::string &voice = "") const override;

 private:
  std::unordered_map<char32_t, int32_t> token2id_;
  OfflineTtsVitsModelMetaData meta_data_;
  bool debug_ = false;
};

}  // namespace sherpa_onnx

#endif  // SHERPA_ONNX_CSRC_ONLINE_PIPER_PHONEMIZE_LEXICON_H_
