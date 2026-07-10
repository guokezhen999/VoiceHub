#ifndef MARIAN_FFI_H_
#define MARIAN_FFI_H_

// Pure C API for dart:ffi interop.
// All functions use C linkage and opaque pointer types.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a Marian translator instance.
typedef struct MarianTranslatorHandle MarianTranslatorHandle;

// Create a translator from a model directory.
//
// The model_dir must contain:
//   - encoder.onnx
//   - decoder.onnx
//   - vocab.json
//   - config.json (optional)
//   - source.spm / target.spm (optional, for sentencepiece mode)
//
// Returns NULL on failure. Call marian_last_error() for details.
MarianTranslatorHandle* marian_create_translator(
    const char* model_dir,
    int32_t num_beams,
    int32_t max_length,
    int32_t num_threads);

// Translate source text. Returns a UTF-8 C string.
// The caller must free the result with marian_free_string().
// Returns NULL on failure.
const char* marian_translate(
    MarianTranslatorHandle* handle,
    const char* source_text);

// Check if the translator is ready.
int32_t marian_is_ready(const MarianTranslatorHandle* handle);

// Destroy a translator and free all resources.
void marian_destroy_translator(MarianTranslatorHandle* handle);

// Free a string returned by marian_translate().
void marian_free_string(const char* str);

// Get the last error message. Returns NULL if no error.
const char* marian_last_error();

#ifdef __cplusplus
}
#endif

#endif  // MARIAN_FFI_H_
