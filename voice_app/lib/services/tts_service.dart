import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:voice_app/models/model_manager.dart';

/// Synthesis result returned by [TtsService.synthesize].
class TtsSynthesisResult {
  /// Absolute path of the written WAV file.
  final String wavPath;

  /// Wall-clock time for the synthesis call (seconds).
  final double elapsedSec;

  /// Duration of the generated audio (seconds).
  final double audioDurationSec;

  /// Real-Time Factor = elapsedSec / audioDurationSec.
  final double rtf;

  const TtsSynthesisResult({
    required this.wavPath,
    required this.elapsedSec,
    required this.audioDurationSec,
    required this.rtf,
  });
}

/// Shared TTS engine lifecycle and synthesis helpers.
///
/// Extracted from [TtsScreen] and [CascadeTranslationScreen] to avoid
/// duplication of:
///   - three-branch model config construction (matcha / vits_online / vits)
///   - espeak-ng-data directory resolution
///   - full-width → half-width punctuation conversion
///   - WAV file name generation
///   - [sherpa_onnx.OfflineTts] synthesis + file write
class TtsService {
  // ---------------------------------------------------------------------------
  // Engine state (readable by callers)
  // ---------------------------------------------------------------------------

  sherpa_onnx.OfflineTts? tts;
  bool isInitialized = false;

  /// Maximum valid speaker ID (numSpeakers - 1).  0 when only one speaker.
  int maxSpeakerId = 0;

  // ---------------------------------------------------------------------------
  // Engine lifecycle
  // ---------------------------------------------------------------------------

