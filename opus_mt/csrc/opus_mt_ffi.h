#ifndef OPUS_MT_FFI_H_
#define OPUS_MT_FFI_H_

// Pure C API for dart:ffi interop.
// All functions use C linkage and opaque pointer types.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to an opus-mt translator instance.
typedef struct OpusMtTranslatorHandle OpusMtTranslatorHandle;

// Callback invoked for each token during streaming translation.
// partial_text is the cumulative detokenized text generated so far.
// user_data is the opaque pointer passed to opus_mt_translate_streaming.
typedef void (*opus_mt_token_callback)(const char* partial_text, void* user_data);

// Create a translator from a model directory.
//
// The model_dir must contain:
//   - encoder.onnx
//   - decoder.onnx
//   - decoder_init.onnx
//   - decoder.onnx.data       (external weights for shared-weight layout)
//   - vocab.json
//   - config.json (optional)
//   - source.spm / target.spm (optional, for sentencepiece mode)
//
// Returns NULL on failure. Call opus_mt_last_error() for details.
OpusMtTranslatorHandle* opus_mt_create_translator(
    const char* model_dir,
    int32_t max_length,
    int32_t num_threads);

// Translate source text. Returns a UTF-8 C string.
// The caller must free the result with opus_mt_free_string().
// Returns NULL on failure.
const char* opus_mt_translate(
    OpusMtTranslatorHandle* handle,
    const char* source_text);

// Translate source text with per-token streaming callbacks.
// on_token is called after each decoder token with the cumulative partial
// translation text. user_data is passed through to the callback.
// Returns a JSON string with the final text and timing metrics, or NULL on error.
// The caller must free the result with opus_mt_free_string().
const char* opus_mt_translate_streaming(
    OpusMtTranslatorHandle* handle,
    const char* source_text,
    opus_mt_token_callback on_token,
    void* user_data);

// Check if the translator is ready.
int32_t opus_mt_is_ready(const OpusMtTranslatorHandle* handle);

// Destroy a translator and free all resources.
void opus_mt_destroy_translator(OpusMtTranslatorHandle* handle);

// Free a string returned by opus_mt_translate().
void opus_mt_free_string(const char* str);

// Get the last error message. Returns NULL if no error.
const char* opus_mt_last_error();

#ifdef __cplusplus
}
#endif

#endif  // OPUS_MT_FFI_H_
