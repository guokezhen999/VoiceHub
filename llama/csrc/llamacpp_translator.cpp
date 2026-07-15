#include "llamacpp_translator.h"
#include "llamacpp_tokenizer.h"
#include "llama.h"
#include "nlohmann/json.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <vector>
#include <string>
#include <stdexcept>
#include <regex>

// ---------------------------------------------------------------------------
// Strip <think>...</think> blocks and leading </think> from model output
// ---------------------------------------------------------------------------

static std::string StripThinkingBlock(const std::string& text) {
    std::string result = text;

    // Remove all <think>...</think> blocks (including multiline)
    static const std::regex think_block(R"(<think>[\s\S]*?</think>)");
    result = std::regex_replace(result, think_block, "");

    // Remove any standalone leading </think> (with optional surrounding whitespace)
    static const std::regex leading_close(R"(^\s*</think>\s*)");
    result = std::regex_replace(result, leading_close, "");

    return result;
}

// ---------------------------------------------------------------------------
// Default templates
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

    // Load model
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = config_.n_gpu_layers;
    model_params.use_mmap = true;
    model_params.use_mlock = false;

    model_ = llama_model_load_from_file(config_.model_path.c_str(), model_params);
    if (!model_) {
        error_ = "Failed to load model: " + config_.model_path;
        return false;
    }

    vocab_ = llama_model_get_vocab(model_);

    // Create context
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx   = config_.n_ctx;
    ctx_params.n_batch = config_.n_batch;
    ctx_params.n_ubatch = config_.n_batch;
    ctx_params.n_seq_max = 2; // Support parallel sequences for static KV cache injection

    ctx_ = llama_init_from_model(model_, ctx_params);
    if (!ctx_) {
        error_ = "Failed to create context";
        llama_model_free(model_);
        model_ = nullptr;
        return false;
    }

    // Cache EOS token
    eos_token_ = llama_vocab_eos(vocab_);

    // Init Sampler.
    // Chat uses standard sampling. NMT uses strict greedy.
    sampler_ = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (config_.chat_mode) {
        if (config_.temperature == 0.0f) {
            config_.temperature = 0.7f;
        }
        if (config_.temperature > 0.0f) {
            llama_sampler_chain_add(sampler_, llama_sampler_init_top_k(40));
            llama_sampler_chain_add(sampler_, llama_sampler_init_top_p(0.95f, 1));
            llama_sampler_chain_add(sampler_, llama_sampler_init_temp(config_.temperature));
            llama_sampler_chain_add(sampler_, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
        }
    } else {
        llama_sampler_chain_add(sampler_, llama_sampler_init_greedy());
    }

    last_tokens_.clear();
    sys_prompt_cached_ = false;

    return true;
}

bool LlamaTranslator::IsReady() const {
    return ctx_ != nullptr && model_ != nullptr;
}

std::string LlamaTranslator::LastError() const {
    return error_;
}

// ---------------------------------------------------------------------------
// Chat template
// ---------------------------------------------------------------------------

