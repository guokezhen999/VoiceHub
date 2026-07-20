import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:voice_app/models/subtitle_segment.dart';

/// Service to handle SRT formatting, audio slicing, and ZIP package export for offline file transcriptions.
class SubtitleExportService {
  /// Generates the SRT format string from a list of subtitle segments.
  static String generateSrtContent(List<SubtitleSegment> subtitles) {
    final buffer = StringBuffer();
    for (final seg in subtitles) {
      buffer.write(seg.toSrtString());
    }
    return buffer.toString();
  }

  /// Exports SRT content to a file at [targetPath].
  static Future<void> exportToSrtFile(List<SubtitleSegment> subtitles, String targetPath) async {
    final srtContent = generateSrtContent(subtitles);
    final file = File(targetPath);
    await file.writeAsString(srtContent);
  }

  /// Exports the transcript as a ZIP archive containing a markdown transcript and sliced WAV segments.
  static Future<void> exportToZip({
    required String audioFileName,
    required String sourceLang,
    required String targetLang,
    required List<SubtitleSegment> subtitles,
    required Float32List audioSamples,
    required String targetZipPath,
  }) async {
    // Initialize native bindings before calling writeWave
    sherpa_onnx.initBindings();

    // 1. Create a temporary folder
    final tempDir = await Directory.systemTemp.createTemp('voice_export_');
    final wavDir = Directory(p.join(tempDir.path, 'wav'));
    await wavDir.create();

    // 2. Generate Markdown Content and slice audio segment by segment
    final mdBuffer = StringBuffer();
    mdBuffer.writeln('# Audio Transcription & Translation');
    mdBuffer.writeln();
    mdBuffer.writeln('- **Original File**: $audioFileName');
    mdBuffer.writeln('- **Source Language**: $sourceLang');
    mdBuffer.writeln('- **Target Language**: $targetLang');
    mdBuffer.writeln('- **Export Date**: ${DateTime.now().toLocal().toString()}');
    mdBuffer.writeln();
    mdBuffer.writeln('---');
    mdBuffer.writeln();

    for (final seg in subtitles) {
      // a. Extract samples
      final int startSample = (seg.start * 16000).round().clamp(0, audioSamples.length);
      final int endSample = (seg.end * 16000).round().clamp(0, audioSamples.length);
      
      if (endSample > startSample) {
        final Float32List segmentSamples = Float32List.sublistView(audioSamples, startSample, endSample);
        final segmentWavName = 'segment_${seg.index}.wav';
        final segmentWavPath = p.join(wavDir.path, segmentWavName);

        // b. Write wave file using sherpa-onnx utility
        final ok = sherpa_onnx.writeWave(
          filename: segmentWavPath,
          samples: segmentSamples,
          sampleRate: 16000,
        );
        if (!ok) {
          throw Exception('Failed to write segment audio wave file: $segmentWavPath');
        }
      }

      // c. Append to markdown
      mdBuffer.writeln('### Segment #${seg.index} (${seg.formatTime(seg.start)} --> ${seg.formatTime(seg.end)})');
      mdBuffer.writeln('[Play Audio](wav/segment_${seg.index}.wav)');
      mdBuffer.writeln();
      mdBuffer.writeln('- **$sourceLang (src)**: ${seg.originalText}');
      if (seg.translatedText.isNotEmpty) {
        mdBuffer.writeln('- **$targetLang (tgt)**: ${seg.translatedText}');
      }
      mdBuffer.writeln();
      mdBuffer.writeln('---');
      mdBuffer.writeln();
    }

    // 3. Write Markdown file
    final mdFile = File(p.join(tempDir.path, 'transcript.md'));
    await mdFile.writeAsString(mdBuffer.toString());

    // 4. Create the ZIP archive
    final encoder = ZipFileEncoder();
    encoder.create(targetZipPath);
    
    // Add the markdown file at root of the zip
    await encoder.addFile(mdFile, 'transcript.md');

    // Add wav folder contents
    final wavFiles = wavDir.listSync();
    for (final entity in wavFiles) {
      if (entity is File) {
        await encoder.addFile(entity, 'wav/${p.basename(entity.path)}');
      }
    }
    await encoder.close();

    // 5. Cleanup the temporary build directory
    await tempDir.delete(recursive: true);
  }
}
