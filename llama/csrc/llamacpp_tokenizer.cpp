#include "llamacpp_tokenizer.h"
#include "llama.h"

#include <stdexcept>

LlamaTokenizer::LlamaTokenizer(const llama_vocab* vocab)
    : vocab_(vocab) {
    if (!vocab_) {
        throw std::runtime_error("LlamaTokenizer: null vocab pointer");
    }
}

std::vector<int32_t> LlamaTokenizer::Encode(const std::string& text, bool add_bos) const {
    std::vector<llama_token> tokens;
    tokens.reserve(text.size() / 4 + 8);  // rough estimate

    int n = llama_tokenize(vocab_, text.c_str(), static_cast<int>(text.size()),
                           tokens.data(), static_cast<int>(tokens.capacity()),
                           add_bos, true);  // add_bos, allow_special
    if (n < 0) {
        // Buffer too small; retry with required size.
        tokens.resize(-n);
        n = llama_tokenize(vocab_, text.c_str(), static_cast<int>(text.size()),
                           tokens.data(), static_cast<int>(tokens.size()),
                           add_bos, true);
    }
    if (n < 0) {
        throw std::runtime_error("LlamaTokenizer: tokenization failed");
    }
    tokens.resize(n);
    return {tokens.begin(), tokens.end()};
}

std::string LlamaTokenizer::Decode(const std::vector<int32_t>& tokens) const {
    std::string result;
    result.reserve(tokens.size() * 4);
    for (auto token : tokens) {
        char buf[64];
        int n = llama_detokenize(vocab_, &token, 1, buf, sizeof(buf), false, false);
        if (n > 0) {
            result.append(buf, n);
        }
    }
    return result;
}

int32_t LlamaTokenizer::EosToken() const {
    return llama_vocab_eos(vocab_);
}

int32_t LlamaTokenizer::BosToken() const {
    return llama_vocab_bos(vocab_);
}
