#ifndef FBANK_EXTRACTOR_H_
#define FBANK_EXTRACTOR_H_

#include <cstdint>
#include <vector>

namespace simulst {

// Streaming 80-dim log-fbank extractor (16 kHz, lhotse-compatible settings).
class FbankExtractor {
 public:
  FbankExtractor();
  ~FbankExtractor();

  void Reset();

  void AcceptWaveform(const float* samples, int32_t n);

  void InputFinished();

  int32_t NumFramesReady() const;

  // Frames available after flushing the waveform tail (as InputFinished would).
  int32_t NumFramesReadyIfFinished() const;

  // Returns flattened (n, feature_dim) row-major features.
  std::vector<float> GetFrames(int32_t frame_index, int32_t n) const;

  int32_t FeatureDim() const { return feature_dim_; }
  int32_t FrameShiftSamples() const;
  int32_t FrameLengthSamples() const;

 private:
  class Impl;
  Impl* impl_ = nullptr;
  int32_t feature_dim_ = 80;
};

}  // namespace simulst

#endif  // FBANK_EXTRACTOR_H_
