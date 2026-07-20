#include "streaming_ast_pipeline.h"

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>

#include "c-api.h"
#include "fbank_extractor.h"
#include "nlohmann/json.hpp"
#include "onnx_streaming_encoder.h"
#include "npz_loader.h"

namespace simulst {
namespace {

static const int32_t kSampleRate = 16000;

static bool DebugEnabled() {
  const char* v = std::getenv("SIMULST_DEBUG");
  return v && v[0] != '\0' && std::string(v) != "0";
}

static void DebugLog(const char* fmt, ...) {
  if (!DebugEnabled()) return;
  va_list args;
  va_start(args, fmt);
  std::vfprintf(stderr, fmt, args);
  va_end(args);
}

static std::string JoinPath(const std::string& a, const std::string& b) {
  if (a.empty()) return b;
  if (a.back() == '/') return a + b;
  return a + "/" + b;
}

static bool ReadBinaryFloats(const std::string& path, std::vector<float>* out) {
  std::ifstream in(path, std::ios::binary | std::ios::ate);
  if (!in) return false;
  const auto size = in.tellg();
  if (size <= 0 || (size % static_cast<std::streamoff>(sizeof(float))) != 0) return false;
  in.seekg(0);
  out->resize(static_cast<size_t>(size) / sizeof(float));
  in.read(reinterpret_cast<char*>(out->data()), size);
  return static_cast<bool>(in);
}

static bool LoadEmbPatchFromNpz(const std::string& path, SpeechLlmMeta* meta,
                                std::string* error) {
  std::map<std::string, std::vector<float>> floats;
  std::map<std::string, std::vector<int64_t>> ints;
  if (!NpzLoader::Load(path, floats, ints, error)) return false;
  const auto it_a = floats.find("emb_a");
  const auto it_end = floats.find("emb_a_end");
  if (it_a == floats.end() || it_end == floats.end()) {
    if (error) *error = "npz missing emb_a or emb_a_end: " + path;
    return false;
  }
  meta->emb_a = it_a->second;
  meta->emb_a_end = it_end->second;
  return true;
}

static bool LoadEmbPatchFromInlineJson(const nlohmann::json& patch,
                                       SpeechLlmMeta* meta, std::string* error) {
  if (!patch.is_array() || patch.size() < 2) {
    if (error) *error = "special_token_input_patch must contain at least 2 rows";
    return false;
  }
  meta->emb_a.clear();
  meta->emb_a_end.clear();
  for (const auto& v : patch[0]) meta->emb_a.push_back(v.get<float>());
  for (const auto& v : patch[1]) meta->emb_a_end.push_back(v.get<float>());
  return true;
}

static bool LoadEmbPatchFromBin(const std::string& path, SpeechLlmMeta* meta,
                                std::string* error) {
  std::vector<float> patch;
  if (!ReadBinaryFloats(path, &patch) ||
      static_cast<int32_t>(patch.size()) < meta->llm_dim * 2) {
    if (error) {
      *error =
          "missing <A>/</A> embeddings: add special_token_input_patch to "
          "speechllm_meta.json or special_token_input_patch.npz/.bin";
    }
    return false;
  }
  meta->emb_a.assign(patch.begin(), patch.begin() + meta->llm_dim);
  meta->emb_a_end.assign(patch.begin() + meta->llm_dim,
                         patch.begin() + meta->llm_dim * 2);
  return true;
}

static const char* TaskKindName(SimulstTaskKind kind) {
  return kind == SimulstTaskKind::kTranscribe ? "transcribe" : "translate";
}

}  // namespace

StreamingAstPipeline::StreamingAstPipeline() = default;

StreamingAstPipeline::~StreamingAstPipeline() { Release(); }

void StreamingAstPipeline::Release() {
  if (vad_) {
    SherpaOnnxDestroyVoiceActivityDetector(vad_);
    vad_ = nullptr;
  }
  if (circular_buffer_) {
    SherpaOnnxDestroyCircularBuffer(circular_buffer_);
    circular_buffer_ = nullptr;
  }
  encoder_.reset();
  task_decoders_.clear();
  shared_llm_.reset();
  fbank_.reset();
}

bool StreamingAstPipeline::LoadMeta(const std::string& export_dir) {
  const std::string meta_path = JoinPath(export_dir, "speechllm_meta.json");
  std::ifstream in(meta_path);
  if (!in) {
    last_error_ = "speechllm_meta.json not found";
    return false;
  }

  nlohmann::json meta;
  try {
    in >> meta;
  } catch (const std::exception& e) {
    last_error_ = std::string("invalid speechllm_meta.json: ") + e.what();
    return false;
  }

  llm_meta_.llm_dim = meta.value("llm_dim", 1024);
  if (meta.contains("special_token_ids")) {
    const auto& ids = meta["special_token_ids"];
    llm_meta_.token_a_id = ids.value("<A>", 0);
    llm_meta_.token_a_end_id = ids.value("</A>", 0);
    llm_meta_.token_w_id = ids.value("<W>", 0);
  }
  if (meta.contains("eos_token_id")) {
    llm_meta_.token_w_id = meta.value("eos_token_id", llm_meta_.token_w_id);
  }

  if (meta.contains("special_token_input_patch")) {
    if (!LoadEmbPatchFromInlineJson(meta["special_token_input_patch"], &llm_meta_,
                                    &last_error_)) {
      return false;
    }
    return true;
  }

  std::vector<std::string> npz_candidates;
  if (meta.contains("special_token_input_patch_file")) {
    npz_candidates.push_back(meta["special_token_input_patch_file"].get<std::string>());
  }
  if (meta.contains("special_token_embeddings_file")) {
    npz_candidates.push_back(meta["special_token_embeddings_file"].get<std::string>());
  }
  npz_candidates.push_back("special_token_input_patch.npz");
  npz_candidates.push_back("special_token_embeddings.npz");

  for (const auto& npz_name : npz_candidates) {
    if (npz_name.empty()) continue;
    const std::string npz_path = JoinPath(export_dir, npz_name);
    if (LoadEmbPatchFromNpz(npz_path, &llm_meta_, &last_error_)) {
      return true;
    }
    last_error_.clear();
  }

  const std::string bin_path = JoinPath(export_dir, "special_token_input_patch.bin");
  if (LoadEmbPatchFromBin(bin_path, &llm_meta_, &last_error_)) {
    return true;
  }
  return false;
}

bool StreamingAstPipeline::InitDecoders(std::string* error) {
  task_decoders_.clear();

  if (!config_.enable_transcribe && !config_.enable_translate) {
    if (error) *error = "at least one of enable_transcribe or enable_translate must be true";
    return false;
  }

  if (!shared_llm_) {
    shared_llm_ = LlamaGgufModel::Load(gguf_path_, llm_meta_, config_.n_gpu_layers,
                                         error);
    if (!shared_llm_) {
      return false;
    }
  }

  const int32_t threads_per_task = config_.DecoderThreadsPerTask();

  auto add_decoder = [&](SimulstTaskKind kind) -> bool {
    TaskDecoderState state;
    state.kind = kind;
    state.prompt = config_.PromptForTask(kind);
    state.decoder = std::make_unique<LlamaGgufDecoder>();
    if (!state.decoder->InitFromSharedModel(shared_llm_, llm_meta_, config_.n_ctx,
                                              config_.n_batch, threads_per_task, error)) {
      return false;
    }
    DebugLog("[simulst] decoder %s prompt=%s\n", TaskKindName(kind),
             state.prompt.c_str());
    task_decoders_.push_back(std::move(state));
    return true;
  };

  if (config_.enable_transcribe && !add_decoder(SimulstTaskKind::kTranscribe)) {
    return false;
  }
  if (config_.enable_translate && !add_decoder(SimulstTaskKind::kTranslate)) {
    return false;
  }
  return true;
}

bool StreamingAstPipeline::Init(const SimulstConfig& config) {
  config_ = config;
  Release();
  last_error_.clear();
  finalized_.clear();
  speaking_ = false;
  pre_speech_.clear();
  pre_speech_size_ = 0;
  post_speech_size_ = 0;
  vad_ever_detected_ = false;
  in_segment_ = false;

  if (!config_.enable_transcribe && !config_.enable_translate) {
    last_error_ = "at least one of enable_transcribe or enable_translate must be true";
    return false;
  }

  if (!LoadMeta(config_.export_dir)) return false;

  encoder_ = std::make_unique<OnnxStreamingEncoder>();
  std::string enc_err;
  if (!encoder_->Init(config_.export_dir, config_.encoder_provider,
                      config_.encoder_num_threads, &enc_err)) {
    last_error_ = enc_err;
    return false;
  }
  ResolveStreamingChunkParams();

  const std::string meta_path = JoinPath(config_.export_dir, "speechllm_meta.json");
  nlohmann::json meta = nlohmann::json::parse(std::ifstream(meta_path));
  const std::string gguf_file = meta.value("gguf_file", "llm-f16.gguf");
  gguf_path_ = JoinPath(config_.export_dir, gguf_file);

  std::string dec_err;
  if (!InitDecoders(&dec_err)) {
    last_error_ = dec_err;
    return false;
  }

  fbank_ = std::make_unique<FbankExtractor>();

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

  vad_ = SherpaOnnxCreateVoiceActivityDetector(&vad_cfg, config_.vad_buffer_size_seconds);
  if (!vad_) {
    last_error_ = "failed to create VAD";
    return false;
  }

  circular_buffer_ = SherpaOnnxCreateCircularBuffer(config_.circular_buffer_capacity);
  if (!circular_buffer_) {
    last_error_ = "failed to create circular buffer";
    return false;
  }

  return true;
}

bool StreamingAstPipeline::SetTasks(const SimulstConfig& config) {
  if (!shared_llm_) {
    last_error_ = "pipeline not initialized";
    return false;
  }
  if (!config.enable_transcribe && !config.enable_translate) {
    last_error_ = "at least one of enable_transcribe or enable_translate must be true";
    return false;
  }

  config_.enable_transcribe = config.enable_transcribe;
  config_.enable_translate = config.enable_translate;
  config_.transcribe_lang = config.transcribe_lang;
  config_.translate_lang = config.translate_lang;
  config_.prompt = config.prompt;

  std::string dec_err;
  if (!InitDecoders(&dec_err)) {
    last_error_ = dec_err;
    return false;
  }

  for (auto& task : task_decoders_) {
    task.partial.clear();
    if (task.decoder) task.decoder->Reset();
  }
  return true;
}

const TaskDecoderState* StreamingAstPipeline::FindTaskDecoder(
    SimulstTaskKind kind) const {
  for (const auto& task : task_decoders_) {
    if (task.kind == kind) return &task;
  }
  return nullptr;
}

TaskDecoderState* StreamingAstPipeline::FindTaskDecoder(SimulstTaskKind kind) {
  for (auto& task : task_decoders_) {
    if (task.kind == kind) return &task;
  }
  return nullptr;
}

std::string StreamingAstPipeline::PartialForTask(SimulstTaskKind kind) const {
  const TaskDecoderState* task = FindTaskDecoder(kind);
  return task ? task->partial : "";
}

void StreamingAstPipeline::ResolveStreamingChunkParams() {
  if (!encoder_) return;
  const int32_t frames_per_step = encoder_->EmbedFramesPerStep();
  if (frames_per_step <= 0) return;

  const int32_t new_embed_chunk = config_.EffectiveEmbedChunkSize(frames_per_step);
  const int32_t new_max_segments = config_.EffectiveMaxLlmSegments();
  if (new_embed_chunk == resolved_embed_chunk_size_ &&
      new_max_segments == resolved_max_llm_segments_ &&
      resolved_max_llm_segments_ > 0) {
    return;
  }

  resolved_embed_chunk_size_ = new_embed_chunk;
  resolved_max_llm_segments_ = new_max_segments;
  std::fprintf(stderr,
               "simulst streaming: num_chunks=%d embed_frames_per_step=%d "
               "embed_chunk_size=%d max_llm_segments=%d\n",
               config_.EffectiveNumChunks(), frames_per_step,
               resolved_embed_chunk_size_, resolved_max_llm_segments_);
}

void StreamingAstPipeline::MaybeEvictLlmKvBySegmentLimit() {
  if (resolved_max_llm_segments_ <= 0) return;

  ++llm_segment_count_;
  if (llm_segment_count_ < resolved_max_llm_segments_) return;

  const int32_t keep_count = std::min(config_.keep_recent_segments, resolved_max_llm_segments_ - 1);
  DebugLog("[simulst] max_llm_segments=%d reached, evicting decoder KV keeping recent %d segments\n",
           resolved_max_llm_segments_, keep_count);
  for (auto& task : task_decoders_) {
    if (task.decoder) {
      if (keep_count > 0) {
        task.decoder->EvictCacheKeepRecent(keep_count);
      } else {
        task.decoder->Reset();
      }
    }
  }
  llm_segment_count_ = std::max(0, keep_count);
}

void StreamingAstPipeline::BeginSegment() {
  in_segment_ = true;
  chunk_index_ = 0;
  encoder_step_ = 0;
  last_decoded_embed_idx_ = 0;
  fbank_finished_ = false;
  llm_embed_cap_ = -1;

  for (auto& task : task_decoders_) {
    task.partial.clear();
    if (!config_.keep_kv_across_segments && task.decoder) {
      task.decoder->Reset();
    }
  }

  encoder_->Reset();
  fbank_->Reset();
  last_real_samples_.clear();
}

void StreamingAstPipeline::EndSegment(FinalizedSegment* out) {
  if (!in_segment_) return;
  const int32_t llm_embed_cap =
      llm_embed_cap_ >= 0 ? llm_embed_cap_ : encoder_->TotalEmbedFrames();
  std::fprintf(stderr,
               "[simulst] EndSegment: freeze llm embed cap=%d (total=%d)\n",
               llm_embed_cap, encoder_->TotalEmbedFrames());

  PadAudioTailForEncoder();
  fbank_->InputFinished();
  fbank_finished_ = true;
  DrainFbankAndEncoder(false);
  DebugLog("[simulst] EndSegment fbank_ready=%d encoder_step=%d embed_frames=%d\n",
           fbank_->NumFramesReady(), encoder_step_, encoder_->TotalEmbedFrames());
  MaybeDecodeChunks(true, llm_embed_cap);

  if (out) {
    out->transcript = PartialForTask(SimulstTaskKind::kTranscribe);
    out->translation = PartialForTask(SimulstTaskKind::kTranslate);
  }

  if (config_.keep_kv_across_segments) {
    MaybeEvictLlmKvBySegmentLimit();
  }

  in_segment_ = false;
  for (auto& task : task_decoders_) {
    task.partial.clear();
  }
  chunk_index_ = 0;
  last_decoded_embed_idx_ = 0;
  encoder_step_ = 0;
  fbank_finished_ = false;
  llm_embed_cap_ = -1;
}

void StreamingAstPipeline::ProcessSpeechWindow(const float* samples, int32_t n,
                                               bool llm_decode) {
  if (!in_segment_) BeginSegment();
  if (samples && n > 0) {
    last_real_samples_.insert(last_real_samples_.end(), samples, samples + n);
    if (last_real_samples_.size() > 16000) {
      last_real_samples_.erase(last_real_samples_.begin(),
                               last_real_samples_.begin() + (last_real_samples_.size() - 16000));
    }
  }
  fbank_->AcceptWaveform(samples, n);
  DrainFbankAndEncoder();
  if (llm_decode) MaybeDecodeChunks(false);
}

void StreamingAstPipeline::PadAudioTailForEncoder() {
  if (!fbank_ || !encoder_) return;

  const int32_t stride = encoder_->DecodeChunkLen();
  const int32_t window = encoder_->InputTimeSteps();
  const int32_t shift_samples = fbank_->FrameShiftSamples();
  const int32_t frame_len_samples = fbank_->FrameLengthSamples();

  for (int32_t iter = 0; iter < 64; ++iter) {
    const int32_t ready = std::max(fbank_->NumFramesReady(),
                                   fbank_->NumFramesReadyIfFinished());

    if (encoder_step_ * stride >= ready) return;

    int32_t need_frames = 0;
    int32_t step = encoder_step_;
    while (step * stride < ready) {
      if (step * stride + window > ready) {
        need_frames = step * stride + window - ready;
        break;
      }
      ++step;
    }
    if (need_frames == 0) return;

    const int32_t silence_samples =
        need_frames * shift_samples + frame_len_samples;
    std::vector<float> pad_samples(static_cast<size_t>(silence_samples), 0.0f);
    if (!last_real_samples_.empty()) {
      for (size_t i = 0; i < pad_samples.size(); ++i) {
        pad_samples[i] = last_real_samples_[last_real_samples_.size() - 1 - (i % last_real_samples_.size())];
      }
    }
    fbank_->AcceptWaveform(pad_samples.data(), silence_samples);
    DebugLog("[simulst] PadAudioTail step=%d need_frames=%d silence_samples=%d "
             "ready_if_finished=%d\n",
             step, need_frames, silence_samples,
             fbank_->NumFramesReadyIfFinished());
  }
}

void StreamingAstPipeline::DrainFbankAndEncoder(bool allow_partial) {
  const int32_t stride = encoder_->DecodeChunkLen();
  const int32_t window = encoder_->InputTimeSteps();

  while (true) {
    const int32_t ready = fbank_->NumFramesReady();
    const int32_t start = encoder_step_ * stride;
    if (start >= ready) break;
    if (start + window > ready) {
      if (!allow_partial) {
        std::fprintf(stderr,
                     "[simulst] incomplete encoder window after tail padding: "
                     "start=%d ready=%d window=%d\n",
                     start, ready, window);
      }
      break;
    }

    std::vector<float> feats = fbank_->GetFrames(start, window);
    std::string err;
    if (!encoder_->FeedFeatures(feats.data(), window, &err)) {
      last_error_ = err;
      DebugLog("[simulst] FeedFeatures failed: %s\n", err.c_str());
      return;
    }
    DebugLog("[simulst] FeedFeatures ok start=%d take=%d embed_frames=%d\n", start,
             window, encoder_->TotalEmbedFrames());
    ++encoder_step_;
  }
}

void StreamingAstPipeline::MaybeDecodeChunks(bool is_last_chunk,
                                             int32_t max_embed_frames) {
  ResolveStreamingChunkParams();

  const int32_t encoder_total = encoder_->TotalEmbedFrames();
  const int32_t total =
      (max_embed_frames >= 0) ? std::min(encoder_total, max_embed_frames)
                              : encoder_total;
  if (total <= last_decoded_embed_idx_) {
    if (is_last_chunk && max_embed_frames >= 0 &&
        encoder_total > max_embed_frames) {
      std::fprintf(stderr,
                   "[simulst] skip tail embed decode: decoded=%d cap=%d "
                   "encoder_total=%d\n",
                   last_decoded_embed_idx_, max_embed_frames, encoder_total);
    }
    return;
  }
  const int32_t chunk_size = std::max(1, resolved_embed_chunk_size_);

  while (true) {
    const int32_t available = total - last_decoded_embed_idx_;
    if (available < chunk_size && !(is_last_chunk && available > 0)) break;

    const int32_t take = (available >= chunk_size || !is_last_chunk)
                             ? std::min(chunk_size, available)
                             : available;
    if (take <= 0) break;

    std::vector<float> slice;
    encoder_->GetEmbeddings(last_decoded_embed_idx_,
                            last_decoded_embed_idx_ + take, &slice);

    const bool is_new_segment = (chunk_index_ == 0);
    // Prefill-only until a full embed batch is ready, or the VAD segment ends.
    const bool is_segment_end = is_last_chunk || (take >= chunk_size);

    for (auto& task : task_decoders_) {
      if (!task.decoder) continue;

      const std::string partial_prefix = task.partial;
      auto on_partial = [&](const std::string& chunk_so_far) {
        std::string display = partial_prefix;
        if (!chunk_so_far.empty()) {
          if (!display.empty()) display += " ";
          display += chunk_so_far;
        }
        task.partial = display;
      };

      std::fprintf(stderr,
                   "[simulst] decode_%s chunk=%d embed_take=%d is_last_chunk=%d\n",
                   TaskKindName(task.kind), chunk_index_, take,
                   is_last_chunk ? 1 : 0);

      const std::string chunk_text = task.decoder->FeedChunk(
          task.prompt, slice.data(), take, config_.max_new_tokens,
          config_.repetition_penalty, config_.first_token_eos_threshold,
          config_.punct_kv_mode, is_new_segment, is_segment_end,
          config_.eos_penalty_only_last_chunk, config_.ClearKvOnSentenceEnd(),
          on_partial);

      DebugLog("[simulst] decode %s chunk=%d take=%d new_seg=%d seg_end=%d text_len=%zu\n",
               TaskKindName(task.kind), chunk_index_, take, is_new_segment ? 1 : 0,
               is_segment_end ? 1 : 0, chunk_text.size());

      if (!chunk_text.empty() && task.partial.empty()) {
        if (!partial_prefix.empty()) task.partial += " ";
        task.partial += chunk_text;
      }
      if (!chunk_text.empty() && config_.clear_kv_on_sentence_punct &&
          LlamaGgufDecoder::EndsWithSentencePunct(chunk_text)) {
        llm_segment_count_ = 0;
        DebugLog("[simulst] sentence punct reset: cleared llm_segment_count\n");
      }
    }

    last_decoded_embed_idx_ += take;
    ++chunk_index_;

    if (!is_last_chunk && (total - last_decoded_embed_idx_) < chunk_size) break;
    if (is_last_chunk && last_decoded_embed_idx_ >= total) break;
  }
}

static bool SegmentHasText(const StreamingAstPipeline::FinalizedSegment& seg) {
  return !seg.transcript.empty() || !seg.translation.empty();
}

void StreamingAstPipeline::FinalizeVadSegment(const SherpaOnnxSpeechSegment* seg) {
  FinalizedSegment final_seg;
  EndSegment(&final_seg);

  vad_ever_detected_ = false;
  pre_speech_.clear();
  pre_speech_size_ = 0;
  post_speech_size_ = 0;

  if (SegmentHasText(final_seg)) {
    if (seg) {
      final_seg.start_sec = seg->start / static_cast<double>(kSampleRate);
      final_seg.end_sec = (seg->start + seg->n) / static_cast<double>(kSampleRate);
    }
    finalized_.push_back(final_seg);
  }
}

void StreamingAstPipeline::AcceptWaveform(const float* samples, int32_t n) {
  if (!vad_ || !circular_buffer_ || !samples || n <= 0) return;

  SherpaOnnxCircularBufferPush(circular_buffer_, samples, n);
  const int32_t window = config_.vad_window_size;

  // Mirrors voice_engine::StreamingAsrPipeline::AcceptWaveform (online path).
  while (SherpaOnnxCircularBufferSize(circular_buffer_) >= window) {
    const int32_t head = SherpaOnnxCircularBufferHead(circular_buffer_);
    const float* w = SherpaOnnxCircularBufferGet(circular_buffer_, head, window);
    SherpaOnnxCircularBufferPop(circular_buffer_, window);

    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad_, w, window);

    if (SherpaOnnxVoiceActivityDetectorDetected(vad_)) {
      post_speech_size_ = 0;
      if (!vad_ever_detected_) {
        vad_ever_detected_ = true;
        for (const auto& buffered : pre_speech_) {
          ProcessSpeechWindow(buffered.data(),
                              static_cast<int32_t>(buffered.size()));
        }
        pre_speech_.clear();
        pre_speech_size_ = 0;
      }
      ProcessSpeechWindow(w, window);
    } else if (!vad_ever_detected_) {
      pre_speech_.emplace_back(w, w + window);
      pre_speech_size_ += window;
      while (pre_speech_size_ > config_.max_pre_speech_samples) {
        pre_speech_size_ -= static_cast<int32_t>(pre_speech_.front().size());
        pre_speech_.erase(pre_speech_.begin());
      }
    } else if (in_segment_ &&
               post_speech_size_ + window <= config_.max_post_speech_samples) {
      if (post_speech_size_ == 0) {
        llm_embed_cap_ = encoder_->TotalEmbedFrames();
        std::fprintf(stderr,
                     "[simulst] VAD speech ended: stop LLM decode, embed_cap=%d\n",
                     llm_embed_cap_);
      }
      ProcessSpeechWindow(w, window, false);
      post_speech_size_ += window;
    }

    while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
      const SherpaOnnxSpeechSegment* seg = SherpaOnnxVoiceActivityDetectorFront(vad_);
      SherpaOnnxVoiceActivityDetectorPop(vad_);
      FinalizeVadSegment(seg);
      if (seg) SherpaOnnxDestroySpeechSegment(seg);
    }

