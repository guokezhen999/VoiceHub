// Dart FFI bindings for the Marian NMT native library (libmarian_nmt).
//
// The native library exposes a simple C API defined in marian/csrc/marian_ffi.h.
//
// On macOS, the dylib is auto-bundled by the marian_nmt_macos Flutter plugin
// (no Xcode setup needed). On other platforms, call init(libPath: ...) with
// the path to the shared library.
//
// Usage:
//   await MarianNmtBridge.init();                   // Load the native library.
//   final handle = MarianNmtBridge.createTranslator(modelDir, numBeams: 4);
//   final result = MarianNmtBridge.translate(handle, "Hello world");
//   print(result);
//   MarianNmtBridge.destroyTranslator(handle);

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:marian_nmt_macos/marian_nmt_macos.dart';

// C type aliases for dart:ffi.
// MarianTranslatorHandle* is an opaque pointer => we use Pointer<Void>.
typedef _CreateNative = Pointer<Void> Function(
    Pointer<Utf8> modelDir, Int32 numBeams, Int32 maxLen, Int32 numThreads);
typedef _CreateDart = Pointer<Void> Function(
    Pointer<Utf8> modelDir, int numBeams, int maxLen, int numThreads);

typedef _TranslateNative = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText);
typedef _TranslateDart = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> sourceText);

typedef _IsReadyNative = Int32 Function(Pointer<Void> handle);
typedef _IsReadyDart = int Function(Pointer<Void> handle);

typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _FreeStringNative = Void Function(Pointer<Utf8> str);
typedef _FreeStringDart = void Function(Pointer<Utf8> str);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

/// Low-level FFI bindings to the Marian NMT shared library.
class MarianNmtBridge {
  static MarianNmtBridge? _instance;
  DynamicLibrary? _lib;

  // ---- FFI function pointers ----
  late _CreateDart _createTranslator;
  late _TranslateDart _translate;
  late _IsReadyDart _isReady;
  late _DestroyDart _destroyTranslator;
  late _FreeStringDart _freeString;
  late _LastErrorDart _lastError;

  MarianNmtBridge._();

  /// Get the singleton instance.
  static MarianNmtBridge get instance {
    _instance ??= MarianNmtBridge._();
    return _instance!;
  }

  /// Load the native library. Call once before any other methods.
  ///
  /// On macOS, the library is loaded automatically via the marian_nmt_macos
  /// plugin — no path needed. On other platforms, pass [libPath] to specify
  /// the shared library location.
  static Future<void> init({String? libPath}) async {
    if (instance._lib != null) return;

    final DynamicLibrary lib;
    if (libPath != null) {
      lib = DynamicLibrary.open(libPath);
    } else {
      lib = loadMarianLibrary();
    }
    instance._lib = lib;
    instance._loadFunctions();
  }

  void _loadFunctions() {
    final lib = _lib!;

    _createTranslator = lib
        .lookup<NativeFunction<_CreateNative>>('marian_create_translator')
        .asFunction();

    _translate = lib
        .lookup<NativeFunction<_TranslateNative>>('marian_translate')
        .asFunction();

    _isReady = lib
        .lookup<NativeFunction<_IsReadyNative>>('marian_is_ready')
        .asFunction();

    _destroyTranslator = lib
        .lookup<NativeFunction<_DestroyNative>>('marian_destroy_translator')
        .asFunction();

    _freeString = lib
        .lookup<NativeFunction<_FreeStringNative>>('marian_free_string')
        .asFunction();

    _lastError = lib
        .lookup<NativeFunction<_LastErrorNative>>('marian_last_error')
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
      throw Exception('Marian NMT translate failed: $error');
    }

    final result = resultPtr.toDartString();
    _freeString(resultPtr);
    return result;
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
