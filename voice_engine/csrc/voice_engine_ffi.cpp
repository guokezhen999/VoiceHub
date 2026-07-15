#include "voice_engine_ffi.h"

#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#endif

#include <cstring>
#include <mutex>
#include <string>

#include "nlohmann/json.hpp"
#include "streaming_asr_pipeline.h"
#include "voice_engine_config.h"

namespace {

static std::mutex g_error_mutex;
static std::string g_last_error;

void SetError(const std::string& msg) {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  g_last_error = msg;
}

// Copy a std::string to a heap C string the caller frees with voice_engine_free_string.
const char* ToHeap(const std::string& s) {
  char* buf = new char[s.size() + 1];
  std::memcpy(buf, s.c_str(), s.size() + 1);
  return buf;
}

}  // namespace

struct VoiceEngineHandle {
  voice_engine::StreamingAsrPipeline pipeline;
};

VoiceEngineHandle* voice_engine_create(const char* json_config) {
  g_last_error.clear();
  if (!json_config) {
    SetError("json_config is null");
    return nullptr;
  }

  voice_engine::VoiceEngineConfig cfg;
  try {
    nlohmann::json j = nlohmann::json::parse(json_config);

    std::string mode = j.value("mode", "online");
    cfg.mode = (mode == "offline") ? voice_engine::AsrMode::kOffline
                                   : voice_engine::AsrMode::kOnline;
    cfg.encoder = j.value("encoder", "");
    cfg.decoder = j.value("decoder", "");
    cfg.joiner = j.value("joiner", "");
    cfg.tokens = j.value("tokens", "");
    cfg.model_type = j.value("model_type", "");
    cfg.decoding_method = j.value("decoding_method", "greedy_search");
    cfg.num_threads = j.value("num_threads", 1);
    cfg.provider = j.value("provider", "cpu");
    cfg.debug = j.value("debug", true);

    if (j.contains("vad")) {
      const auto& v = j["vad"];
      cfg.vad_model = v.value("model", "");
      cfg.vad_threshold = v.value("threshold", 0.5f);
      cfg.vad_min_silence_duration = v.value("min_silence_duration", 0.5f);
      cfg.vad_min_speech_duration = v.value("min_speech_duration", 0.25f);
      cfg.vad_window_size = v.value("window_size", 512);
      cfg.vad_max_speech_duration = v.value("max_speech_duration", 20.0f);
      cfg.vad_sample_rate = v.value("sample_rate", 16000);
      cfg.vad_num_threads = v.value("num_threads", 1);
      cfg.vad_buffer_size_seconds = v.value("buffer_size_seconds", 60.0f);
    }
    if (j.contains("vad_model")) cfg.vad_model = j.value("vad_model", cfg.vad_model);

    if (j.contains("endpoint")) {
      const auto& e = j["endpoint"];
      cfg.enable_endpoint = e.value("enable", true);
      cfg.rule1_min_trailing_silence = e.value("rule1_min_trailing_silence", 2.4f);
      cfg.rule2_min_trailing_silence = e.value("rule2_min_trailing_silence", 1.0f);
    }

    cfg.circular_buffer_capacity = j.value("circular_buffer_capacity", 480000);
    cfg.max_pre_speech_samples = j.value("max_pre_speech_samples", 8000);
  } catch (const std::exception& e) {
    SetError(std::string("invalid json config: ") + e.what());
    return nullptr;
  }

  auto* handle = new VoiceEngineHandle();
  if (!handle->pipeline.Init(cfg)) {
    SetError(handle->pipeline.LastError());
    delete handle;
    return nullptr;
  }
  return handle;
}

void voice_engine_accept_waveform(VoiceEngineHandle* handle,
                                  const float* samples, int32_t n) {
  if (!handle) return;
  handle->pipeline.AcceptWaveform(samples, n);
}

const char* voice_engine_poll(VoiceEngineHandle* handle) {
  if (!handle) {
    SetError("handle is null");
    return nullptr;
  }
  return ToHeap(handle->pipeline.PollJson());
}

void voice_engine_flush(VoiceEngineHandle* handle) {
  if (!handle) return;
  handle->pipeline.Flush();
}

void voice_engine_reset(VoiceEngineHandle* handle) {
  if (!handle) return;
  handle->pipeline.Reset();
}

void voice_engine_destroy(VoiceEngineHandle* handle) {
  delete handle;
}

void voice_engine_free_string(const char* str) {
  delete[] str;
}

const char* voice_engine_last_error() {
  std::lock_guard<std::mutex> lock(g_error_mutex);
  if (g_last_error.empty()) return nullptr;
  return g_last_error.c_str();
}

float* voice_engine_decode_file(const char* path, int32_t* out_n) {
  if (!path || !out_n) return nullptr;
  *out_n = 0;

#ifdef __APPLE__
  CFStringRef pathStr = CFStringCreateWithCString(nullptr, path, kCFStringEncodingUTF8);
  if (!pathStr) return nullptr;

  CFURLRef url = CFURLCreateWithFileSystemPath(nullptr, pathStr, kCFURLPOSIXPathStyle, false);
  CFRelease(pathStr);
  if (!url) return nullptr;

  ExtAudioFileRef audioFile = nullptr;
  OSStatus status = ExtAudioFileOpenURL(url, &audioFile);
  CFRelease(url);
  if (status != noErr) return nullptr;

  // Set client format to 16kHz Float32 mono PCM
  AudioStreamBasicDescription clientFormat;
  std::memset(&clientFormat, 0, sizeof(clientFormat));
  clientFormat.mSampleRate = 16000.0;
  clientFormat.mFormatID = kAudioFormatLinearPCM;
  clientFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  clientFormat.mBitsPerChannel = 32;
  clientFormat.mChannelsPerFrame = 1;
  clientFormat.mFramesPerPacket = 1;
  clientFormat.mBytesPerFrame = 4;
  clientFormat.mBytesPerPacket = 4;

  status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                    sizeof(clientFormat), &clientFormat);
  if (status != noErr) {
    ExtAudioFileDispose(audioFile);
    return nullptr;
  }

  std::vector<float> allSamples;
  const int kBufferSize = 4096;
  std::vector<float> buffer(kBufferSize);

  AudioBufferList bufferList;
  bufferList.mNumberBuffers = 1;
  bufferList.mBuffers[0].mNumberChannels = 1;
  bufferList.mBuffers[0].mDataByteSize = kBufferSize * sizeof(float);
  bufferList.mBuffers[0].mData = buffer.data();

  while (true) {
    UInt32 numFrames = kBufferSize;
    status = ExtAudioFileRead(audioFile, &numFrames, &bufferList);
    if (status != noErr || numFrames == 0) break;
    allSamples.insert(allSamples.end(), buffer.begin(), buffer.begin() + numFrames);
  }

  ExtAudioFileDispose(audioFile);

  if (allSamples.empty()) return nullptr;

  *out_n = static_cast<int32_t>(allSamples.size());
  float* outSamples = new float[allSamples.size()];
  std::memcpy(outSamples, allSamples.data(), allSamples.size() * sizeof(float));
  return outSamples;
#else
  return nullptr;
#endif
}

void voice_engine_free_samples(float* samples) {
  delete[] samples;
}
