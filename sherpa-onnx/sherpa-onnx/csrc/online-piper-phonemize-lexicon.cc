// sherpa-onnx/csrc/online-piper-phonemize-lexicon.cc

#include "sherpa-onnx/csrc/online-piper-phonemize-lexicon.h"

#include <codecvt>
#include <fstream>
#include <locale>
#include <map>
#include <mutex>  // NOLINT
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#if __ANDROID_API__ >= 9
#include <strstream>

#include "android/asset_manager.h"
#include "android/asset_manager_jni.h"
#endif

#include "espeak-ng/speak_lib.h"
#include "phoneme_ids.hpp"
#include "phonemize.hpp"
#include "sherpa-onnx/csrc/macros.h"
#include "sherpa-onnx/csrc/onnx-utils.h"

namespace sherpa_onnx {

std::string convert_chinese_punctuation(const std::string &text) {
  return text;
}

static std::unordered_map<char32_t, int32_t> ReadTokens(std::istream &is) {
  std::wstring_convert<std::codecvt_utf8<char32_t>, char32_t> conv;
  std::unordered_map<char32_t, int32_t> token2id;

  std::string line;

  std::string sym;
  std::u32string s;
  int32_t id = 0;
  while (std::getline(is, line)) {
    std::istringstream iss(line);
    iss >> sym;
    if (iss.eof()) {
      id = atoi(sym.c_str());
      sym = " ";
    } else {
      iss >> id;
    }

    // eat the trailing \r\n on windows
    iss >> std::ws;
    if (!iss.eof()) {
      SHERPA_ONNX_LOGE("Error when reading tokens: %s", line.c_str());
      SHERPA_ONNX_EXIT(-1);
    }

    s = conv.from_bytes(sym);
    if (s.size() != 1) {
      // for tokens.txt from coqui-ai/TTS, the last token is <BLNK>
      if (s.size() == 6 && s[0] == '<' && s[1] == 'B' && s[2] == 'L' &&
          s[3] == 'N' && s[4] == 'K' && s[5] == '>') {
        continue;
      }

      SHERPA_ONNX_LOGE("Error when reading tokens at Line %s. size: %d",
                       line.c_str(), static_cast<int32_t>(s.size()));
      SHERPA_ONNX_EXIT(-1);
    }

    char32_t c = s[0];

    if (token2id.count(c)) {
      SHERPA_ONNX_LOGE("Duplicated token %s. Line %s. Existing ID: %d",
                       sym.c_str(), line.c_str(), token2id.at(c));
      SHERPA_ONNX_EXIT(-1);
    }

    token2id.insert({c, id});
  }

  return token2id;
}

static std::vector<int64_t> PiperPhonemesToIds(
    const std::unordered_map<char32_t, int32_t> &token2id,
    const std::vector<piper::Phoneme> &phonemes) {
  std::vector<int64_t> ans;
  ans.reserve(phonemes.size());

  for (auto p : phonemes) {
    if (token2id.count(p)) {
      ans.push_back(token2id.at(p));
    } else {
      SHERPA_ONNX_LOGE("Skip unknown phonemes. Unicode codepoint: \\U+%04x.",
                       static_cast<uint32_t>(p));
    }
  }

  return ans;
}

static std::vector<int64_t> CoquiPhonemesToIds(
    const std::unordered_map<char32_t, int32_t> &token2id,
    const std::vector<piper::Phoneme> &phonemes,
    const OfflineTtsVitsModelMetaData &meta_data) {
  int32_t use_eos_bos = meta_data.use_eos_bos;
  int32_t bos_id = meta_data.bos_id;
  int32_t eos_id = meta_data.eos_id;
  int32_t blank_id = meta_data.blank_id;
  int32_t add_blank = meta_data.add_blank;
  int32_t comma_id = token2id.at(',');

  std::vector<int64_t> ans;
  if (add_blank) {
    ans.reserve(phonemes.size() * 2 + 3);
  } else {
    ans.reserve(phonemes.size() + 2);
  }

  if (use_eos_bos) {
    ans.push_back(bos_id);
  }

  if (add_blank) {
    ans.push_back(blank_id);

    for (auto p : phonemes) {
      if (token2id.count(p)) {
        ans.push_back(token2id.at(p));
        ans.push_back(blank_id);
      } else {
        SHERPA_ONNX_LOGE("Skip unknown phonemes. Unicode codepoint: \\U+%04x.",
                         static_cast<uint32_t>(p));
      }
    }
  } else {
    for (auto p : phonemes) {
      if (token2id.count(p)) {
        ans.push_back(token2id.at(p));
      } else {
        SHERPA_ONNX_LOGE("Skip unknown phonemes. Unicode codepoint: \\U+%04x.",
                         static_cast<uint32_t>(p));
      }
    }
  }

  ans.push_back(comma_id);

  if (use_eos_bos) {
    ans.push_back(eos_id);
  }

  return ans;
}

extern void InitEspeak(const std::string &data_dir);

OnlinePiperPhonemizeLexicon::OnlinePiperPhonemizeLexicon(
    const std::string &tokens, const std::string &data_dir,
    const OfflineTtsVitsModelMetaData &meta_data, bool debug)
    : meta_data_(meta_data), debug_(debug) {
  std::chrono::high_resolution_clock::time_point t1, t2;
  {
    if (debug) {
      t1 = std::chrono::high_resolution_clock::now();
      SHERPA_ONNX_LOGE("init tokens start");
    }
    std::ifstream is(tokens);
    token2id_ = ReadTokens(is);
    if (debug) {
      t2 = std::chrono::high_resolution_clock::now();
      SHERPA_ONNX_LOGE("init tokens end");
      auto duration =
          std::chrono::duration_cast<std::chrono::milliseconds>(t2 - t1);
      SHERPA_ONNX_LOGE("init tokens cost %lldms", static_cast<long long>(duration.count()));
    }
  }
  if (debug) {
    SHERPA_ONNX_LOGE("init espeak start");
  }
  InitEspeak(data_dir);
  if (debug) {
    t1 = std::chrono::high_resolution_clock::now();
    SHERPA_ONNX_LOGE("init espeak end");
    auto duration =
        std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t2);
    SHERPA_ONNX_LOGE("init espeak cost %lldms", static_cast<long long>(duration.count()));
  }
}

