// Dart FFI bindings for the LlamaCpp NMT native library (libllamacpp_nmt).
//
// The native library exposes a C API defined in llama/csrc/llamacpp_ffi.h.
// The API is signature-compatible with marian_ffi.h so the Dart bridge
// mirrors marian_ffi_bridge.dart.
//
// On macOS, the dylib is auto-bundled by the llamacpp_macos Flutter plugin.
//
// Usage:
//   await LlamaCppBridge.init();
//   final handle = LlamaCppBridge.createTranslator(
//       modelPath, sourceLang: 'Chinese', targetLang: 'English');
//   final result = LlamaCppBridge.translate(handle, '你好世界');
//   LlamaCppBridge.destroyTranslator(handle);

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:llamacpp_macos/llamacpp_macos.dart';

// ---------------------------------------------------------------------------
// C type aliases for dart:ffi
// ---------------------------------------------------------------------------

typedef _CreateNative = Pointer<Void> Function(
    Pointer<Utf8> modelPath,
    Pointer<Utf8> sourceLang,
    Pointer<Utf8> targetLang,
    Int32 nCtx,
    Int32 nThreads,
    Int32 nGpuLayers,
    Int32 maxTokens,
    Int32 chatMode,
    Pointer<Utf8> systemPrompt);
typedef _CreateDart = Pointer<Void> Function(
    Pointer<Utf8> modelPath,
    Pointer<Utf8> sourceLang,
    Pointer<Utf8> targetLang,
    int nCtx,
    int nThreads,
    int nGpuLayers,
    int maxTokens,
    int chatMode,
    Pointer<Utf8> systemPrompt);

typedef _TranslateNative = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText);
typedef _TranslateDart = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText);

typedef _TranslateStreamingNative = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText,
    Pointer<NativeFunction<LlamaTokenCallbackNative>> onToken, Pointer<Void> userData);
typedef _TranslateStreamingDart = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText,
    Pointer<NativeFunction<LlamaTokenCallbackNative>> onToken, Pointer<Void> userData);

typedef LlamaTokenCallbackNative = Void Function(
    Pointer<Utf8> partialText, Pointer<Void> userData);

typedef _IsReadyNative = Int32 Function(Pointer<Void> handle);
typedef _IsReadyDart = int Function(Pointer<Void> handle);

typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _SetEnableThinkingNative = Void Function(Pointer<Void> handle, Int32 enableThinking);
typedef _SetEnableThinkingDart = void Function(Pointer<Void> handle, int enableThinking);

typedef _FreeStringNative = Void Function(Pointer<Utf8> str);
typedef _FreeStringDart = void Function(Pointer<Utf8> str);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

// ---------------------------------------------------------------------------
// LlamaCppBridge
// ---------------------------------------------------------------------------

/// Low-level FFI bindings to the LlamaCpp NMT shared library.
class LlamaCppBridge {
  static LlamaCppBridge? _instance;
  DynamicLibrary? _lib;

  // FFI function pointers.
  late _CreateDart _createTranslator;
  late _TranslateDart _translate;
  late _TranslateStreamingDart _translateStreaming;
  late _IsReadyDart _isReady;
  late _DestroyDart _destroyTranslator;
  late _SetEnableThinkingDart _setEnableThinking;
  late _FreeStringDart _freeString;
  late _LastErrorDart _lastError;

  LlamaCppBridge._();

  /// Get the singleton instance.
  static LlamaCppBridge get instance {
    _instance ??= LlamaCppBridge._();
    return _instance!;
  }

  /// Load the native library. Call once before any other methods.
  ///
  /// On macOS, the library is loaded automatically via the llamacpp_macos
  /// plugin. On other platforms, pass [libPath] to specify the library.
  static Future<void> init({String? libPath}) async {
    if (instance._lib != null) return;

    final DynamicLibrary lib;
    if (libPath != null) {
      lib = DynamicLibrary.open(libPath);
    } else {
      lib = loadLlamaLibrary();
    }
    instance._lib = lib;
    instance._loadFunctions();
  }

