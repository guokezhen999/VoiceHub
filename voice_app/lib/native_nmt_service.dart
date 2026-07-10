import 'dart:ffi';

import 'marian_ffi_bridge.dart';
import 'model_manager.dart';

/// NMT service backed by the native Marian C++ library via FFI.
///
/// Compared to the Dart-based [NmtService] (which runs ONNX Runtime in Dart),
/// this service delegates the full pipeline — tokenization, encoder-decoder
/// inference (greedy or beam search), and detokenization — to the native
/// `libmarian_nmt` shared library.
///
/// Usage:
///   await NativeNmtService.init();                  // once at startup
///   final svc = NativeNmtService();
///   await svc.loadModel(modelInfo);
///   final result = await svc.translate("你好世界");
///   await svc.release();
class NativeNmtService {
  Pointer<Void>? _handle;
  ModelInfo? _currentModel;

  bool get isLoaded => _handle != null;
  ModelInfo? get currentModel => _currentModel;

  /// Initialize the native FFI bindings. Call once at app startup.
  static Future<void> init({String? libPath}) async {
    await MarianNmtBridge.init(libPath: libPath);
  }

  /// Load a Marian NMT model from [modelInfo].
  ///
  /// The model directory must contain:
  /// - encoder.onnx
  /// - decoder.onnx
  /// - vocab.json
  Future<void> loadModel(
    ModelInfo modelInfo, {
    int numBeams = 4,
    int maxLength = 512,
    int numThreads = 4,
  }) async {
    if (_currentModel?.path == modelInfo.path && _handle != null) {
      return; // Already loaded.
    }

    await release();

    final handle = MarianNmtBridge.instance.createTranslator(
      modelInfo.path,
      numBeams: numBeams,
      maxLength: maxLength,
      numThreads: numThreads,
    );

    if (handle == nullptr) {
      final err = MarianNmtBridge.instance.lastError();
      throw Exception('Failed to create native translator: ${err ?? "unknown"}');
    }

    if (!MarianNmtBridge.instance.isReady(handle)) {
      MarianNmtBridge.instance.destroyTranslator(handle);
      throw Exception('Native translator is not ready after creation');
    }

    _handle = handle;
    _currentModel = modelInfo;
  }

  /// Translate [text] from the source language to the target language.
  ///
  /// The language direction is determined by which model is loaded
  /// (e.g. zh→en, en→zh).
  ///
  /// [targetLangToken] will be prepended to the input text for multilingual
  /// models that use language direction tokens (e.g. ">>en<<").
  Future<String> translate(String text, {String? targetLangToken}) async {
    if (_handle == null) {
      throw Exception('Native NMT model not loaded. Call loadModel() first.');
    }

    final sourceText = (targetLangToken != null && targetLangToken.isNotEmpty)
        ? '$targetLangToken $text'
        : text;

    // Run translation on a background isolate to avoid blocking the UI.
    // For simplicity, we run it synchronously here; in production consider
    // using Isolate.run() or compute().
    final result = MarianNmtBridge.instance.translate(_handle!, sourceText);
    if (result == null || result.isEmpty) {
      throw Exception(
          'Native NMT translation failed: ${MarianNmtBridge.instance.lastError() ?? "empty result"}');
    }
    return result;
  }

  /// Release the loaded model and free native resources.
  Future<void> release() async {
    if (_handle != null) {
      MarianNmtBridge.instance.destroyTranslator(_handle!);
      _handle = null;
      _currentModel = null;
    }
  }
}