template <typename Manager>
OnlinePiperPhonemizeLexicon::OnlinePiperPhonemizeLexicon(
    Manager *mgr, const std::string &tokens, const std::string &data_dir,
    const OfflineTtsVitsModelMetaData &meta_data, bool debug)
    : meta_data_(meta_data), debug_(debug) {
  auto buf = ReadFile(mgr, tokens);
  std::istringstream is(std::string(buf.data(), buf.size()));
  token2id_ = ReadTokens(is);

  InitEspeak(data_dir);
}

#if __ANDROID_API__ >= 9
OnlinePiperPhonemizeLexicon::OnlinePiperPhonemizeLexicon(
    AAssetManager *mgr, const std::string &tokens, const std::string &data_dir,
    const OfflineTtsVitsModelMetaData &meta_data, bool debug)
    : meta_data_(meta_data), debug_(debug) {
  {
    auto buf = ReadFile(mgr, tokens);
    std::istringstream is(std::string(buf.data(), buf.size()));
    token2id_ = ReadTokens(is);
  }
  InitEspeak(data_dir);
}
#endif

std::vector<TokenIDs> OnlinePiperPhonemizeLexicon::ConvertTextToTokenIds(
    const std::string &text, const std::string &voice /*= ""*/) const {
  piper::eSpeakPhonemeConfig config;

  std::string norm_text = text;
  if (voice == "cmn-latn-pinyin") {
    if (debug_) {
      SHERPA_ONNX_LOGE("input text: %s", text.c_str());
    }
    norm_text = convert_chinese_punctuation(text);
    if (debug_) {
      SHERPA_ONNX_LOGE("after convert_chinese_punctuation: %s",
                       norm_text.c_str());
    }
  }
  config.voice = voice;

  std::vector<std::vector<piper::Phoneme>> phonemes;

  static std::mutex espeak_mutex;
  {
    std::lock_guard<std::mutex> lock(espeak_mutex);
    piper::phonemize_eSpeak(norm_text, config, phonemes);
  }

  if (debug_) {
    std::u32string str;
    for (auto& item : phonemes) {
      for (auto& ch : item) {
        str += ch;
        str += U' ';
      }
    }
    std::wstring_convert<std::codecvt_utf8<char32_t>, char32_t> converter;
    std::string utf8_str = converter.to_bytes(str);
    SHERPA_ONNX_LOGE("token is %s", utf8_str.c_str());
  }
  std::vector<TokenIDs> ans;

  std::vector<int64_t> phoneme_ids;

  if (meta_data_.is_piper || meta_data_.is_icefall) {
    for (const auto &p : phonemes) {
      phoneme_ids = PiperPhonemesToIds(token2id_, p);
      ans.push_back(std::move(phoneme_ids));
    }
  } else if (meta_data_.is_coqui) {
    for (const auto &p : phonemes) {
      phoneme_ids = CoquiPhonemesToIds(token2id_, p, meta_data_);
      ans.push_back(std::move(phoneme_ids));
    }
  } else {
    SHERPA_ONNX_LOGE("Unsupported model");
    SHERPA_ONNX_EXIT(-1);
  }

  return ans;
}

#if __ANDROID_API__ >= 9
template OnlinePiperPhonemizeLexicon::OnlinePiperPhonemizeLexicon(
    AAssetManager *mgr, const std::string &tokens, const std::string &data_dir,
    const OfflineTtsVitsModelMetaData &meta_data, bool debug);
#endif

#if __OHOS__
template OnlinePiperPhonemizeLexicon::OnlinePiperPhonemizeLexicon(
    NativeResourceManager *mgr, const std::string &tokens,
    const std::string &data_dir,
    const OfflineTtsVitsModelMetaData &meta_data, bool debug);
#endif

}  // namespace sherpa_onnx
