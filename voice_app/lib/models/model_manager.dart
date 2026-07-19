import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

const List<String> supportedLanguages = [
  'English',
  'Chinese',
  'Cantonese',
  'Vietnamese',
  'Japanese',
];

class LanguageManager {
  static const List<String> defaultLanguages = [
    'English',
    'Chinese',
    'Cantonese',
    'Vietnamese',
    'Japanese',
    'Korean',
    'Spanish',
    'French',
    'German',
    'Italian',
    'Russian',
    'Portuguese',
    'Arabic',
    'Thai',
  ];

  static List<String> _languages = [];
  static Set<String> _enabledLanguages = {};
  static bool _loaded = false;

  static List<String> get languages {
    if (!_loaded) {
      return defaultLanguages;
    }
    return _languages;
  }

  static Set<String> get enabledLanguages {
    if (!_loaded) {
      return Set.from(defaultLanguages);
    }
    return _enabledLanguages;
  }

  static Future<void> load() async {
    if (_loaded) return;
    final file = await _getConfigFile();
    if (file.existsSync()) {
      try {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final langs = List<String>.from(json['languages'] ?? []);
        final enabled = Set<String>.from(json['enabled'] ?? []);

        // Ensure all default languages are in the list
        for (final l in defaultLanguages) {
          if (!langs.contains(l)) {
            langs.add(l);
          }
        }

        _languages = langs;
        if (enabled.isEmpty) {
          _enabledLanguages = Set<String>.from(_languages);
        } else {
          _enabledLanguages = enabled.where((l) => _languages.contains(l)).toSet();
        }
        _loaded = true;
        return;
      } catch (e) {
        print('Error loading languages config: $e');
      }
    }

    _languages = List.from(defaultLanguages);
    _enabledLanguages = Set.from(defaultLanguages);
    _loaded = true;
  }

  static Future<void> save() async {
    final file = await _getConfigFile();
    final json = {
      'languages': _languages,
      'enabled': _enabledLanguages.toList(),
    };
    await file.writeAsString(jsonEncode(json));
  }

  static Future<void> addLanguage(String lang) async {
    await load();
    final trimmed = lang.trim();
    if (trimmed.isEmpty) return;
    final capitalized = trimmed[0].toUpperCase() + trimmed.substring(1);
    if (!_languages.contains(capitalized)) {
      _languages.add(capitalized);
      _enabledLanguages.add(capitalized);
      await save();
    }
  }

  static Future<void> removeLanguage(String lang) async {
    await load();
    if (defaultLanguages.contains(lang)) return;
    if (_languages.contains(lang)) {
      _languages.remove(lang);
      _enabledLanguages.remove(lang);
      await save();
    }
  }

  static Future<void> toggleLanguage(String lang, bool enabled) async {
    await load();
    if (enabled) {
      _enabledLanguages.add(lang);
    } else {
      _enabledLanguages.remove(lang);
    }
    await save();
  }

  static Future<File> _getConfigFile() async {
    final appSupport = await getApplicationSupportDirectory();
    return File(p.join(appSupport.path, 'languages_config.json'));
  }
}

class ModelInfo {
  final String name;
  final String language;
  final String path; // Root folder path of the model
  final String type; // 'asr', 'tts', 'nmt', 'llm', or 'simulst'

  ModelInfo({
    required this.name,
    required this.language,
    required this.path,
    required this.type,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ModelInfo &&
        other.name == name &&
        other.language == language &&
        other.path == path &&
        other.type == type;
  }

  @override
  int get hashCode => Object.hash(name, language, path, type);

  List<String> get languages {
    final metaFile = File(p.join(path, 'metadata.json'));
    if (metaFile.existsSync()) {
      try {
        final jsonStr = metaFile.readAsStringSync();
        final data = jsonDecode(jsonStr);
        if (data['languages'] != null) {
          return List<String>.from(data['languages']);
        }
      } catch (e) {
        print('Error reading metadata.json: $e');
      }
    }
    return [language];
  }

  String get casing {
    // LLM models don't have a tokenizer casing concept.
    if (type == 'llm') return 'mixed';

    String? storedCasing;
    final metaFile = File(p.join(path, 'metadata.json'));
    if (metaFile.existsSync()) {
      try {
        final jsonStr = metaFile.readAsStringSync();
        final data = jsonDecode(jsonStr);
        if (data['casing'] != null) {
          storedCasing = data['casing'] as String;
        }
      } catch (e) {
        print('Error reading metadata.json for casing: $e');
      }
    }

    // Always run detection to ensure correctness and handle updates/migrations
    final tokFile = tokensPath != null ? File(tokensPath!) : null;
    final detected = (tokFile != null && tokFile.existsSync())
        ? _detectTokensCasing(tokFile)
        : 'mixed';

    if (storedCasing != detected) {
      _updateMetadataKey('casing', detected);
    }
    return detected;
  }

  void _updateMetadataKey(String key, dynamic value) {
    final metaFile = File(p.join(path, 'metadata.json'));
    try {
      Map<String, dynamic> data = {};
      if (metaFile.existsSync()) {
        final jsonStr = metaFile.readAsStringSync();
        data = Map<String, dynamic>.from(jsonDecode(jsonStr));
      }
      data[key] = value;
      metaFile.writeAsStringSync(jsonEncode(data));
      ModelManager.notifyChange();
    } catch (e) {
      print('Error updating metadata.json for $key: $e');
    }
  }

  static String _detectTokensCasing(File tokensFile) {
    if (!tokensFile.existsSync()) return 'mixed';
    try {
      final lines = tokensFile.readAsLinesSync();
      bool hasUpper = false;
      bool hasLower = false;

      for (var line in lines) {
        if (line.trim().isEmpty) continue;
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.isEmpty) continue;
        final token = parts[0];

        // Skip special tokens enclosed in <...> or [...]
        if ((token.startsWith('<') && token.endsWith('>')) ||
            (token.startsWith('[') && token.endsWith(']'))) {
          continue;
        }

        for (int i = 0; i < token.length; i++) {
          final charCode = token.codeUnitAt(i);
          if (charCode >= 65 && charCode <= 90) { // A-Z
            hasUpper = true;
          } else if (charCode >= 97 && charCode <= 122) { // a-z
            hasLower = true;
          }
        }
        if (hasUpper && hasLower) {
          return 'mixed';
        }
      }

      if (hasUpper && !hasLower) {
        return 'upper';
      } else if (hasLower && !hasUpper) {
        return 'lower';
      }
    } catch (e) {
      print('Error detecting token casing: $e');
    }
    return 'mixed';
  }

