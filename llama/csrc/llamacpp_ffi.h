#ifndef LLAMACPP_FFI_H_
#define LLAMACPP_FFI_H_

// Pure C API for dart:ffi interop.
// Signature-compatible with opus_mt_ffi.h for easy Dart-side integration.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a Llama translator instance.
typedef struct LlamaTranslatorHandle LlamaTranslatorHandle;

// Callback invoked for each token during streaming translation.
// partial_text is the cumulative detokenized text generated so far.
typedef void (*llamacpp_token_callback)(const char* partial_text, void* user_data);

// Create a translator from a GGUF model file.
//
// Parameters:
//   model_path    - Path to the .gguf model file.
//   source_lang   - Source language name (e.g., "Chinese").
//   target_lang   - Target language name (e.g., "English").
//   n_ctx         - Context window size (default: 2048).
//   n_threads     - CPU threads (default: 4).
//   n_gpu_layers  - GPU offload layers (-1 = all layers).
//   max_tokens    - Maximum output tokens (default: 512).
//   chat_mode     - 1 = general chat (uses system_prompt), 0 = translation.
//   system_prompt - Custom system prompt for chat mode (can be NULL).
//
// Returns NULL on failure. Call llamacpp_last_error() for details.
LlamaTranslatorHandle* llamacpp_create_translator(
    const char* model_path,
    const char* source_lang,
    const char* target_lang,
    int32_t n_ctx,
    int32_t n_threads,
    int32_t n_gpu_layers,
    int32_t max_tokens,
    int32_t chat_mode,
    const char* system_prompt);

// Translate source text. Returns a JSON string with text + timing metrics.
// The caller must free the result with llamacpp_free_string().
const char* llamacpp_translate(
    LlamaTranslatorHandle* handle,
    const char* source_text);

// Translate source text with per-token streaming callbacks.
// on_token is called after each decoder token with the cumulative partial
// translation text. user_data is passed through to the callback.
// Returns a JSON string with the final text and timing metrics.
const char* llamacpp_translate_streaming(
    LlamaTranslatorHandle* handle,
    const char* source_text,
    llamacpp_token_callback on_token,
    void* user_data);

// Check if the translator is ready.
int32_t llamacpp_is_ready(const LlamaTranslatorHandle* handle);

// Destroy a translator and free all resources.
void llamacpp_destroy_translator(LlamaTranslatorHandle* handle);

// Enable/disable thinking dynamically in chat mode.
void llamacpp_set_enable_thinking(LlamaTranslatorHandle* handle, int32_t enable_thinking);

// Update translation languages without reloading the model.
void llamacpp_set_languages(
    LlamaTranslatorHandle* handle,
    const char* source_lang,
    const char* target_lang);

// Free a string returned by llamacpp_translate().
void llamacpp_free_string(const char* str);

// Get the last error message. Returns NULL if no error.
const char* llamacpp_last_error();

#ifdef __cplusplus
}
#endif

#endif  // LLAMACPP_FFI_H_
