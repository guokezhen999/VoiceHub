#include "streaming_asr_pipeline.h"

#include <cstring>

// The include dir is the folder that directly contains c-api.h (set by
// build_macos.sh's -DSHERPA_ONNX_INCLUDE_DIR and by CMake's find_path), so we
// include it directly rather than via the "sherpa-onnx/c-api/" prefix.
#include "c-api.h"
#include "nlohmann/json.hpp"

namespace voice_engine {

static const int32_t kSampleRate = 16000;

StreamingAsrPipeline::~StreamingAsrPipeline() { Release(); }

void StreamingAsrPipeline::Release() {
  if (online_stream_) {
    SherpaOnnxDestroyOnlineStream(online_stream_);
    online_stream_ = nullptr;
  }
  if (online_recognizer_) {
    SherpaOnnxDestroyOnlineRecognizer(online_recognizer_);
    online_recognizer_ = nullptr;
  }
  if (offline_recognizer_) {
    SherpaOnnxDestroyOfflineRecognizer(offline_recognizer_);
    offline_recognizer_ = nullptr;
  }
  if (vad_) {
    SherpaOnnxDestroyVoiceActivityDetector(vad_);
    vad_ = nullptr;
  }
  if (circular_buffer_) {
    SherpaOnnxDestroyCircularBuffer(circular_buffer_);
    circular_buffer_ = nullptr;
  }
}

void StreamingAsrPipeline::RecreateOnlineStream() {
  if (online_stream_) {
    SherpaOnnxDestroyOnlineStream(online_stream_);
    online_stream_ = nullptr;
  }
  online_stream_ = SherpaOnnxCreateOnlineStream(online_recognizer_);
}

std::string StreamingAsrPipeline::GetOnlineText() {
  if (!online_recognizer_ || !online_stream_) return "";
  const SherpaOnnxOnlineRecognizerResult* r =
      SherpaOnnxGetOnlineStreamResult(online_recognizer_, online_stream_);
  std::string text = (r && r->text) ? r->text : "";
  if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
  return text;
}

bool StreamingAsrPipeline::Init(const VoiceEngineConfig& config) {
  config_ = config;
  Release();
  pre_speech_.clear();
  pre_speech_size_ = 0;
  vad_ever_detected_ = false;
  partial_.clear();
  finalized_.clear();
  speaking_ = false;

  // ---- VAD (silero) ----
  SherpaOnnxVadModelConfig vad_cfg;
  std::memset(&vad_cfg, 0, sizeof(vad_cfg));
  vad_cfg.silero_vad.model = config_.vad_model.c_str();
  vad_cfg.silero_vad.threshold = config_.vad_threshold;
  vad_cfg.silero_vad.min_silence_duration = config_.vad_min_silence_duration;
  vad_cfg.silero_vad.min_speech_duration = config_.vad_min_speech_duration;
  vad_cfg.silero_vad.window_size = config_.vad_window_size;
  vad_cfg.silero_vad.max_speech_duration = config_.vad_max_speech_duration;
  vad_cfg.sample_rate = config_.vad_sample_rate;
  vad_cfg.num_threads = config_.vad_num_threads;
  vad_cfg.provider = "cpu";
  vad_cfg.debug = 0;

  vad_ = SherpaOnnxCreateVoiceActivityDetector(&vad_cfg,
                                                config_.vad_buffer_size_seconds);
  if (!vad_) {
    last_error_ = "Failed to create VoiceActivityDetector";
    return false;
  }

  circular_buffer_ =
      SherpaOnnxCreateCircularBuffer(config_.circular_buffer_capacity);
  if (!circular_buffer_) {
    last_error_ = "Failed to create CircularBuffer";
    return false;
  }

  if (config_.mode == AsrMode::kOnline) {
    SherpaOnnxOnlineRecognizerConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.feat_config.sample_rate = kSampleRate;
    cfg.feat_config.feature_dim = 80;
    cfg.model_config.transducer.encoder = config_.encoder.c_str();
    cfg.model_config.transducer.decoder = config_.decoder.c_str();
    cfg.model_config.transducer.joiner = config_.joiner.c_str();
    cfg.model_config.tokens = config_.tokens.c_str();
    cfg.model_config.num_threads = config_.num_threads;
    cfg.model_config.provider = config_.provider.c_str();
    cfg.model_config.debug = config_.debug ? 1 : 0;
    cfg.model_config.model_type = config_.model_type.c_str();
    cfg.decoding_method = config_.decoding_method.c_str();
    cfg.enable_endpoint = config_.enable_endpoint ? 1 : 0;
    cfg.rule1_min_trailing_silence = config_.rule1_min_trailing_silence;
    cfg.rule2_min_trailing_silence = config_.rule2_min_trailing_silence;
    cfg.rule_fsts = "";
    cfg.rule_fars = "";

    online_recognizer_ = SherpaOnnxCreateOnlineRecognizer(&cfg);
    if (!online_recognizer_) {
      last_error_ = "Failed to create OnlineRecognizer";
      return false;
    }
    online_stream_ = SherpaOnnxCreateOnlineStream(online_recognizer_);
    if (!online_stream_) {
      last_error_ = "Failed to create OnlineStream";
      return false;
    }
  } else {
    SherpaOnnxOfflineRecognizerConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.feat_config.sample_rate = kSampleRate;
    cfg.feat_config.feature_dim = 80;
    cfg.model_config.transducer.encoder = config_.encoder.c_str();
    cfg.model_config.transducer.decoder = config_.decoder.c_str();
    cfg.model_config.transducer.joiner = config_.joiner.c_str();
    cfg.model_config.tokens = config_.tokens.c_str();
    cfg.model_config.num_threads = config_.num_threads;
    cfg.model_config.provider = config_.provider.c_str();
    cfg.model_config.debug = config_.debug ? 1 : 0;
    cfg.model_config.model_type = config_.model_type.c_str();
    cfg.decoding_method = config_.decoding_method.c_str();
    cfg.rule_fsts = "";
    cfg.rule_fars = "";

    offline_recognizer_ = SherpaOnnxCreateOfflineRecognizer(&cfg);
    if (!offline_recognizer_) {
      last_error_ = "Failed to create OfflineRecognizer";
      return false;
    }
  }

  return true;
}

void StreamingAsrPipeline::AcceptWaveform(const float* samples, int32_t n) {
  if (!vad_ || !circular_buffer_ || !samples || n <= 0) return;

  SherpaOnnxCircularBufferPush(circular_buffer_, samples, n);
  const int32_t window = config_.vad_window_size;

  if (config_.mode == AsrMode::kOnline) {
    // ---- Online path ----
    while (SherpaOnnxCircularBufferSize(circular_buffer_) >= window) {
      const int32_t head = SherpaOnnxCircularBufferHead(circular_buffer_);
      const float* w = SherpaOnnxCircularBufferGet(circular_buffer_, head, window);
      SherpaOnnxCircularBufferPop(circular_buffer_, window);

      SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad_, w, window);

      if (SherpaOnnxVoiceActivityDetectorDetected(vad_)) {
        if (!vad_ever_detected_) {
          vad_ever_detected_ = true;
          for (const auto& buffered : pre_speech_) {
            SherpaOnnxOnlineStreamAcceptWaveform(online_stream_, kSampleRate,
                                                 buffered.data(),
                                                 static_cast<int32_t>(buffered.size()));
          }
          pre_speech_.clear();
          pre_speech_size_ = 0;
        }
        SherpaOnnxOnlineStreamAcceptWaveform(online_stream_, kSampleRate, w, window);
      } else if (!vad_ever_detected_) {
        pre_speech_.emplace_back(w, w + window);
        pre_speech_size_ += window;
        while (pre_speech_size_ > config_.max_pre_speech_samples) {
          pre_speech_size_ -= static_cast<int32_t>(pre_speech_.front().size());
          pre_speech_.erase(pre_speech_.begin());
        }
      }

      // A completed VAD segment signals utterance end: finalize + reset stream.
      while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
        const SherpaOnnxSpeechSegment* seg =
            SherpaOnnxVoiceActivityDetectorFront(vad_);
        SherpaOnnxVoiceActivityDetectorPop(vad_);

        while (SherpaOnnxIsOnlineStreamReady(online_recognizer_, online_stream_)) {
          SherpaOnnxDecodeOnlineStream(online_recognizer_, online_stream_);
        }

        const std::string final_text = GetOnlineText();
        RecreateOnlineStream();
        vad_ever_detected_ = false;
        pre_speech_.clear();
        pre_speech_size_ = 0;

        if (!final_text.empty()) {
          double start_sec = 0.0;
          double end_sec = 0.0;
          if (seg) {
            start_sec = seg->start / static_cast<double>(kSampleRate);
            end_sec = (seg->start + seg->n) / static_cast<double>(kSampleRate);
          }
          finalized_.push_back({final_text, start_sec, end_sec});
        }
        if (seg) {
          SherpaOnnxDestroySpeechSegment(seg);
        }
        partial_.clear();
      }

      SherpaOnnxCircularBufferFree(w);
    }