  Future<void> updateLanguages(List<String> langs) async {
    final metaFile = File(p.join(path, 'metadata.json'));
    try {
      final data = {
        'languages': langs,
      };
      await metaFile.writeAsString(jsonEncode(data));
      ModelManager.notifyChange();
    } catch (e) {
      print('Error writing metadata.json: $e');
    }
  }

  /// Returns a map indicating whether each punctuation should be normalized to full-width (true) or half-width (false).
  Map<String, bool> getPunctuationWidths() {
    final Map<String, bool> results = {
      'comma': true, // default to full-width
      'period': true,
      'question': true,
      'exclamation': true,
    };

    final tokPath = tokensPath;
    if (tokPath == null) return results;

    final file = File(tokPath);
    if (!file.existsSync()) return results;

    try {
      final lines = file.readAsLinesSync();
      final Set<String> tokensSet = {};
      for (var line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.isNotEmpty) {
          tokensSet.add(parts[0]);
        }
      }

      // Check commas:
      if (tokensSet.contains('，')) {
        results['comma'] = true;
      } else if (tokensSet.contains(',')) {
        results['comma'] = false;
      }

      // Check periods:
      if (tokensSet.contains('。')) {
        results['period'] = true;
      } else if (tokensSet.contains('.')) {
        results['period'] = false;
      }

      // Check question marks:
      if (tokensSet.contains('？')) {
        results['question'] = true;
      } else if (tokensSet.contains('?')) {
        results['question'] = false;
      }

      // Check exclamation marks:
      if (tokensSet.contains('！')) {
        results['exclamation'] = true;
      } else if (tokensSet.contains('!')) {
        results['exclamation'] = false;
      }
    } catch (e) {
      print('Error parsing tokens.txt for punctuation widths: $e');
    }

