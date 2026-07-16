#ifndef LLAMACPP_TRANSLATOR_H_
#define LLAMACPP_TRANSLATOR_H_

#include "llamacpp_config.h"

#include <chrono>
#include <functional>
#include <string>

struct llama_model;
struct llama_context;
struct llama_vocab;
struct llama_sampler;

class LlamaTranslator {
public:
    // Callback invoked for each generated token during streaming translation.
    // partial_text is the cumulative detokenized text generated so far.
    using TokenCallback = std::function<void(const std::string& partial_text)>;

    LlamaTranslator();
    ~LlamaTranslator();

    // Load the model and create the inference context.
    bool Init(const LlamaConfig& config);

    // Set thinking mode dynamically.
    void SetEnableThinking(bool enable_thinking) { config_.enable_thinking = enable_thinking; }

    // Update translation languages without reloading the model.
    void SetLanguages(const std::string& source_lang, const std::string& target_lang);

    // Check whether the translator is initialized and ready.
    bool IsReady() const;

    // Translate source text. Returns a JSON string with text + timing metrics.
    std::string Translate(const std::string& source_text);

    // Translate with per-token streaming callbacks.
    std::string TranslateStreaming(const std::string& source_text,
                                   TokenCallback on_token);

    // Get the last error message.
    std::string LastError() const;

private:
    // Build a formatted prompt from source text using chat template.
    std::string BuildPrompt(const std::string& source_text);

    // Run the decode loop and return generated tokens + timing.
    struct DecodeResult {
        std::vector<int32_t> tokens;
        double prompt_ms;
        double decode_ms;
    };
    DecodeResult RunDecode(const std::vector<int32_t>& input_tokens,
                           TokenCallback on_token);

    // Format result as JSON.
    std::string FormatResult(const std::string& text,
                             int input_tokens,
                             double prompt_ms,
                             double decode_ms,
                             int decoder_tokens) const;

    // Get chat template from model metadata, or return built-in fallback.
    std::string GetChatTemplate() const;

    LlamaConfig config_;
    llama_model* model_ = nullptr;
    llama_context* ctx_ = nullptr;
    const llama_vocab* vocab_ = nullptr;
    llama_sampler* sampler_ = nullptr;
    std::string error_;
    int32_t eos_token_ = -1;

    // Scratch storage for BuildPrompt to keep string memory alive
    // across llama_chat_apply_template calls.
    std::vector<std::string> saved_roles_;
    std::vector<std::string> saved_contents_;

    // Cached token history from previous run to reuse KV cache
    std::vector<int32_t> last_tokens_;
    bool sys_prompt_cached_ = false;
    size_t sys_prompt_len_ = 0;
};

#endif  // LLAMACPP_TRANSLATOR_H_