    // Drain pending frames and refresh the partial result.
    while (SherpaOnnxIsOnlineStreamReady(online_recognizer_, online_stream_)) {
      SherpaOnnxDecodeOnlineStream(online_recognizer_, online_stream_);
    }
    partial_ = GetOnlineText();
    speaking_ = SherpaOnnxVoiceActivityDetectorDetected(vad_) != 0;
  } else {
    // ---- Offline path ----
    while (SherpaOnnxCircularBufferSize(circular_buffer_) >= window) {
      const int32_t head = SherpaOnnxCircularBufferHead(circular_buffer_);
      const float* w = SherpaOnnxCircularBufferGet(circular_buffer_, head, window);
      SherpaOnnxCircularBufferPop(circular_buffer_, window);
      SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad_, w, window);
      SherpaOnnxCircularBufferFree(w);
    }

    speaking_ = SherpaOnnxVoiceActivityDetectorDetected(vad_) != 0;

    while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
      const SherpaOnnxSpeechSegment* seg =
          SherpaOnnxVoiceActivityDetectorFront(vad_);
      SherpaOnnxVoiceActivityDetectorPop(vad_);
      if (!seg) continue;

      const SherpaOnnxOfflineStream* stream =
          SherpaOnnxCreateOfflineStream(offline_recognizer_);
      SherpaOnnxAcceptWaveformOffline(stream, kSampleRate, seg->samples, seg->n);
      SherpaOnnxDecodeOfflineStream(offline_recognizer_, stream);

      const SherpaOnnxOfflineRecognizerResult* r =
          SherpaOnnxGetOfflineStreamResult(stream);
      std::string text = (r && r->text) ? r->text : "";
      if (r) SherpaOnnxDestroyOfflineRecognizerResult(r);

      SherpaOnnxDestroyOfflineStream(stream);

      if (!text.empty()) {
        double start_sec = seg->start / static_cast<double>(kSampleRate);
        double end_sec = (seg->start + seg->n) / static_cast<double>(kSampleRate);
        finalized_.push_back({text, start_sec, end_sec});
      }
      SherpaOnnxDestroySpeechSegment(seg);
    }
  }
}

