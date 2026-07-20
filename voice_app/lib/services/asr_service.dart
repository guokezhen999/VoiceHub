import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/utils/utils.dart';
import 'package:voice_app/ffi/voice_engine_ffi_bridge.dart';
import 'package:voice_app/services/vad_settings.dart';

/// Shared ASR helper methods and engine lifecycle management.
///
/// The native voice_engine lives in a dedicated **background isolate**
/// (same pattern as [SimulstService]) so model load / decode never blocks
/// the Flutter UI thread.
class AsrService {
  static const List<String> leadingPuncs = [
    '，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';',
  ];

  /// Kept for API compatibility with older call sites that checked `handle != null`.
  /// Non-null when the worker isolate is ready (mock address, not a real FFI pointer).
  Pointer<Void>? handle;
  bool isInitialized = false;
  bool isOfflineModel = false;

  Isolate? _worker;
  SendPort? _workerSendPort;
  ReceivePort? _workerReceivePort;
  StreamSubscription<dynamic>? _workerSub;
  Future<void>? _releasing;

  static String stripLeadingPuncs(String text) {
    while (text.isNotEmpty && leadingPuncs.contains(text[0])) {
      text = text.substring(1);
    }
    return text;
  }

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

  /// Initialises the ASR engine for [model] in a background isolate.
  Future<void> initialize(ModelInfo model) async {
    if (isInitialized) return;

    // Ensure native lib is loadable on this isolate (worker will init again).
    await VoiceEngineBridge.init();

    final sileroModelPath = await ModelManager.ensureSileroVad();
    isOfflineModel = !model.isStreamingASR;

    final provider = (Platform.isMacOS || Platform.isIOS) ? 'coreml' : 'cpu';

    final config = {
      'mode': isOfflineModel ? 'offline' : 'online',
      'encoder': model.asrEncoderPath!,
      'decoder': model.asrDecoderPath!,
      'joiner': model.asrJoinerPath!,
      'tokens': model.tokensPath!,
      'model_type': 'zipformer2',
      'decoding_method': 'greedy_search',
      'num_threads': 1,
      'provider': provider,
      'debug': true,
      ...buildAudioPipelineConfig(sileroModelPath),
      'endpoint': {
        'enable': true,
        'rule1_min_trailing_silence': 2.4,
        'rule2_min_trailing_silence': 1.0,
      },
    };

    _workerReceivePort = ReceivePort();
    final completer = Completer<void>();

    _worker = await Isolate.spawn(
      _asrWorkerEntry,
      _AsrWorkerInit(
        sendPort: _workerReceivePort!.sendPort,
        jsonConfig: jsonEncode(config),
      ),
    );

    _workerSub = _workerReceivePort!.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        handle = Pointer<Void>.fromAddress(1); // mock ready marker
        isInitialized = true;
        if (!completer.isCompleted) completer.complete();
      } else if (message is _AsrWorkerError) {
        if (!completer.isCompleted) {
          completer.completeError(Exception(message.error));
        }
      }
    });

    try {
      await completer.future;
    } catch (e) {
      await deinitialize();
      rethrow;
    }
  }

  Future<void> deinitialize() async {
    if (_releasing != null) {
      await _releasing;
      return;
    }
    if (_worker == null) {
      isInitialized = false;
      handle = null;
      isOfflineModel = false;
      return;
    }

    _releasing = _doRelease();
    try {
      await _releasing;
    } finally {
      _releasing = null;
      isInitialized = false;
      handle = null;
      isOfflineModel = false;
    }
  }

  Future<void> _doRelease() async {
    if (_workerSendPort != null) {
      final replyPort = ReceivePort();
      try {
        _workerSendPort!.send(_AsrShutdownRequest(replyPort: replyPort.sendPort));
        await replyPort.first.timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        );
      } catch (_) {}
      replyPort.close();
      _workerSendPort = null;
    }

    await _workerSub?.cancel();
    _workerSub = null;
    _workerReceivePort?.close();
    _workerReceivePort = null;

    _worker?.kill(priority: Isolate.beforeNextEvent);
    _worker = null;
  }

  /// Resets the engine's internal buffers without tearing it down.
  Future<void> reset() async {
    if (_workerSendPort == null) return;
    final replyPort = ReceivePort();
    _workerSendPort!.send(_AsrResetRequest(replyPort: replyPort.sendPort));
    await replyPort.first;
    replyPort.close();
  }

  static const RecordConfig recordConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
  );

  static Map<String, dynamic> buildAudioPipelineConfig(String sileroModelPath) => {
        'vad': {
          'model': sileroModelPath,
          'threshold': VadSettings.generalMode.threshold,
          'min_silence_duration': VadSettings.generalMode.minSilenceDuration,
          'min_speech_duration': VadSettings.generalMode.minSpeechDuration,
          'window_size': 512,
          'max_speech_duration': 20.0,
          'sample_rate': 16000,
          'num_threads': 1,
          'buffer_size_seconds': 60.0,
        },
        'circular_buffer_capacity': 480000,
        'max_pre_speech_samples': 8000,
        'max_post_speech_samples': 8000,
      };

  /// Feed one PCM chunk and poll (used by offline file transcription).
  Future<VoiceEnginePollResult> acceptAndPoll(Float32List samples) async {
    if (_workerSendPort == null) {
      return const VoiceEnginePollResult(
        speaking: false,
        partial: '',
        finalized: [],
        segments: [],
      );
    }
    final replyPort = ReceivePort();
    _workerSendPort!.send(_AsrAudioChunkRequest(
      replyPort: replyPort.sendPort,
      samples: samples,
    ));
    final res = await replyPort.first;
    replyPort.close();
    if (res is VoiceEnginePollResult) return res;
    return const VoiceEnginePollResult(
      speaking: false,
      partial: '',
      finalized: [],
      segments: [],
    );
  }

  Future<StreamSubscription<Uint8List>> startStream(
    AudioRecorder recorder,
    void Function(VoiceEnginePollResult) onPoll, {
    void Function(Float32List samples)? onAudioSamples,
  }) async {
    final audioStream = await recorder.startStream(recordConfig);
    final replyPort = ReceivePort();

    final replySub = replyPort.listen((message) {
      if (message is VoiceEnginePollResult) {
        onPoll(message);
      }
    });

    final streamSub = audioStream.listen((data) {
      if (_workerSendPort == null) return;
      final samples = convertBytesToFloat32(Uint8List.fromList(data));
      onAudioSamples?.call(samples);
      _workerSendPort!.send(_AsrAudioChunkRequest(
        replyPort: replyPort.sendPort,
        samples: samples,
      ));
    });

    return _AsrStreamSubscription(streamSub, replyPort, replySub);
  }

  /// Flushes the VAD tail and returns the final poll result.
  Future<VoiceEnginePollResult> flushAndPoll() async {
    if (_workerSendPort == null) {
      return const VoiceEnginePollResult(
        speaking: false,
        partial: '',
        finalized: [],
        segments: [],
      );
    }
    final replyPort = ReceivePort();
    _workerSendPort!.send(_AsrFlushRequest(replyPort: replyPort.sendPort));
    final res = await replyPort.first;
    replyPort.close();
    if (res is VoiceEnginePollResult) return res;
    return const VoiceEnginePollResult(
      speaking: false,
      partial: '',
      finalized: [],
      segments: [],
    );
  }
}

