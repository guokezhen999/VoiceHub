import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:voice_app/ffi/simulst_ffi_bridge.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/services/asr_service.dart';
import 'package:voice_app/utils/utils.dart';
import 'package:voice_app/services/vad_settings.dart';

/// Streaming simultaneous interpretation via the simulst native pipeline.
/// Runs in a dedicated background isolate to avoid blocking the Flutter UI thread.
class SimulstService {
  Pointer<Void>? handle;
  bool isInitialized = false;

  bool enableTranscribe = true;
  bool enableTranslate = true;
  String transcribeLang = 'auto';
  String translateLang = 'English';
  int numChunks = 1;
  double repetitionPenalty = 1.0;
  double vadThreshold = 0.5;
  double vadMinSilenceDuration = 0.5; // Default changed to 0.5 for simulst mode
  double vadMinSpeechDuration = 0.3;

  static const RecordConfig recordConfig = AsrService.recordConfig;

  Isolate? _worker;
  SendPort? _workerSendPort;
  ReceivePort? _workerReceivePort;
  StreamSubscription<dynamic>? _workerSub;
  Future<void>? _releasing;

  Future<void> initialize({
    required ModelInfo model,
    bool? enableTranscribe,
    bool? enableTranslate,
    String? transcribeLang,
    String? translateLang,
    int? numChunks,
    double? repetitionPenalty,
    double? vadThreshold,
    double? vadMinSilenceDuration,
    double? vadMinSpeechDuration,
  }) async {
    if (isInitialized) return;

    if (enableTranscribe != null) this.enableTranscribe = enableTranscribe;
    if (enableTranslate != null) this.enableTranslate = enableTranslate;
    if (transcribeLang != null) this.transcribeLang = transcribeLang;
    if (translateLang != null) this.translateLang = translateLang;
    if (numChunks != null) this.numChunks = numChunks;
    if (repetitionPenalty != null) this.repetitionPenalty = repetitionPenalty;
    if (vadThreshold != null) this.vadThreshold = vadThreshold;
    if (vadMinSilenceDuration != null) this.vadMinSilenceDuration = vadMinSilenceDuration;
    if (vadMinSpeechDuration != null) this.vadMinSpeechDuration = vadMinSpeechDuration;

    final sileroModelPath = await ModelManager.ensureSileroVad();
    final useGpu = Platform.isMacOS || Platform.isIOS;

    final config = {
      'export_dir': model.path,
      'enable_transcribe': this.enableTranscribe,
      'enable_translate': this.enableTranslate,
      'transcribe_lang': this.transcribeLang,
      'translate_lang': this.translateLang,
      'clear_kv_on_sentence_punct': true,
      'keep_kv_across_segments': false,
      'num_chunks': this.numChunks,
      'max_llm_kv_segments_base': 64,
      'encoder_provider': useGpu ? 'coreml' : 'auto',
      'encoder_num_threads': 1,
      'n_ctx': 8192,
      'n_batch': 512,
      'n_threads': 4,
      'n_gpu_layers': useGpu ? -1 : 0,
      'max_new_tokens': 32,
      'repetition_penalty': this.repetitionPenalty,
      'first_token_eos_threshold': 1.0,
      'punct_kv_mode': 1,
      'eos_penalty_only_last_chunk': false,
      ...AsrService.buildAudioPipelineConfig(sileroModelPath),
    };

    // Override with custom VAD parameters
    final vadMap = config['vad'] as Map<String, dynamic>;
    vadMap['threshold'] = this.vadThreshold;
    vadMap['min_silence_duration'] = this.vadMinSilenceDuration;
    vadMap['min_speech_duration'] = this.vadMinSpeechDuration;

    _workerReceivePort = ReceivePort();
    final completer = Completer<void>();

    _worker = await Isolate.spawn(
      _workerEntry,
      _SimulstWorkerInit(
        sendPort: _workerReceivePort!.sendPort,
        jsonConfig: jsonEncode(config),
      ),
    );

    _workerSub = _workerReceivePort!.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        handle = Pointer<Void>.fromAddress(1); // Mock handle
        isInitialized = true;
        if (!completer.isCompleted) {
          completer.complete();
        }
      } else if (message is _SimulstWorkerError) {
        if (!completer.isCompleted) {
          completer.completeError(Exception(message.error));
        }
      }
    });

    await completer.future;
  }

  /// Update task toggles and languages without reloading models.
  Future<bool> updateTasks({
    bool? enableTranscribe,
    bool? enableTranslate,
    String? transcribeLang,
    String? translateLang,
  }) async {
    if (_workerSendPort == null) return false;

    if (enableTranscribe != null) this.enableTranscribe = enableTranscribe;
    if (enableTranslate != null) this.enableTranslate = enableTranslate;
    if (transcribeLang != null) this.transcribeLang = transcribeLang;
    if (translateLang != null) this.translateLang = translateLang;

    final replyPort = ReceivePort();
    _workerSendPort!.send(_SimulstUpdateTasksRequest(
      replyPort: replyPort.sendPort,
      enableTranscribe: this.enableTranscribe,
      enableTranslate: this.enableTranslate,
      transcribeLang: this.transcribeLang,
      translateLang: this.translateLang,
    ));

    final res = await replyPort.first;
    replyPort.close();

    if (res is _SimulstWorkerError) {
      throw Exception('simulst_set_tasks failed in isolate: ${res.error}');
    }
    return res == true;
  }

  /// Destroys the native engine handle and resets state.
  Future<void> deinitialize() async {
    if (_releasing != null) return _releasing!;
    if (_worker == null) {
      isInitialized = false;
      return;
    }

    _releasing = _doRelease();
    try {
      await _releasing;
    } finally {
      _releasing = null;
      isInitialized = false;
    }
  }

  Future<void> _doRelease() async {
    if (_workerSendPort != null) {
      final replyPort = ReceivePort();
      try {
        _workerSendPort!.send(_SimulstShutdownRequest(replyPort: replyPort.sendPort));
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
    handle = null;
  }

  /// Resets the engine's internal buffers without tearing it down.
  Future<void> reset() async {
    if (_workerSendPort == null) return;
    final replyPort = ReceivePort();
    _workerSendPort!.send(_SimulstResetRequest(replyPort: replyPort.sendPort));
    await replyPort.first;
    replyPort.close();
  }

  Future<StreamSubscription<Uint8List>> startStream(
    AudioRecorder recorder,
    void Function(SimulstPollResult) onPoll,
  ) async {
    final audioStream = await recorder.startStream(recordConfig);
    final replyPort = ReceivePort();

    final replySub = replyPort.listen((message) {
      if (message is SimulstPollResult) {
        onPoll(message);
      }
    });

    final streamSub = audioStream.listen((data) {
      if (_workerSendPort == null) return;
      final samples = convertBytesToFloat32(Uint8List.fromList(data));
      _workerSendPort!.send(_SimulstAudioChunkRequest(
        replyPort: replyPort.sendPort,
        samples: samples,
      ));
    });

    return _SimulstStreamSubscription(streamSub, replyPort, replySub);
  }

  /// Flushes the VAD tail and returns the final poll result.
  Future<SimulstPollResult> flushAndPoll() async {
    if (_workerSendPort == null) return SimulstPollResult.empty;
    final replyPort = ReceivePort();
    _workerSendPort!.send(_SimulstFlushRequest(replyPort: replyPort.sendPort));
    final res = await replyPort.first;
    replyPort.close();
    if (res is SimulstPollResult) {
      return res;
    }
    return SimulstPollResult.empty;
  }
}

// ===========================================================================
// Background-isolate worker
// ===========================================================================

class _SimulstStreamSubscription implements StreamSubscription<Uint8List> {
  final StreamSubscription<Uint8List> _audioSub;
  final ReceivePort _replyPort;
  final StreamSubscription<dynamic> _replySub;

  _SimulstStreamSubscription(this._audioSub, this._replyPort, this._replySub);

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

class _SimulstWorkerInit {
  final SendPort sendPort;
  final String jsonConfig;
  _SimulstWorkerInit({required this.sendPort, required this.jsonConfig});
}

class _SimulstWorkerError {
  final String error;
  _SimulstWorkerError(this.error);
}

class _SimulstAudioChunkRequest {
  final SendPort replyPort;
  final Float32List samples;
  _SimulstAudioChunkRequest({required this.replyPort, required this.samples});
}

class _SimulstUpdateTasksRequest {
  final SendPort replyPort;
  final bool enableTranscribe;
  final bool enableTranslate;
  final String transcribeLang;
  final String translateLang;
  _SimulstUpdateTasksRequest({
    required this.replyPort,
    required this.enableTranscribe,
    required this.enableTranslate,
    required this.transcribeLang,
    required this.translateLang,
  });
}

class _SimulstResetRequest {
  final SendPort replyPort;
  _SimulstResetRequest({required this.replyPort});
}

class _SimulstFlushRequest {
  final SendPort replyPort;
  _SimulstFlushRequest({required this.replyPort});
}

class _SimulstShutdownRequest {
  final SendPort replyPort;
  _SimulstShutdownRequest({required this.replyPort});
}

void _workerEntry(_SimulstWorkerInit init) {
  try {
    _workerEntryInternal(init);
  } catch (e, st) {
    init.sendPort.send(_SimulstWorkerError('Simulst worker isolate init failed: $e\n$st'));
  }
}

void _workerEntryInternal(_SimulstWorkerInit init) async {
  await SimulstBridge.init();

  Pointer<Void>? handle;
  final requestPort = ReceivePort();

  try {
    handle = SimulstBridge.instance.create(init.jsonConfig);
  } catch (e) {
    init.sendPort.send(_SimulstWorkerError('Failed to create simulst engine: $e'));
    requestPort.close();
    return;
  }

  // Tell the main isolate we are ready.
  init.sendPort.send(requestPort.sendPort);

  await for (final message in requestPort) {
    if (message is _SimulstShutdownRequest) {
      if (handle != null && handle != nullptr) {
        SimulstBridge.instance.destroy(handle);
      }
      message.replyPort.send(true);
      requestPort.close();
      break;
    }

    if (message is _SimulstResetRequest) {
      if (handle != null && handle != nullptr) {
        SimulstBridge.instance.reset(handle);
      }
      message.replyPort.send(true);
      continue;
    }

    if (message is _SimulstUpdateTasksRequest) {
      if (handle == null || handle == nullptr) {
        message.replyPort.send(_SimulstWorkerError('Engine not initialized'));
        continue;
      }
      try {
        final tasks = {
          'enable_transcribe': message.enableTranscribe,
          'enable_translate': message.enableTranslate,
          'transcribe_lang': message.transcribeLang,
          'translate_lang': message.translateLang,
          'clear_kv_on_sentence_punct': true,
        };
        final ok = SimulstBridge.instance.setTasks(handle, jsonEncode(tasks));
        message.replyPort.send(ok);
      } catch (e) {
        message.replyPort.send(_SimulstWorkerError(e.toString()));
      }
      continue;
    }

    if (message is _SimulstAudioChunkRequest) {
      if (handle == null || handle == nullptr) {
        message.replyPort.send(SimulstPollResult.empty);
        continue;
      }
      try {
        SimulstBridge.instance.acceptWaveform(handle, message.samples);
        final pollRes = SimulstBridge.instance.poll(handle);
        message.replyPort.send(pollRes);
      } catch (_) {
        message.replyPort.send(SimulstPollResult.empty);
      }
      continue;
    }

    if (message is _SimulstFlushRequest) {
      if (handle == null || handle == nullptr) {
        message.replyPort.send(SimulstPollResult.empty);
        continue;
      }
      try {
        SimulstBridge.instance.flush(handle);
        final pollRes = SimulstBridge.instance.poll(handle);
        message.replyPort.send(pollRes);
      } catch (_) {
        message.replyPort.send(SimulstPollResult.empty);
      }
      continue;
    }
  }
}