  /// Initialises [sherpa_onnx.OfflineTts] for [model].
  ///
  /// Handles all three engine types automatically:
  ///   - `matcha`      → [sherpa_onnx.OfflineTtsMatchaModelConfig]
  ///   - `vits_online` → [sherpa_onnx.OfflineTtsVitsModelConfig] (dir path)
  ///   - else          → [sherpa_onnx.OfflineTtsVitsModelConfig] (file path)
  ///
  /// Throws on failure so callers can catch and show a snack-bar.
  Future<void> initialize(ModelInfo model) async {
    if (isInitialized) return;

    // sherpa_onnx native bindings must be initialised before first use.
    sherpa_onnx.initBindings();

    final encoderPath = model.ttsEncoderPath;
    final decoderPath = model.ttsDecoderPath;
    final isSplit = encoderPath != null && decoderPath != null;

    final tokensPath = model.tokensPath!;
    final lexiconPath = model.lexiconPath ?? '';
    final ruleFsts = model.ruleFsts;

    // The espeak-ng data_dir is ONLY for phoneme-based VITS models
    // (piper/coqui/icefall) that lack a lexicon. Feeding it to jieba/lexicon
    // models such as melo or fanchen corrupts synthesis, so we only resolve it
    // when no lexicon exists.
    var dataDir = '';
    if (lexiconPath.isEmpty) {
      dataDir = model.ttsDataDirPath ?? '';
      if (dataDir.isEmpty) {
        final appSupport = await getApplicationSupportDirectory();
        final globalEspeakDir =
            Directory(p.join(appSupport.path, 'espeak-ng-data'));
        if (globalEspeakDir.existsSync()) {
          dataDir = globalEspeakDir.path;
        }
      }
    }

    final sherpa_onnx.OfflineTtsModelConfig modelConfig;

    if (isSplit && model.ttsEngineType == 'matcha') {
      final matcha = sherpa_onnx.OfflineTtsMatchaModelConfig(
        acousticModel: encoderPath,
        vocoder: decoderPath,
        lexicon: lexiconPath,
        tokens: tokensPath,
        dataDir: dataDir,
      );
      modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        numThreads: 2,
        matcha: matcha,
      );
    } else if (isSplit && model.ttsEngineType == 'vits_online') {
      // Pass directory path so C++ auto-detection (offline-tts-impl.cc)
      // finds encoder.onnx/decoder.onnx and routes to OnlineTtsVitsImpl.
      final vits = sherpa_onnx.OfflineTtsVitsModelConfig(
        model: model.path,
        lexicon: lexiconPath,
        tokens: tokensPath,
        dataDir: dataDir,
        dictDir: model.ttsDictDirPath ?? '',
      );
      modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        numThreads: 2,
        vits: vits,
      );
    } else {
      final modelPath = model.ttsModelPath ?? '';
      if (modelPath.isEmpty) {
        throw Exception(
            'VITS model file not found in directory ${model.path}');
      }
      final vits = sherpa_onnx.OfflineTtsVitsModelConfig(
        model: modelPath,
        lexicon: lexiconPath,
        tokens: tokensPath,
        dataDir: dataDir,
        dictDir: model.ttsDictDirPath ?? '',
      );
      modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        numThreads: 2,
        vits: vits,
      );
    }

    final config = sherpa_onnx.OfflineTtsConfig(
      model: modelConfig,
      ruleFsts: ruleFsts,
    );

    tts = sherpa_onnx.OfflineTts(config);

    maxSpeakerId = (tts!.numSpeakers > 0) ? tts!.numSpeakers - 1 : 0;
    isInitialized = true;
  }

  /// Frees the native TTS engine and resets state.
  void deinitialize() {
    tts?.free();
    tts = null;
    isInitialized = false;
    maxSpeakerId = 0;
  }

  // ---------------------------------------------------------------------------
  // Synthesis
  // ---------------------------------------------------------------------------

  /// Synthesises [text] and writes the result to a temporary WAV file.
  ///
  /// [prefix] is prepended to the file name (e.g. `'tts'` or `'tts-cascade'`).
  /// [suffix] is appended before the `.wav` extension (e.g. speaker/speed tag).
  ///
  /// Returns a [TtsSynthesisResult] with the file path and timing metrics.
  /// Throws if the engine is not initialised or if [sherpa_onnx.writeWave] fails.
  Future<TtsSynthesisResult> synthesize({
    required String text,
    required ModelInfo model,
    required int speakerId,
    required double speed,
    String prefix = 'tts',
    String suffix = '',
    int Function(Float32List samples, double progress)? onProgress,
  }) async {
    if (!isInitialized || tts == null) {
      throw StateError('TtsService is not initialized. Call initialize() first.');
    }

    // Pre-process text based on engine type.
    final encoderPath = model.ttsEncoderPath;
    final decoderPath = model.ttsDecoderPath;
    final isSplit = encoderPath != null && decoderPath != null;

    final String normalizedText;
    if (isSplit) {
      normalizedText = model.normalizeText(text);
    } else {
      normalizedText = convertFullWidthToHalfWidth(text);
    }

    final genConfig = sherpa_onnx.OfflineTtsGenerationConfig(
      sid: speakerId,
      speed: speed,
      silenceScale: 0.2,
    );

    final stopwatch = Stopwatch()..start();

    final audio = onProgress != null
        ? tts!.generateWithConfig(
            text: normalizedText,
            config: genConfig,
            onProgress: onProgress,
          )
        : tts!.generateWithConfig(
            text: normalizedText,
            config: genConfig,
          );

    final filename = await generateWavFilename(prefix, suffix);

    final file = File(filename);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    final ok = sherpa_onnx.writeWave(
      filename: filename,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );

    if (!ok) {
      throw Exception('Failed to write WAV file: $filename');
    }

    stopwatch.stop();
    final elapsed = stopwatch.elapsed.inMilliseconds / 1000.0;
    final audioDuration = audio.samples.length / audio.sampleRate;

    return TtsSynthesisResult(
      wavPath: filename,
      elapsedSec: elapsed,
      audioDurationSec: audioDuration,
      rtf: elapsed / audioDuration,
    );
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  /// Converts full-width CJK punctuation to ASCII half-width equivalents.
  ///
  /// Used for VITS (non-split) models that do not have an online text
  /// normaliser.
  static String convertFullWidthToHalfWidth(String text) {
    var result = text;
    const fullToHalf = {
      '，': ',',
      '。': '.',
      '！': '!',
      '？': '?',
      '：': ':',
      '；': ';',
      '（': '(',
      '）': ')',
      '【': '[',
      '】': ']',
      '《': '<',
      '》': '>',
      '\u201c': '"', // "
      '\u201d': '"', // "
      '\u2018': "'", // '
      '\u2019': "'", // '
      '、': ',',
      '—': '-',
      '～': '~',
      '\u3000': ' ', // ideographic space
    };
    fullToHalf.forEach((full, half) {
      result = result.replaceAll(full, half);
    });
    return result;
  }

  /// Generates a temporary WAV file path.
  ///
  /// Example: `tts-1721012345678-sid-0-speed-1.0.wav`
  static Future<String> generateWavFilename(
      String prefix, String suffix) async {
    final dir = await getTemporaryDirectory();
    final name = '$prefix-${DateTime.now().millisecondsSinceEpoch}$suffix.wav';
    return p.join(dir.path, name);
  }
}
