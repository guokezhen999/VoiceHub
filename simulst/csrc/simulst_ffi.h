#ifndef SIMULST_FFI_H_
#define SIMULST_FFI_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SimulstHandle SimulstHandle;

// Create a streaming AST pipeline from a JSON config string.
//
// Task config (at least one must be enabled):
//   enable_transcribe  - bool, default false
//   enable_translate   - bool, default true
//   transcribe_lang    - e.g. "Chinese" or "auto" (default "auto")
//   translate_lang     - e.g. "English" (default "English")
//   prompt             - legacy translate prompt override
//   keep_kv_across_segments   - keep LLM KV across VAD segments (default true)
//   clear_kv_on_sentence_punct- reset KV on . ? ! 。 ？ ！ (default false)
//   num_chunks              - ONNX encoder steps per LLM prefill (default 1)
//   max_llm_kv_segments_base- segment budget at num_chunks=1 (default 56)
//   keep_recent_segments    - segments to keep on eviction (default 12)
//   max_llm_segments        - explicit override, 0 = base / num_chunks
//   embed_chunk_size        - explicit override in embed frames, 0 = auto
SimulstHandle* simulst_create(const char* json_config);

// Update enabled tasks and languages without reloading encoder/VAD.
// JSON fields: enable_transcribe, enable_translate, transcribe_lang,
// translate_lang, prompt (all optional).
int32_t simulst_set_tasks(SimulstHandle* handle, const char* json_tasks);

// Feed 16kHz mono float32 samples.
void simulst_accept_waveform(SimulstHandle* handle, const float* samples, int32_t n);

// Poll JSON:
// {
//   "speaking": bool,
//   "partial_transcript": "...",
//   "partial_translation": "...",
//   "partial": "...",              // legacy: translation or transcript
//   "finalized_transcripts": [...],
//   "finalized_translations": [...],
//   "finalized": [...],            // legacy
//   "segments": [{
//     "transcript": "...",
//     "translation": "...",
//     "text": "...",
//     "start": 0.0,
//     "end": 1.0
//   }]
// }
const char* simulst_poll(SimulstHandle* handle);

void simulst_flush(SimulstHandle* handle);
void simulst_reset(SimulstHandle* handle);
void simulst_destroy(SimulstHandle* handle);

void simulst_free_string(const char* str);
const char* simulst_last_error();

#ifdef __cplusplus
}
#endif

#endif  // SIMULST_FFI_H_
