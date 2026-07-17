#include "simulst_ffi.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"

namespace fs = std::filesystem;

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

static void PrintPollSummary(const char* poll_json) {
  if (!poll_json || poll_json[0] == '\0') return;
  try {
    const nlohmann::json j = nlohmann::json::parse(poll_json);
    const bool speaking = j.value("speaking", false);
    const std::string partial_transcript = j.value("partial_transcript", "");
    const std::string partial_translation = j.value("partial_translation", "");
    std::fprintf(stderr, "[poll] speaking=%s transcript=%zu translation=%zu chars\n",
                 speaking ? "true" : "false", partial_transcript.size(),
                 partial_translation.size());
    if (!partial_transcript.empty()) {
      std::fprintf(stderr, "       transcript: %s\n", partial_transcript.c_str());
    }
    if (!partial_translation.empty()) {
      std::fprintf(stderr, "       translation: %s\n", partial_translation.c_str());
    }
    if (j.contains("finalized_transcripts") && j["finalized_transcripts"].is_array()) {
      for (const auto& item : j["finalized_transcripts"]) {
        std::fprintf(stderr, "       finalized transcript: %s\n",
                     item.get<std::string>().c_str());
      }
    }
    if (j.contains("finalized_translations") && j["finalized_translations"].is_array()) {
      for (const auto& item : j["finalized_translations"]) {
        std::fprintf(stderr, "       finalized translation: %s\n",
                     item.get<std::string>().c_str());
      }
    }
  } catch (const std::exception& e) {
    std::fprintf(stderr, "[poll] raw: %s\n", poll_json);
    std::fprintf(stderr, "[poll] parse error: %s\n", e.what());
  }
}

static void PrintUsage(const char* prog) {
  std::fprintf(stderr,
               "Usage: %s [json_config] [wav_16k_mono] [chunk_samples]\n"
               "\n"
               "Defaults (when args omitted):\n"
               "  json_config   <repo>/simulst/test/test_config.json\n"
               "  wav_16k_mono  <repo>/wav/001.wav\n"
               "  chunk_samples 1600\n",
               prog);
}

int main(int argc, char** argv) {
  const fs::path repo_root = FindRepoRoot(fs::current_path());
  const fs::path default_cfg =
      repo_root.empty() ? fs::path("../test/test_config.json")
                        : repo_root / "simulst/test/test_config.json";
  const fs::path default_wav =
      repo_root.empty() ? fs::path("../../wav/001.wav") : repo_root / "wav/001.wav";

  std::string config_path = default_cfg.string();
  std::string wav_path = default_wav.string();
  int32_t chunk = 1600;

  if (argc > 1) {
    if (std::string(argv[1]) == "-h" || std::string(argv[1]) == "--help") {
      PrintUsage(argv[0]);
      return 0;
    }
    config_path = argv[1];
  }
  if (argc > 2) wav_path = argv[2];
  if (argc > 3) chunk = std::atoi(argv[3]);

  nlohmann::json cfg;
  try {
    const std::string json = LoadConfigWithResolvedPaths(config_path.c_str());
    cfg = nlohmann::json::parse(json);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "config error: %s\n", e.what());
    return 1;
  }

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
  if (!fs::exists(wav_path)) {
    std::fprintf(stderr, "wav not found: %s\n", wav_path.c_str());
    return 1;
  }

  std::fprintf(stderr, "config: %s\n", config_path.c_str());
  std::fprintf(stderr, "model:  %s\n", export_dir.c_str());
  std::fprintf(stderr, "vad:    %s\n", vad_path.c_str());
  std::fprintf(stderr, "wav:    %s\n", wav_path.c_str());
  std::fprintf(stderr, "chunk:  %d samples\n", chunk);

  SimulstHandle* handle = simulst_create(cfg.dump().c_str());
  if (!handle) {
    std::fprintf(stderr, "create failed: %s\n",
                 simulst_last_error() ? simulst_last_error() : "unknown");
    return 2;
  }
  std::fprintf(stderr, "pipeline initialized\n");

  const std::vector<float> samples = ReadWavMono16k(wav_path.c_str());
  if (samples.empty()) {
    std::fprintf(stderr, "failed to read wav: %s\n", wav_path.c_str());
    simulst_destroy(handle);
    return 3;
  }
  std::fprintf(stderr, "loaded %zu samples (%.2f sec)\n", samples.size(),
               samples.size() / 16000.0);

  bool got_finalized = false;

  for (size_t i = 0; i < samples.size(); i += static_cast<size_t>(chunk)) {
    const int32_t n = static_cast<int32_t>(
        std::min<size_t>(chunk, samples.size() - i));
    simulst_accept_waveform(handle, samples.data() + i, n);
    const char* poll = simulst_poll(handle);
    if (poll && poll[0] != '\0') {
      bool interesting = false;
      try {
        const nlohmann::json j = nlohmann::json::parse(poll);
        if (j.value("speaking", false)) interesting = true;
        if (!j.value("partial_transcript", std::string()).empty()) interesting = true;
        if (!j.value("partial_translation", std::string()).empty()) interesting = true;
        if (!j.value("partial", std::string()).empty()) interesting = true;
        if (j.contains("finalized_transcripts") && j["finalized_transcripts"].is_array() &&
            !j["finalized_transcripts"].empty()) {
          got_finalized = true;
          interesting = true;
        }
        if (j.contains("finalized_translations") && j["finalized_translations"].is_array() &&
            !j["finalized_translations"].empty()) {
          got_finalized = true;
          interesting = true;
        }
        if (j.contains("finalized") && j["finalized"].is_array() &&
            !j["finalized"].empty()) {
          got_finalized = true;
          interesting = true;
        }
      } catch (...) {
        interesting = true;
      }
      if (interesting) {
        PrintPollSummary(poll);
        std::printf("%s\n", poll);
      }
      simulst_free_string(poll);
    }
  }

  simulst_flush(handle);
  const char* poll = simulst_poll(handle);
  if (poll && poll[0] != '\0') {
    PrintPollSummary(poll);
    try {
      const nlohmann::json j = nlohmann::json::parse(poll);
      if (j.contains("finalized_transcripts") && j["finalized_transcripts"].is_array() &&
          !j["finalized_transcripts"].empty()) {
        got_finalized = true;
      }
      if (j.contains("finalized_translations") && j["finalized_translations"].is_array() &&
          !j["finalized_translations"].empty()) {
        got_finalized = true;
      }
      if (j.contains("finalized") && j["finalized"].is_array() &&
          !j["finalized"].empty()) {
        got_finalized = true;
      }
    } catch (...) {
    }
    std::printf("final %s\n", poll);
    simulst_free_string(poll);
  }

  const char* err = simulst_last_error();
  if (err && err[0] != '\0') {
    std::fprintf(stderr, "pipeline error: %s\n", err);
  }

  simulst_destroy(handle);

  if (!got_finalized) {
    std::fprintf(stderr, "warning: no finalized translation produced\n");
    return 4;
  }

  std::fprintf(stderr, "done\n");
  return 0;
}
