#ifndef MARIAN_TOKENIZER_H_
#define MARIAN_TOKENIZER_H_

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace marian {

// SentencePiece-compatible tokenizer for Marian NMT models.
//
// Supports two modes:
// 1. "vocab mode" — uses vocab.json for longest-prefix-match tokenization.
//    This is the default and works without external dependencies.
// 2. "spm mode" — uses SentencePiece .spm model files via the sentencepiece
//    library for full normalization + subword encoding. Enable by setting
//    use_sentencepiece=true in MarianConfig and linking against sentencepiece.
class MarianTokenizer {
 public:
  MarianTokenizer() = default;
  ~MarianTokenizer() = default;

  // Load vocabulary from a Marian-style vocab.json file.
  // Format: {"token": id, ...}
  // Also accepts sentencepiece model paths (used when use_spm=true).
  bool LoadVocab(const std::string& vocab_json_path);

  bool LoadSourceSpm(const std::string& spm_path);
  bool LoadTargetSpm(const std::string& spm_path);

  // Encode raw text into token IDs, adding BOS/EOS as configured.
  // If use_spm_ is true, uses SentencePiece encode.
  // Otherwise uses longest-prefix-match against the loaded vocab.
  std::vector<int32_t> Encode(std::string_view text,
                               int32_t bos_id,
                               int32_t eos_id) const;

  // Decode token IDs back to text.
  // Handles SentencePiece-style ▁ (U+2581) space markers.
  std::string Decode(const std::vector<int32_t>& ids) const;

  // Set special token IDs for encode/decode behavior.
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

  // Trie node for efficient longest-prefix-match lookup.
  struct TrieNode {
    std::unordered_map<char32_t, TrieNode*> children;
    int32_t token_id = -1;
    ~TrieNode() {
      for (auto& [_, child] : children) delete child;
    }
  };

  void BuildTrie();
  int32_t FindLongestMatch(const std::string& text, size_t pos) const;

  std::unordered_map<std::string, int32_t> vocab_;  // token -> id
  std::vector<std::string> id_to_token_;            // id -> token
  TrieNode* trie_root_ = nullptr;

  std::string source_spm_path_;
  std::string target_spm_path_;
  bool use_spm_ = false;

  int32_t pad_id_ = 65000;
  int32_t eos_id_ = 0;
  int32_t unk_id_ = 1;

  // Punctuation characters for detokenization.
  static bool IsPunctuation(const std::string& token);
};

}  // namespace marian

#endif  // MARIAN_TOKENIZER_H_
