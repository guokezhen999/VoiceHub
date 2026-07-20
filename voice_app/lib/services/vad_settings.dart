class VadConfig {
  double threshold;
  double minSilenceDuration;
  double minSpeechDuration;

  VadConfig({
    required this.threshold,
    required this.minSilenceDuration,
    required this.minSpeechDuration,
  });
}

class VadSettings {
  static final VadConfig generalMode = VadConfig(
    threshold: 0.5,
    minSilenceDuration: 0.3,
    minSpeechDuration: 0.3,
  );

  static final VadConfig simulstMode = VadConfig(
    threshold: 0.5,
    minSilenceDuration: 0.5,
    minSpeechDuration: 0.3,
  );
}