void StreamingAsrPipeline::Flush() {
  if (!vad_) return;
  // Force the VAD to emit a segment for any buffered tail samples, mirroring
  // the Dart _stopRecording path that calls vad.flush() before draining.
  SherpaOnnxVoiceActivityDetectorFlush(vad_);

  if (config_.mode == AsrMode::kOnline) {
    if (!online_recognizer_ || !online_stream_) return;
    while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
      const SherpaOnnxSpeechSegment* seg =
          SherpaOnnxVoiceActivityDetectorFront(vad_);
      SherpaOnnxVoiceActivityDetectorPop(vad_);

      while (SherpaOnnxIsOnlineStreamReady(online_recognizer_, online_stream_)) {
        SherpaOnnxDecodeOnlineStream(online_recognizer_, online_stream_);
      }

      const std::string final_text = GetOnlineText();
      RecreateOnlineStream();
      vad_ever_detected_ = false;
      pre_speech_.clear();
      pre_speech_size_ = 0;

      if (!final_text.empty()) {
        double start_sec = 0.0;
        double end_sec = 0.0;
        if (seg) {
          start_sec = seg->start / static_cast<double>(kSampleRate);
          end_sec = (seg->start + seg->n) / static_cast<double>(kSampleRate);
        }
        finalized_.push_back({final_text, start_sec, end_sec});
      }
      if (seg) {
        SherpaOnnxDestroySpeechSegment(seg);
      }
      partial_.clear();
    }
  } else {
    if (!offline_recognizer_) return;
    while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
      const SherpaOnnxSpeechSegment* seg =
          SherpaOnnxVoiceActivityDetectorFront(vad_);
      SherpaOnnxVoiceActivityDetectorPop(vad_);
      if (!seg) continue;

      const SherpaOnnxOfflineStream* stream =
          SherpaOnnxCreateOfflineStream(offline_recognizer_);
      SherpaOnnxAcceptWaveformOffline(stream, kSampleRate, seg->samples, seg->n);
      SherpaOnnxDecodeOfflineStream(offline_recognizer_, stream);

      const SherpaOnnxOfflineRecognizerResult* r =
          SherpaOnnxGetOfflineStreamResult(stream);
      std::string text = (r && r->text) ? r->text : "";
      if (r) SherpaOnnxDestroyOfflineRecognizerResult(r);

      SherpaOnnxDestroyOfflineStream(stream);

      if (!text.empty()) {
        double start_sec = seg->start / static_cast<double>(kSampleRate);
        double end_sec = (seg->start + seg->n) / static_cast<double>(kSampleRate);
        finalized_.push_back({text, start_sec, end_sec});
      }
      SherpaOnnxDestroySpeechSegment(seg);
    }
  }
}

void StreamingAsrPipeline::Reset() {
  if (vad_) SherpaOnnxVoiceActivityDetectorReset(vad_);
  if (circular_buffer_) SherpaOnnxCircularBufferReset(circular_buffer_);
  if (online_recognizer_ && online_stream_)
    SherpaOnnxOnlineStreamReset(online_recognizer_, online_stream_);
  vad_ever_detected_ = false;
  pre_speech_.clear();
  pre_speech_size_ = 0;
  partial_.clear();
  finalized_.clear();
  speaking_ = false;
}

std::string StreamingAsrPipeline::PollJson() {
  nlohmann::json j;
  j["speaking"] = speaking_;
  j["partial"] = partial_;
  std::vector<std::string> out;
  nlohmann::json segments = nlohmann::json::array();
  out.reserve(finalized_.size());
  while (!finalized_.empty()) {
    const auto& seg = finalized_.front();
    out.push_back(seg.text);

    nlohmann::json s;
    s["text"] = seg.text;
    s["start"] = seg.start_sec;
    s["end"] = seg.end_sec;
    segments.push_back(s);

    finalized_.pop_front();
  }
  j["finalized"] = out;
  j["segments"] = segments;
  return j.dump();
}

}  // namespace voice_engine
