#ifndef VOICE_ENGINE_FFI_H_
#define VOICE_ENGINE_FFI_H_

// Pure C API for dart:ffi interop.
// All functions use C linkage and an opaque pointer handle.
// Signature style mirrors opus_mt_ffi.h / llamacpp_ffi.h.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a streaming ASR pipeline instance.
typedef struct VoiceEngineHandle VoiceEngineHandle;

// Create a pipeline from a JSON config string (see voice_engine_config.h for
// the schema). Returns NULL on failure; call voice_engine_last_error().
VoiceEngineHandle* voice_engine_create(const char* json_config);

// Feed 16kHz mono float32 samples into the pipeline.
void voice_engine_accept_waveform(VoiceEngineHandle* handle,
                                   const float* samples, int32_t n);

// Poll the current pipeline state as JSON:
//   {"speaking":bool,"partial":"..","finalized":["..",...]}
// The caller must free the result with voice_engine_free_string().
const char* voice_engine_poll(VoiceEngineHandle* handle);

// Finalize the remaining online result (call when recording stops).
// The finalized text is delivered via a subsequent voice_engine_poll().
void voice_engine_flush(VoiceEngineHandle* handle);

// Reset the pipeline for a new utterance session.
void voice_engine_reset(VoiceEngineHandle* handle);

// Destroy a pipeline and free all resources.
void voice_engine_destroy(VoiceEngineHandle* handle);

// Free a string returned by voice_engine_poll().
void voice_engine_free_string(const char* str);

// Get the last error message. Returns NULL if no error.
const char* voice_engine_last_error();

// Decode any audio file supported by OS (MP3, AAC, M4A, WAV, etc.) to 16kHz mono Float32 samples.
// Returns a pointer to a float array of size *out_n. Free with voice_engine_free_samples().
float* voice_engine_decode_file(const char* path, int32_t* out_n);

// Free the float array returned by voice_engine_decode_file().
void voice_engine_free_samples(float* samples);

#ifdef __cplusplus
}
#endif

#endif  // VOICE_ENGINE_FFI_H_
