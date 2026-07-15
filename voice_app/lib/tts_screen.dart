import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'model_manager.dart';
import 'model_management_sheet.dart';

class TtsScreen extends StatefulWidget {
  const TtsScreen({Key? key}) : super(key: key);

  @override
  State<TtsScreen> createState() => _TtsScreenState();
}

class _TtsScreenState extends State<TtsScreen> {
  final TextEditingController _textController = TextEditingController(
      text: 'Hello! This is a real-time text-to-speech demonstration powered by sherpa-onnx in Flutter.');
  int _selectedSpeakerId = 0;
  final TextEditingController _logsController = TextEditingController();

  late final AudioPlayer _audioPlayer;
  bool _isInitialized = false;
  sherpa_onnx.OfflineTts? _tts;
  int _maxSpeakerID = 0;
  double _speed = 1.0;
  bool _isSpeaking = false;

  // Local model configurations
  List<ModelInfo> _allModels = [];
  String? _selectedLanguage;
  ModelInfo? _selectedModel;
  bool _loadingModels = true;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() {
        _isSpeaking = state == PlayerState.playing;
      });
    });
    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
    });
    final models = await ModelManager.getModels('tts');
    setState(() {
      _allModels = models;
      _loadingModels = false;

      final availableLanguages = _allModels.expand((m) => m.languages).toSet().toList();
      // Handle language selection logic
      if (_selectedLanguage == null || !availableLanguages.contains(_selectedLanguage)) {
        if (availableLanguages.isNotEmpty) {
          _selectedLanguage = availableLanguages.first;
        } else {
          _selectedLanguage = null;
        }
      }
      _updateSelectedModel();
    });
  }

  void _updateSelectedModel() {
    final languageModels = _allModels.where((m) => m.languages.contains(_selectedLanguage)).toList();
    if (languageModels.isNotEmpty) {
      if (_selectedModel == null || !_selectedModel!.languages.contains(_selectedLanguage)) {
        _selectedModel = languageModels.first;
      } else {
        // Keep selected if still valid
        final stillExists = languageModels.any((m) => m.path == _selectedModel!.path);
        if (!stillExists) {
          _selectedModel = languageModels.first;
        }
      }
    } else {
      _selectedModel = null;
    }

    // Set default text based on language
    if (_selectedModel != null) {
      final lang = _selectedLanguage?.toLowerCase() ?? '';
      if (lang == 'chinese') {
        _textController.text = '你好！这是在 Flutter 中使用 sherpa-onnx 运行的离线文本转语音演示。';
      } else if (lang == 'cantonese') {
        _textController.text = '你好！呢度係喺 Flutter 中使用 sherpa-onnx 運行嘅離線廣東話語音合成演示。';
      } else if (lang == 'japanese') {
        _textController.text = 'こんにちは！これは Flutter で sherpa-onnx を使用したオフライン音声合成のデモです。';
      } else if (lang == 'vietnamese') {
        _textController.text = 'Xin chào! Đây là bản thử nghiệm tổng hợp giọng nói ngoại tuyến sử dụng sherpa-onnx trong Flutter.';
      } else {
        _textController.text = 'Hello! This is a real-time text-to-speech demonstration powered by sherpa-onnx in Flutter.';
      }
    }

    // De-initialize if active model changes
    if (_isInitialized) {
      _deinitializeEngine();
    }
  }

  void _deinitializeEngine() {
    _tts?.free();
    _tts = null;
    setState(() {
      _isInitialized = false;
      _maxSpeakerID = 0;
    });
  }

  Future<void> _initializeEngine() async {
    if (_isInitialized) return;
    if (_selectedModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please import/select a TTS model first!')),
      );
      return;
    }

    try {
      sherpa_onnx.initBindings();

      final encoderPath = _selectedModel!.ttsEncoderPath;
      final decoderPath = _selectedModel!.ttsDecoderPath;
      final isSplit = encoderPath != null && decoderPath != null;

      final tokensPath = _selectedModel!.tokensPath!;
      final lexiconPath = _selectedModel!.lexiconPath ?? '';
      final ruleFsts = _selectedModel!.ruleFsts;

      // The espeak-ng data_dir is ONLY for phoneme-based VITS models
      // (piper/coqui/icefall) that lack a lexicon. Feeding it to jieba/lexicon
      // models such as melo or fanchen corrupts synthesis (truncated,
      // non-deterministic audio), so we only resolve it when no lexicon exists.
      var dataDir = '';
      if (lexiconPath.isEmpty) {
        dataDir = _selectedModel!.ttsDataDirPath ?? '';
        if (dataDir.isEmpty) {
          final appSupport = await getApplicationSupportDirectory();
          final globalEspeakDir = Directory(p.join(appSupport.path, 'espeak-ng-data'));
          if (globalEspeakDir.existsSync()) {
            dataDir = globalEspeakDir.path;
          }
        }
      }

      final sherpa_onnx.OfflineTtsModelConfig modelConfig;

      if (isSplit && _selectedModel!.ttsEngineType == 'matcha') {
        final matcha = sherpa_onnx.OfflineTtsMatchaModelConfig(
          acousticModel: encoderPath,
          vocoder: decoderPath,
          lexicon: lexiconPath,
          tokens: tokensPath,
          dataDir: dataDir,
        );
        modelConfig = sherpa_onnx.OfflineTtsModelConfig(
          numThreads: 2,
          matcha: matcha,
        );
      } else if (isSplit && _selectedModel!.ttsEngineType == 'vits_online') {
        // Pass directory path so C++ auto-detection (offline-tts-impl.cc)
        // finds encoder.onnx/decoder.onnx and routes to OnlineTtsVitsImpl.
        final vits = sherpa_onnx.OfflineTtsVitsModelConfig(
          model: _selectedModel!.path,
          lexicon: lexiconPath,
          tokens: tokensPath,
          dataDir: dataDir,
          dictDir: _selectedModel!.ttsDictDirPath ?? '',
        );
        modelConfig = sherpa_onnx.OfflineTtsModelConfig(
          numThreads: 2,
          vits: vits,
        );
      } else {
        final modelPath = _selectedModel!.ttsModelPath ?? '';
        if (modelPath.isEmpty) {
          throw Exception('VITS model file not found in directory ${_selectedModel!.path}');
        }
        final vits = sherpa_onnx.OfflineTtsVitsModelConfig(
          model: modelPath,
          lexicon: lexiconPath,
          tokens: tokensPath,
          dataDir: dataDir,
          dictDir: _selectedModel!.ttsDictDirPath ?? '',
        );
        modelConfig = sherpa_onnx.OfflineTtsModelConfig(
          numThreads: 2,
          vits: vits,
        );
      }

      final config = sherpa_onnx.OfflineTtsConfig(
        model: modelConfig,
        ruleFsts: ruleFsts,
      );

      _tts = sherpa_onnx.OfflineTts(config);

      setState(() {
        _maxSpeakerID = _tts?.numSpeakers ?? 0;
        if (_maxSpeakerID > 0) {
          _maxSpeakerID -= 1;
        }
        _selectedSpeakerId = 0;
        _isInitialized = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('TTS Engine initialized: ${_selectedModel!.name}')),
      );
    } catch (e) {
      debugPrint('TTS Init Error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to initialize TTS: $e')),
      );
    }
  }

  Future<String> _generateWavFilename(String suffix) async {
    final dir = await getTemporaryDirectory();
    final name = 'tts-${DateTime.now().millisecondsSinceEpoch}$suffix.wav';
    return p.join(dir.path, name);
  }

  Future<void> _speak() async {
    if (!_isInitialized) {
      await _initializeEngine();
    }
    if (_tts == null) return;

    var text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text to speak.')),
      );
      return;
    }

    final encoderPath = _selectedModel!.ttsEncoderPath;
    final decoderPath = _selectedModel!.ttsDecoderPath;
    final isSplit = encoderPath != null && decoderPath != null;

    if (isSplit) {
      text = _selectedModel!.normalizeText(text);
      debugPrint('[TTS] Text after online normalization: $text');
    } else {
      text = _convertFullWidthToHalfWidth(text);
      debugPrint('[TTS] Text after offline converting full-width to half-width: $text');
    }

    final sid = _selectedSpeakerId;

    try {
      _logsController.value = const TextEditingValue(text: 'Synthesizing...');
      await _audioPlayer.stop();

      final stopwatch = Stopwatch()..start();

      final genConfig = sherpa_onnx.OfflineTtsGenerationConfig(
        sid: sid,
        speed: _speed,
        silenceScale: 0.2,
      );

      int chunkCount = 0;
      final audio = _tts!.generateWithConfig(
        text: text,
        config: genConfig,
        onProgress: (samples, progress) {
          chunkCount++;
          setState(() {
            _logsController.value = TextEditingValue(
              text: 'Synthesizing...\n'
                  ' - Generated Chunk #$chunkCount\n'
                  ' - Chunk Size: ${samples.length} samples\n'
                  ' - Progressive Progress: ${(progress * 100).toStringAsFixed(1)}%\n',
            );
          });
          return 1; // 1 to continue generation
        },
      );
      
      final suffix = '-sid-$sid-speed-${_speed.toStringAsFixed(1)}';
      final filename = await _generateWavFilename(suffix);

      // Ensure parent directory exists on disk before C++ std::ofstream writes to it
      final file = File(filename);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }

      debugPrint('[TTS] Writing WAV: filename=$filename, samples=${audio.samples.length}, sampleRate=${audio.sampleRate}');
      // Write PCM data to a temporary WAV file
      final ok = sherpa_onnx.writeWave(
        filename: filename,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      if (ok) {
        stopwatch.stop();
        final elapsed = stopwatch.elapsed.inMilliseconds / 1000.0;
        final waveDuration = audio.samples.length / audio.sampleRate;
        final rtf = elapsed / waveDuration;

        setState(() {
          _logsController.value = TextEditingValue(
            text: 'WAV Saved to: $filename\n'
                'Inference Speed Details:\n'
                ' - Elapsed Time: ${elapsed.toStringAsFixed(3)} s\n'
                ' - Audio Duration: ${waveDuration.toStringAsFixed(3)} s\n'
                ' - RTF (Real-Time Factor): ${rtf.toStringAsFixed(3)}\n',
          );
        });

        // Play the generated WAV file
        await _audioPlayer.play(DeviceFileSource(filename));
      } else {
        _logsController.value = const TextEditingValue(text: 'Failed to save synthesized WAV file.');
      }
    } catch (e) {
      debugPrint('TTS speak error: $e');
      _logsController.value = TextEditingValue(text: 'Error: $e');
    }
  }

  String _convertFullWidthToHalfWidth(String text) {
    var result = text;
    final fullToHalf = {
      '，': ',',
      '。': '.',
      '！': '!',
      '？': '?',
      '：': ':',
      '；': ';',
      '（': '(',
      '）': ')',
      '【': '[',
      '】': ']',
      '《': '<',
      '》': '>',
      '“': '"',
      '”': '"',
      '‘': "'",
      '’': "'",
      '、': ',',
      '—': '-',
      '～': '~',
      '　': ' ',
    };
    fullToHalf.forEach((full, half) {
      result = result.replaceAll(full, half);
    });
    return result;
  }

  Future<void> _stop() async {
    await _audioPlayer.stop();
  }

  void _openModelManagement() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: 'tts',
        onModelsChanged: _loadModels,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final availableLanguages = _allModels.expand((m) => m.languages).toSet().toList();
    final languageModels = _allModels.where((m) => m.languages.contains(_selectedLanguage)).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'TTS Speech Synthesis',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          
          // Config Card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'TTS Model Setup',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      IconButton(
                        onPressed: _openModelManagement,
                        icon: const Icon(Icons.settings, color: Colors.blue),
                        tooltip: 'Manage Local Models',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (_loadingModels)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    if (availableLanguages.isEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange[50],
                          border: Border.all(color: Colors.orange[200]!),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning, color: Colors.orange),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'No local TTS models found. Please click the settings icon to import one.',
                                style: TextStyle(fontSize: 12, color: Colors.orange),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      // Language selection Dropdown
                      const Text('Select Language:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<String>(
                        value: _selectedLanguage,
                        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                        items: availableLanguages.map((lang) {
                          return DropdownMenuItem(value: lang, child: Text(lang));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _selectedLanguage = val;
                              _updateSelectedModel();
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),

                      // Model selection Dropdown
                      const Text('Select Model:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<ModelInfo>(
                        value: _selectedModel,
                        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                        items: languageModels.map((model) {
                          return DropdownMenuItem(value: model, child: Text(model.name));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _selectedModel = val;
                              final lang = _selectedModel!.language.toLowerCase();
                              if (lang == 'chinese') {
                                _textController.text = '你好！这是在 Flutter 中使用 sherpa-onnx 运行的离线文本转语音演示。';
                              } else if (lang == 'cantonese') {
                                _textController.text = '你好！呢度係喺 Flutter 中使用 sherpa-onnx 運行嘅離線廣东话語音合成演示。';
                              } else if (lang == 'japanese') {
                                _textController.text = 'こんにちは！これは Flutter で sherpa-onnx を使用したオフライン音声合成のデモです。';
                              } else if (lang == 'vietnamese') {
                                _textController.text = 'Xin chào! Đây là bản thử nghiệm tổng hợp giọng nói ngoại tuyến sử dụng sherpa-onnx trong Flutter.';
                              } else {
                                _textController.text = 'Hello! This is a real-time text-to-speech demonstration powered by sherpa-onnx in Flutter.';
                              }
                              if (_isInitialized) {
                                _deinitializeEngine();
                              }
                            });
                          }
                        },
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Init / Deinit Button
          ElevatedButton(
            onPressed: _selectedModel == null
                ? null
                : (_isInitialized ? _deinitializeEngine : _initializeEngine),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(14),
              backgroundColor: _isInitialized ? Colors.red : Colors.blue,
              foregroundColor: Colors.white,
            ),
            child: Text(_isInitialized ? 'Deinitialize TTS Engine' : 'Initialize TTS Engine'),
          ),
          const SizedBox(height: 20),
          
          const Divider(),
          const SizedBox(height: 10),
          
          // Synthesizer Section
          if (_isInitialized) ...[
            DropdownButtonFormField<int>(
              value: _selectedSpeakerId,
              decoration: const InputDecoration(
                labelText: 'Select Speaker',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: List.generate(_maxSpeakerID + 1, (index) {
                return DropdownMenuItem(
                  value: index,
                  child: Text('Speaker $index'),
                );
              }),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedSpeakerId = val;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Speed: ${_speed.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 14)),
                Expanded(
                  child: Slider(
                    min: 0.5,
                    max: 2.0,
                    value: _speed,
                    onChanged: (value) {
                      setState(() {
                        _speed = value;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Text to Synthesize:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _textController,
              maxLines: 3,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isSpeaking ? _stop : _speak,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isSpeaking ? Colors.red : Colors.green,
                      padding: const EdgeInsets.all(14),
                    ),
                    child: Text(_isSpeaking ? 'Stop Speaking' : 'Synthesize & Speak'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('Logs / Performance Details:', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _logsController,
              maxLines: 4,
              readOnly: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Inference statistics will appear here...'),
            ),
          ] else ...[
            const Text(
              'Please initialize the engine first to start synthesis.',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ]
        ],
      ),
    );
  }

  @override
  void dispose() {
    ModelManager.changeNotifier.removeListener(_loadModels);
    _tts?.free();
    _audioPlayer.dispose();
    super.dispose();
  }
}