    SherpaOnnxCircularBufferFree(w);
  }

  speaking_ = SherpaOnnxVoiceActivityDetectorDetected(vad_) != 0;
}

void StreamingAstPipeline::DrainCircularBufferTail() {
  if (!vad_ || !circular_buffer_) return;

  const int32_t window = config_.vad_window_size;
  std::vector<float> padded(static_cast<size_t>(window), 0.0f);

  while (SherpaOnnxCircularBufferSize(circular_buffer_) > 0) {
    const int32_t head = SherpaOnnxCircularBufferHead(circular_buffer_);
    const int32_t avail = SherpaOnnxCircularBufferSize(circular_buffer_);
    const int32_t n = std::min(avail, window);
    const float* w = SherpaOnnxCircularBufferGet(circular_buffer_, head, n);
    SherpaOnnxCircularBufferPop(circular_buffer_, n);

    std::fill(padded.begin(), padded.end(), 0.0f);
    std::memcpy(padded.data(), w, static_cast<size_t>(n) * sizeof(float));
    SherpaOnnxCircularBufferFree(w);

    // VAD always expects a full window; zero-pad the tail.
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad_, padded.data(), window);

    if (SherpaOnnxVoiceActivityDetectorDetected(vad_)) {
      post_speech_size_ = 0;
      if (!vad_ever_detected_) {
        vad_ever_detected_ = true;
        for (const auto& buffered : pre_speech_) {
          ProcessSpeechWindow(buffered.data(),
                              static_cast<int32_t>(buffered.size()));
        }
        pre_speech_.clear();
        pre_speech_size_ = 0;
      }
      ProcessSpeechWindow(padded.data(), window);
    } else if (in_segment_ &&
               post_speech_size_ + window <= config_.max_post_speech_samples) {
      if (post_speech_size_ == 0) {
        llm_embed_cap_ = encoder_->TotalEmbedFrames();
        std::fprintf(stderr,
                     "[simulst] VAD speech ended: stop LLM decode, embed_cap=%d\n",
                     llm_embed_cap_);
      }
      ProcessSpeechWindow(padded.data(), window, false);
      post_speech_size_ += window;
    }

    while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
      const SherpaOnnxSpeechSegment* seg = SherpaOnnxVoiceActivityDetectorFront(vad_);
      SherpaOnnxVoiceActivityDetectorPop(vad_);
      FinalizeVadSegment(seg);
      if (seg) SherpaOnnxDestroySpeechSegment(seg);
    }
  }
}