std::string LlamaTranslator::GetChatTemplate() const {
    // Try to read chat_template from model metadata.
    int n = llama_model_meta_count(model_);
    for (int i = 0; i < n; i++) {
        char key_buf[256] = {};
        int key_len = llama_model_meta_key_by_index(model_, i, key_buf, sizeof(key_buf));
        if (key_len > 0 && std::strcmp(key_buf, "tokenizer.chat_template") == 0) {
            std::vector<char> val_buf(4096);
            int val_len = llama_model_meta_val_str_by_index(
                model_, i, val_buf.data(), static_cast<int>(val_buf.size()));
            if (val_len < 0) continue;
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
    saved_roles_.clear();
    saved_contents_.clear();

    std::string template_str = GetChatTemplate();

    std::vector<llama_chat_message> messages;

    if (config_.chat_mode) {
        // ---- Chat mode: parse JSON messages array + use custom system prompt ----
        messages.push_back({"system", config_.system_prompt.c_str()});

        try {
            auto j = nlohmann::json::parse(source_text);
            if (j.is_array()) {
                for (const auto& msg : j) {
                    std::string role = msg.value("role", "user");
                    std::string content = msg.value("content", "");

                    // Safeguard: if assistant message has <think> but no </think>, auto-close it
                    if (role == "assistant" &&
                        content.find("<think>") != std::string::npos &&
                        content.find("</think>") == std::string::npos) {
                        content += "\n</think>";
                    }

                    // Store strings on heap so pointers stay valid
                    saved_roles_.push_back(role);
                    saved_contents_.push_back(content);
                }
            }
        } catch (const std::exception& e) {
            saved_roles_.push_back("user");
            saved_contents_.push_back(source_text);
        }

        for (size_t i = 0; i < saved_roles_.size(); i++) {
            messages.push_back({saved_roles_[i].c_str(), saved_contents_[i].c_str()});
        }
    } else {
        // ---- Translation mode (original behavior) ----
        std::string system_prompt =
            "You are a professional translator. Translate the following text from " +
            config_.source_lang + " to " + config_.target_lang +
            " accurately and concisely. "
            "Return ONLY the translation without any explanations, notes, or additional text.";

        // Store in saved_contents_ so the c_str() pointer stays valid.
        saved_contents_.push_back(system_prompt);
        saved_contents_.push_back(source_text);
        messages = {
            {"system", saved_contents_[saved_contents_.size() - 2].c_str()},
            {"user",   saved_contents_.back().c_str()},
        };

        // Cache the translation template (system prompt) in last_tokens_
        std::vector<llama_chat_message> sys_msg = {
            {"system", saved_contents_[saved_contents_.size() - 2].c_str()}
        };
        std::vector<char> sys_buf(2048);
        int sys_n = llama_chat_apply_template(
            template_str.c_str(),
            sys_msg.data(), 1,
            false,          // add_ass = false
            sys_buf.data(), static_cast<int>(sys_buf.size()));
        if (sys_n > 0) {
            std::string sys_prompt_str(sys_buf.data(), sys_n);
            last_tokens_ = LlamaTokenizer(vocab_).Encode(sys_prompt_str, true);
        } else {
            last_tokens_.clear();
        }
    }

    // Format with template.
    int buf_size = 4096;
    for (const auto& msg : messages) {
        buf_size += static_cast<int>(std::strlen(msg.content)) * 2;
    }
    std::vector<char> buf(buf_size);

    int n = llama_chat_apply_template(
        template_str.c_str(),
        messages.data(), static_cast<int>(messages.size()),
        true,          // add_ass = true (add generation prompt)
        buf.data(), static_cast<int>(buf.size()));

    if (n < 0) {
        error_ = "llama_chat_apply_template failed";
        return "";
    }
    if (n > buf_size) {
        buf.resize(n);
        n = llama_chat_apply_template(
            template_str.c_str(),
            messages.data(), static_cast<int>(messages.size()),
            true,
            buf.data(), static_cast<int>(buf.size()));
    }

    std::string prompt(buf.data(), n);

    if (!config_.enable_thinking) {
        // Append </think> to bypass reasoning model thinking blocks
        prompt += "</think>\n";
    }

    std::fprintf(stderr, "\n--- LLAMA TRANSLATOR PROMPT START ---\n%s\n--- LLAMA TRANSLATOR PROMPT END ---\n\n", prompt.c_str());
    std::fflush(stderr);

    return prompt;
}

// ---------------------------------------------------------------------------
// Decode loop
// ---------------------------------------------------------------------------

LlamaTranslator::DecodeResult
LlamaTranslator::RunDecode(const std::vector<int32_t>& input_tokens,
                           TokenCallback on_token) {
    DecodeResult result;
    result.tokens.reserve(config_.max_tokens);

    // Find the common prefix with the last run's tokens
    size_t n_keep = 0;

    if (!config_.chat_mode) {
        // ---- Translation Mode: Static Prefix Caching (KV Cache Injection) ----
        size_t sys_len = last_tokens_.size();

        if (sys_len > 0 && input_tokens.size() >= sys_len) {
            // Check if the input_tokens starts with the system prompt
            bool match = true;
            for (size_t i = 0; i < sys_len; ++i) {
                if (input_tokens[i] != last_tokens_[i]) {
                    match = false;
                    break;
                }
            }

            if (match) {
                if (!sys_prompt_cached_) {
                    // 1. First run: clear context, decode the system prompt on sequence 1
                    llama_memory_clear(llama_get_memory(ctx_), true);

                    // Decode system prompt tokens on sequence 1
                    llama_batch batch = llama_batch_init(static_cast<int32_t>(sys_len), 0, 1);
                    batch.n_tokens = static_cast<int32_t>(sys_len);
                    for (size_t i = 0; i < sys_len; ++i) {
                        batch.token[i] = last_tokens_[i];
                        batch.pos[i]   = static_cast<llama_pos>(i);
                        batch.n_seq_id[i] = 1;
                        batch.seq_id[i][0] = 1;
                        batch.logits[i] = false;
                    }

                    if (llama_decode(ctx_, batch) != 0) {
                        std::fprintf(stderr, "ERROR: failed to precompute system prompt KV cache\n");
                        std::fflush(stderr);
                    } else {
                        sys_prompt_cached_ = true;
                        sys_prompt_len_ = sys_len;
                        std::fprintf(stderr, "KV cache precompute: successfully cached %zu system prompt tokens on sequence 1\n", sys_len);
                        std::fflush(stderr);
                    }
                    llama_batch_free(batch);
                }

                if (sys_prompt_cached_) {
                    // 2. Clear sequence 0 (where translation runs)
                    llama_memory_seq_rm(llama_get_memory(ctx_), 0, 0, -1);

                    // 3. Inject (copy) cached system prompt from sequence 1 to sequence 0
                    llama_memory_seq_cp(llama_get_memory(ctx_), 1, 0, 0, -1);

                    // 4. We keep the cached tokens (length = sys_prompt_len_)
                    n_keep = sys_prompt_len_;
                    
                    std::fprintf(stderr, "KV cache injection: injected %zu precomputed system prompt tokens from seq 1 to seq 0\n", sys_prompt_len_);
                    std::fflush(stderr);
                }
            }
        }
    } else {
        // ---- Chat Mode: Standard Dynamic Cache Reuse ----
        while (n_keep < input_tokens.size() && n_keep < last_tokens_.size() &&
               input_tokens[n_keep] == last_tokens_[n_keep]) {
            n_keep++;
        }
    }

    if (!config_.chat_mode && !sys_prompt_cached_) {
        // Fallback: Clear all KV cache if static prefix caching failed or not matched
        llama_memory_clear(llama_get_memory(ctx_), true);
    } else if (config_.chat_mode) {
        if (n_keep > 0) {
            llama_memory_seq_rm(llama_get_memory(ctx_), 0, static_cast<llama_pos>(n_keep), -1);
        } else {
            llama_memory_clear(llama_get_memory(ctx_), true);
            sys_prompt_cached_ = false;
        }
    }

    std::fprintf(stderr, "KV cache reuse: kept %zu tokens out of %zu input tokens (last run had %zu tokens)\n",
                 n_keep, input_tokens.size(), last_tokens_.size());
    std::fflush(stderr);

    // ---- Prompt processing with batch chunking ----
    auto t_prompt_start = std::chrono::high_resolution_clock::now();

    std::vector<llama_token> prompt_tokens(input_tokens.begin() + n_keep, input_tokens.end());
    if (!prompt_tokens.empty()) {
        int32_t n_batch_limit = config_.n_batch;
        size_t total_tokens = prompt_tokens.size();
        for (size_t i = 0; i < total_tokens; i += n_batch_limit) {
            size_t chunk_size = std::min(static_cast<size_t>(n_batch_limit), total_tokens - i);
            llama_batch batch = llama_batch_init(static_cast<int32_t>(chunk_size), 0, 1);
            batch.n_tokens = static_cast<int32_t>(chunk_size);
            for (size_t j = 0; j < chunk_size; j++) {
                batch.token[j] = prompt_tokens[i + j];
                batch.pos[j] = static_cast<llama_pos>(n_keep + i + j);
                batch.n_seq_id[j] = 1;
                batch.seq_id[j][0] = 0;
                // Only request logits for the absolute last token of the entire prompt
                batch.logits[j] = (i + j == total_tokens - 1);
            }

            if (llama_decode(ctx_, batch) != 0) {
                error_ = "llama_decode failed on prompt chunk starting at " + std::to_string(i);
                llama_batch_free(batch);
                return result;
            }
            llama_batch_free(batch);
        }
        if (config_.chat_mode) {
            sys_prompt_cached_ = true;
        }
    }

    auto t_prompt_end = std::chrono::high_resolution_clock::now();
    result.prompt_ms = std::chrono::duration<double, std::milli>(
        t_prompt_end - t_prompt_start).count();

    // ---- Autoregressive generation ----
    auto t_decode_start = std::chrono::high_resolution_clock::now();
    std::string partial;

    bool prompt_ends_with_think = (!config_.chat_mode || !config_.enable_thinking);

    llama_token next_token;
    for (int i = 0; i < config_.max_tokens; i++) {
        if (i == 0 && prompt_ends_with_think) {
            float* logits = llama_get_logits_ith(ctx_, -1);
            if (logits) {
                logits[eos_token_] = -INFINITY;
            }
        }

        // Sample the next token.
        next_token = llama_sampler_sample(sampler_, ctx_, -1);

        // Check stop conditions.
        if (next_token == eos_token_) break;

        result.tokens.push_back(next_token);
        llama_sampler_accept(sampler_, next_token);

        // Decode the single token with explicit position.
        llama_batch single = llama_batch_init(1, 0, 1);
        single.n_tokens = 1;
        single.token[0] = next_token;
        single.pos[0] = static_cast<llama_pos>(input_tokens.size() + i);
        single.n_seq_id[0] = 1;
        single.seq_id[0][0] = 0;
        single.logits[0] = true;

        if (llama_decode(ctx_, single) != 0) {
            error_ = "llama_decode failed at token " + std::to_string(i);
            llama_batch_free(single);
            return result;
        }
        llama_batch_free(single);

        // Callback with cumulative partial text.
        if (on_token) {
            partial = LlamaTokenizer(vocab_).Decode(result.tokens);
            if (!config_.enable_thinking) {
                partial = StripThinkingBlock(partial);
            }
            on_token(partial);
        }
    }

    auto t_decode_end = std::chrono::high_resolution_clock::now();
    result.decode_ms = std::chrono::duration<double, std::milli>(
        t_decode_end - t_decode_start).count();

    // Save evaluated and generated tokens for the next call to reuse KV cache (only in chat mode)
    if (config_.chat_mode) {
        last_tokens_ = input_tokens;
        last_tokens_.insert(last_tokens_.end(), result.tokens.begin(), result.tokens.end());
    }

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
        if (!config_.enable_thinking) {
            output = StripThinkingBlock(output);
        }

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
        if (!config_.enable_thinking) {
            output = StripThinkingBlock(output);
        }

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
