#include "simulst_ffi.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"

namespace fs = std::filesystem;

struct TestOptions {
  std::string config_path;
  std::string wav_path;
  int32_t chunk_samples = 1600;
  bool enable_transcribe = true;
  bool enable_translate = true;
  std::string transcribe_lang = "auto";
  std::string translate_lang = "English";
  int32_t n_gpu_layers = -1;
  std::string encoder_provider = "coreml";
  int32_t num_chunks = 1;
  bool test_set_tasks = false;
};

static std::vector<float> ReadWavMono16k(const char* path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return {};
  std::vector<char> data((std::istreambuf_iterator<char>(in)),
                         std::istreambuf_iterator<char>());
  if (data.size() < 44) return {};

  const int32_t sample_rate = *reinterpret_cast<const int32_t*>(&data[24]);
  const int16_t channels = *reinterpret_cast<const int16_t*>(&data[22]);
  const int16_t bits = *reinterpret_cast<const int16_t*>(&data[34]);
  if (bits != 16) {
    std::fprintf(stderr, "error: only 16-bit PCM wav supported, got %d\n", bits);
    return {};
  }

  const size_t offset = 44;
  std::vector<float> samples;
  for (size_t i = offset; i + 1 < data.size(); i += 2 * static_cast<size_t>(channels)) {
    const int16_t s = *reinterpret_cast<const int16_t*>(&data[i]);
    samples.push_back(s / 32768.0f);
  }

  if (sample_rate != 16000) {
    std::fprintf(stderr, "warning: expected 16kHz wav, got %d\n", sample_rate);
  }
  return samples;
}

static std::string ResolvePath(const fs::path& base, const std::string& path) {
  if (path.empty()) return path;
  fs::path p(path);
  if (p.is_absolute()) return p.lexically_normal().string();
  return (base / p).lexically_normal().string();
}

static fs::path FindRepoRoot(const fs::path& start) {
  fs::path cur = fs::absolute(start);
  for (int i = 0; i < 8; ++i) {
    const fs::path marker = cur / "model" / "tmk" / "speechllm" / "grpo-comet";
    if (fs::exists(marker / "speechllm_meta.json")) {
      return cur;
    }
    if (!cur.has_parent_path() || cur == cur.parent_path()) break;
    cur = cur.parent_path();
  }
  return {};
}

static std::string LoadConfigWithResolvedPaths(const char* config_path) {
  const fs::path cfg_path = fs::absolute(config_path);
  const fs::path cfg_dir = cfg_path.parent_path();

  std::ifstream cfg_in(cfg_path);
  if (!cfg_in) {
    throw std::runtime_error(std::string("failed to open config: ") + config_path);
  }

  nlohmann::json j;
  cfg_in >> j;

  if (j.contains("export_dir")) {
    j["export_dir"] = ResolvePath(cfg_dir, j["export_dir"].get<std::string>());
  }
  if (j.contains("vad_model")) {
    j["vad_model"] = ResolvePath(cfg_dir, j["vad_model"].get<std::string>());
  }
  if (j.contains("vad") && j["vad"].contains("model")) {
    j["vad"]["model"] = ResolvePath(cfg_dir, j["vad"]["model"].get<std::string>());
  }
  return j.dump();
}

static bool ValidateModelDir(const std::string& export_dir, std::string* error) {
  const auto require = [&](const char* name) -> bool {
    const fs::path p = fs::path(export_dir) / name;
    if (!fs::exists(p)) {
      if (error) *error = "missing model file: " + p.string();
      return false;
    }
    return true;
  };

  if (!fs::is_directory(export_dir)) {
    if (error) *error = "export_dir is not a directory: " + export_dir;
    return false;
  }
  if (!require("speechllm_meta.json")) return false;
  if (!require("metadata.json")) return false;
  if (!require("init_states.npz")) return false;
  if (!require("llm-f16.gguf")) return false;
  if (!require("encoder_adapter-chunk-16-left-128.onnx")) return false;
  if (!fs::exists(fs::path(export_dir) / "special_token_input_patch.npz") &&
      !fs::exists(fs::path(export_dir) / "special_token_input_patch.bin")) {
    if (error) {
      *error = "missing special_token_input_patch.npz/.bin in " + export_dir;
    }
    return false;
  }
  return true;
}

