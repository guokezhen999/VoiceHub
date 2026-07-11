#ifndef LLAMACPP_CONFIG_H_
#define LLAMACPP_CONFIG_H_

#include <string>

struct LlamaConfig {
    // Model
    std::string model_path;    // Path to .gguf file

    // Translation
    std::string source_lang;   // e.g., "Chinese"
    std::string target_lang;   // e.g., "English"

    // Context
    int32_t n_ctx     = 2048;  // Context window size
    int32_t n_threads = 4;     // CPU threads
    int32_t n_gpu_layers = -1;  // GPU offload layers (-1 = all)
    int32_t max_tokens = 512;  // Max output tokens
    int32_t n_batch    = 512;  // Batch size for prompt processing

    // Sampling
    float temperature  = 0.0f; // 0 = greedy decoding
};

#endif  // LLAMACPP_CONFIG_H_