    return results;
  }

  String normalizeText(String text) {
    final widths = getPunctuationWidths();
    var result = text;

    // 1. Quotes and hyphens replaced by space
    final replaceWithSpace = ["'", '"', '“', '”', '‘', '’', '-', '—', '–'];
    for (var char in replaceWithSpace) {
      result = result.replaceAll(char, ' ');
    }

    // 2. Colon becomes comma
    final commaChar = widths['comma'] == true ? '，' : ',';
    result = result.replaceAll(':', commaChar);
    result = result.replaceAll('：', commaChar);

    // 3. Commas, periods, question marks, exclamation marks
    if (widths['comma'] == true) {
      result = result.replaceAll(',', '，');
    } else {
      result = result.replaceAll('，', ', ');
    }

    if (widths['period'] == true) {
      result = result.replaceAll('.', '。');
    } else {
      result = result.replaceAll('。', '. ');
    }

    if (widths['question'] == true) {
      result = result.replaceAll('?', '？');
    } else {
      result = result.replaceAll('？', '? ');
    }

    if (widths['exclamation'] == true) {
      result = result.replaceAll('!', '！');
    } else {
      result = result.replaceAll('！', '! ');
    }

    // 4. Collapse consecutive spaces to a single space
    result = result.replaceAll(RegExp(r' +'), ' ');

    return result.trim();
  }


  // ASR specific resolved paths
  String? get asrEncoderPath => _findFile('encoder.onnx');
  String? get asrDecoderPath => _findFile('decoder.onnx');
  String? get asrJoinerPath => _findFile('joiner.onnx');
  String? get tokensPath => _findFile('tokens.txt');

  bool? _isStreamingCache;
  bool get isStreamingASR {
    if (type != 'asr') return false;
    if (_isStreamingCache != null) return _isStreamingCache!;

    final encPath = asrEncoderPath;
    if (encPath == null) {
      _isStreamingCache = false;
      return false;
    }

    final file = File(encPath);
    if (!file.existsSync()) {
      _isStreamingCache = false;
      return false;
    }

    try {
      final raf = file.openSync();
      try {
        final buffer = Uint8List(1024 * 1024); // 1MB buffer
        while (true) {
          final bytesRead = raf.readIntoSync(buffer);
          if (bytesRead <= 0) break;

          if (_searchBytes(buffer, bytesRead, const [101, 110, 99, 111, 100, 101, 114, 95, 100, 105, 109, 115])) {
            _isStreamingCache = true;
            return true;
          }
        }
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      print('Error checking streaming ASR: $e');
    }

    _isStreamingCache = false;
    return false;
  }

  bool get isStreaming {
    if (type == 'asr') {
      return isStreamingASR;
    } else if (type == 'tts') {
      return ttsEncoderPath != null && ttsDecoderPath != null;
    }
    return false;
  }

  static bool _searchBytes(Uint8List buffer, int length, List<int> pattern) {
    if (length < pattern.length) return false;
    for (int i = 0; i <= length - pattern.length; i++) {
      bool found = true;
      for (int j = 0; j < pattern.length; j++) {
        if (buffer[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return true;
    }
    return false;
  }

  // NMT specific resolved paths
  String? get nmtEncoderPath => _findFile('encoder.onnx');
  String? get nmtDecoderPath => _findFile('decoder.onnx');
  String? get nmtDecoderInitPath => _findFile('decoder_init.onnx');
  String? get nmtVocabPath => _findFile('vocab.json');

  // LLM / simulst specific resolved paths
  String? get llmModelPath => _findFileEndingWith('.gguf');

  String? get simulstGgufPath {
    final metaFile = File(p.join(path, 'speechllm_meta.json'));
    if (metaFile.existsSync()) {
      try {
        final data = jsonDecode(metaFile.readAsStringSync());
        final gguf = data['gguf_file']?.toString();
        if (gguf != null && gguf.isNotEmpty) {
          final resolved = p.join(path, gguf);
          if (File(resolved).existsSync()) return resolved;
        }
      } catch (_) {}
    }
    return llmModelPath;
  }

  bool get _hasSimulstSpecialTokenPatch {
    return _findFile('special_token_input_patch.npz') != null ||
        _findFile('special_token_input_patch.bin') != null ||
        _findFile('special_token_embeddings.npz') != null;
  }

  // TTS specific resolved paths
  String? get ttsEncoderPath => _findFile('encoder.onnx');
  String? get ttsDecoderPath => _findFile('decoder.onnx');
  String? get lexiconPath => _findFile('lexicon.txt');

  String get ruleFsts {
    final dir = Directory(path);
    if (!dir.existsSync()) return '';
    final fsts = <String>[];
    try {
      for (var entity in dir.listSync(recursive: true)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.fst')) {
          fsts.add(entity.path);
        }
      }
    } catch (_) {}
    return fsts.join(',');
  }

  String get ttsEngineType {
    String? _readMetaJsonModelType() {
      final metaFile = File(p.join(path, 'metadata.json'));
      if (metaFile.existsSync()) {
        try {
          final data = jsonDecode(metaFile.readAsStringSync());
          if (data['model_type'] != null) {
            return data['model_type'] as String;
          }
        } catch (_) {}
      }
      return null;
    }

    if (ttsEncoderPath != null && ttsDecoderPath != null) {
      final mt = _readMetaJsonModelType();
      if (mt == 'vits') {
        return 'vits_online';
      }
      if (mt == 'matcha') {
        return 'matcha';
      }
      // No metadata.json or unrecognized type => default to vits
      _updateMetadataKey('model_type', 'vits');
      return 'vits_online';
    }

    final mt = _readMetaJsonModelType();
    if (mt != null) {
      return mt;
    }

    final modelFile = ttsEncoderPath != null
        ? File(ttsEncoderPath!)
        : (ttsModelPath != null ? File(ttsModelPath!) : null);
    if (modelFile != null && modelFile.existsSync()) {
      try {
        final raf = modelFile.openSync();
        try {
          final len = raf.lengthSync();
          final bytesToRead = len < 128 * 1024 ? len : 128 * 1024;
          final bytes = raf.readSync(bytesToRead);
          final content = String.fromCharCodes(bytes);
          if (content.contains('matcha')) {
            _updateMetadataKey('model_type', 'matcha');
            return 'matcha';
          }
        } finally {
          raf.closeSync();
        }
      } catch (_) {}
    }

    _updateMetadataKey('model_type', 'vits');
    return 'vits';
  }

  String? get ttsModelPath {
    final dir = Directory(path);
    if (!dir.existsSync()) return null;
    try {
      for (var entity in dir.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.onnx')) {
          final filename = p.basename(entity.path);
          if (filename != 'encoder.onnx' &&
              filename != 'decoder.onnx' &&
              filename != 'joiner.onnx' &&
              filename != 'encoder_model.onnx' &&
              filename != 'decoder_model.onnx') {
            return entity.path;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  String? get ttsDataDirPath {
    final dir = Directory(path);
    if (!dir.existsSync()) return null;
    try {
      for (var entity in dir.listSync(recursive: true)) {
        if (entity is Directory && p.basename(entity.path) == 'espeak-ng-data') {
          return entity.path;
        }
      }
    } catch (_) {}
    return null;
  }

  String? get ttsDictDirPath {
    final dir = Directory(path);
    if (!dir.existsSync()) return null;
    try {
      for (var entity in dir.listSync(recursive: true)) {
        if (entity is Directory && p.basename(entity.path) == 'dict') {
          return entity.path;
        }
      }
    } catch (_) {}
    return null;
  }

  String? _findFile(String filename) {
    final dir = Directory(path);
    if (!dir.existsSync()) return null;
    try {
      for (var entity in dir.listSync(recursive: true)) {
        if (entity is File && p.basename(entity.path) == filename) {
          return entity.path;
        }
      }
    } catch (_) {}
    return null;
  }

  String? _findFileEndingWith(String suffix) {
    // File-based LLM: path itself IS the .gguf file.
    final pathFile = File(path);
    if (pathFile.existsSync() && path.endsWith(suffix)) {
      return path;
    }
    // Legacy: directory-based search.
    final dir = Directory(path);
    if (!dir.existsSync()) return null;
    try {
      for (var entity in dir.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith(suffix)) {
          return entity.path;
        }
      }
    } catch (_) {}
    return null;
  }

  bool get isValid {
    if (type == 'asr') {
      return asrEncoderPath != null &&
          asrDecoderPath != null &&
          asrJoinerPath != null &&
          tokensPath != null;
    } else if (type == 'tts') {
      return (ttsModelPath != null || (ttsEncoderPath != null && ttsDecoderPath != null)) && tokensPath != null;
    } else if (type == 'nmt') {
      return nmtEncoderPath != null &&
          nmtDecoderPath != null &&
          nmtDecoderInitPath != null &&
          nmtVocabPath != null;
    } else if (type == 'llm') {
      return llmModelPath != null;
    } else if (type == 'simulst') {
      return File(p.join(path, 'speechllm_meta.json')).existsSync() &&
          File(p.join(path, 'metadata.json')).existsSync() &&
          File(p.join(path, 'init_states.npz')).existsSync() &&
          simulstGgufPath != null &&
          _hasSimulstSpecialTokenPatch;
    }
    return false;
  }

  // Calculate total size of the model directory (or single file for file-based LLM).
  Future<int> getDirectorySize() async {
    // File-based storage: return the single file's size directly.
    final file = File(path);
    if (file.existsSync()) {
      try {
        return await file.length();
      } catch (_) {
        return 0;
      }
    }
    // Legacy: directory-based.
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    int totalSize = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
    } catch (_) {}
    return totalSize;
  }

  // Get list of all files in the model directory (or the single file for file-based LLM) with their sizes.
  Future<List<Map<String, dynamic>>> getFilesWithSize() async {
    // File-based storage: return a single entry for the .gguf file.
    final file = File(path);
    if (file.existsSync()) {
      try {
        final size = await file.length();
        return [{
          'name': p.basename(path),
          'size': size,
        }];
      } catch (_) {
        return [];
      }
    }
    // Legacy: directory-based.
    final dir = Directory(path);
    if (!dir.existsSync()) return [];
    List<Map<String, dynamic>> files = [];
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final size = await entity.length();
          final relativePath = p.relative(entity.path, from: path);
          files.add({
            'name': relativePath,
            'size': size,
          });
        }
      }
    } catch (_) {}
    // Sort files by name
    files.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return files;
  }
}

class ModelManager {
  static final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  static void notifyChange() {
    changeNotifier.value++;
  }

  static Future<Directory> getModelsRoot() async {
    final appSupport = await getApplicationSupportDirectory();
    final root = Directory(p.join(appSupport.path, 'models'));
    if (!root.existsSync()) {
      root.createSync(recursive: true);
    }
    return root;
  }

  static Future<Directory> getTypeRoot(String type) async {
    final root = await getModelsRoot();
    final typeRoot = Directory(p.join(root.path, type));
    if (!typeRoot.existsSync()) {
      typeRoot.createSync(recursive: true);
    }
    return typeRoot;
  }

  static Future<List<ModelInfo>> getModels(String type) async {
    final typeRoot = await getTypeRoot(type);
    final List<ModelInfo> models = [];

    if (!typeRoot.existsSync()) return models;

    try {
      if (type == 'simulst') {
        // SpeechLLM export bundles: models/simulst/{model-name}/
        final modelEntities = typeRoot.listSync(recursive: false);
        for (var modelEntity in modelEntities) {
          if (modelEntity is Directory) {
            final modelName = p.basename(modelEntity.path);
            final modelInfo = ModelInfo(
              name: modelName,
              language: 'multi',
              path: modelEntity.path,
              type: type,
            );
            if (modelInfo.isValid) {
              models.add(modelInfo);
            }
          }
        }
      } else if (type == 'llm') {
        // LLM models can be stored as:
        //   1) Direct .gguf files: models/llm/{model-name}.gguf  (new, file-based)
        //   2) Directories:        models/llm/{model-name}/       (legacy)
        // A single LLM model supports all language pairs.
        final modelEntities = typeRoot.listSync(recursive: false);
        final Set<String> seenModelNames = {};

        // 1) Scan for loose .gguf files (new file-based format).
        for (var modelEntity in modelEntities) {
          if (modelEntity is File && modelEntity.path.endsWith('.gguf')) {
            final modelName = p.basenameWithoutExtension(modelEntity.path);
            if (!seenModelNames.contains(modelName)) {
              seenModelNames.add(modelName);
              final modelInfo = ModelInfo(
                name: modelName,
                language: 'multi',
                path: modelEntity.path, // points directly to the .gguf file
                type: type,
              );
              if (modelInfo.isValid) {
                models.add(modelInfo);
              }
            }
          }
        }

        // 2) Scan for directories (legacy directory-based format).
        for (var modelEntity in modelEntities) {
          if (modelEntity is Directory) {
            final modelName = p.basename(modelEntity.path);
            if (!seenModelNames.contains(modelName)) {
              seenModelNames.add(modelName);
              final modelInfo = ModelInfo(
                name: modelName,
                language: 'multi', // supports all language pairs
                path: modelEntity.path,
                type: type,
              );
              if (modelInfo.isValid) {
                models.add(modelInfo);
              }
            }
          }
        }
      } else {
        // ASR/TTS/NMT: models/{type}/{language-pair}/{model-name}/
        final langEntities = typeRoot.listSync(recursive: false);
        for (var langEntity in langEntities) {
          if (langEntity is Directory) {
            final language = p.basename(langEntity.path);
            final modelEntities = langEntity.listSync(recursive: false);
            for (var modelEntity in modelEntities) {
              if (modelEntity is Directory) {
                final modelName = p.basename(modelEntity.path);
                final modelInfo = ModelInfo(
                  name: modelName,
                  language: language,
                  path: modelEntity.path,
                  type: type,
                );
                if (modelInfo.isValid) {
                  models.add(modelInfo);
                }
              }
            }
          }
        }
      }
    } catch (e) {
      print('Error scanning models: $e');
    }

    return models;
  }

  static Future<void> importModelFromDirectory({
    required String srcPath,
    required String type,
    required String language,
    required String modelName,
    Function(double)? onProgress,
  }) async {
    final typeRoot = await getTypeRoot(type);
    final destPath = (type == 'llm' || type == 'simulst')
        ? p.join(typeRoot.path, modelName)
        : p.join(typeRoot.path, language, modelName);
    final destDir = Directory(destPath);
    if (destDir.existsSync()) {
      await destDir.delete(recursive: true);
    }
    await destDir.create(recursive: true);

    final srcDir = Directory(srcPath);
    final files = srcDir.listSync(recursive: true);

    // First find base path in the source directory (ignoring macOS metadata/junk files)
    String? basePath;
    for (var entity in files) {
      if (entity is File) {
        final pathLower = entity.path.toLowerCase();
        final nameLower = p.basename(entity.path).toLowerCase();
        if (pathLower.contains('__macosx') || nameLower.startsWith('._') || nameLower == '.ds_store') {
          continue;
        }
        if (entity.path.endsWith('.onnx') || entity.path.endsWith('.gguf')) {
          basePath = p.dirname(entity.path);
          break;
        }
      }
    }
    basePath ??= srcPath;

    // Collect all relative paths
    final relativePaths = <String>[];
    final fileEntities = <String, File>{};

    for (var entity in files) {
      if (entity is File) {
        final normalizedPath = p.normalize(entity.path);
        final pathLower = normalizedPath.toLowerCase();
        final nameLower = p.basename(normalizedPath).toLowerCase();
        if (pathLower.contains('__macosx') || nameLower.startsWith('._') || nameLower == '.ds_store') {
          continue;
        }
        final normalizedBase = p.normalize(basePath);

        if (normalizedPath.startsWith(normalizedBase)) {
          var sub = normalizedPath.substring(normalizedBase.length);
          if (sub.startsWith('/') || sub.startsWith('\\')) {
            sub = sub.substring(1);
          }
          if (sub.isNotEmpty) {
            relativePaths.add(sub);
            fileEntities[sub] = entity;
          }
        }
      }
    }

    final importMap = _resolveImportFiles(relativePaths, type);

    int completed = 0;
    int total = importMap.length;

    for (var entry in importMap.entries) {
      final srcRelPath = entry.key;
      final destRelPath = entry.value;
      final entity = fileEntities[srcRelPath];

      if (entity != null) {
        final destEntityPath = p.join(destPath, destRelPath);
        await File(destEntityPath).create(recursive: true);
        await entity.copy(destEntityPath);
      }

      completed++;
      if (onProgress != null && total > 0) {
        onProgress(completed / total);
      }
    }

    // Detect and write casing info to metadata.json during import
    final tokensFile = File(p.join(destPath, 'tokens.txt'));
    if (tokensFile.existsSync()) {
      final casing = ModelInfo._detectTokensCasing(tokensFile);
      final metaFile = File(p.join(destPath, 'metadata.json'));
      Map<String, dynamic> metaData = {};
      if (metaFile.existsSync()) {
        try {
          metaData = Map<String, dynamic>.from(jsonDecode(metaFile.readAsStringSync()));
        } catch (_) {}
      }
      metaData['casing'] = casing;
      metaFile.writeAsStringSync(jsonEncode(metaData));
    }

    notifyChange();
  }

  static Future<void> importModelFromArchive({
    required String archivePath,
    required String type,
    required String language,
    required String modelName,
    Function(double)? onProgress,
  }) async {
    final typeRoot = await getTypeRoot(type);
    final String destPath = (type == 'llm' || type == 'simulst')
        ? p.join(typeRoot.path, modelName)
        : p.join(typeRoot.path, language, modelName);
    if (type == 'llm') {
      // For LLM, destPath is a file: ensure parent directory exists.
      final parentDir = Directory(p.dirname(destPath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
    } else {
      final destDir = Directory(destPath);
      if (destDir.existsSync()) {
        await destDir.delete(recursive: true);
      }
      await destDir.create(recursive: true);
    }

    final bytes = await File(archivePath).readAsBytes();
    final Archive archive;
    final pathLower = archivePath.toLowerCase();

    if (pathLower.endsWith('.zip')) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else if (pathLower.endsWith('.tar.gz') || pathLower.endsWith('.tgz') || pathLower.endsWith('.gz')) {
      final tarBytes = GZipDecoder().decodeBytes(bytes);
      archive = TarDecoder().decodeBytes(tarBytes);
    } else if (pathLower.endsWith('.tar.bz2') || pathLower.endsWith('.tbz2') || pathLower.endsWith('.bz2')) {
      final tarBytes = BZip2Decoder().decodeBytes(bytes);
      archive = TarDecoder().decodeBytes(tarBytes);
    } else if (pathLower.endsWith('.tar')) {
      archive = TarDecoder().decodeBytes(bytes);
    } else {
      throw Exception('Unsupported archive format: ${p.extension(archivePath)}');
    }

    // Find base path in archive (ignoring macOS metadata/junk files)
    String? basePath;
    for (final file in archive) {
      if (file.isFile) {
        final pathLower = file.name.toLowerCase();
        final nameLower = p.basename(file.name).toLowerCase();
        if (pathLower.contains('__macosx') || nameLower.startsWith('._') || nameLower == '.ds_store') {
          continue;
        }
        if (file.name.endsWith('.onnx') || file.name.endsWith('.gguf')) {
          basePath = p.dirname(file.name);
          break;
        }
      }
    }

    if (basePath == '.' || basePath == null) {
      basePath = '';
    } else {
      basePath = p.normalize(basePath);
      if (basePath == '.') {
        basePath = '';
      }
    }

    // Collect all relative paths
    final relativePaths = <String>[];
    final archiveFiles = <String, ArchiveFile>{};

    for (final file in archive) {
      if (file.isFile) {
        final normalizedFilePath = p.normalize(file.name);
        final pathLower = normalizedFilePath.toLowerCase();
        final nameLower = p.basename(normalizedFilePath).toLowerCase();
        if (pathLower.contains('__macosx') || nameLower.startsWith('._') || nameLower == '.ds_store') {
          continue;
        }
        String relativePath = '';
        if (basePath.isEmpty) {
          relativePath = normalizedFilePath;
        } else {
          if (normalizedFilePath.startsWith(basePath)) {
            var sub = normalizedFilePath.substring(basePath.length);
            if (sub.startsWith('/') || sub.startsWith('\\')) {
              sub = sub.substring(1);
            }
            relativePath = sub;
          }
        }
        if (relativePath.isNotEmpty) {
          relativePaths.add(relativePath);
          archiveFiles[relativePath] = file;
        }
      }
    }

    final importMap = _resolveImportFiles(relativePaths, type);

    if (type == 'llm') {
      // For LLM, extract only the .gguf file directly to the dest file path.
      final ggufEntry = importMap.entries.firstWhere(
        (e) => e.value.endsWith('.gguf'),
        orElse: () => const MapEntry('', ''),
      );
      if (ggufEntry.key.isNotEmpty) {
        final archiveFile = archiveFiles[ggufEntry.key];
        if (archiveFile != null) {
          final data = archiveFile.content as List<int>;
          final outFile = File(destPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(data);
          if (onProgress != null) {
            onProgress(1.0);
          }
        }
      }
    } else {
      int completed = 0;
      int total = importMap.length;

      for (var entry in importMap.entries) {
        final srcRelPath = entry.key;
        final destRelPath = entry.value;
        final file = archiveFiles[srcRelPath];

        if (file != null) {
          final outPath = p.join(destPath, destRelPath);
          final data = file.content as List<int>;
          final outFile = File(outPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(data);
        }

        completed++;
        if (onProgress != null && total > 0) {
          onProgress(completed / total);
        }
      }
    }

    // Detect and write casing info to metadata.json during import (not for LLM).
    if (type != 'llm') {
      final tokensFile = File(p.join(destPath, 'tokens.txt'));
      if (tokensFile.existsSync()) {
        final casing = ModelInfo._detectTokensCasing(tokensFile);
        final metaFile = File(p.join(destPath, 'metadata.json'));
        Map<String, dynamic> metaData = {};
        if (metaFile.existsSync()) {
          try {
            metaData = Map<String, dynamic>.from(jsonDecode(metaFile.readAsStringSync()));
          } catch (_) {}
        }
        metaData['casing'] = casing;
        metaFile.writeAsStringSync(jsonEncode(metaData));
      }
    }

    notifyChange();
  }

  /// Import a single .gguf file as an LLM model.
  /// Copies the source file to models/llm/{modelName}.gguf.
  static Future<void> importLlmGgufFile({
    required String sourceFilePath,
    required String modelName,
    Function(double)? onProgress,
  }) async {
    final typeRoot = await getTypeRoot('llm');
    final destPath = p.join(typeRoot.path, '$modelName.gguf');

    final srcFile = File(sourceFilePath);
    if (!srcFile.existsSync()) {
      throw Exception('Source .gguf file not found: $sourceFilePath');
    }

    final destFile = File(destPath);
    if (destFile.existsSync()) {
      await destFile.delete();
    }
    await destFile.create(recursive: true);
    await srcFile.copy(destPath);

    if (onProgress != null) {
      onProgress(0.5);
      onProgress(1.0);
    }

    notifyChange();
  }

  static Map<String, String> _resolveImportFiles(List<String> srcPaths, String type) {
    final result = <String, String>{};

    // Group ONNX files by category
    final onnxFiles = srcPaths.where((p) => p.toLowerCase().endsWith('.onnx')).toList();

    List<String> encoders = [];
    List<String> decoders = [];
    List<String> joiners = [];
    List<String> models = [];

    for (final path in onnxFiles) {
      final name = p.basename(path).toLowerCase();
      if (name.startsWith('encoder')) {
        encoders.add(path);
      } else if (name.startsWith('decoder')) {
        decoders.add(path);
      } else if (name.startsWith('joiner')) {
        joiners.add(path);
      } else if (name.startsWith('model') || type == 'tts') {
        models.add(path);
      }
    }

    String? selectBest(List<String> files, String type) {
      if (files.isEmpty) return null;
      if (type == 'tts') {
        // Prioritize non-int8 files for TTS to avoid quality degradation
        final nonInt8Files = files.where((f) {
          final base = p.basename(f).toLowerCase();
          return !base.contains('.int8') && !base.contains('int8');
        }).toList();
        if (nonInt8Files.isNotEmpty) {
          return nonInt8Files.first;
        }
        return files.first;
      } else {
        // Prioritize files containing ".int8" or "int8" for other types (ASR, NMT)
        final int8Files = files.where((f) {
          final base = p.basename(f).toLowerCase();
          return base.contains('.int8') || base.contains('int8');
        }).toList();
        if (int8Files.isNotEmpty) {
          return int8Files.first;
        }
        return files.first;
      }
    }

    final bestEncoder = selectBest(encoders, type);
    final bestDecoder = selectBest(decoders, type);
    final bestJoiner = selectBest(joiners, type);
    final bestModel = selectBest(models, type);

    if (type == 'asr') {
      if (bestEncoder != null) result[bestEncoder] = 'encoder.onnx';
      if (bestDecoder != null) result[bestDecoder] = 'decoder.onnx';
      if (bestJoiner != null) result[bestJoiner] = 'joiner.onnx';
    } else if (type == 'nmt') {
      if (bestEncoder != null) result[bestEncoder] = 'encoder.onnx';
      if (bestDecoder != null) {
        // decoder.onnx may have an external data companion (.onnx.data)
        result[bestDecoder] = 'decoder.onnx';
        // Also carry over any .onnx.data file for the decoder
        final decoderDataFile = srcPaths.firstWhere(
          (sp) => p.basename(sp) == 'decoder.onnx.data',
          orElse: () => '',
        );
        if (decoderDataFile.isNotEmpty) {
          result[decoderDataFile] = 'decoder.onnx.data';
        }
        // Also carry over the decoder init model
        final initFile = srcPaths.firstWhere(
          (sp) => p.basename(sp) == 'decoder_init.onnx',
          orElse: () => '',
        );
        if (initFile.isNotEmpty) {
          result[initFile] = 'decoder_init.onnx';
        }
      }
    } else if (type == 'tts') {
      if (bestEncoder != null && bestDecoder != null) {
        result[bestEncoder] = 'encoder.onnx';
        result[bestDecoder] = 'decoder.onnx';
      } else {
        final bestTtsModel = selectBest(onnxFiles, type);
        if (bestTtsModel != null) {
          result[bestTtsModel] = 'model.onnx';
        }
      }
    } else if (type == 'simulst') {
      for (final path in srcPaths) {
        final name = p.basename(path);
        final lower = name.toLowerCase();
        if (lower.endsWith('.json') ||
            lower.endsWith('.npz') ||
            lower.endsWith('.gguf') ||
            lower.endsWith('.onnx') ||
            lower.endsWith('.bin') ||
            lower.endsWith('.onnx.data')) {
          result[path] = name;
        }
      }
    }

    // Keep other resource files
    for (final path in srcPaths) {
      final name = p.basename(path).toLowerCase();
      final segments = p.split(p.normalize(path));

      if (name == 'tokens.txt') {
        result[path] = 'tokens.txt';
      } else if (name == 'vocab.json') {
        result[path] = 'vocab.json';
      } else if (name == 'source.spm') {
        result[path] = 'source.spm';
      } else if (name == 'target.spm') {
        result[path] = 'target.spm';
      } else if (name == 'config.json') {
        result[path] = 'config.json';
      } else if (name == 'chat_template.json') {
        result[path] = 'chat_template.json';
      } else if (name.endsWith('.gguf')) {
        result[path] = name;  // Keep GGUF filename as-is
      } else if (name == 'lexicon.txt') {
        result[path] = 'lexicon.txt';
      } else if (name.endsWith('.fst')) {
        result[path] = name;
      } else if (segments.contains('dict')) {
        final idx = segments.indexOf('dict');
        final subPath = p.joinAll(segments.sublist(idx));
        result[path] = subPath;
      } else if (segments.contains('espeak-ng-data')) {
        final idx = segments.indexOf('espeak-ng-data');
        final subPath = p.joinAll(segments.sublist(idx));
        result[path] = subPath;
      }
    }

    return result;
  }

  static Future<void> deleteModel(ModelInfo model) async {
    // File-based LLM: delete the single .gguf file.
    final file = File(model.path);
    if (file.existsSync()) {
      await file.delete();
    } else {
      final dir = Directory(model.path);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    }
    notifyChange();
  }

  static Future<void> renameModel(ModelInfo model, String newName) async {
    // File-based LLM: rename the .gguf file, preserving its extension.
    if (model.type == 'llm' && model.path.endsWith('.gguf')) {
      final file = File(model.path);
      if (!file.existsSync()) {
        throw Exception('Model file does not exist.');
      }
      final parentPath = p.dirname(model.path);
      final newPath = p.join(parentPath, '$newName.gguf');
      final newFile = File(newPath);
      if (newFile.existsSync()) {
        throw Exception('A model named "$newName" already exists.');
      }
      await file.rename(newPath);
      notifyChange();
      return;
    }

    // Legacy: directory-based rename.
    final oldDir = Directory(model.path);
    if (!oldDir.existsSync()) {
      throw Exception('Model directory does not exist.');
    }

    final parentPath = p.dirname(model.path);
    final newPath = p.join(parentPath, newName);
    final newDir = Directory(newPath);

    if (newDir.existsSync()) {
      throw Exception('A model named "$newName" already exists.');
    }

    await oldDir.rename(newPath);
    notifyChange();
  }

  static Future<void> ensureEspeakDataExtractor() async {
    final appSupport = await getApplicationSupportDirectory();
    final espeakDir = Directory(p.join(appSupport.path, 'espeak-ng-data'));
    final sentinelFile = File(p.join(espeakDir.path, '.complete'));

    if (espeakDir.existsSync() && sentinelFile.existsSync()) {
      return; // Already extracted successfully
    }

    // Clean up partial or corrupted directory if it exists
    if (espeakDir.existsSync()) {
      try {
        await espeakDir.delete(recursive: true);
      } catch (e) {
        print('Failed to delete incomplete espeak-ng-data directory: $e');
      }
    }

    try {
      final bytes = await rootBundle.load('assets/espeak-ng-data.zip');
      final archiveBytes = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      final archive = ZipDecoder().decodeBytes(archiveBytes);

      for (final file in archive) {
        final filename = file.name;
        final outPath = p.join(appSupport.path, filename);

        if (file.isFile) {
          final data = file.content as List<int>;
          final outFile = File(outPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(data);
        } else {
          final outDir = Directory(outPath);
          await outDir.create(recursive: true);
        }
      }

      // Create sentinel file to indicate success
      await sentinelFile.create(recursive: true);
      await sentinelFile.writeAsString('extracted');
      print('espeak-ng-data extracted successfully to ${espeakDir.path}');
    } catch (e) {
      print('Failed to extract espeak-ng-data: $e');
    }
  }

  static Future<String> ensureSileroVad() async {
    final appSupport = await getApplicationSupportDirectory();
    final file = File(p.join(appSupport.path, 'silero_vad.onnx'));
    if (file.existsSync()) {
      return file.path;
    }

    try {
      final bytes = await rootBundle.load('assets/silero_vad.onnx');
      final list = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      await file.create(recursive: true);
      await file.writeAsBytes(list);
      print('silero_vad.onnx extracted successfully to ${file.path}');
    } catch (e) {
      print('Failed to extract silero_vad.onnx: $e');
    }
    return file.path;
  }
}