void StreamingAstPipeline::Flush() {
  if (!vad_) return;

  // Feed any tail samples (< vad_window_size) still sitting in the circular buffer.
  DrainCircularBufferTail();

  // If speech ended without a VAD segment pop, finalize the open AST segment.
  if (in_segment_) {
    FinalizedSegment final_seg;
    EndSegment(&final_seg);
    vad_ever_detected_ = false;
    pre_speech_.clear();
    pre_speech_size_ = 0;
    post_speech_size_ = 0;
    if (SegmentHasText(final_seg)) {
      finalized_.push_back(final_seg);
    }
  }

  // Mirrors voice_engine::StreamingAsrPipeline::Flush (online path).
  SherpaOnnxVoiceActivityDetectorFlush(vad_);

  while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
    const SherpaOnnxSpeechSegment* seg = SherpaOnnxVoiceActivityDetectorFront(vad_);
    SherpaOnnxVoiceActivityDetectorPop(vad_);
    FinalizeVadSegment(seg);
    if (seg) SherpaOnnxDestroySpeechSegment(seg);
  }
}

void StreamingAstPipeline::Reset() {
  if (vad_) SherpaOnnxVoiceActivityDetectorReset(vad_);
  if (circular_buffer_) SherpaOnnxCircularBufferReset(circular_buffer_);
  if (encoder_) encoder_->Reset();
  for (auto& task : task_decoders_) {
    if (task.decoder) task.decoder->Reset();
    task.partial.clear();
  }
  if (fbank_) fbank_->Reset();

  vad_ever_detected_ = false;
  in_segment_ = false;
  pre_speech_.clear();
  pre_speech_size_ = 0;
  post_speech_size_ = 0;
  llm_embed_cap_ = -1;
  encoder_step_ = 0;
  fbank_finished_ = false;
  last_decoded_embed_idx_ = 0;
  chunk_index_ = 0;
  llm_segment_count_ = 0;
  finalized_.clear();
  speaking_ = false;
  last_real_samples_.clear();
}