static void PrintUsage(const char* prog) {
  std::fprintf(stderr,
               "GPU dual-decoder test for simulst\n"
               "\n"
               "Usage: %s [options] [json_config] [wav_16k_mono] [chunk_samples]\n"
               "\n"
               "Options:\n"
               "  -h, --help              Show this help\n"
               "  --transcribe-only       Enable transcribe decoder only\n"
               "  --translate-only        Enable translate decoder only\n"
               "  --both                  Enable both decoders (default)\n"
               "  --transcribe-lang LANG  e.g. auto, Chinese (default: auto)\n"
               "  --translate-lang LANG   e.g. English (default: English)\n"
               "  --n-gpu-layers N        LLM Metal layers, -1 = all (default: -1)\n"
               "  --encoder-provider P    coreml or auto (default: coreml)\n"
               "  --num-chunks N          ONNX encoder steps per LLM prefill (default: 1)\n"
               "  --test-set-tasks        Switch tasks mid-run via simulst_set_tasks\n"
               "\n"
               "Defaults:\n"
               "  json_config   <repo>/simulst/test/test_config_gpu.json\n"
               "  wav_16k_mono  <repo>/wav/001.wav\n"
               "  chunk_samples 1600\n"
               "\n"
               "GPU notes (macOS):\n"
               "  LLM decoder uses llama.cpp Metal when n_gpu_layers != 0\n"
               "  ONNX encoder uses CoreML when encoder_provider=coreml/auto\n",
               prog);
}

static bool ParseArgs(int argc, char** argv, const fs::path& repo_root,
                      TestOptions* opts) {
  const fs::path default_cfg =
      repo_root.empty() ? fs::path("../test/test_config_gpu.json")
                        : repo_root / "simulst/test/test_config_gpu.json";
  const fs::path default_wav =
      repo_root.empty() ? fs::path("../../wav/001.wav") : repo_root / "wav/001.wav";

  opts->config_path = default_cfg.string();
  opts->wav_path = default_wav.string();

  std::vector<std::string> positional;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "-h" || arg == "--help") {
      PrintUsage(argv[0]);
      return false;
    }
    if (arg == "--transcribe-only") {
      opts->enable_transcribe = true;
      opts->enable_translate = false;
      continue;
    }
    if (arg == "--translate-only") {
      opts->enable_transcribe = false;
      opts->enable_translate = true;
      continue;
    }
    if (arg == "--both") {
      opts->enable_transcribe = true;
      opts->enable_translate = true;
      continue;
    }
    if (arg == "--test-set-tasks") {
      opts->test_set_tasks = true;
      continue;
    }
    if (arg == "--transcribe-lang" && i + 1 < argc) {
      opts->transcribe_lang = argv[++i];
      continue;
    }
    if (arg == "--translate-lang" && i + 1 < argc) {
      opts->translate_lang = argv[++i];
      continue;
    }
    if (arg == "--n-gpu-layers" && i + 1 < argc) {
      opts->n_gpu_layers = std::atoi(argv[++i]);
      continue;
    }
    if (arg == "--encoder-provider" && i + 1 < argc) {
      opts->encoder_provider = argv[++i];
      continue;
    }
    if (arg == "--num-chunks" && i + 1 < argc) {
      opts->num_chunks = std::atoi(argv[++i]);
      continue;
    }
    positional.push_back(arg);
  }

  if (!positional.empty()) opts->config_path = positional[0];
  if (positional.size() > 1) opts->wav_path = positional[1];
  if (positional.size() > 2) opts->chunk_samples = std::atoi(positional[2].c_str());
  return true;
}

static nlohmann::json BuildRuntimeConfig(const TestOptions& opts,
                                         const nlohmann::json& base) {
  nlohmann::json cfg = base;
  cfg["enable_transcribe"] = opts.enable_transcribe;
  cfg["enable_translate"] = opts.enable_translate;
  cfg["transcribe_lang"] = opts.transcribe_lang;
  cfg["translate_lang"] = opts.translate_lang;
  cfg["n_gpu_layers"] = opts.n_gpu_layers;
  cfg["encoder_provider"] = opts.encoder_provider;
  cfg["num_chunks"] = std::max(1, opts.num_chunks);
  return cfg;
}

