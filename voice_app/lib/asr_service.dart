import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'model_manager.dart';
import 'utils.dart';
import 'voice_engine_ffi_bridge.dart';

/// Shared ASR helper methods and engine lifecycle management.
///
/// Extracted from [AsrScreen] and [CascadeTranslationScreen] to avoid
/// duplication of:
///   - leading-punctuation stripping
///   - text casing formatting
///   - engine config construction & initialisation
///   - audio stream setup / teardown
class AsrService {
  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  static const List<String> leadingPuncs = [
    '，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';',
  ];

  // ---------------------------------------------------------------------------
  // Engine state (readable by callers)
  // ---------------------------------------------------------------------------

  Pointer<Void>? handle;
  bool isInitialized = false;
  bool isOfflineModel = false;

  // ---------------------------------------------------------------------------
  // Static text-processing utilities
  // ---------------------------------------------------------------------------

  /// Strips any leading punctuation characters from [text].
  static String stripLeadingPuncs(String text) {
    while (text.isNotEmpty && leadingPuncs.contains(text[0])) {
      text = text.substring(1);
    }
    return text;
  }

  /// Applies sentence-start capitalisation when the model uses lowercase output.
  ///
  /// When [casing] is `'mixed'` the text is returned unchanged.
  /// Otherwise the first letter of every sentence (after `.`, `?`, or `!`) is
  /// capitalised.  Uses the more-complete logic from
  /// [CascadeTranslationScreen].
  static String formatTextWithCasing(String text, String casing) {
    if (casing == 'mixed') return text;

    final lowercaseText = text.toLowerCase();
    final result = StringBuffer();
    bool capitalizeNext = true;

    for (int i = 0; i < lowercaseText.length; i++) {
      final char = lowercaseText[i];
      if (capitalizeNext && RegExp(r'[a-zA-Z]').hasMatch(char)) {
        result.write(char.toUpperCase());
        capitalizeNext = false;
      } else {
        result.write(char);
      }
      if (char == '.' || char == '?' || char == '!') {
        capitalizeNext = true;
      }
    }
    return result.toString();
  }

  // ---------------------------------------------------------------------------
  // Engine lifecycle
  // ---------------------------------------------------------------------------

  /// Initialises the ASR engine for [model].
  ///
  /// Calls [VoiceEngineBridge.init] and constructs the JSON config that is
  /// shared between [AsrScreen] and [CascadeTranslationScreen].
  ///
  /// Throws if the bridge fails to create a handle.
  Future<void> initialize(ModelInfo model) async {
    if (isInitialized) return;

    await VoiceEngineBridge.init();

    final sileroModelPath = await ModelManager.ensureSileroVad();
    isOfflineModel = !model.isStreamingASR;

    final config = {
      'mode': isOfflineModel ? 'offline' : 'online',
      'encoder': model.asrEncoderPath!,
      'decoder': model.asrDecoderPath!,
      'joiner': model.asrJoinerPath!,
      'tokens': model.tokensPath!,
      'model_type': 'zipformer2',
      'decoding_method': 'greedy_search',
      'num_threads': 1,
      'vad': {
        'model': sileroModelPath,
        'threshold': 0.5,
        'min_silence_duration': 0.5,
        'min_speech_duration': 0.25,
        'window_size': 512,
        'max_speech_duration': 20.0,
        'sample_rate': 16000,
        'num_threads': 1,
        'buffer_size_seconds': 60.0,
      },
      'endpoint': {
        'enable': true,
        'rule1_min_trailing_silence': 2.4,
        'rule2_min_trailing_silence': 1.0,
      },
    };

    handle = VoiceEngineBridge.instance.create(jsonEncode(config));
    isInitialized = true;
  }

  /// Destroys the native engine handle and resets state.
  void deinitialize() {
    if (handle != null) {
      VoiceEngineBridge.instance.destroy(handle!);
      handle = null;
    }
    isInitialized = false;
    isOfflineModel = false;
  }

  /// Resets the engine's internal buffers without tearing it down.
  void reset() {
    if (handle != null) {
      VoiceEngineBridge.instance.reset(handle!);
    }
  }

  // ---------------------------------------------------------------------------
  // Audio streaming
  // ---------------------------------------------------------------------------

  /// Standard 16 kHz mono PCM recording config shared by all ASR screens.
  static const RecordConfig recordConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
  );

  /// Starts an audio stream on [recorder], feeds each chunk into the engine,
  /// and calls [onPoll] with every poll result.
  ///
  /// Returns the [StreamSubscription] so the caller can cancel it later.
  Future<StreamSubscription<Uint8List>> startStream(
    AudioRecorder recorder,
    void Function(VoiceEnginePollResult) onPoll,
  ) async {
    final audioStream = await recorder.startStream(recordConfig);
    return audioStream.listen((data) {
      if (handle == null) return;
      final samples = convertBytesToFloat32(Uint8List.fromList(data));
      VoiceEngineBridge.instance.acceptWaveform(handle!, samples);
      final result = VoiceEngineBridge.instance.poll(handle!);
      onPoll(result);
    });
  }

  /// Flushes the VAD tail and returns the final poll result.
  ///
  /// Call this after stopping the recorder to drain any buffered audio.
  VoiceEnginePollResult flushAndPoll() {
    VoiceEngineBridge.instance.flush(handle!);
    return VoiceEngineBridge.instance.poll(handle!);
  }
}