  void _loadFunctions() {
    final lib = _lib!;

    _createTranslator = lib
        .lookup<NativeFunction<_CreateNative>>('llamacpp_create_translator')
        .asFunction();

    _translate = lib
        .lookup<NativeFunction<_TranslateNative>>('llamacpp_translate')
        .asFunction();

    _translateStreaming = lib
        .lookup<NativeFunction<_TranslateStreamingNative>>('llamacpp_translate_streaming')
        .asFunction();

    _isReady = lib
        .lookup<NativeFunction<_IsReadyNative>>('llamacpp_is_ready')
        .asFunction();

    _destroyTranslator = lib
        .lookup<NativeFunction<_DestroyNative>>('llamacpp_destroy_translator')
        .asFunction();

    _setEnableThinking = lib
        .lookup<NativeFunction<_SetEnableThinkingNative>>('llamacpp_set_enable_thinking')
        .asFunction();

    _freeString = lib
        .lookup<NativeFunction<_FreeStringNative>>('llamacpp_free_string')
        .asFunction();

    _lastError = lib
        .lookup<NativeFunction<_LastErrorNative>>('llamacpp_last_error')
        .asFunction();
  }

  /// Create a translator handle for the GGUF model at [modelPath].
  ///
  /// [sourceLang] and [targetLang] are used to construct the translation prompt.
  /// Set [chatMode] = true for general chat (uses [systemPrompt] instead of
  /// the hardcoded translation prompt).
  /// [nGpuLayers] = -1 offloads all layers to GPU (Metal on Apple Silicon).
  Pointer<Void> createTranslator(
    String modelPath, {
    String sourceLang = 'Chinese',
    String targetLang = 'English',
    int nCtx = 2048,
    int nThreads = 4,
    int nGpuLayers = -1,
    int maxTokens = 512,
    bool chatMode = false,
    String? systemPrompt,
  }) {
    final mp = modelPath.toNativeUtf8();
    final sl = sourceLang.toNativeUtf8();
    final tl = targetLang.toNativeUtf8();
    final sp = (systemPrompt ?? '').toNativeUtf8();
    final handle = _createTranslator(
        mp, sl, tl, nCtx, nThreads, nGpuLayers, maxTokens,
        chatMode ? 1 : 0, sp);
    calloc.free(mp);
    calloc.free(sl);
    calloc.free(tl);
    calloc.free(sp);
    return handle;
  }

  /// Translate [sourceText] using the given [handle].
  /// Returns a JSON string with text and timing metrics.
  String? translate(Pointer<Void> handle, String sourceText) {
    final textPtr = sourceText.toNativeUtf8();
    final resultPtr = _translate(handle, textPtr);
    calloc.free(textPtr);

    if (resultPtr == nullptr) {
      final errPtr = _lastError();
      final error = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
      throw Exception('LlamaCpp translate failed: $error');
    }

    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Translate [sourceText] with per-token streaming callbacks.
  ///
  /// [onToken] is called synchronously from C++ for each generated token
  /// with the cumulative partial translation text.
  /// Returns the final JSON string with translated text and timing metrics.
  String? translateStreaming(
    Pointer<Void> handle,
    String sourceText,
    void Function(String partialText) onToken,
  ) {
    final textPtr = sourceText.toNativeUtf8();

    final callback = NativeCallable<LlamaTokenCallbackNative>.isolateLocal(
      (Pointer<Utf8> tokenPtr, Pointer<Void> _) {
        final partial = tokenPtr.toDartString();
        onToken(partial);
      },
    );

    try {
      final resultPtr = _translateStreaming(
        handle,
        textPtr,
        callback.nativeFunction,
        nullptr,
      );

      if (resultPtr == nullptr) {
        final errPtr = _lastError();
        final error = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
        throw Exception('LlamaCpp translate streaming failed: $error');
      }

      final result = resultPtr.toDartString();
      _freeString(resultPtr);
      return result;
    } finally {
      calloc.free(textPtr);
      callback.close();
    }
  }

  /// Check whether [handle] is initialized and ready.
  bool isReady(Pointer<Void> handle) {
    return _isReady(handle) != 0;
  }

  /// Destroy a translator and free its resources.
  void destroyTranslator(Pointer<Void> handle) {
    _destroyTranslator(handle);
  }

  /// Dynamically toggle thinking mode on or off.
  void setEnableThinking(Pointer<Void> handle, bool enableThinking) {
    _setEnableThinking(handle, enableThinking ? 1 : 0);
  }

  /// Get the last error message from the native library.
  String? lastError() {
    final errPtr = _lastError();
    return errPtr == nullptr ? null : errPtr.toDartString();
  }
}
