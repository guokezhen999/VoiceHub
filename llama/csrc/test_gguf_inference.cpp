// test_gguf_inference.cpp — 最简 GGUF 推理测试，直接调 llama.h
// 编译:
//   g++ -std=c++17 -O2 -I llama/llama.cpp/include -I llama/llama.cpp/src \
//       -I llama/llama.cpp/ggml/src -I llama/llama.cpp/ggml/include \
//       llama/csrc/test_gguf_inference.cpp \
//       llama/csrc/build/_llama_build/src/libllama.a \
//       llama/csrc/build/_llama_build/ggml/src/libggml.a \
//       llama/csrc/build/_llama_build/ggml/src/libggml-cpu.a \
//       llama/csrc/build/_llama_build/ggml/src/libggml-base.a \
//       llama/csrc/build/_llama_build/ggml/src/ggml-blas/libggml-blas.a \
//       llama/csrc/build/_llama_build/ggml/src/ggml-metal/libggml-metal.a \
//       -framework Foundation -framework Metal -framework MetalKit \
//       -framework Accelerate -Xclang -fopenmp -lomp \
//       -o llama/csrc/build/test_gguf_inference

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <chrono>

#include "llama.h"

int main(int argc, char* argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <model.gguf> <prompt> [n_batch] [n_gpu_layers]\n", argv[0]);
        return 1;
    }

    const char* model_path   = argv[1];
    const char* prompt_text  = argv[2];
    int n_batch              = argc > 3 ? atoi(argv[3]) : 512;
    int n_gpu_layers         = argc > 4 ? atoi(argv[4]) : -1;

    fprintf(stderr, "=== GGUF inference test ===\n");
    fprintf(stderr, "Model:   %s\n", model_path);
    fprintf(stderr, "Prompt:  %s\n", prompt_text);
    fprintf(stderr, "n_batch: %d\n", n_batch);
    fprintf(stderr, "n_gpu:   %d\n\n", n_gpu_layers);

    llama_backend_init();

    // ---- Load model ----
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    llama_model* model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        fprintf(stderr, "FAILED to load model\n");
        return 1;
    }
    fprintf(stderr, "[1] Model loaded OK\n");

    // ---- Create context ----
    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx   = 2048;
    cparams.n_batch = n_batch;
    cparams.n_ubatch = n_batch;
    llama_context* ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        fprintf(stderr, "FAILED to create context\n");
        llama_model_free(model);
        return 1;
    }
    fprintf(stderr, "[2] Context created OK\n");

    // ---- Tokenize ----
    const llama_vocab* vocab = llama_model_get_vocab(model);
    std::vector<llama_token> tokens;
    tokens.resize(prompt_text ? strlen(prompt_text) + 128 : 128);
    int n_tokens = llama_tokenize(vocab, prompt_text, strlen(prompt_text),
                                   tokens.data(), (int)tokens.size(), true, false);
    tokens.resize(n_tokens < 0 ? 0 : n_tokens);
    fprintf(stderr, "[3] Tokenized: %d tokens\n", n_tokens);

    // ---- Sampler ----
    auto sparams = llama_sampler_chain_default_params();
    llama_sampler* smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    // ---- Prompt eval ----
    fprintf(stderr, "[4] Prompt eval...\n");
    auto t0 = std::chrono::high_resolution_clock::now();

    llama_batch batch = llama_batch_get_one(tokens.data(), (int32_t)tokens.size());
    if (llama_decode(ctx, batch) != 0) {
        fprintf(stderr, "FAILED: prompt decode\n");
        llama_sampler_free(smpl);
        llama_free(ctx);
        llama_model_free(model);
        return 1;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    double prompt_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    fprintf(stderr, "      Prompt eval: %.0f ms\n\n", prompt_ms);

    // ---- Generate ----
    fprintf(stderr, "[5] Generating...\n---OUTPUT---\n");
    auto t2 = std::chrono::high_resolution_clock::now();

    std::vector<llama_token> generated;
    int eos = llama_vocab_eos(vocab);
    for (int i = 0; i < 256; i++) {
        llama_token next = llama_sampler_sample(smpl, ctx, -1);
        if (next == eos) break;
        generated.push_back(next);
        llama_sampler_accept(smpl, next);

        llama_batch single = llama_batch_get_one(&next, 1);
        if (llama_decode(ctx, single) != 0) {
            fprintf(stderr, "\nFAILED: decode at token %d\n", i);
            break;
        }

        char buf[256];
        int n = llama_token_to_piece(vocab, next, buf, sizeof(buf), 0, true);
        if (n > 0) fwrite(buf, 1, n, stderr);
    }
    fprintf(stderr, "\n---END---\n");

    auto t3 = std::chrono::high_resolution_clock::now();
    double gen_ms = std::chrono::duration<double, std::milli>(t3 - t2).count();
    double tok_per_s = generated.size() / (gen_ms / 1000.0);

    fprintf(stderr, "\n=== STATS ===\n");
    fprintf(stderr, "Prompt:   %.0f ms (%d tokens)\n", prompt_ms, n_tokens);
    fprintf(stderr, "Generate: %.0f ms (%zu tokens, %.1f tok/s)\n",
            gen_ms, generated.size(), tok_per_s);

    llama_sampler_free(smpl);
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    fprintf(stderr, "=== DONE ===\n");
    return 0;
}