static void PrintGpuPlan(const TestOptions& opts, const nlohmann::json& cfg) {
  std::fprintf(stderr, "=== simulst GPU test plan ===\n");
  std::fprintf(stderr, "config:           %s\n", opts.config_path.c_str());
  std::fprintf(stderr, "wav:              %s\n", opts.wav_path.c_str());
  std::fprintf(stderr, "chunk_samples:    %d\n", opts.chunk_samples);
  std::fprintf(stderr, "encoder_provider: %s\n", cfg.value("encoder_provider", "").c_str());
  std::fprintf(stderr, "num_chunks:       %d\n", cfg.value("num_chunks", 1));
  std::fprintf(stderr, "n_gpu_layers:     %d\n", cfg.value("n_gpu_layers", 0));
  std::fprintf(stderr, "enable_transcribe:%s lang=%s\n",
               cfg.value("enable_transcribe", false) ? " true" : " false",
               cfg.value("transcribe_lang", "").c_str());
  std::fprintf(stderr, "enable_translate: %s lang=%s\n",
               cfg.value("enable_translate", false) ? "true" : "false",
               cfg.value("translate_lang", "").c_str());
#if defined(__APPLE__)
  std::fprintf(stderr, "platform:         macOS (Metal LLM + CoreML encoder expected)\n");
#else
  std::fprintf(stderr, "platform:         non-Apple (GPU may be unavailable)\n");
#endif
  std::fprintf(stderr, "=============================\n");
}

static void PrintPollSummary(const char* poll_json, const char* tag) {
  if (!poll_json || poll_json[0] == '\0') return;
  try {
    const nlohmann::json j = nlohmann::json::parse(poll_json);
    std::fprintf(stderr, "[%s] speaking=%s\n", tag,
                 j.value("speaking", false) ? "true" : "false");
    const std::string transcript = j.value("partial_transcript", "");
    const std::string translation = j.value("partial_translation", "");
    if (!transcript.empty()) {
      std::fprintf(stderr, "[%s] partial_transcript: %s\n", tag, transcript.c_str());
    }
    if (!translation.empty()) {
      std::fprintf(stderr, "[%s] partial_translation: %s\n", tag, translation.c_str());
    }
    if (j.contains("finalized_transcripts")) {
      for (const auto& item : j["finalized_transcripts"]) {
        std::fprintf(stderr, "[%s] finalized_transcript: %s\n", tag,
                     item.get<std::string>().c_str());
      }
    }
    if (j.contains("finalized_translations")) {
      for (const auto& item : j["finalized_translations"]) {
        std::fprintf(stderr, "[%s] finalized_translation: %s\n", tag,
                     item.get<std::string>().c_str());
      }
    }
  } catch (const std::exception& e) {
    std::fprintf(stderr, "[%s] parse error: %s\n", tag, e.what());
    std::fprintf(stderr, "[%s] raw: %s\n", tag, poll_json);
  }
}

static bool PollHasFinalized(const char* poll_json) {
  if (!poll_json || poll_json[0] == '\0') return false;
  try {
    const nlohmann::json j = nlohmann::json::parse(poll_json);
    if (j.contains("finalized_transcripts") && j["finalized_transcripts"].is_array() &&
        !j["finalized_transcripts"].empty()) {
      return true;
    }
    if (j.contains("finalized_translations") && j["finalized_translations"].is_array() &&
        !j["finalized_translations"].empty()) {
      return true;
    }
    if (j.contains("finalized") && j["finalized"].is_array() && !j["finalized"].empty()) {
      return true;
    }
  } catch (...) {
  }
  return false;
}

static bool RunStreamingInference(SimulstHandle* handle,
                                  const std::vector<float>& samples,
                                  int32_t chunk_samples, bool* got_finalized) {
  const auto t0 = std::chrono::steady_clock::now();

  for (size_t i = 0; i < samples.size(); i += static_cast<size_t>(chunk_samples)) {
    const int32_t n = static_cast<int32_t>(
        std::min<size_t>(chunk_samples, samples.size() - i));
    simulst_accept_waveform(handle, samples.data() + i, n);
    const char* poll = simulst_poll(handle);
    if (poll && poll[0] != '\0') {
      if (PollHasFinalized(poll)) {
        *got_finalized = true;
        PrintPollSummary(poll, "stream");
        std::printf("%s\n", poll);
      }
      simulst_free_string(poll);
    }
  }

  simulst_flush(handle);
  const char* poll = simulst_poll(handle);
  if (poll && poll[0] != '\0') {
    if (PollHasFinalized(poll)) {
      *got_finalized = true;
    }
    PrintPollSummary(poll, "final");
    std::printf("final %s\n", poll);
    simulst_free_string(poll);
  }

  const auto t1 = std::chrono::steady_clock::now();
  const double sec = std::chrono::duration<double>(t1 - t0).count();
  const double audio_sec = samples.size() / 16000.0;
  std::fprintf(stderr, "inference wall time: %.3f s for %.2f s audio (%.2fx realtime)\n",
               sec, audio_sec, audio_sec > 0.0 ? audio_sec / sec : 0.0);
  return true;
}

