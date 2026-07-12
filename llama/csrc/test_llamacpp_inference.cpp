// test_llamacpp_inference.cpp — E2E inference test for llama.cpp NMT C++ library.
//
// Build (from VoiceHub root):
//   cd llama/csrc && mkdir -p build && cd build
//   cmake .. && make -j$(sysctl -n hw.logicalcpu)
//
// Run:
//   ./llama/csrc/build/test_llamacpp_inference \
//     model/llm/qwen3-0.6B/qwen3-0.6b-instruct-q4_k_m.gguf \
//     "你好，今天天气怎么样？"

#include <cstdio>
#include <cstdlib>
#include <string>

#include "llamacpp_translator.h"
#include "llamacpp_config.h"

int main(int argc, char* argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <model.gguf> <source_text> [n_gpu_layers] [n_batch]\n", argv[0]);
        fprintf(stderr, "  n_gpu_layers: GPU offload layers, -1=all (default: -1)\n");
        fprintf(stderr, "  n_batch:      prompt batch size (default: 512)\n");
        return 1;
    }

    const char* model_path  = argv[1];
    const char* source_text = argv[2];
    int n_gpu_layers = argc > 3 ? atoi(argv[3]) : -1;
    int n_batch      = argc > 4 ? atoi(argv[4]) : 512;

    fprintf(stderr, "=== llama.cpp NMT C++ inference test ===\n");
    fprintf(stderr, "Model:        %s\n", model_path);
    fprintf(stderr, "Source:       %s\n", source_text);
    fprintf(stderr, "n_batch:      %d\n", n_batch);
    fprintf(stderr, "n_gpu_layers: %d\n\n", n_gpu_layers);

    // ---- Build config ----
    LlamaConfig config;
    config.model_path   = model_path;
    config.source_lang  = "Chinese";
    config.target_lang  = "English";
    config.n_ctx        = 2048;
    config.n_threads    = 4;
    config.n_gpu_layers = n_gpu_layers;
    config.max_tokens   = 256;
    config.n_batch      = n_batch;
    config.temperature  = 0.0f;

    // ---- Init translator ----
    fprintf(stderr, "[1/3] Loading model and creating context...\n");
    LlamaTranslator translator;
    if (!translator.Init(config)) {
        fprintf(stderr, "FAILED to init: %s\n", translator.LastError().c_str());
        return 1;
    }
    fprintf(stderr, "      Model loaded OK.\n\n");

    // ---- Translate ----
    fprintf(stderr, "[2/3] Translating (non-streaming)...\n");
    std::string result = translator.Translate(source_text);
    if (result.empty()) {
        fprintf(stderr, "FAILED to translate: %s\n", translator.LastError().c_str());
        return 1;
    }
    fprintf(stderr, "      Result: %s\n\n", result.c_str());

    // ---- Translate streaming ----
    fprintf(stderr, "[3/3] Translating (streaming)...\n");
    int token_count = 0;
    std::string result2 = translator.TranslateStreaming(
        source_text,
        [&token_count](const std::string& partial) {
            token_count++;
            fprintf(stderr, "  token %3d: %s\n", token_count, partial.c_str());
        });

    if (result2.empty()) {
        fprintf(stderr, "FAILED to translate streaming: %s\n", translator.LastError().c_str());
        return 1;
    }
    fprintf(stderr, "\n      Final: %s\n", result2.c_str());

    fprintf(stderr, "\n=== TEST PASSED ===\n");
    return 0;
}
