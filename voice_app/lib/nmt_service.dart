import 'local_onnx_model.dart';
import 'model_manager.dart';

class NmtService {
  LocalOnnxModel? _model;
  ModelInfo? _currentModel;

  bool get isLoaded => _model != null;
  ModelInfo? get currentModel => _currentModel;

  Future<void> loadModel(ModelInfo modelInfo) async {
    if (_currentModel?.path == modelInfo.path && _model != null) {
      return; // Already loaded
    }

    await release();

    try {
      final onnxModel = LocalOnnxModel();
      // Initialize with the directory containing encoder.onnx, decoder.onnx, decoder_init.onnx, vocab.json
      await onnxModel.init(modelBasePath: modelInfo.path);
      _model = onnxModel;
      _currentModel = modelInfo;
    } catch (e) {
      print("NMT Load Error: $e");
      rethrow;
    }
  }

  Future<String> translate(String text, {String? targetLangToken}) async {
    if (_model == null) {
      throw Exception('NMT Model not loaded.');
    }
    try {
      // runModel executes seq2seq generation loop locally
      return await _model!.runModel(text, initialLangToken: targetLangToken ?? '');
    } catch (e) {
      print("NMT Translation Error: $e");
      rethrow;
    }
  }

  Future<void> release() async {
    _model = null;
    _currentModel = null;
  }
}
