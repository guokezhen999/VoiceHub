import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'llamacpp_ffi_bridge.dart';
import 'model_manager.dart';
import 'nmt_service_common.dart';

// FFI callback type for streaming token callbacks from C++.
typedef _WorkerTokenCallback = Void Function(Pointer<Utf8>, Pointer<Void>);

/// NMT service backed by llama.cpp + Metal GPU via FFI.
///
/// Translation runs in a dedicated **background isolate** so that the
/// synchronous llama_decode loop never blocks the Flutter UI thread.
///
/// Usage:
///   await LlamaNmtService.init();                  // once at startup
///   final svc = LlamaNmtService();
///   await svc.loadModel(modelInfo);
///   final result = await svc.translate("你好世界");
///   await svc.release();
class LlamaNmtService {
  // ---- Background-isolate communication ----------------------------------
  Isolate? _worker;
  SendPort? _workerSendPort;
  ReceivePort? _workerReceivePort;
  Completer<void>? _readyCompleter;

  ModelInfo? _currentModel;

  bool get isLoaded => _worker != null;
  ModelInfo? get currentModel => _currentModel;

  /// Initialize the native FFI bindings. Call once at app startup.
  static Future<void> init({String? libPath}) async {
    await LlamaCppBridge.init(libPath: libPath);
  }

  /// Load a GGUF model from [modelInfo] in a background isolate.
  /// [sourceLang] and [targetLang] are the UI-selected languages used for prompts.
  Future<void> loadModel(
    ModelInfo modelInfo, {
    String sourceLang = 'Chinese',
    String targetLang = 'English',
    int nCtx = 2048,
    int maxLength = 512,
    int numThreads = 4,
    int nGpuLayers = -1,
  }) async {
    if (_currentModel?.path == modelInfo.path && _worker != null) {
      return; // Already loaded.
    }
    await release();

    final modelPath = modelInfo.llmModelPath ?? modelInfo.path;
    _readyCompleter = Completer<void>();
    _workerReceivePort = ReceivePort();

    _worker = await Isolate.spawn(
      _workerEntry,
      NmtWorkerInit(
        sendPort: _workerReceivePort!.sendPort,
        modelPath: modelPath,
        maxLength: maxLength,
        numThreads: numThreads,
        nGpuLayers: nGpuLayers,
        sourceLang: sourceLang,
        targetLang: targetLang,
      ),
    );

    // Wait for the worker to signal it is ready.
    final completer = Completer<void>();
    _workerReceivePort!.listen((message) {
      if (completer.isCompleted) return;

      if (message == kNmtReady) {
        return;
      }

      if (message is SendPort) {
        _workerSendPort = message;
        _currentModel = modelInfo;
        _readyCompleter?.complete();
        _readyCompleter = null;
        completer.complete();
        return;
      }

      if (message is NmtWorkerError) {
        _readyCompleter?.completeError(Exception(message.error));
        _readyCompleter = null;
        completer.completeError(Exception(message.error));
        return;
      }
    });

    await completer.future;
  }

  /// Translate [text] in the background isolate.
  Future<TranslationResult> translate(String text) async {
    if (_workerSendPort == null) {
      throw Exception('Llama NMT model not loaded. Call loadModel() first.');
    }

    final replyPort = ReceivePort();
    _workerSendPort!.send(NmtTranslateRequest(
      text: text,
      replyPort: replyPort.sendPort,
    ));

    final result = await replyPort.first;
    if (result is NmtWorkerError) {
      throw Exception(result.error);
    }
    if (result is Map) {
      return TranslationResult(
        text: (result['text'] ?? '').toString(),
        inputTokens: (result['input_tokens'] ?? 0) as int,
        encoderMs: (result['encoder_ms'] ?? 0).toDouble(),
        decoderMs: (result['decoder_ms'] ?? 0).toDouble(),
        decoderTokens: (result['decoder_tokens'] ?? 0) as int,
      );
    }
    throw Exception('Unexpected response from Llama worker: $result');
  }

  /// Translate [text] with per-token streaming.
  Stream<String> translateStream(String text) {
    if (_workerSendPort == null) {
      throw Exception('Llama NMT model not loaded. Call loadModel() first.');
    }

    final replyPort = ReceivePort();
    late StreamController<String> controller;

    controller = StreamController<String>(
      onListen: () {
        _workerSendPort!.send(NmtTranslateStreamRequest(
          text: text,
          replyPort: replyPort.sendPort,
        ));

        replyPort.listen((message) {
          if (message is NmtWorkerError) {
            controller.addError(Exception(message.error));
            replyPort.close();
          } else if (message is NmtStreamToken) {
            controller.add(message.text);
          } else if (message is Map) {
            _lastStreamResult = TranslationResult(
              text: (message['text'] ?? '').toString(),
              inputTokens: (message['input_tokens'] ?? 0) as int,
              encoderMs: (message['encoder_ms'] ?? 0).toDouble(),
              decoderMs: (message['decoder_ms'] ?? 0).toDouble(),
              decoderTokens: (message['decoder_tokens'] ?? 0) as int,
            );
            controller.close();
            replyPort.close();
          }
        });
      },
    );

    return controller.stream;
  }

  /// The timing result from the most recent [translateStream] call.
  TranslationResult? _lastStreamResult;
  TranslationResult? get lastStreamTiming => _lastStreamResult;

