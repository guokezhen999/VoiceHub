#include "llamacpp_translator.h"
#include "llamacpp_tokenizer.h"
#include "llama.h"
#include "nlohmann/json.hpp"

#include <cstring>
#include <sstream>
#include <stdexcept>

// ---------------------------------------------------------------------------
// Default chat template (ChatML format) — used when the model doesn't
// include a tokenizer.chat_template in its GGUF metadata.
// ---------------------------------------------------------------------------
static const char* kDefaultChatTemplate = R"(
{%- for message in messages -%}
  {%- if message.role == 'system' -%}
    <|im_start|>system
{{ message.content }}<|im_end|>
  {%- elif message.role == 'user' -%}
    <|im_start|>user
{{ message.content }}<|im_end|>
  {%- elif message.role == 'assistant' -%}
    <|im_start|>assistant
{{ message.content }}<|im_end|>
  {%- endif -%}
{%- endfor -%}
{%- if add_generation_prompt -%}
  <|im_start|>assistant
{%- endif -%}
)";

// ---------------------------------------------------------------------------
// LlamaTranslator
// ---------------------------------------------------------------------------

LlamaTranslator::LlamaTranslator() = default;

LlamaTranslator::~LlamaTranslator() {
    if (sampler_) llama_sampler_free(sampler_);
    if (ctx_)     llama_free(ctx_);
    if (model_)   llama_model_free(model_);
}

