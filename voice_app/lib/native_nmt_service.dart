import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'opus_mt_ffi_bridge.dart';
import 'model_manager.dart';
import 'nmt_service_common.dart';

/// NMT service backed by the native opus-mt C++ library via FFI.
///
/// Translation runs in a dedicated **background isolate** so that the
/// encoder-decoder inference loop (which is synchronous C++ code) never
/// blocks the Flutter UI thread.
///
/// Usage:
///   await NativeNmtService.init();                  // once at startup
///   final svc = NativeNmtService();
///   await svc.loadModel(modelInfo);
///   final result = await svc.translate("你好世界");
///   await svc.release();
class NativeNmtService {
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
    await OpusMtBridge.init(libPath: libPath);
  }

  /// Load a opus-mt model from [modelInfo] in a background isolate.
  Future<void> loadModel(
    ModelInfo modelInfo, {
    int numBeams = 1,
    int maxLength = 512,
    int numThreads = 4,
  }) async {
    if (_currentModel?.path == modelInfo.path && _worker != null) {
      return; // Already loaded.
    }
    await release();

    _readyCompleter = Completer<void>();
    _workerReceivePort = ReceivePort();

    _worker = await Isolate.spawn(
      _workerEntry,
      _WorkerInit(
        sendPort: _workerReceivePort!.sendPort,
        modelDir: modelInfo.path,
        numBeams: numBeams,
        maxLength: maxLength,
        numThreads: numThreads,
      ),
    );

    // Wait for the worker to signal it is ready, or forward any error.
    final completer = Completer<void>();
    _workerReceivePort!.listen((message) {
      if (completer.isCompleted) return;

      // The first message is the _kReady signal (1); ignore it.
      if (message == _kReady) {
        return;
      }

      // The second message is the worker's request SendPort.
      if (message is SendPort) {
        _workerSendPort = message;
        _currentModel = modelInfo;
        _readyCompleter?.complete();
        _readyCompleter = null;
        completer.complete();
        return;
      }

      if (message is _WorkerError) {
        _readyCompleter?.completeError(Exception(message.error));
        _readyCompleter = null;
        completer.completeError(Exception(message.error));
        return;
      }
    });

    await completer.future;
  }

  /// Translate [text] in the background isolate.
  Future<TranslationResult> translate(String text, {String? targetLangToken}) async {
    if (_workerSendPort == null) {
      throw Exception('Native NMT model not loaded. Call loadModel() first.');
    }

    final sourceText = (targetLangToken != null && targetLangToken.isNotEmpty)
        ? '$targetLangToken $text'
        : text;

    final replyPort = ReceivePort();
    _workerSendPort!.send(_TranslateRequest(
      text: sourceText,
      replyPort: replyPort.sendPort,
    ));

    final result = await replyPort.first;
    if (result is _WorkerError) {
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
    throw Exception('Unexpected response from NMT worker: $result');
  }

  /// Release the loaded model and terminate the background isolate.
  Future<void> release() async {
    if (_workerSendPort != null) {
      try {
        _workerSendPort!.send(_kShutdown);
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

  /// Translate [text] with per-token streaming.
  ///
  /// Returns a [Stream] that yields cumulative partial translation text
  /// after each decoder token. When the stream is done, call
  /// [lastStreamTiming] to get the performance metrics.
  Stream<String> translateStream(String text) {
    if (_workerSendPort == null) {
      throw Exception('Native NMT model not loaded. Call loadModel() first.');
    }

    final replyPort = ReceivePort();
    late StreamController<String> controller;

    controller = StreamController<String>(
      onListen: () {
        _workerSendPort!.send(_TranslateStreamRequest(
          text: text,
          replyPort: replyPort.sendPort,
        ));

        replyPort.listen((message) {
          if (message is _WorkerError) {
            controller.addError(Exception(message.error));
            replyPort.close();
          } else if (message is _StreamToken) {
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

}

/// TranslationResult is now defined in nmt_service_common.dart (shared with LlamaNmtService).

// ---- Background-isolate protocol ------------------------------------------

/// Sentinel sent by the worker to signal it has finished loading.
const _kReady = 1;

/// Sentinel sent to the worker to request shutdown.
const _kShutdown = 2;

/// Initialisation message sent to the worker isolate.
class _WorkerInit {
  final SendPort sendPort;
  final String modelDir;
  final int numBeams;
  final int maxLength;
  final int numThreads;
  const _WorkerInit({
    required this.sendPort,
    required this.modelDir,
    required this.numBeams,
    required this.maxLength,
    required this.numThreads,
  });
}

/// Request the worker to translate [text], reply on [replyPort].
class _TranslateRequest {
  final String text;
  final SendPort replyPort;
  const _TranslateRequest({required this.text, required this.replyPort});
}

/// Error response from the worker.
class _WorkerError {
  final String error;
  const _WorkerError(this.error);
}

/// A streaming partial translation token sent from the worker to the main isolate.
class _StreamToken {
  final String text;
  const _StreamToken(this.text);
}

/// Request the worker to translate [text] with streaming, reply on [replyPort].
class _TranslateStreamRequest {
  final String text;
  final SendPort replyPort;
  const _TranslateStreamRequest({required this.text, required this.replyPort});
}

/// Entry-point for the background isolate.
///
/// This top-level function is spawned via [Isolate.spawn].  It opens the
/// shared library, creates a translator handle, then listens for translation
/// requests on the receive port.

// FFI callback type for streaming token callbacks from C++.
typedef _WorkerTokenCallback = Void Function(Pointer<Utf8>, Pointer<Void>);

void _workerEntry(_WorkerInit init) {
  try {
    _workerEntryInternal(init);
  } catch (e, st) {
    // Any exception during init (e.g. dylib not found, symbol lookup failure,
    // native crash) would otherwise kill the isolate silently, leaving the
    // main isolate blocked forever on completer.future.
    init.sendPort.send(_WorkerError('Worker isolate init failed: $e\n$st'));
  }
}

void _workerEntryInternal(_WorkerInit init) {
  // Open the native library in this isolate.
  // DynamicLibrary.open is reference-counted on macOS so this is cheap.
  final lib = DynamicLibrary.open('libopus_mt.dylib');

  // Look up C functions.
  final createTranslator = lib
      .lookup<NativeFunction<Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Int32)>>(
          'opus_mt_create_translator')
      .asFunction<Pointer<Void> Function(Pointer<Utf8>, int, int, int)>();

  final translate = lib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>>(
          'opus_mt_translate')
      .asFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>();

  final destroyTranslator = lib
      .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
          'opus_mt_destroy_translator')
      .asFunction<void Function(Pointer<Void>)>();

  final freeString = lib
      .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>(
          'opus_mt_free_string')
      .asFunction<void Function(Pointer<Utf8>)>();

  final lastError = lib
      .lookup<NativeFunction<Pointer<Utf8> Function()>>(
          'opus_mt_last_error')
      .asFunction<Pointer<Utf8> Function()>();

  final isReady = lib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'opus_mt_is_ready')
      .asFunction<int Function(Pointer<Void>)>();

  // Look up the streaming translate function.
  final translateStreaming = lib
      .lookup<NativeFunction<Pointer<Utf8> Function(
          Pointer<Void>, Pointer<Utf8>,
          Pointer<NativeFunction<_WorkerTokenCallback>>, Pointer<Void>)>>(
          'opus_mt_translate_streaming')
      .asFunction<Pointer<Utf8> Function(
          Pointer<Void>, Pointer<Utf8>,
          Pointer<NativeFunction<_WorkerTokenCallback>>, Pointer<Void>)>();

  // Create the translator handle.
  final dirPtr = init.modelDir.toNativeUtf8();
  final handle =
      createTranslator(dirPtr, init.numBeams, init.maxLength, init.numThreads);
  calloc.free(dirPtr);

  if (handle == nullptr || isReady(handle) == 0) {
    final errPtr = lastError();
    final err = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
    init.sendPort.send(_WorkerError('Failed to create translator: $err'));
    return;
  }

  // Tell the main isolate we are ready and give it our request port.
  final requestPort = ReceivePort();
  init.sendPort.send(_kReady);
  init.sendPort.send(requestPort.sendPort);

  // Process translation requests.
  requestPort.listen((message) {
    if (message == _kShutdown) {
      destroyTranslator(handle);
      requestPort.close();
      return;
    }

    if (message is _TranslateRequest) {
      try {
        final textPtr = message.text.toNativeUtf8();
        final resultPtr = translate(handle, textPtr);
        calloc.free(textPtr);

        if (resultPtr == nullptr) {
          final errPtr = lastError();
          final err = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
          message.replyPort.send(_WorkerError(err));
        } else {
          final resultStr = resultPtr.toDartString();
          freeString(resultPtr);
          try {
            final jsonMap = jsonDecode(resultStr) as Map<String, dynamic>;
            message.replyPort.send(jsonMap);
          } catch (_) {
            // Fallback: plain text result (backward compat with old dylib).
            message.replyPort.send(<String, dynamic>{
              'text': resultStr,
              'encoder_ms': -1.0,
              'decoder_ms': -1.0,
              'decoder_tokens': -1,
            });
          }
        }
      } catch (e) {
        message.replyPort.send(_WorkerError(e.toString()));
      }
    }

    if (message is _TranslateStreamRequest) {
      try {
        // Create a NativeCallable that C++ will invoke for each token.
        final callback = NativeCallable<_WorkerTokenCallback>.isolateLocal(
          (Pointer<Utf8> tokenPtr, Pointer<Void> _) {
            final partialText = tokenPtr.toDartString();
            message.replyPort.send(_StreamToken(partialText));
          },
        );

        final textPtr = message.text.toNativeUtf8();
        final resultPtr = translateStreaming(
            handle, textPtr, callback.nativeFunction, nullptr);
        calloc.free(textPtr);

        if (resultPtr == nullptr) {
          final errPtr = lastError();
          final err = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
          message.replyPort.send(_WorkerError(err));
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
        message.replyPort.send(_WorkerError(e.toString()));
      }
    }
  });
}
