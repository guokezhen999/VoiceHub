// Dart FFI bindings for the simulst native library (libsimulst).
//
// The native library exposes a pure C API defined in simulst/csrc/simulst_ffi.h.
// It wraps the streaming speech-to-text / speech translation pipeline
// (VAD + ONNX encoder + dual Llama decoders).
//
// On macOS the dylib is auto-bundled by the simulst_macos Flutter plugin.
//
// Usage:
//   await SimulstBridge.init();
//   final handle = SimulstBridge.instance.create(jsonConfig);
//   SimulstBridge.instance.acceptWaveform(handle, samples);
//   final r = SimulstBridge.instance.poll(handle);
//   SimulstBridge.instance.destroy(handle);

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:simulst_macos/simulst_macos.dart';

typedef _CreateNative = Pointer<Void> Function(Pointer<Utf8> jsonConfig);
typedef _CreateDart = Pointer<Void> Function(Pointer<Utf8> jsonConfig);

typedef _SetTasksNative = Int32 Function(Pointer<Void> handle, Pointer<Utf8> jsonTasks);
typedef _SetTasksDart = int Function(Pointer<Void> handle, Pointer<Utf8> jsonTasks);

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

class SimulstSegment {
  final String transcript;
  final String translation;
  final String text;
  final double start;
  final double end;

  const SimulstSegment({
    required this.transcript,
    required this.translation,
    required this.text,
    required this.start,
    required this.end,
  });
}

/// Parsed result of simulst_poll().
class SimulstPollResult {
  final bool speaking;
  final String partialTranscript;
  final String partialTranslation;
  final String partial;
  final List<String> finalizedTranscripts;
  final List<String> finalizedTranslations;
  final List<String> finalized;
  final List<SimulstSegment> segments;

  const SimulstPollResult({
    required this.speaking,
    required this.partialTranscript,
    required this.partialTranslation,
    required this.partial,
    required this.finalizedTranscripts,
    required this.finalizedTranslations,
    required this.finalized,
    required this.segments,
  });

  static const empty = SimulstPollResult(
    speaking: false,
    partialTranscript: '',
    partialTranslation: '',
    partial: '',
    finalizedTranscripts: [],
    finalizedTranslations: [],
    finalized: [],
    segments: [],
  );
}

/// Low-level FFI bindings to the simulst shared library.
class SimulstBridge {
  static SimulstBridge? _instance;
  DynamicLibrary? _lib;

  late _CreateDart _create;
  _SetTasksDart? _setTasks;
  late _AcceptWaveformDart _acceptWaveform;
  late _PollDart _poll;
  late _FlushDart _flush;
  late _ResetDart _reset;
  late _DestroyDart _destroy;
  late _FreeStringDart _freeString;
  late _LastErrorDart _lastError;

  SimulstBridge._();

  static SimulstBridge get instance {
    _instance ??= SimulstBridge._();
    return _instance!;
  }

  /// Load the native library. Call once before any other methods.
  ///
  /// Always re-binds FFI symbols so hot reload cannot leave [late] fields stale.
  static Future<void> init({String? libPath}) async {
    if (instance._lib == null) {
      final DynamicLibrary lib;
      if (libPath != null) {
        lib = DynamicLibrary.open(libPath);
      } else {
        lib = loadSimulstLibrary();
      }
      instance._lib = lib;
    }
    instance._loadFunctions();
  }

  void _ensureFunctions() {
    if (_lib == null) {
      throw StateError(
          'SimulstBridge not initialized. Call SimulstBridge.init() first.');
    }
    _loadFunctions();
  }