  /// Release the loaded model and terminate the background isolate.
  Future<void> release() async {
    if (_workerSendPort != null) {
      try {
        _workerSendPort!.send(kNmtShutdown);
      } catch (_) {}
      _workerSendPort = null;
    }
    _workerReceivePort?.close();
    _workerReceivePort = null;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _currentModel = null;
    _readyCompleter = null;
  }

}

// ===========================================================================
// Background-isolate worker
// ===========================================================================

/// Entry-point for the background isolate.
void _workerEntry(NmtWorkerInit init) {
  try {
    _workerEntryInternal(init);
  } catch (e, st) {
    init.sendPort.send(NmtWorkerError('Llama worker isolate init failed: $e\n$st'));
  }
}

void _workerEntryInternal(NmtWorkerInit init) {
  // Open the native library in this isolate.
  final lib = DynamicLibrary.open('libllamacpp_nmt.dylib');

  // Look up C functions.
  final createTranslator = lib
      .lookup<NativeFunction<Pointer<Void> Function(
          Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32, Int32)>>(
          'llamacpp_create_translator')
      .asFunction<Pointer<Void> Function(
          Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, int, int, int)>();

  final translate = lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>>(
          'llamacpp_translate')
      .asFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>();

  final translateStreaming = lib
      .lookup<NativeFunction<Pointer<Utf8> Function(
          Pointer<Void>, Pointer<Utf8>,
          Pointer<NativeFunction<_WorkerTokenCallback>>, Pointer<Void>)>>(
          'llamacpp_translate_streaming')
      .asFunction<Pointer<Utf8> Function(
          Pointer<Void>, Pointer<Utf8>,
          Pointer<NativeFunction<_WorkerTokenCallback>>, Pointer<Void>)>();

  final destroyTranslator = lib
      .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
          'llamacpp_destroy_translator')
      .asFunction<void Function(Pointer<Void>)>();

  final freeString = lib
      .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>(
          'llamacpp_free_string')
      .asFunction<void Function(Pointer<Utf8>)>();

  final lastError = lib
      .lookup<NativeFunction<Pointer<Utf8> Function()>>(
          'llamacpp_last_error')
      .asFunction<Pointer<Utf8> Function()>();

  final isReady = lib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'llamacpp_is_ready')
      .asFunction<int Function(Pointer<Void>)>();

  // Create the translator handle.
  final mp = init.modelPath.toNativeUtf8();
  final sl = (init.sourceLang ?? 'Chinese').toNativeUtf8();
  final tl = (init.targetLang ?? 'English').toNativeUtf8();
  final handle = createTranslator(
      mp, sl, tl, 2048, init.numThreads, init.nGpuLayers, init.maxLength);
  calloc.free(mp);
  calloc.free(sl);
  calloc.free(tl);

  if (handle == nullptr || isReady(handle) == 0) {
    final errPtr = lastError();
    final err = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
    init.sendPort.send(NmtWorkerError('Failed to create Llama translator: $err'));
    return;
  }

  // Tell the main isolate we are ready.
  final requestPort = ReceivePort();
  init.sendPort.send(kNmtReady);
  init.sendPort.send(requestPort.sendPort);

  // Process translation requests.
  requestPort.listen((message) {
    if (message == kNmtShutdown) {
      destroyTranslator(handle);
      requestPort.close();
      return;
    }

    if (message is NmtTranslateRequest) {
      try {
        final textPtr = message.text.toNativeUtf8();
        final resultPtr = translate(handle, textPtr);
        calloc.free(textPtr);

        if (resultPtr == nullptr) {
          final errPtr = lastError();
          final err = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
          message.replyPort.send(NmtWorkerError(err));
        } else {
          final resultStr = resultPtr.toDartString();
          freeString(resultPtr);
          try {
            final jsonMap = jsonDecode(resultStr) as Map<String, dynamic>;
            message.replyPort.send(jsonMap);
          } catch (_) {
            message.replyPort.send(<String, dynamic>{
              'text': resultStr,
              'encoder_ms': -1.0,
              'decoder_ms': -1.0,
              'decoder_tokens': -1,
            });
          }
        }
      } catch (e) {
        message.replyPort.send(NmtWorkerError(e.toString()));
      }
    }

    if (message is NmtTranslateStreamRequest) {
      try {
        final callback = NativeCallable<_WorkerTokenCallback>.isolateLocal(
          (Pointer<Utf8> tokenPtr, Pointer<Void> _) {
            final partialText = tokenPtr.toDartString();
            message.replyPort.send(NmtStreamToken(partialText));
          },
        );

        final textPtr = message.text.toNativeUtf8();
        final resultPtr = translateStreaming(
            handle, textPtr, callback.nativeFunction, nullptr);
        calloc.free(textPtr);

        if (resultPtr == nullptr) {
          final errPtr = lastError();
          final err = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
          message.replyPort.send(NmtWorkerError(err));
        } else {
          final resultStr = resultPtr.toDartString();
          freeString(resultPtr);
          try {
            final jsonMap = jsonDecode(resultStr) as Map<String, dynamic>;
            message.replyPort.send(jsonMap);
          } catch (_) {
            message.replyPort.send(<String, dynamic>{
              'text': resultStr,
              'encoder_ms': -1.0,
              'decoder_ms': -1.0,
              'decoder_tokens': -1,
            });
          }
        }

        callback.close();
      } catch (e) {
        message.replyPort.send(NmtWorkerError(e.toString()));
      }
    }
  });
}
