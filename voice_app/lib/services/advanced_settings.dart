class AdvancedSettings {
  /// Penalty for repeated tokens in simultaneous translation (1.0 = off).
  static double repetitionPenalty = 1.0;

  /// Decoding method for ASR: 'modified_beam_search' (default/Beam Search) or 'greedy_search'.
  static String asrDecodingMethod = 'modified_beam_search';
}
