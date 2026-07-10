#include "marian_tokenizer.h"

#include <algorithm>
#include <codecvt>
#include <fstream>
#include <locale>
#include <sstream>

#include "nlohmann/json.hpp"

namespace marian {

// ---- SentencePiece-style inline helpers -----------------------------------

namespace {

// Decode a UTF-8 character to a codepoint. Returns -1 on error.
int32_t Utf8Decode(std::string_view text, size_t& pos) {
  if (pos >= text.size()) return -1;
  unsigned char c = static_cast<unsigned char>(text[pos]);
  int32_t cp = 0;
  int extra = 0;
  if ((c & 0x80) == 0) {
    cp = c;
  } else if ((c & 0xE0) == 0xC0) {
    cp = c & 0x1F;
    extra = 1;
  } else if ((c & 0xF0) == 0xE0) {
    cp = c & 0x0F;
    extra = 2;
  } else if ((c & 0xF8) == 0xF0) {
    cp = c & 0x07;
    extra = 3;
  } else {
    return -1;
  }
  for (int i = 0; i < extra; i++) {
    pos++;
    if (pos >= text.size()) return -1;
    unsigned char follow = static_cast<unsigned char>(text[pos]);
    if ((follow & 0xC0) != 0x80) return -1;
    cp = (cp << 6) | (follow & 0x3F);
  }
  pos++;
  return cp;
}

// SentencePiece whitespace replacement character.
constexpr char32_t kSpaceMarker = U'▁';  // ▁

}  // namespace

// ---- Tokenizer implementation --------------------------------------------

bool MarianTokenizer::LoadVocab(const std::string& vocab_json_path) {
  std::ifstream file(vocab_json_path);
  if (!file.is_open()) return false;

  nlohmann::json j;
  try {
    file >> j;
  } catch (const nlohmann::json::parse_error&) {
    return false;
  }

  vocab_.clear();
  id_to_token_.clear();

  for (const auto& [token, id] : j.items()) {
    int32_t token_id = id.get<int32_t>();
    vocab_[token] = token_id;
    if (token_id >= static_cast<int32_t>(id_to_token_.size())) {
      id_to_token_.resize(token_id + 1);
    }
    id_to_token_[token_id] = token;
  }

  // Sort tokens by length descending for longest-match.
  BuildTrie();

  return true;
}

bool MarianTokenizer::LoadSourceSpm(const std::string& spm_path) {
  source_spm_path_ = spm_path;
  // Full sentencepiece integration would load the .spm model here.
  // For now, we store the path for future use.
  return true;
}

bool MarianTokenizer::LoadTargetSpm(const std::string& spm_path) {
  target_spm_path_ = spm_path;
  return true;
}

void MarianTokenizer::BuildTrie() {
  delete trie_root_;
  trie_root_ = new TrieNode();

  for (const auto& [token, id] : vocab_) {
    TrieNode* node = trie_root_;
    size_t pos = 0;
    while (pos < token.size()) {
      int32_t cp = Utf8Decode(token, pos);
      if (cp < 0) break;
      auto it = node->children.find(static_cast<char32_t>(cp));
      if (it == node->children.end()) {
        node->children[static_cast<char32_t>(cp)] = new TrieNode();
        it = node->children.find(static_cast<char32_t>(cp));
      }
      node = it->second;
    }
    node->token_id = id;
  }
}

// ---- Normalization --------------------------------------------------------

namespace {

std::string NormalizeText(std::string_view text) {
  std::string result;
  result.reserve(text.size());

  for (size_t i = 0; i < text.size();) {
    unsigned char c = static_cast<unsigned char>(text[i]);
    if (c == 0xEF && i + 2 < text.size() &&
        static_cast<unsigned char>(text[i + 1]) == 0xBB &&
        static_cast<unsigned char>(text[i + 2]) == 0xBF) {
      // Skip UTF-8 BOM
      i += 3;
      continue;
    }
    // Normalize various whitespace to space.
    if (c == '\r' || c == '\n' || c == '\t' || c == '\v' || c == '\f') {
      result += ' ';
      i++;
      continue;
    }
    // NFKC-style normalization: fullwidth ASCII to halfwidth.
    if (c == 0xEF) {
      // Fullwidth range: EF BC 80 ~ EF BD 9F
      if (i + 2 < text.size() &&
          static_cast<unsigned char>(text[i + 1]) == 0xBC &&
          static_cast<unsigned char>(text[i + 2]) >= 0x80) {
        // FF01 → 21 ('!')
        result += static_cast<char>(0x20 + (static_cast<unsigned char>(text[i + 2]) - 0x80));
        i += 3;
        continue;
      }
      if (i + 2 < text.size() &&
          static_cast<unsigned char>(text[i + 1]) == 0xBD &&
          static_cast<unsigned char>(text[i + 2]) >= 0x80 &&
          static_cast<unsigned char>(text[i + 2]) <= 0x9F) {
        // FF00 → 00 ... => skip or map
        i += 3;
        continue;
      }
    }
    // Fullwidth A-Z / a-z: EF BC A1...BA
    if (c == 0xEF && i + 2 < text.size() &&
        static_cast<unsigned char>(text[i + 1]) == 0xBC) {
      auto b2 = static_cast<unsigned char>(text[i + 2]);
      if (b2 >= 0xA1 && b2 <= 0xBA) {
        result += static_cast<char>('A' + (b2 - 0xA1));
        i += 3;
        continue;
      }
    }
    // Fullwidth digits: EF BC 90...99 → 0-9
    if (c == 0xEF && i + 2 < text.size() &&
        static_cast<unsigned char>(text[i + 1]) == 0xBC) {
      auto b2 = static_cast<unsigned char>(text[i + 2]);
      if (b2 >= 0x90 && b2 <= 0x99) {
        result += static_cast<char>('0' + (b2 - 0x90));
        i += 3;
        continue;
      }
    }
    // Replace fullwidth space (E3 80 80) with regular space.
    if (c == 0xE3 && i + 2 < text.size() &&
        static_cast<unsigned char>(text[i + 1]) == 0x80 &&
        static_cast<unsigned char>(text[i + 2]) == 0x80) {
      result += ' ';
      i += 3;
      continue;
    }
    result += static_cast<char>(c);
    i++;
  }

  // Collapse multiple whitespace into single space, trim.
  std::string out;
  out.reserve(result.size());
  bool last_was_space = false;
  for (char ch : result) {
    if (ch == ' ') {
      if (last_was_space) continue;
      last_was_space = true;
      out += ' ';
    } else {
      last_was_space = false;
      out += ch;
    }
  }
  // Trim leading/trailing space.
  size_t start = 0;
  while (start < out.size() && out[start] == ' ') start++;
  size_t end = out.size();
  while (end > start && out[end - 1] == ' ') end--;

  return out.substr(start, end - start);
}

}  // namespace

// ---- Pre-tokenization -----------------------------------------------------

std::vector<std::string> MarianTokenizer::PreTokenize(std::string_view text) const {
  std::vector<std::string> chunks;

  // Tokenize by whitespace, but preserve CJK characters as individual
  // pre-tokens (similar to SentencePiece behavior).
  std::string current;
  for (size_t i = 0; i < text.size();) {
    size_t prev_i = i;
    int32_t cp = Utf8Decode(text, i);
    if (cp < 0) {
      i = prev_i + 1;
      continue;
    }

    if (cp == ' ') {
      if (!current.empty()) {
        chunks.push_back(current);
        current.clear();
      }
      // Add a single space marker as its own chunk.
      chunks.push_back(std::string("▁"));
    } else if (cp >= 0x4E00 && cp <= 0x9FFF) {
      // CJK Unified Ideographs: treat each char as a separate token boundary.
      if (!current.empty()) {
        chunks.push_back(current);
        current.clear();
      }
      // Prepend space marker to simulate SentencePiece behavior.
      std::string cjk;
      for (size_t j = prev_i; j < i; j++) {
        cjk += text[j];
      }
      chunks.push_back("▁" + cjk);
    } else if (cp >= 0x3400 && cp <= 0x4DBF) {
      // CJK Extension A
      if (!current.empty()) {
        chunks.push_back(current);
        current.clear();
      }
      std::string cjk;
      for (size_t j = prev_i; j < i; j++) cjk += text[j];
      chunks.push_back("▁" + cjk);
    } else {
      // Append to current chunk.
      for (size_t j = prev_i; j < i; j++) current += text[j];
    }
  }
  if (!current.empty()) {
    chunks.push_back(current);
  }

  return chunks;
}

// ---- Longest-prefix-match encoding ----------------------------------------

int32_t MarianTokenizer::FindLongestMatch(const std::string& text, size_t pos) const {
  TrieNode* node = trie_root_;
  int32_t best_id = -1;

  while (pos < text.size()) {
    size_t prev_pos = pos;
    int32_t cp = Utf8Decode(text, pos);
    if (cp < 0) break;

    auto it = node->children.find(static_cast<char32_t>(cp));
    if (it == node->children.end()) break;

    node = it->second;
    if (node->token_id >= 0) {
      best_id = node->token_id;
    }
  }
  return best_id;
}

std::vector<int32_t> MarianTokenizer::EncodeWithVocab(std::string_view text,
                                                       int32_t bos_id,
                                                       int32_t eos_id) const {
  std::string normalized = NormalizeText(text);
  if (normalized.empty()) return {eos_id};

  auto chunks = PreTokenize(normalized);
  std::vector<int32_t> token_ids;

  if (bos_id >= 0) {
    token_ids.push_back(bos_id);
  }

  for (const auto& chunk : chunks) {
    if (chunk.empty()) continue;

    size_t pos = 0;
    while (pos < chunk.size()) {
      int32_t match_id = FindLongestMatch(chunk, pos);
      if (match_id >= 0) {
        token_ids.push_back(match_id);
        // Advance by the matched token's text.
        const std::string& matched_token = id_to_token_[match_id];
        // Handle space marker: ▁prefix matches consume the non-▁ part.
        if (!matched_token.empty() && matched_token[0] == '\xE2') {
          // Check for UTF-8 encoding of ▁ (E2 96 81).
          if (matched_token.size() >= 3 &&
              static_cast<unsigned char>(matched_token[0]) == 0xE2 &&
              static_cast<unsigned char>(matched_token[1]) == 0x96 &&
              static_cast<unsigned char>(matched_token[2]) == 0x81) {
            // The space marker token was matched; advance past the ▁ in chunk.
            if (chunk.size() - pos >= 3) {
              auto b0 = static_cast<unsigned char>(chunk[pos]);
              auto b1 = static_cast<unsigned char>(chunk[pos + 1]);
              auto b2 = static_cast<unsigned char>(chunk[pos + 2]);
              if (b0 == 0xE2 && b1 == 0x96 && b2 == 0x81) {
                pos += 3;
              } else {
                pos += matched_token.size();
              }
            } else {
              pos += matched_token.size();
            }
          } else {
            pos += matched_token.size();
          }
        } else {
          pos += matched_token.size();
        }
      } else {
        token_ids.push_back(unk_id_);
        // Advance by one UTF-8 character.
        size_t old_pos = pos;
        Utf8Decode(chunk, pos);
        if (pos == old_pos) pos++;
      }
    }
  }

  if (eos_id >= 0) {
    token_ids.push_back(eos_id);
  }

  return token_ids;
}

std::vector<int32_t> MarianTokenizer::EncodeWithSentencePiece(std::string_view text,
                                                               int32_t bos_id,
                                                               int32_t eos_id) const {
  // Placeholder for SentencePiece-based encoding.
  // Would call sentencepiece::SentencePieceProcessor::Encode() here.
  // Falls back to vocab-based encoding.
  return EncodeWithVocab(text, bos_id, eos_id);
}

std::vector<int32_t> MarianTokenizer::Encode(std::string_view text,
                                              int32_t bos_id,
                                              int32_t eos_id) const {
  if (use_spm_ && (!source_spm_path_.empty() || !target_spm_path_.empty())) {
    return EncodeWithSentencePiece(text, bos_id, eos_id);
  }
  return EncodeWithVocab(text, bos_id, eos_id);
}

// ---- Decoding ------------------------------------------------------------

bool MarianTokenizer::IsPunctuation(const std::string& token) {
  if (token.size() == 1) {
    char c = token[0];
    return c == '.' || c == ',' || c == '!' || c == '?' || c == ':' ||
           c == ';' || c == '-' || c == '\'' || c == '"' || c == ')' ||
           c == ']' || c == '}' || c == '%';
  }
  return false;
}

std::string MarianTokenizer::Decode(const std::vector<int32_t>& ids) const {
  std::string result;

  for (size_t i = 0; i < ids.size(); i++) {
    int32_t id = ids[i];
    if (id < 0 || id >= static_cast<int32_t>(id_to_token_.size())) continue;

    const std::string& token = id_to_token_[id];

    // Skip EOS marker.
    if (token == "</s>" || token == "<eos>") continue;
    // Handle PAD (usually not generated, but skip if so).
    if (token == "<pad>") continue;

    // SentencePiece space marker (▁ U+2581, encoded as E2 96 81 in UTF-8).
    if (token.size() >= 3 &&
        static_cast<unsigned char>(token[0]) == 0xE2 &&
        static_cast<unsigned char>(token[1]) == 0x96 &&
        static_cast<unsigned char>(token[2]) == 0x81) {
      // If the token is just the space marker, add a space.
      if (token.size() == 3) {
        if (!result.empty() && result.back() != ' ') {
          result += ' ';
        }
        continue;
      }
      // Otherwise, add a space followed by the rest of the token.
      if (!result.empty() && result.back() != ' ') {
        result += ' ';
      }
      result += token.substr(3);
      continue;
    }

    // Skip other special tokens.
    if (token.size() >= 2 && token.front() == '<' && token.back() == '>') {
      continue;
    }

    // Language token prefix (e.g., ">>zh<<").
    if (token.size() >= 2 && token.substr(0, 2) == ">>") {
      continue;
    }

    // Handle punctuation: no space before.
    if (IsPunctuation(token)) {
      result += token;
      continue;
    }

    result += token;
  }

  // Trim and collapse spaces.
  std::string out;
  out.reserve(result.size());
  bool last_was_space = false;
  for (char c : result) {
    if (c == ' ') {
      if (last_was_space) continue;
      last_was_space = true;
      out += c;
    } else {
      last_was_space = false;
      out += c;
    }
  }

  size_t start = 0;
  while (start < out.size() && out[start] == ' ') start++;
  size_t end = out.size();
  while (end > start && out[end - 1] == ' ') end--;

  return out.substr(start, end - start);
}

}  // namespace marian
