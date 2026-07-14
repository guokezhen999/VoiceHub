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
    if (text.empty()) {
        return {};
    }
    int n = llama_tokenize(vocab_, text.c_str(), static_cast<int>(text.size()),
                           nullptr, 0,
                           add_bos, true);
    if (n >= 0) {
        return {};
    }
    std::vector<llama_token> tokens(-n);
    int ret = llama_tokenize(vocab_, text.c_str(), static_cast<int>(text.size()),
                             tokens.data(), static_cast<int>(tokens.size()),
                             add_bos, true);
    if (ret < 0) {
        throw std::runtime_error("LlamaTokenizer: tokenization failed");
    }
    tokens.resize(ret);
    return std::vector<int32_t>(tokens.begin(), tokens.end());
}

std::string LlamaTokenizer::Decode(const std::vector<int32_t>& tokens) const {
    if (tokens.empty()) return "";

    // Query size first (negative returned value represents size required)
    int n = llama_detokenize(vocab_, tokens.data(), static_cast<int32_t>(tokens.size()), nullptr, 0, false, false);
    if (n < 0) {
        std::vector<char> buf(-n);
        int actual = llama_detokenize(
            vocab_, tokens.data(), static_cast<int32_t>(tokens.size()),
            buf.data(), static_cast<int32_t>(buf.size()),
            false, false
        );
        if (actual > 0) {
            return std::string(buf.data(), actual);
        }
    } else if (n > 0) {
        std::vector<char> buf(n);
        int actual = llama_detokenize(
            vocab_, tokens.data(), static_cast<int32_t>(tokens.size()),
            buf.data(), static_cast<int32_t>(buf.size()),
            false, false
        );
        if (actual > 0) {
            return std::string(buf.data(), actual);
        }
    }
    return "";
}

int32_t LlamaTokenizer::EosToken() const {
    return llama_vocab_eos(vocab_);
}

int32_t LlamaTokenizer::BosToken() const {
    return llama_vocab_bos(vocab_);
}