  void _loadFunctions() {
    final lib = _lib!;

    _create = lib
        .lookup<NativeFunction<_CreateNative>>('simulst_create')
        .asFunction();

    try {
      _setTasks = lib
          .lookup<NativeFunction<_SetTasksNative>>('simulst_set_tasks')
          .asFunction();
    } catch (_) {
      _setTasks = null;
    }

    _acceptWaveform = lib
        .lookup<NativeFunction<_AcceptWaveformNative>>('simulst_accept_waveform')
        .asFunction();

    _poll = lib
        .lookup<NativeFunction<_PollNative>>('simulst_poll')
        .asFunction();

    _flush = lib
        .lookup<NativeFunction<_FlushNative>>('simulst_flush')
        .asFunction();

    _reset = lib
        .lookup<NativeFunction<_ResetNative>>('simulst_reset')
        .asFunction();

    _destroy = lib
        .lookup<NativeFunction<_DestroyNative>>('simulst_destroy')
        .asFunction();

    _freeString = lib
        .lookup<NativeFunction<_FreeStringNative>>('simulst_free_string')
        .asFunction();

    _lastError = lib
        .lookup<NativeFunction<_LastErrorNative>>('simulst_last_error')
        .asFunction();
  }

  Pointer<Void> create(String jsonConfig) {
    _ensureFunctions();
    final cfgPtr = jsonConfig.toNativeUtf8();
    final handle = _create(cfgPtr);
    calloc.free(cfgPtr);

    if (handle == nullptr) {
      final errPtr = _lastError();
      final error = errPtr == nullptr ? 'unknown error' : errPtr.toDartString();
      throw Exception('simulst_create failed: $error');
    }
    return handle;
  }

  /// Whether this native library exports [simulst_set_tasks].
  bool get supportsSetTasks => _setTasks != null;

  bool setTasks(Pointer<Void> handle, String jsonTasks) {
    _ensureFunctions();
    final setTasksFn = _setTasks;
    if (setTasksFn == null) return false;
    final tasksPtr = jsonTasks.toNativeUtf8();
    try {
      return setTasksFn(handle, tasksPtr) != 0;
    } finally {
      calloc.free(tasksPtr);
    }
  }

  void acceptWaveform(Pointer<Void> handle, Float32List samples) {
    _ensureFunctions();
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

  SimulstPollResult poll(Pointer<Void> handle) {
    _ensureFunctions();
    final resultPtr = _poll(handle);
    if (resultPtr == nullptr) {
      return SimulstPollResult.empty;
    }
    final jsonStr = resultPtr.toDartString();
    _freeString(resultPtr);

    try {
      final j = jsonDecode(jsonStr) as Map<String, dynamic>;
      return SimulstPollResult(
        speaking: j['speaking'] == true,
        partialTranscript: (j['partial_transcript'] ?? '').toString(),
        partialTranslation: (j['partial_translation'] ?? '').toString(),
        partial: (j['partial'] ?? '').toString(),
        finalizedTranscripts: _parseStringList(j['finalized_transcripts']),
        finalizedTranslations: _parseStringList(j['finalized_translations']),
        finalized: _parseStringList(j['finalized']),
        segments: _parseSegments(j['segments']),
      );
    } catch (_) {
      return SimulstPollResult.empty;
    }
  }

  void flush(Pointer<Void> handle) {
    _ensureFunctions();
    _flush(handle);
  }

  void reset(Pointer<Void> handle) {
    _ensureFunctions();
    _reset(handle);
  }

  void destroy(Pointer<Void> handle) {
    _ensureFunctions();
    _destroy(handle);
  }

  String? lastError() {
    _ensureFunctions();
    final errPtr = _lastError();
    return errPtr == nullptr ? null : errPtr.toDartString();
  }

  static List<String> _parseStringList(dynamic raw) {
    final out = <String>[];
    if (raw is List) {
      for (final item in raw) {
        out.add(item.toString());
      }
    }
    return out;
  }

  static List<SimulstSegment> _parseSegments(dynamic raw) {
    final segments = <SimulstSegment>[];
    if (raw is! List) return segments;
    for (final s in raw) {
      if (s is Map) {
        segments.add(SimulstSegment(
          transcript: (s['transcript'] ?? '').toString(),
          translation: (s['translation'] ?? '').toString(),
          text: (s['text'] ?? '').toString(),
          start: (s['start'] ?? 0.0).toDouble(),
          end: (s['end'] ?? 0.0).toDouble(),
        ));
      }
    }
    return segments;
  }
}