bool LlamaTranslator::Init(const LlamaConfig& config) {
    config_ = config;

    // ---- Load model ----
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = config_.n_gpu_layers;
    model_params.use_mmap = true;
    model_params.use_mlock = false;

    model_ = llama_model_load_from_file(config_.model_path.c_str(), model_params);
    if (!model_) {
        error_ = "Failed to load model: " + config_.model_path;
        return false;
    }

    // ---- Create context ----
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx   = config_.n_ctx;
    ctx_params.n_batch = config_.n_batch;
    ctx_params.n_ubatch = config_.n_batch;

    ctx_ = llama_init_from_model(model_, ctx_params);
    if (!ctx_) {
        error_ = "Failed to create context";
        llama_model_free(model_);
        model_ = nullptr;
        return false;
    }

    vocab_ = llama_model_get_vocab(model_);
    eos_token_ = llama_vocab_eos(vocab_);

    // ---- Create sampler (greedy) ----
    auto sparams = llama_sampler_chain_default_params();
    sampler_ = llama_sampler_chain_init(sparams);
    if (config_.temperature > 0.0f) {
        llama_sampler_chain_add(sampler_, llama_sampler_init_temp(config_.temperature));
        llama_sampler_chain_add(sampler_, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    } else {
        llama_sampler_chain_add(sampler_, llama_sampler_init_greedy());
    }

    return true;
}

bool LlamaTranslator::IsReady() const {
    return model_ != nullptr && ctx_ != nullptr;
}

std::string LlamaTranslator::LastError() const {
    return error_;
}

// ---------------------------------------------------------------------------
// Chat template
// ---------------------------------------------------------------------------

std::string LlamaTranslator::GetChatTemplate() const {
    // Try to read chat_template from model metadata.
    // The new API writes key/value into buffers.
    int n = llama_model_meta_count(model_);
    for (int i = 0; i < n; i++) {
        char key_buf[256] = {};
        int key_len = llama_model_meta_key_by_index(model_, i, key_buf, sizeof(key_buf));
        if (key_len > 0 && std::strcmp(key_buf, "tokenizer.chat_template") == 0) {
            // Read the value into a buffer.
            std::vector<char> val_buf(4096);
            int val_len = llama_model_meta_val_str_by_index(
                model_, i, val_buf.data(), static_cast<int>(val_buf.size()));
            if (val_len < 0) continue;  // buffer too small? try once more
            if (val_len > static_cast<int>(val_buf.size())) {
                val_buf.resize(val_len);
                val_len = llama_model_meta_val_str_by_index(
                    model_, i, val_buf.data(), static_cast<int>(val_buf.size()));
            }
            if (val_len > 0) {
                return std::string(val_buf.data(), val_len);
            }
            break;
        }
    }
    return std::string(kDefaultChatTemplate);
}

// ---------------------------------------------------------------------------
// Prompt building
// ---------------------------------------------------------------------------

std::string LlamaTranslator::BuildPrompt(const std::string& source_text) {
    std::string template_str = GetChatTemplate();

    // Build chat messages.
    std::string system_prompt =
        "You are a professional translator. Translate the following text from " +
        config_.source_lang + " to " + config_.target_lang +
        " accurately and concisely. "
        "Return ONLY the translation without any explanations, notes, or additional text.";

    std::vector<llama_chat_message> messages = {
        {"system",    system_prompt.c_str()},
        {"user",      source_text.c_str()},
    };

    // Format with template.
    // Buffer size: 2x total input as recommended by llama.h.
    int buf_size = static_cast<int>(system_prompt.size() + source_text.size()) * 2 + 512;
    std::vector<char> buf(buf_size);

    int n = llama_chat_apply_template(
        template_str.c_str(),
        messages.data(), messages.size(),
        true,          // add_ass = true (add generation prompt)
        buf.data(), buf_size);

    if (n < 0) {
        error_ = "llama_chat_apply_template failed";
        return "";
    }
    if (n > buf_size) {
        buf.resize(n);
        n = llama_chat_apply_template(
            template_str.c_str(),
            messages.data(), messages.size(),
            true,
            buf.data(), static_cast<int>(buf.size()));
    }

    return std::string(buf.data(), n);
}

// ---------------------------------------------------------------------------
// Decode loop
// ---------------------------------------------------------------------------

LlamaTranslator::DecodeResult
LlamaTranslator::RunDecode(const std::vector<int32_t>& input_tokens,
                           TokenCallback on_token) {
    DecodeResult result;
    result.tokens.reserve(config_.max_tokens);

    // ---- Prompt processing ----
    auto t_prompt_start = std::chrono::high_resolution_clock::now();

    // Use llama_batch_get_one for prompt evaluation.
    // We need mutable copies since llama_batch_get_one takes non-const.
    std::vector<llama_token> prompt_tokens(input_tokens.begin(), input_tokens.end());
    llama_batch batch = llama_batch_get_one(prompt_tokens.data(),
                                            static_cast<int32_t>(prompt_tokens.size()));

    if (llama_decode(ctx_, batch) != 0) {
        error_ = "llama_decode failed on prompt";
        return result;
    }

    auto t_prompt_end = std::chrono::high_resolution_clock::now();
    result.prompt_ms = std::chrono::duration<double, std::milli>(
        t_prompt_end - t_prompt_start).count();

    // ---- Autoregressive generation ----
    auto t_decode_start = std::chrono::high_resolution_clock::now();
    std::string partial;

    llama_token next_token;
    for (int i = 0; i < config_.max_tokens; i++) {
        // Sample the next token.
        next_token = llama_sampler_sample(sampler_, ctx_, -1);

        // Check stop conditions.
        if (next_token == eos_token_) break;

        result.tokens.push_back(next_token);
        llama_sampler_accept(sampler_, next_token);

        // Decode the single token.
        llama_batch single = llama_batch_get_one(&next_token, 1);

        if (llama_decode(ctx_, single) != 0) {
            error_ = "llama_decode failed at token " + std::to_string(i);
            return result;
        }

        // Callback with cumulative partial text.
        if (on_token) {
            partial = LlamaTokenizer(vocab_).Decode(result.tokens);
            on_token(partial);
        }
    }

    auto t_decode_end = std::chrono::high_resolution_clock::now();
    result.decode_ms = std::chrono::duration<double, std::milli>(
        t_decode_end - t_decode_start).count();

    return result;
}

// ---------------------------------------------------------------------------
// Translate
// ---------------------------------------------------------------------------

std::string LlamaTranslator::Translate(const std::string& source_text) {
    error_.clear();

    try {
        // 1. Build prompt.
        std::string prompt = BuildPrompt(source_text);
        if (prompt.empty()) return "";

        // 2. Tokenize.
        LlamaTokenizer tokenizer(vocab_);
        std::vector<int32_t> input_tokens = tokenizer.Encode(prompt, true);

        // 3. Decode.
        DecodeResult result = RunDecode(input_tokens, nullptr);

        // 4. Detokenize.
        std::string output = tokenizer.Decode(result.tokens);

        return FormatResult(output,
                            static_cast<int>(input_tokens.size()),
                            result.prompt_ms,
                            result.decode_ms,
                            static_cast<int>(result.tokens.size()));
    } catch (const std::exception& e) {
        error_ = e.what();
        return "";
    }
}

std::string LlamaTranslator::TranslateStreaming(const std::string& source_text,
                                                TokenCallback on_token) {
    error_.clear();

    try {
        std::string prompt = BuildPrompt(source_text);
        if (prompt.empty()) return "";

        LlamaTokenizer tokenizer(vocab_);
        std::vector<int32_t> input_tokens = tokenizer.Encode(prompt, true);

        DecodeResult result = RunDecode(input_tokens, on_token);

        std::string output = tokenizer.Decode(result.tokens);

        return FormatResult(output,
                            static_cast<int>(input_tokens.size()),
                            result.prompt_ms,
                            result.decode_ms,
                            static_cast<int>(result.tokens.size()));
    } catch (const std::exception& e) {
        error_ = e.what();
        return "";
    }
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------

std::string LlamaTranslator::FormatResult(const std::string& text,
                                          int input_tokens,
                                          double prompt_ms,
                                          double decode_ms,
                                          int decoder_tokens) const {
    nlohmann::json j;
    j["text"]           = text;
    j["input_tokens"]   = input_tokens;
    j["encoder_ms"]     = prompt_ms;    // prompt processing = "encoder" in Marian terms
    j["decoder_ms"]     = decode_ms;
    j["decoder_tokens"] = decoder_tokens;
    return j.dump();
}
