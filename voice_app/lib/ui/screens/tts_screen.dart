import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';
import 'package:voice_app/services/tts_service.dart';

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
  final TtsService _ttsService = TtsService();
  double _speed = 1.0;
  bool _isSpeaking = false;
  bool _isInitializing = false;
  bool _isConfigExpanded = true;

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
    if (_ttsService.isInitialized) {
      _deinitializeEngine();
    }
  }

  void _deinitializeEngine() {
    _ttsService.deinitialize();
    setState(() {
      _isConfigExpanded = true;
    });
  }

  Future<void> _initializeEngine() async {
    if (_ttsService.isInitialized) return;
    if (_selectedModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please import/select a TTS model first!')),
      );
      return;
    }

    setState(() {
      _isInitializing = true;
    });

    try {
      await _ttsService.initialize(_selectedModel!);

      setState(() {
        _selectedSpeakerId = 0;
        _isConfigExpanded = false;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('TTS Engine initialized: ${_selectedModel!.name}')),
      );
    } catch (e) {
      debugPrint('TTS Init Error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to initialize TTS: $e')),
      );
    } finally {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  Future<void> _speak() async {
    if (!_ttsService.isInitialized) {
      await _initializeEngine();
    }
    if (_ttsService.tts == null) return;

    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text to speak.')),
      );
      return;
    }

    final sid = _selectedSpeakerId;

    try {
      _logsController.value = const TextEditingValue(text: 'Synthesizing...');
      await _audioPlayer.stop();

      int chunkCount = 0;

      final result = await _ttsService.synthesize(
        text: text,
        model: _selectedModel!,
        speakerId: sid,
        speed: _speed,
        prefix: 'tts',
        suffix: '-sid-$sid-speed-${_speed.toStringAsFixed(1)}',
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

      setState(() {
        _logsController.value = TextEditingValue(
          text: 'WAV Saved to: ${result.wavPath}\n'
              'Inference Speed Details:\n'
              ' - Elapsed Time: ${result.elapsedSec.toStringAsFixed(3)} s\n'
              ' - Audio Duration: ${result.audioDurationSec.toStringAsFixed(3)} s\n'
              ' - RTF (Real-Time Factor): ${result.rtf.toStringAsFixed(3)}\n',
        );
      });

      await _audioPlayer.play(DeviceFileSource(result.wavPath));
    } catch (e) {
      debugPrint('TTS speak error: $e');
      _logsController.value = TextEditingValue(text: 'Error: $e');
    }
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

    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F9),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Title ---
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.record_voice_over_rounded, size: 26, color: Color(0xFF1E3C72)),
                  SizedBox(width: 8),
                  Text(
                    'TTS Speech Synthesis',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3748),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              // --- Config Card ---
              Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() {
                          _isConfigExpanded = !_isConfigExpanded;
                        });
                      },
                      child: Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                const Text(
                                  'TTS Model Setup',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF2D3748),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  _isConfigExpanded
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  color: Colors.grey.shade600,
                                  size: 20,
                                ),
                                if (!_isConfigExpanded) ...[
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: _ttsService.isInitialized ? Colors.green.shade50 : Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: _ttsService.isInitialized ? Colors.green.shade200 : Colors.grey.shade300),
                                      ),
                                      child: Text(
                                        _ttsService.isInitialized
                                            ? 'Initialized: ${_selectedModel?.name ?? ""}'
                                            : 'Not Initialized',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: _ttsService.isInitialized ? Colors.green.shade700 : Colors.grey.shade600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _openModelManagement,
                            icon: const Icon(Icons.inventory_2_outlined, color: Color(0xFF1E3C72)),
                            tooltip: 'Model Repository',
                          ),
                        ],
                      ),
                    ),
                    if (_isConfigExpanded) ...[
                      const SizedBox(height: 10),

                      if (_loadingModels)
                        const Center(child: CircularProgressIndicator())
                      else ...[
                        if (availableLanguages.isEmpty) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              border: Border.all(color: Colors.orange.shade200),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.warning_rounded, color: Colors.orange.shade600),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'No local TTS models found. Please click the model repository icon to import one.',
                                    style: TextStyle(fontSize: 12, color: Color(0xFFC05621)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ] else ...[
                          const Text(
                            'Select Language:',
                            style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            value: _selectedLanguage,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFF1E3C72), width: 2),
                              ),
                              isDense: true,
                            ),
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

                          const Text(
                            'Select Model:',
                            style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<ModelInfo>(
                            value: _selectedModel,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFF1E3C72), width: 2),
                              ),
                              isDense: true,
                            ),
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
                                    _textController.text = 'こんにちは！这是在 Flutter で sherpa-onnx を使用したオフライン音声合成のデモです。';
                                  } else if (lang == 'vietnamese') {
                                    _textController.text = 'Xin chào! Đây là bản thử nghiệm tổng hợp giọng nói ngoại tuyến sử dụng sherpa-onnx trong Flutter.';
                                  } else {
                                    _textController.text = 'Hello! This is a real-time text-to-speech demonstration powered by sherpa-onnx in Flutter.';
                                  }
                                  if (_ttsService.isInitialized) {
                                    _deinitializeEngine();
                                  }
                                });
                              }
                            },
                          ),
                        ],
                      ],
                      const SizedBox(height: 16),
                      
                      // Init / Deinit Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _selectedModel == null
                              ? null
                              : (_ttsService.isInitialized ? _deinitializeEngine : _initializeEngine),
                          icon: Icon(
                            _ttsService.isInitialized
                                ? Icons.power_settings_new_rounded
                                : Icons.flash_on_rounded,
                            color: Colors.white,
                          ),
                          label: Text(
                            _ttsService.isInitialized ? 'Deinitialize TTS Engine' : 'Initialize TTS Engine',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _ttsService.isInitialized ? Colors.red.shade600 : const Color(0xFF1E3C72),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 2,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
              // --- Synthesizer Section ---
              if (_ttsService.isInitialized) ...[
                Container(
                  padding: const EdgeInsets.all(16.0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Voice Synthesis Controls',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D3748),
                        ),
                      ),
                      const SizedBox(height: 12),
                      
                      const Text(
                        'Select Speaker:',
                        style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<int>(
                        value: _selectedSpeakerId,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFF1E3C72), width: 2),
                          ),
                          isDense: true,
                        ),
                        items: List.generate(_ttsService.maxSpeakerId + 1, (index) {
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
                          Text(
                            'Speed: ${_speed.toStringAsFixed(1)}x',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
                          ),
                          Expanded(
                            child: Slider(
                              min: 0.5,
                              max: 2.0,
                              value: _speed,
                              activeColor: const Color(0xFF1E3C72),
                              inactiveColor: Colors.grey.shade200,
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

                      const Text(
                        'Text to Synthesize:',
                        style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _textController,
                        maxLines: 3,
                        style: const TextStyle(fontSize: 15, height: 1.4, color: Color(0xFF2D3748)),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isSpeaking ? _stop : _speak,
                          icon: Icon(
                            _isSpeaking ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                            color: Colors.white,
                          ),
                          label: Text(
                            _isSpeaking ? 'Stop Speaking' : 'Synthesize & Speak',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isSpeaking ? Colors.red.shade600 : const Color(0xFF1E3C72),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // --- Logs Section ---
                Container(
                  padding: const EdgeInsets.all(16.0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Inference statistics & Logs',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D3748),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _logsController,
                        maxLines: 4,
                        readOnly: true,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontFamily: 'monospace'),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          hintText: 'Inference statistics will appear here...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Container(
                  height: 120,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Text(
                    'Please initialize the engine first to start synthesis.',
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    ModelManager.changeNotifier.removeListener(_loadModels);
    _ttsService.deinitialize();
    _audioPlayer.dispose();
    super.dispose();
  }
}

