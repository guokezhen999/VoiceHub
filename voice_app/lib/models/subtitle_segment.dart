class SubtitleSegment {
  final int index;
  final double start; // seconds
  final double end; // seconds
  final String originalText;
  String translatedText;

  /// Optional speaker side for dual-dialogue history ('A' | 'B').
  final String? side;

  SubtitleSegment({
    required this.index,
    required this.start,
    required this.end,
    required this.originalText,
    this.translatedText = '',
    this.side,
  });

  String formatTime(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).round());
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final secs = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$secs,$ms';
  }

  String toSrtString() {
    final buffer = StringBuffer();
    buffer.writeln(index);
    buffer.writeln('${formatTime(start)} --> ${formatTime(end)}');
    buffer.writeln(originalText);
    if (translatedText.isNotEmpty) {
      buffer.writeln(translatedText);
    }
    buffer.writeln();
    return buffer.toString();
  }
}
