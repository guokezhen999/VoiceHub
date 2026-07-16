import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'package:voice_app/ffi/llamacpp_ffi_bridge.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/services/nmt_service_common.dart';

// FFI callback type for streaming token callbacks from C++.
typedef _WorkerTokenCallback = Void Function(Pointer<Utf8>, Pointer<Void>);

/// LLM chat service backed by llama.cpp + Metal GPU via FFI.
///
/// Runs in a dedicated background isolate so the synchronous llama_decode
/// loop never blocks the Flutter UI thread.
///
/// Supports multi-turn conversation with history management.
///
/// Usage:
///   await LlamaChatService.init();                  // once at startup
///   final svc = LlamaChatService();
///   await svc.loadModel(modelInfo);
///   svc.chatStream("Hello!").listen((partial) { ... });
///   await svc.release();
class LlamaChatService {
  static final List<LlamaChatService> _instances = [];

  static List<LlamaChatService> get activeInstances => List.unmodifiable(_instances);

  LlamaChatService() {
    _instances.add(this);
  }

  // ---- Background-isolate communication ----------------------------------
  Isolate? _worker;
  SendPort? _workerSendPort;
  ReceivePort? _workerReceivePort;
  Completer<void>? _readyCompleter;

  ModelInfo? _currentModel;

  // ---- Conversation history ----------------------------------------------
  final List<ChatMessage> _history = [];

  bool get isLoaded => _worker != null;
  ModelInfo? get currentModel => _currentModel;
  List<ChatMessage> get history => List.unmodifiable(_history);

  /// Initialize the native FFI bindings. Call once at app startup.
  static Future<void> init({String? libPath}) async {
    await LlamaCppBridge.init(libPath: libPath);
  }

