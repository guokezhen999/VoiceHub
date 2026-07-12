// test_opus_mt_inference.cpp — Quick E2E inference test for opus-mt C++ library.
//
// Build (from VoiceHub root):
//   cd opus_mt/csrc && mkdir -p build && cd build
//   cmake .. -DOPUS_MT_USE_SYSTEM_ONNXRUNTIME=ON
//   make -j$(sysctl -n hw.logicalcpu)
//   cd ../../..
//
// Run:
//   DYLD_LIBRARY_PATH=/opt/homebrew/lib \
//   ./opus_mt/csrc/build/test_opus_mt_inference \
//     opus_mt/model/opus-mt-zh-en/onnx \
//     "你好，今天天气怎么样？"
//

#include <cstdio>

#include "opus_mt_ffi.h"

int main(int argc, char* argv[]) {
  if (argc < 3) {
    fprintf(stderr, "Usage: %s <model_dir> <source_text>\n", argv[0]);
    return 1;
  }

  const char* model_dir = argv[1];
  const char* text = argv[2];

  fprintf(stderr, "=== opus-mt C++ inference test ===\n");
  fprintf(stderr, "Model dir: %s\n", model_dir);
  fprintf(stderr, "Source:    %s\n\n", text);

  // Create translator
  OpusMtTranslatorHandle* h =
      opus_mt_create_translator(model_dir, /*max_length=*/128, /*num_threads=*/4);

  if (!h) {
    const char* err = opus_mt_last_error();
    fprintf(stderr, "FAILED to create translator: %s\n", err ? err : "unknown");
    return 1;
  }

  if (!opus_mt_is_ready(h)) {
    fprintf(stderr, "FAILED: translator not ready\n");
    opus_mt_destroy_translator(h);
    return 1;
  }

  fprintf(stderr, "Translator created OK, running inference...\n\n");

  // Translate
  const char* result = opus_mt_translate(h, text);
  if (!result) {
    const char* err = opus_mt_last_error();
    fprintf(stderr, "FAILED to translate: %s\n", err ? err : "unknown");
    opus_mt_destroy_translator(h);
    return 1;
  }

  fprintf(stderr, "Result JSON: %s\n", result);

  opus_mt_free_string(result);
  opus_mt_destroy_translator(h);

  fprintf(stderr, "\n=== TEST PASSED ===\n");
  return 0;
}
