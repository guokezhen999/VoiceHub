#include "fbank_extractor.h"

#include <memory>

#include "kaldi-native-fbank/csrc/online-feature.h"
#include "kaldi-native-fbank/csrc/feature-window.h"

namespace simulst {

class FbankExtractor::Impl {
 public:
  knf::FbankOptions opts;
  std::unique_ptr<knf::OnlineFbank> fbank;
  int64_t num_samples_ = 0;

  Impl() {
    opts.frame_opts.samp_freq = 16000;
    opts.frame_opts.dither = 0.0f;
    opts.frame_opts.snip_edges = false;
    opts.frame_opts.frame_shift_ms = 10.0f;
    opts.frame_opts.frame_length_ms = 25.0f;
    opts.mel_opts.num_bins = 80;
    opts.mel_opts.low_freq = 20.0f;
    opts.mel_opts.high_freq = -400.0f;
    fbank = std::make_unique<knf::OnlineFbank>(opts);
  }

  void Reset() {
    num_samples_ = 0;
    fbank = std::make_unique<knf::OnlineFbank>(opts);
  }
};

FbankExtractor::FbankExtractor() : impl_(new Impl()) {}

FbankExtractor::~FbankExtractor() { delete impl_; }

void FbankExtractor::Reset() { impl_->Reset(); }

void FbankExtractor::AcceptWaveform(const float* samples, int32_t n) {
  if (!samples || n <= 0) return;
  impl_->num_samples_ += n;
  impl_->fbank->AcceptWaveform(16000, samples, n);
}

void FbankExtractor::InputFinished() { impl_->fbank->InputFinished(); }

int32_t FbankExtractor::NumFramesReady() const {
  return impl_->fbank->NumFramesReady();
}

int32_t FbankExtractor::NumFramesReadyIfFinished() const {
  return knf::NumFrames(impl_->num_samples_, impl_->opts.frame_opts, true);
}

int32_t FbankExtractor::FrameShiftSamples() const {
  return static_cast<int32_t>(impl_->opts.frame_opts.samp_freq *
                              impl_->opts.frame_opts.frame_shift_ms / 1000.0f);
}

int32_t FbankExtractor::FrameLengthSamples() const {
  return static_cast<int32_t>(impl_->opts.frame_opts.samp_freq *
                              impl_->opts.frame_opts.frame_length_ms / 1000.0f);
}

std::vector<float> FbankExtractor::GetFrames(int32_t frame_index, int32_t n) const {
  std::vector<float> out;
  if (n <= 0) return out;
  out.reserve(static_cast<size_t>(n) * feature_dim_);
  for (int32_t i = 0; i < n; ++i) {
    const float* frame = impl_->fbank->GetFrame(frame_index + i);
    out.insert(out.end(), frame, frame + feature_dim_);
  }
  return out;
}

}  // namespace simulst
