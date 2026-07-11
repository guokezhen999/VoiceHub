#ifndef LLAMACPP_TOKENIZER_H_
#define LLAMACPP_TOKENIZER_H_

#include <string>
#include <vector>

struct llama_vocab;

class LlamaTokenizer {
public:
    // The tokenizer shares the model's vocab; the model must outlive the tokenizer.
    explicit LlamaTokenizer(const llama_vocab* vocab);

    // Tokenize text into token IDs.
    std::vector<int32_t> Encode(const std::string& text, bool add_bos = true) const;

    // Detokenize token IDs back to text.
    std::string Decode(const std::vector<int32_t>& tokens) const;

    // Get the EOS token ID.
    int32_t EosToken() const;

    // Get the BOS token ID.
    int32_t BosToken() const;

private:
    const llama_vocab* vocab_;
};

#endif  // LLAMACPP_TOKENIZER_H_
