#ifndef OPUS_MT_TOKENIZER_H_
#define OPUS_MT_TOKENIZER_H_

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#ifdef OPUS_MT_USE_SENTENCEPIECE
#  include <sentencepiece_processor.h>
#endif

namespace opus_mt {

// SentencePiece-compatible tokenizer for opus-mt models.
//
// Two modes:
// 1. "vocab mode" — longest-prefix-match against vocab.json (fallback).
// 2. "spm mode" — SentencePiece .spm model (preferred, accurate).
//    Enable by building with -DOPUS_MT_USE_SENTENCEPIECE=ON and providing
//    source.spm / target.spm.
class OpusMtTokenizer {
 public:
  OpusMtTokenizer() = default;
  ~OpusMtTokenizer() = default;

  bool LoadVocab(const std::string& vocab_json_path);
  bool LoadSourceSpm(const std::string& spm_path);
  bool LoadTargetSpm(const std::string& spm_path);

  std::vector<int32_t> Encode(std::string_view text,
                               int32_t bos_id,
                               int32_t eos_id) const;

  std::string Decode(const std::vector<int32_t>& ids) const;

  void SetPadId(int32_t id) { pad_id_ = id; }
  void SetEosId(int32_t id) { eos_id_ = id; }
  void SetUnkId(int32_t id) { unk_id_ = id; }

  bool UseSentencePiece() const { return use_spm_; }
  void SetUseSentencePiece(bool v) { use_spm_ = v; }

  int32_t VocabSize() const { return static_cast<int32_t>(vocab_.size()); }

 private:
  std::vector<int32_t> EncodeWithVocab(std::string_view text,
                                        int32_t bos_id,
                                        int32_t eos_id) const;

  std::vector<int32_t> EncodeWithSentencePiece(std::string_view text,
                                                int32_t bos_id,
                                                int32_t eos_id) const;

  std::vector<std::string> PreTokenize(std::string_view text) const;

  struct TrieNode {
    std::unordered_map<char32_t, TrieNode*> children;
    int32_t token_id = -1;
    ~TrieNode() {
      for (auto& [_, child] : children) delete child;
    }
  };

  void BuildTrie();
  int32_t FindLongestMatch(const std::string& text, size_t pos) const;

  std::unordered_map<std::string, int32_t> vocab_;
  std::vector<std::string> id_to_token_;
  TrieNode* trie_root_ = nullptr;

#ifdef OPUS_MT_USE_SENTENCEPIECE
  std::unique_ptr<sentencepiece::SentencePieceProcessor> source_spm_;
  std::unique_ptr<sentencepiece::SentencePieceProcessor> target_spm_;
#endif

  std::string source_spm_path_;
  std::string target_spm_path_;
  bool use_spm_ = false;

  int32_t pad_id_ = 65000;
  int32_t eos_id_ = 0;
  int32_t unk_id_ = 1;

  static bool IsPunctuation(const std::string& token);
};

}  // namespace opus_mt

#endif  // OPUS_MT_TOKENIZER_H_