  /// Load a GGUF model from [modelInfo] in a background isolate.
  ///
  /// [systemPrompt] is the custom system prompt for chat mode.
  Future<void> loadModel(
    ModelInfo modelInfo, {
    String systemPrompt = 'You are a helpful, respectful and honest AI assistant.',
    int nCtx = 2048,
    int maxTokens = 1024,
    int numThreads = 4,
    int nGpuLayers = -1,
    bool enableThinking = true,
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
      _ChatWorkerInit(
        sendPort: _workerReceivePort!.sendPort,
        modelPath: modelPath,
        systemPrompt: systemPrompt,
        maxTokens: maxTokens,
        numThreads: numThreads,
        nGpuLayers: nGpuLayers,
        enableThinking: enableThinking,
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
        _history.clear();
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

  /// Send a user message and get a streaming response.
  ///
  /// The conversation history (including this new message) is sent to the LLM.
  /// Returns a [Stream] of partial response text. When the stream completes,
  /// the final response is added to history.
  Stream<String> chatStream(String userMessage, {bool enableThinking = true}) {
    if (_workerSendPort == null) {
      throw Exception('LLM chat model not loaded. Call loadModel() first.');
    }

    // Add the user message to history for this request.
    final messages = List<ChatMessage>.from(_history)
      ..add(ChatMessage(role: 'user', content: userMessage));

    final replyPort = ReceivePort();
    late StreamController<String> controller;

    controller = StreamController<String>(
      onListen: () {
        _workerSendPort!.send(NmtToggleThinkingRequest(enableThinking: enableThinking));
        _workerSendPort!.send(NmtChatRequest(
          messages: messages,
          replyPort: replyPort.sendPort,
        ));

        replyPort.listen((message) {
          if (message is NmtWorkerError) {
            controller.addError(Exception(message.error));
            replyPort.close();
          } else if (message is NmtStreamToken) {
            controller.add(message.text);
          } else if (message is Map) {
            // Final result: add to history.
            final responseText = (message['text'] ?? '').toString();
            _history.add(ChatMessage(role: 'user', content: userMessage));
            _history.add(ChatMessage(role: 'assistant', content: responseText));
            if (_history.length > 10) {
              _history.removeRange(0, _history.length - 10);
            }
            _lastStreamResult = TranslationResult(
              text: responseText,
              inputTokens: (message['input_tokens'] ?? 0) as int,
              encoderMs: (message['encoder_ms'] ?? 0).toDouble(),
              decoderMs: (message['decoder_ms'] ?? 0).toDouble(),
              decoderTokens: (message['decoder_tokens'] ?? 0) as int,
            );
            controller.add(responseText);
            controller.close();
            replyPort.close();
          }
        });
      },
    );

    return controller.stream;
  }

  /// Clear the conversation history.
  void clearHistory() {
    _history.clear();
  }

  /// The timing result from the most recent [chatStream] call.
  TranslationResult? _lastStreamResult;
  TranslationResult? get lastStreamTiming => _lastStreamResult;

  /// Release the loaded model and terminate the background isolate.
  Future<void> release() async {
    _instances.remove(this);
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

  /// Clean up and release all active instances of LlamaChatService.
  static Future<void> releaseAll() async {
    final copy = List<LlamaChatService>.from(_instances);
    for (final svc in copy) {
      await svc.release();
    }
  }
}

// ===========================================================================
// Background-isolate worker
// ===========================================================================

/// Initialisation message sent to the worker isolate for chat mode.
class _ChatWorkerInit {
  final SendPort sendPort;
  final String modelPath;
  final String systemPrompt;
  final int maxTokens;
  final int numThreads;
  final int nGpuLayers;
  final bool enableThinking;
  const _ChatWorkerInit({
    required this.sendPort,
    required this.modelPath,
    required this.systemPrompt,
    this.maxTokens = 1024,
    this.numThreads = 4,
    this.nGpuLayers = -1,
    this.enableThinking = true,
  });
}

/// Entry-point for the background isolate.
void _workerEntry(_ChatWorkerInit init) {
  try {
    _workerEntryInternal(init);
  } catch (e, st) {
    init.sendPort.send(NmtWorkerError('LLM chat worker isolate init failed: $e\n$st'));
  }
}

void _workerEntryInternal(_ChatWorkerInit init) {
  // Open the native library in this isolate.
  // On iOS the static library is linked into the process image.
  final lib = Platform.isIOS
      ? DynamicLibrary.process()
      : DynamicLibrary.open('libllamacpp_nmt.dylib');

  // Look up C functions.
  final createTranslator = lib
      .lookup<NativeFunction<Pointer<Void> Function(
          Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
          Int32, Int32, Int32, Int32,
          Int32, Pointer<Utf8>)>>(
          'llamacpp_create_translator')
      .asFunction<Pointer<Void> Function(
          Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
          int, int, int, int,
          int, Pointer<Utf8>)>();

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

  final setEnableThinking = lib
      .lookup<NativeFunction<Void Function(Pointer<Void>, Int32)>>(
          'llamacpp_set_enable_thinking')
      .asFunction<void Function(Pointer<Void>, int)>();

  final lastError = lib
      .lookup<NativeFunction<Pointer<Utf8> Function()>>(
          'llamacpp_last_error')
      .asFunction<Pointer<Utf8> Function()>();

  final isReady = lib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'llamacpp_is_ready')
      .asFunction<int Function(Pointer<Void>)>();

  // Create the translator handle in chat mode.
  final mp = init.modelPath.toNativeUtf8();
  final sp = init.systemPrompt.toNativeUtf8();
  final emptyLang = ''.toNativeUtf8();
  final chatModeVal = init.enableThinking ? 1 : 2;
  final handle = createTranslator(
      mp, emptyLang, emptyLang, 2048, init.numThreads, init.nGpuLayers, init.maxTokens,
      chatModeVal, sp);
  calloc.free(mp);
  calloc.free(sp);
  calloc.free(emptyLang);

  if (handle == nullptr || isReady(handle) == 0) {
    final errPtr = lastError();
    final err = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
    init.sendPort.send(NmtWorkerError('Failed to create LLM chat translator: $err'));
    return;
  }

  // Tell the main isolate we are ready.
  final requestPort = ReceivePort();
  init.sendPort.send(kNmtReady);
  init.sendPort.send(requestPort.sendPort);

  // Process chat requests.
  requestPort.listen((message) {
    if (message == kNmtShutdown) {
      destroyTranslator(handle);
      requestPort.close();
      return;
    }

    if (message is NmtToggleThinkingRequest) {
      setEnableThinking(handle, message.enableThinking ? 1 : 0);
      return;
    }

    if (message is NmtChatRequest) {
      try {
        // Serialize messages to JSON for the C++ layer.
        final jsonList = message.messages.map((m) => m.toJson()).toList();
        final jsonStr = jsonEncode(jsonList);

        final callback = NativeCallable<_WorkerTokenCallback>.isolateLocal(
          (Pointer<Utf8> tokenPtr, Pointer<Void> _) {
            final partialText = tokenPtr.toDartString();
            message.replyPort.send(NmtStreamToken(partialText));
          },
        );

        final textPtr = jsonStr.toNativeUtf8();
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