// ===========================================================================
// Background-isolate worker
// ===========================================================================

class _AsrStreamSubscription implements StreamSubscription<Uint8List> {
  final StreamSubscription<Uint8List> _audioSub;
  final ReceivePort _replyPort;
  final StreamSubscription<dynamic> _replySub;

  _AsrStreamSubscription(this._audioSub, this._replyPort, this._replySub);

  @override
  Future<void> cancel() async {
    await _audioSub.cancel();
    await _replySub.cancel();
    _replyPort.close();
  }

  @override
  void onData(void Function(Uint8List data)? handleData) => _audioSub.onData(handleData);

  @override
  void onError(Function? handleError) => _audioSub.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _audioSub.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _audioSub.pause(resumeSignal);

  @override
  void resume() => _audioSub.resume();

  @override
  bool get isPaused => _audioSub.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _audioSub.asFuture(futureValue);
}

class _AsrWorkerInit {
  final SendPort sendPort;
  final String jsonConfig;
  _AsrWorkerInit({required this.sendPort, required this.jsonConfig});
}

class _AsrWorkerError {
  final String error;
  _AsrWorkerError(this.error);
}

class _AsrAudioChunkRequest {
  final SendPort replyPort;
  final Float32List samples;
  _AsrAudioChunkRequest({required this.replyPort, required this.samples});
}

class _AsrResetRequest {
  final SendPort replyPort;
  _AsrResetRequest({required this.replyPort});
}

class _AsrFlushRequest {
  final SendPort replyPort;
  _AsrFlushRequest({required this.replyPort});
}

class _AsrShutdownRequest {
  final SendPort replyPort;
  _AsrShutdownRequest({required this.replyPort});
}

void _asrWorkerEntry(_AsrWorkerInit init) {
  try {
    _asrWorkerEntryInternal(init);
  } catch (e, st) {
    init.sendPort.send(_AsrWorkerError('ASR worker isolate init failed: $e\n$st'));
  }
}

void _asrWorkerEntryInternal(_AsrWorkerInit init) async {
  await VoiceEngineBridge.init();

  Pointer<Void>? handle;
  final requestPort = ReceivePort();

  try {
    handle = VoiceEngineBridge.instance.create(init.jsonConfig);
  } catch (e) {
    init.sendPort.send(_AsrWorkerError('Failed to create ASR engine: $e'));
    requestPort.close();
    return;
  }

  init.sendPort.send(requestPort.sendPort);

  await for (final message in requestPort) {
    if (message is _AsrShutdownRequest) {
      if (handle != nullptr) {
        VoiceEngineBridge.instance.destroy(handle);
      }
      message.replyPort.send(true);
      requestPort.close();
      break;
    }

    if (message is _AsrResetRequest) {
      if (handle != nullptr) {
        VoiceEngineBridge.instance.reset(handle);
      }
      message.replyPort.send(true);
      continue;
    }

    if (message is _AsrAudioChunkRequest) {
      if (handle == nullptr) {
        message.replyPort.send(const VoiceEnginePollResult(
          speaking: false,
          partial: '',
          finalized: [],
          segments: [],
        ));
        continue;
      }
      try {
        VoiceEngineBridge.instance.acceptWaveform(handle, message.samples);
        final pollRes = VoiceEngineBridge.instance.poll(handle);
        message.replyPort.send(pollRes);
      } catch (_) {
        message.replyPort.send(const VoiceEnginePollResult(
          speaking: false,
          partial: '',
          finalized: [],
          segments: [],
        ));
      }
      continue;
    }

    if (message is _AsrFlushRequest) {
      if (handle == nullptr) {
        message.replyPort.send(const VoiceEnginePollResult(
          speaking: false,
          partial: '',
          finalized: [],
          segments: [],
        ));
        continue;
      }
      try {
        VoiceEngineBridge.instance.flush(handle);
        final pollRes = VoiceEngineBridge.instance.poll(handle);
        message.replyPort.send(pollRes);
      } catch (_) {
        message.replyPort.send(const VoiceEnginePollResult(
          speaking: false,
          partial: '',
          finalized: [],
          segments: [],
        ));
      }
      continue;
    }
  }
}
