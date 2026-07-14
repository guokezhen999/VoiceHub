#include "llamacpp_ffi.h"
#include "llamacpp_config.h"
#include "llamacpp_translator.h"

#include <mutex>
#include <string>

// ---------------------------------------------------------------------------
// Handle definition
// ---------------------------------------------------------------------------

struct LlamaTranslatorHandle {
    LlamaTranslator translator;
    LlamaConfig config;
    bool ready = false;
};

// ---------------------------------------------------------------------------
// Global error state
// ---------------------------------------------------------------------------

static std::mutex g_error_mutex;
static std::string g_last_error;

static void set_error(const std::string& err) {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    g_last_error = err;
}

// ---------------------------------------------------------------------------
// Helper: copy string to heap (caller must free with llamacpp_free_string)
// ---------------------------------------------------------------------------

static const char* str_to_heap(const std::string& s) {
    if (s.empty()) return nullptr;
    char* buf = new char[s.size() + 1];
    std::memcpy(buf, s.c_str(), s.size() + 1);
    return buf;
}

// ---------------------------------------------------------------------------
// C API implementation
// ---------------------------------------------------------------------------

LlamaTranslatorHandle* llamacpp_create_translator(
    const char* model_path,
    const char* source_lang,
    const char* target_lang,
    int32_t n_ctx,
    int32_t n_threads,
    int32_t n_gpu_layers,
    int32_t max_tokens,
    int32_t chat_mode,
    const char* system_prompt)
{
    g_last_error.clear();

    auto* h = new LlamaTranslatorHandle();

    // Defaults
    if (n_ctx     <= 0) n_ctx     = 2048;
    if (n_threads <= 0) n_threads = 4;
    if (max_tokens <= 0) max_tokens = 512;

    h->config.model_path    = model_path ? model_path : "";
    h->config.source_lang   = source_lang ? source_lang : "";
    h->config.target_lang   = target_lang ? target_lang : "";
    h->config.n_ctx         = n_ctx;
    h->config.n_threads     = n_threads;
    h->config.n_gpu_layers  = n_gpu_layers;
    h->config.max_tokens    = max_tokens;
    h->config.chat_mode     = (chat_mode != 0);
    h->config.enable_thinking = (chat_mode != 2);
    h->config.system_prompt = system_prompt ? system_prompt : "";

    if (!h->translator.Init(h->config)) {
        set_error(h->translator.LastError());
        delete h;
        return nullptr;
    }

    h->ready = true;
    return h;
}

const char* llamacpp_translate(LlamaTranslatorHandle* handle, const char* source_text) {
    g_last_error.clear();

    if (!handle || !handle->ready) {
        set_error("Translator not initialized");
        return nullptr;
    }

    std::string result = handle->translator.Translate(source_text ? source_text : "");
    if (result.empty() && !handle->translator.LastError().empty()) {
        set_error(handle->translator.LastError());
        return nullptr;
    }

    return str_to_heap(result);
}

const char* llamacpp_translate_streaming(
    LlamaTranslatorHandle* handle,
    const char* source_text,
    llamacpp_token_callback on_token,
    void* user_data)
{
    g_last_error.clear();

    if (!handle || !handle->ready) {
        set_error("Translator not initialized");
        return nullptr;
    }

    // Wrap C callback in a C++ std::function.
    LlamaTranslator::TokenCallback cpp_callback = nullptr;
    if (on_token) {
        cpp_callback = [on_token, user_data](const std::string& partial) {
            on_token(partial.c_str(), user_data);
        };
    }

    std::string result = handle->translator.TranslateStreaming(
        source_text ? source_text : "", cpp_callback);
    if (result.empty() && !handle->translator.LastError().empty()) {
        set_error(handle->translator.LastError());
        return nullptr;
    }

    return str_to_heap(result);
}

int32_t llamacpp_is_ready(const LlamaTranslatorHandle* handle) {
    return (handle && handle->ready) ? 1 : 0;
}

void llamacpp_destroy_translator(LlamaTranslatorHandle* handle) {
    delete handle;
}

void llamacpp_set_enable_thinking(LlamaTranslatorHandle* handle, int32_t enable_thinking) {
    if (handle) {
        handle->config.enable_thinking = (enable_thinking != 0);
        handle->translator.SetEnableThinking(enable_thinking != 0);
    }
}

void llamacpp_free_string(const char* str) {
    delete[] str;
}

const char* llamacpp_last_error() {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    return g_last_error.empty() ? nullptr : g_last_error.c_str();
}