std::string StreamingAstPipeline::PollJson() {
  nlohmann::json j;
  j["speaking"] = speaking_;

  const std::string partial_transcript = PartialForTask(SimulstTaskKind::kTranscribe);
  const std::string partial_translation = PartialForTask(SimulstTaskKind::kTranslate);
  j["partial_transcript"] = partial_transcript;
  j["partial_translation"] = partial_translation;

  // Legacy field: prefer translation, fall back to transcript.
  if (!partial_translation.empty()) {
    j["partial"] = partial_translation;
  } else {
    j["partial"] = partial_transcript;
  }

  nlohmann::json segments = nlohmann::json::array();
  nlohmann::json finalized_transcripts = nlohmann::json::array();
  nlohmann::json finalized_translations = nlohmann::json::array();
  nlohmann::json finalized_legacy = nlohmann::json::array();

  while (!finalized_.empty()) {
    const auto& seg = finalized_.front();

    nlohmann::json s;
    s["transcript"] = seg.transcript;
    s["translation"] = seg.translation;
    s["start"] = seg.start_sec;
    s["end"] = seg.end_sec;
    if (!seg.translation.empty()) {
      s["text"] = seg.translation;
    } else {
      s["text"] = seg.transcript;
    }
    segments.push_back(s);

    if (!seg.transcript.empty()) {
      finalized_transcripts.push_back(seg.transcript);
    }
    if (!seg.translation.empty()) {
      finalized_translations.push_back(seg.translation);
    }
    if (!seg.translation.empty()) {
      finalized_legacy.push_back(seg.translation);
    } else if (!seg.transcript.empty()) {
      finalized_legacy.push_back(seg.transcript);
    }

    finalized_.pop_front();
  }

  j["segments"] = segments;
  j["finalized_transcripts"] = finalized_transcripts;
  j["finalized_translations"] = finalized_translations;
  j["finalized"] = finalized_legacy;
  return j.dump();
}

}  // namespace simulst
