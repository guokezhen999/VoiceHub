// Dart FFI bindings for the opus-mt native library (libopus_mt).
//
// The native library exposes a simple C API defined in opus_mt/csrc/opus_mt_ffi.h.
//
// On macOS, the dylib is auto-bundled by the opus_mt_macos Flutter plugin
// (no Xcode setup needed). On other platforms, call init(libPath: ...) with
// the path to the shared library.
//
// Usage:
//   await OpusMtBridge.init();                   // Load the native library.
//   final handle = OpusMtBridge.createTranslator(modelDir, numBeams: 4);
//   final result = OpusMtBridge.translate(handle, "Hello world");
//   print(result);
//   OpusMtBridge.destroyTranslator(handle);

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:opus_mt_macos/opus_mt_macos.dart';

// C type aliases for dart:ffi.
// OpusMtTranslatorHandle* is an opaque pointer => we use Pointer<Void>.
typedef _CreateNative = Pointer<Void> Function(
    Pointer<Utf8> modelDir, Int32 numBeams, Int32 maxLen, Int32 numThreads);
typedef _CreateDart = Pointer<Void> Function(
    Pointer<Utf8> modelDir, int numBeams, int maxLen, int numThreads);

typedef _TranslateNative = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText);
typedef _TranslateDart = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText);

typedef _TranslateStreamingNative = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText,
    Pointer<NativeFunction<TokenCallbackNative>> onToken, Pointer<Void> userData);
typedef _TranslateStreamingDart = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText,
    Pointer<NativeFunction<TokenCallbackNative>> onToken, Pointer<Void> userData);

typedef TokenCallbackNative = Void Function(Pointer<Utf8> partialText, Pointer<Void> userData);

typedef _IsReadyNative = Int32 Function(Pointer<Void> handle);
typedef _IsReadyDart = int Function(Pointer<Void> handle);

typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _FreeStringNative = Void Function(Pointer<Utf8> str);
typedef _FreeStringDart = void Function(Pointer<Utf8> str);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

/// Low-level FFI bindings to the opus-mt shared library.
class OpusMtBridge {
  static OpusMtBridge? _instance;
  DynamicLibrary? _lib;

  // ---- FFI function pointers ----
  late _CreateDart _createTranslator;
  late _TranslateDart _translate;
  late _TranslateStreamingDart _translateStreaming;
  late _IsReadyDart _isReady;
  late _DestroyDart _destroyTranslator;
  late _FreeStringDart _freeString;
  late _LastErrorDart _lastError;

  OpusMtBridge._();

  /// Get the singleton instance.
  static OpusMtBridge get instance {
    _instance ??= OpusMtBridge._();
    return _instance!;
  }

  /// Load the native library. Call once before any other methods.
  ///
  /// On macOS, the library is loaded automatically via the opus_mt_macos
  /// plugin — no path needed. On other platforms, pass [libPath] to specify
  /// the shared library location.
  static Future<void> init({String? libPath}) async {
    if (instance._lib != null) return;

    final DynamicLibrary lib;
    if (libPath != null) {
      lib = DynamicLibrary.open(libPath);
    } else {
      lib = loadOpusMtLibrary();
    }
    instance._lib = lib;
    instance._loadFunctions();
  }

  void _loadFunctions() {
    final lib = _lib!;

    _createTranslator = lib
        .lookup<NativeFunction<_CreateNative>>('opus_mt_create_translator')
        .asFunction();

    _translate = lib
        .lookup<NativeFunction<_TranslateNative>>('opus_mt_translate')
        .asFunction();

    _translateStreaming = lib
        .lookup<NativeFunction<_TranslateStreamingNative>>('opus_mt_translate_streaming')
        .asFunction();

    _isReady = lib
        .lookup<NativeFunction<_IsReadyNative>>('opus_mt_is_ready')
        .asFunction();

    _destroyTranslator = lib
        .lookup<NativeFunction<_DestroyNative>>('opus_mt_destroy_translator')
        .asFunction();

    _freeString = lib
        .lookup<NativeFunction<_FreeStringNative>>('opus_mt_free_string')
        .asFunction();

    _lastError = lib
        .lookup<NativeFunction<_LastErrorNative>>('opus_mt_last_error')
        .asFunction();
  }

  /// Create a translator handle for the model at [modelDir].
  ///
  /// [modelDir] must contain: encoder.onnx, decoder.onnx, vocab.json.
  /// Optionally: config.json, source.spm, target.spm.
  Pointer<Void> createTranslator(
    String modelDir, {
    int numBeams = 4,
    int maxLength = 512,
    int numThreads = 4,
  }) {
    final dirPtr = modelDir.toNativeUtf8();
    final handle = _createTranslator(dirPtr, numBeams, maxLength, numThreads);
    calloc.free(dirPtr);
    return handle;
  }

  /// Translate [sourceText] using the given [handle].
  String? translate(Pointer<Void> handle, String sourceText) {
    final textPtr = sourceText.toNativeUtf8();
    final resultPtr = _translate(handle, textPtr);
    calloc.free(textPtr);

    if (resultPtr == nullptr) {
      final errPtr = _lastError();
      final error = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
      throw Exception('opus-mt translate failed: $error');
    }

    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
  }

  /// Translate [sourceText] with per-token streaming callbacks.
  ///
  /// [onToken] is called synchronously from C++ for each decoded token
  /// with the cumulative partial translation text.
  /// Returns the final JSON string with translated text and timing metrics.
  String? translateStreaming(
    Pointer<Void> handle,
    String sourceText,
    void Function(String partialText) onToken,
  ) {
    final textPtr = sourceText.toNativeUtf8();

    // Create a NativeCallable that C++ can invoke for each token.
    final callback = NativeCallable<TokenCallbackNative>.isolateLocal(
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
        throw Exception('opus-mt translate streaming failed: $error');
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

  /// Get the last error message from the native library.
  String? lastError() {
    final errPtr = _lastError();
    return errPtr == nullptr ? null : errPtr.toDartString();
  }
}