int main(int argc, char** argv) {
  const fs::path repo_root = FindRepoRoot(fs::current_path());
  TestOptions opts;
  if (!ParseArgs(argc, argv, repo_root, &opts)) {
    return 0;
  }

  nlohmann::json base_cfg;
  try {
    base_cfg = nlohmann::json::parse(LoadConfigWithResolvedPaths(opts.config_path.c_str()));
  } catch (const std::exception& e) {
    std::fprintf(stderr, "config error: %s\n", e.what());
    return 1;
  }

  const nlohmann::json cfg = BuildRuntimeConfig(opts, base_cfg);
  PrintGpuPlan(opts, cfg);

  const std::string export_dir = cfg.value("export_dir", "");
  std::string model_error;
  if (!ValidateModelDir(export_dir, &model_error)) {
    std::fprintf(stderr, "model error: %s\n", model_error.c_str());
    return 1;
  }

  std::string vad_path;
  if (cfg.contains("vad") && cfg["vad"].contains("model")) {
    vad_path = cfg["vad"]["model"].get<std::string>();
  } else {
    vad_path = cfg.value("vad_model", "");
  }
  if (vad_path.empty() || !fs::exists(vad_path)) {
    std::fprintf(stderr, "vad model not found: %s\n", vad_path.c_str());
    return 1;
  }
  if (!fs::exists(opts.wav_path)) {
    std::fprintf(stderr, "wav not found: %s\n", opts.wav_path.c_str());
    return 1;
  }

  const auto init_t0 = std::chrono::steady_clock::now();
  SimulstHandle* handle = simulst_create(cfg.dump().c_str());
  const auto init_t1 = std::chrono::steady_clock::now();
  if (!handle) {
    std::fprintf(stderr, "create failed: %s\n",
                 simulst_last_error() ? simulst_last_error() : "unknown");
    return 2;
  }
  const double init_sec =
      std::chrono::duration<double>(init_t1 - init_t0).count();
  std::fprintf(stderr, "pipeline initialized in %.3f s\n", init_sec);

  const std::vector<float> samples = ReadWavMono16k(opts.wav_path.c_str());
  if (samples.empty()) {
    std::fprintf(stderr, "failed to read wav: %s\n", opts.wav_path.c_str());
    simulst_destroy(handle);
    return 3;
  }
  std::fprintf(stderr, "loaded %zu samples (%.2f sec)\n", samples.size(),
               samples.size() / 16000.0);

  bool got_finalized = false;

  if (opts.test_set_tasks) {
    std::fprintf(stderr, "phase 1: translate-only\n");
    nlohmann::json task_json = {
        {"enable_transcribe", false},
        {"enable_translate", true},
        {"translate_lang", opts.translate_lang},
    };
    if (!simulst_set_tasks(handle, task_json.dump().c_str())) {
      std::fprintf(stderr, "set_tasks(translate-only) failed: %s\n",
                   simulst_last_error() ? simulst_last_error() : "unknown");
      simulst_destroy(handle);
      return 5;
    }
    const size_t half = samples.size() / 2;
    std::vector<float> first_half(samples.begin(),
                                  samples.begin() + static_cast<ptrdiff_t>(half));
    RunStreamingInference(handle, first_half, opts.chunk_samples, &got_finalized);
    simulst_reset(handle);

    std::fprintf(stderr, "phase 2: transcribe-only\n");
    task_json = {
        {"enable_transcribe", true},
        {"enable_translate", false},
        {"transcribe_lang", opts.transcribe_lang},
    };
    if (!simulst_set_tasks(handle, task_json.dump().c_str())) {
      std::fprintf(stderr, "set_tasks(transcribe-only) failed: %s\n",
                   simulst_last_error() ? simulst_last_error() : "unknown");
      simulst_destroy(handle);
      return 5;
    }
    std::vector<float> second_half(samples.begin() + static_cast<ptrdiff_t>(half),
                                   samples.end());
    RunStreamingInference(handle, second_half, opts.chunk_samples, &got_finalized);
  } else {
    RunStreamingInference(handle, samples, opts.chunk_samples, &got_finalized);
  }

  const char* err = simulst_last_error();
  if (err && err[0] != '\0') {
    std::fprintf(stderr, "pipeline error: %s\n", err);
  }

  simulst_destroy(handle);

  if (!got_finalized) {
    std::fprintf(stderr, "warning: no finalized output produced\n");
    return 4;
  }

  std::fprintf(stderr, "gpu test done\n");
  return 0;
}
