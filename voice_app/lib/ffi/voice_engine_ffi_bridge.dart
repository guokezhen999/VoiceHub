// Dart FFI bindings for the voice_engine native library (libvoice_engine).
//
// The native library exposes a pure C API defined in
// voice_engine/csrc/voice_engine_ffi.h. It wraps the streaming ASR pipeline
// (VAD + circular buffer + online/offline recognizer + pre-speech replay)
// so the Dart frontend no longer needs to drive sherpa-onnx directly.
//
// On macOS the dylib is auto-bundled by the voice_engine_macos Flutter plugin
// (no Xcode setup needed). On other platforms, call init(libPath: ...) with
// the path to the shared library.
//
// Usage:
//   await VoiceEngineBridge.init();
//   final handle = VoiceEngineBridge.instance.create(jsonConfig);
//   VoiceEngineBridge.instance.acceptWaveform(handle, samples);
//   final r = VoiceEngineBridge.instance.poll(handle);
//   print(r.partial); print(r.finalized);
//   VoiceEngineBridge.instance.destroy(handle);

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:voice_engine_macos/voice_engine_macos.dart';

// ---------------------------------------------------------------------------
// C type aliases for dart:ffi
// ---------------------------------------------------------------------------

// VoiceEngineHandle* is an opaque pointer => Pointer<Void>.
typedef _CreateNative = Pointer<Void> Function(Pointer<Utf8> jsonConfig);
typedef _CreateDart = Pointer<Void> Function(Pointer<Utf8> jsonConfig);

typedef _AcceptWaveformNative = Void Function(
    Pointer<Void> handle, Pointer<Float> samples, Int32 n);
typedef _AcceptWaveformDart = void Function(
    Pointer<Void> handle, Pointer<Float> samples, int n);

typedef _PollNative = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _PollDart = Pointer<Utf8> Function(Pointer<Void> handle);

typedef _FlushNative = Void Function(Pointer<Void> handle);
typedef _FlushDart = void Function(Pointer<Void> handle);

typedef _ResetNative = Void Function(Pointer<Void> handle);
typedef _ResetDart = void Function(Pointer<Void> handle);

typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _FreeStringNative = Void Function(Pointer<Utf8> str);
typedef _FreeStringDart = void Function(Pointer<Utf8> str);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

/// Parsed result of voice_engine_poll().
class VoiceEnginePollResult {
  final bool speaking;
  final String partial;
  final List<String> finalized;

  const VoiceEnginePollResult({
    required this.speaking,
    required this.partial,
    required this.finalized,
  });

  @override
  String toString() =>
      'VoiceEnginePollResult(speaking=$speaking, partial="$partial", '
      'finalized=${finalized.length})';
}

/// Low-level FFI bindings to the voice_engine shared library.
class VoiceEngineBridge {
  static VoiceEngineBridge? _instance;
  DynamicLibrary? _lib;

  // FFI function pointers.
  late _CreateDart _create;
  late _AcceptWaveformDart _acceptWaveform;
  late _PollDart _poll;
  late _FlushDart _flush;
  late _ResetDart _reset;
  late _DestroyDart _destroy;
  late _FreeStringDart _freeString;
  late _LastErrorDart _lastError;

  VoiceEngineBridge._();

  /// Get the singleton instance.
  static VoiceEngineBridge get instance {
    _instance ??= VoiceEngineBridge._();
    return _instance!;
  }

  /// Load the native library. Call once before any other methods.
  ///
  /// On macOS the library is loaded automatically via the voice_engine_macos
  /// plugin — no path needed. On other platforms, pass [libPath] to specify the
  /// shared library location.
  static Future<void> init({String? libPath}) async {
    if (instance._lib != null) return;

    final DynamicLibrary lib;
    if (libPath != null) {
      lib = DynamicLibrary.open(libPath);
    } else {
      lib = loadVoiceEngineLibrary();
    }
    instance._lib = lib;
    instance._loadFunctions();
  }

  void _loadFunctions() {
    final lib = _lib!;

    _create = lib
        .lookup<NativeFunction<_CreateNative>>('voice_engine_create')
        .asFunction();

    _acceptWaveform = lib
        .lookup<NativeFunction<_AcceptWaveformNative>>(
            'voice_engine_accept_waveform')
        .asFunction();

    _poll = lib
        .lookup<NativeFunction<_PollNative>>('voice_engine_poll')
        .asFunction();

    _flush = lib
        .lookup<NativeFunction<_FlushNative>>('voice_engine_flush')
        .asFunction();

    _reset = lib
        .lookup<NativeFunction<_ResetNative>>('voice_engine_reset')
        .asFunction();

    _destroy = lib
        .lookup<NativeFunction<_DestroyNative>>('voice_engine_destroy')
        .asFunction();

    _freeString = lib
        .lookup<NativeFunction<_FreeStringNative>>('voice_engine_free_string')
        .asFunction();

    _lastError = lib
        .lookup<NativeFunction<_LastErrorNative>>('voice_engine_last_error')
        .asFunction();
  }

  /// Create a pipeline from a JSON config string (see voice_engine_config.h).
  ///
  /// Returns an opaque handle. Throws on failure, with the native last_error.
  Pointer<Void> create(String jsonConfig) {
    final cfgPtr = jsonConfig.toNativeUtf8();
    final handle = _create(cfgPtr);
    calloc.free(cfgPtr);

    if (handle == nullptr) {
      final errPtr = _lastError();
      final error = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
      throw Exception('voice_engine_create failed: $error');
    }
    return handle;
  }

  /// Feed 16kHz mono Float32 samples into the pipeline.
  void acceptWaveform(Pointer<Void> handle, Float32List samples) {
    if (samples.isEmpty) return;
    final n = samples.length;
    final ptr = calloc<Float>(n);
    try {
      ptr.asTypedList(n).setAll(0, samples);
      _acceptWaveform(handle, ptr, n);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Poll the pipeline state. Drains the finalized queue.
  ///
  /// Returns {speaking, partial, finalized[]} as a typed result.
  VoiceEnginePollResult poll(Pointer<Void> handle) {
    final resultPtr = _poll(handle);
    if (resultPtr == nullptr) {
      return const VoiceEnginePollResult(
          speaking: false, partial: '', finalized: []);
    }
    final jsonStr = resultPtr.toDartString();
    _freeString(resultPtr);

    try {
      final j = jsonDecode(jsonStr) as Map<String, dynamic>;
      final finRaw = j['finalized'];
      final finalized = <String>[];
      if (finRaw is List) {
        for (final s in finRaw) {
          finalized.add(s.toString());
        }
      }
      return VoiceEnginePollResult(
        speaking: j['speaking'] == true,
        partial: (j['partial'] ?? '').toString(),
        finalized: finalized,
      );
    } catch (_) {
      return const VoiceEnginePollResult(
          speaking: false, partial: '', finalized: []);
    }
  }

  /// Finalize the remaining buffered audio (call when recording stops).
  /// Finalized text is delivered via a subsequent poll().
  void flush(Pointer<Void> handle) => _flush(handle);

  /// Reset the pipeline for a new utterance session.
  void reset(Pointer<Void> handle) => _reset(handle);

  /// Destroy a pipeline and free all resources.
  void destroy(Pointer<Void> handle) => _destroy(handle);

  /// Get the last error message from the native library.
  String? lastError() {
    final errPtr = _lastError();
    return errPtr == nullptr ? null : errPtr.toDartString();
  }
}
