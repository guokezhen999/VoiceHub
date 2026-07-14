import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'utils.dart';
import 'model_manager.dart';
import 'model_management_sheet.dart';
import 'voice_engine_ffi_bridge.dart';

class AsrScreen extends StatefulWidget {
  const AsrScreen({Key? key}) : super(key: key);

  @override
  State<AsrScreen> createState() => _AsrScreenState();
}

class _AsrScreenState extends State<AsrScreen> {
  final TextEditingController _transcriptController = TextEditingController();

  late final AudioRecorder _audioRecorder;
  StreamSubscription<RecordState>? _recordSub;
  StreamSubscription<Uint8List>? _audioStreamSub;
  RecordState _recordState = RecordState.stop;

  bool _isInitialized = false;
  bool _isOfflineModel = false;
  Pointer<Void>? _handle;

  List<String> _sentences = [];
  String _currentResult = "";
  int _sentenceIndex = 0;

  // Local model configurations
  List<ModelInfo> _allModels = [];
  String? _selectedLanguage;
  ModelInfo? _selectedModel;
  bool _loadingModels = true;

  static const List<String> _leadingPuncs = [
    '，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';',
  ];

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _recordSub = _audioRecorder.onStateChanged().listen((recordState) {
      setState(() {
        _recordState = recordState;
      });
    });
    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
    });
    final models = await ModelManager.getModels('asr');
    setState(() {
      _allModels = models;
      _loadingModels = false;

      final availableLanguages =
          _allModels.expand((m) => m.languages).toSet().toList();
      if (_selectedLanguage == null ||
          !availableLanguages.contains(_selectedLanguage)) {
        _selectedLanguage =
            availableLanguages.isNotEmpty ? availableLanguages.first : null;
      }
      _updateSelectedModel();
    });
  }

  void _updateSelectedModel() {
    final languageModels =
        _allModels.where((m) => m.languages.contains(_selectedLanguage)).toList();
    if (languageModels.isNotEmpty) {
      if (_selectedModel == null ||
          !_selectedModel!.languages.contains(_selectedLanguage)) {
        _selectedModel = languageModels.first;
      } else {
        final stillExists =
            languageModels.any((m) => m.path == _selectedModel!.path);
        if (!stillExists) {
          _selectedModel = languageModels.first;
        }
      }
    } else {
      _selectedModel = null;
    }
    if (_isInitialized) {
      _deinitializeEngine();
    }
  }

  void _deinitializeEngine() {
    if (_handle != null) {
      VoiceEngineBridge.instance.destroy(_handle!);
      _handle = null;
    }
    setState(() {
      _isInitialized = false;
    });
  }

  Future<void> _initializeEngine() async {
    if (_isInitialized) return;
    if (_selectedModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please import/select an ASR model first!')),
      );
      return;
    }

    try {
      await VoiceEngineBridge.init();

      final sileroModelPath = await ModelManager.ensureSileroVad();
      _isOfflineModel = !_selectedModel!.isStreamingASR;

      final config = {
        'mode': _isOfflineModel ? 'offline' : 'online',
        'encoder': _selectedModel!.asrEncoderPath!,
        'decoder': _selectedModel!.asrDecoderPath!,
        'joiner': _selectedModel!.asrJoinerPath!,
        'tokens': _selectedModel!.tokensPath!,
        'model_type': 'zipformer2',
        'decoding_method': 'greedy_search',
        'num_threads': 1,
        'vad': {
          'model': sileroModelPath,
          'threshold': 0.5,
          'min_silence_duration': 0.5,
          'min_speech_duration': 0.25,
          'window_size': 512,
          'max_speech_duration': 20.0,
          'sample_rate': 16000,
          'num_threads': 1,
          'buffer_size_seconds': 60.0,
        },
        'endpoint': {
          'enable': true,
          'rule1_min_trailing_silence': 2.4,
          'rule2_min_trailing_silence': 1.0,
        },
      };

      _handle = VoiceEngineBridge.instance.create(jsonEncode(config));

      setState(() {
        _isInitialized = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ASR Engine initialized: ${_selectedModel!.name}')),
      );
    } catch (e) {
      debugPrint('ASR Init Error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to initialize ASR: $e')),
      );
    }
  }

  Future<void> _startRecording() async {
    if (!_isInitialized || _handle == null) return;

    try {
      if (await _audioRecorder.hasPermission()) {
        const config = RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        );

        VoiceEngineBridge.instance.reset(_handle!);

        setState(() {
          _currentResult = "";
          _updateTranscript();
        });

        final audioStream = await _audioRecorder.startStream(config);

        _audioStreamSub = audioStream.listen((data) {
          if (_handle == null) return;

          final samples = convertBytesToFloat32(Uint8List.fromList(data));
          VoiceEngineBridge.instance.acceptWaveform(_handle!, samples);
          final r = VoiceEngineBridge.instance.poll(_handle!);
          _onPoll(r);
        });
      }
    } catch (e) {
      debugPrint('ASR Recording Error: $e');
    }
  }

  void _onPoll(VoiceEnginePollResult r) {
    setState(() {
      for (final f in r.finalized) {
        var text = _stripLeadingPuncs(f);
        text = _formatTextWithCasing(text);
        if (text.isNotEmpty) {
          _sentences.add(text);
          _sentenceIndex += 1;
        }
      }

      if (r.speaking) {
        _currentResult = r.partial.isEmpty
            ? "Speaking..."
            : _formatTextWithCasing(r.partial);
      } else {
        _currentResult = "";
      }
      _updateTranscript();
    });
  }

  static String _stripLeadingPuncs(String text) {
    while (text.isNotEmpty && _leadingPuncs.contains(text[0])) {
      text = text.substring(1);
    }
    return text;
  }

  Future<void> _stopRecording() async {
    await _audioStreamSub?.cancel();
    _audioStreamSub = null;
    await _audioRecorder.stop();

    if (_handle != null) {
      VoiceEngineBridge.instance.flush(_handle!);
      final r = VoiceEngineBridge.instance.poll(_handle!);
      _onPoll(r);
    }

    setState(() {
      _currentResult = "";
      _updateTranscript();
    });
  }

  String _formatTextWithCasing(String text) {
    final casing = _selectedModel?.casing ?? 'mixed';
    if (casing == 'mixed') return text;

    String lowercaseText = text.toLowerCase();
    StringBuffer result = StringBuffer();
    bool capitalizeNext = true;

    for (int i = 0; i < lowercaseText.length; i++) {
      String char = lowercaseText[i];
      if (capitalizeNext && RegExp(r'[a-zA-Z]').hasMatch(char)) {
        result.write(char.toUpperCase());
        capitalizeNext = false;
      } else {
        result.write(char);
        if (char == '.' || char == '。') {
          capitalizeNext = true;
        }
      }
    }
    return result.toString();
  }

  void _clearTranscript() {
    setState(() {
      _sentences = [];
      _currentResult = "";
      _sentenceIndex = 0;
      _updateTranscript();
    });
  }

  void _updateTranscript() {
    List<String> renderedSentences = List.from(_sentences);
    String renderedCurrent = _currentResult;

    while (renderedCurrent.isNotEmpty && _leadingPuncs.contains(renderedCurrent[0])) {
      renderedCurrent = renderedCurrent.substring(1);
    }

    String fullText = renderedSentences.asMap().entries.map((entry) {
      return '${entry.key}: ${entry.value}';
    }).join('\n');

    if (renderedCurrent.isNotEmpty) {
      if (fullText.isNotEmpty) fullText += '\n';
      fullText += '$_sentenceIndex: $renderedCurrent';
    }

    _transcriptController.value = TextEditingValue(
      text: fullText,
      selection: TextSelection.collapsed(offset: fullText.length),
    );
  }

  void _openModelManagement() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: 'asr',
        onModelsChanged: _loadModels,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final availableLanguages = _allModels.expand((m) => m.languages).toSet().toList();
    final languageModels =
        _allModels.where((m) => m.languages.contains(_selectedLanguage)).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'ASR Speech Recognition',
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
                        'ASR Model Setup',
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
                                'No local ASR models found. Please click the settings icon to import one.',
                                style: TextStyle(fontSize: 12, color: Colors.orange),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      const Text('Select Language:',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<String>(
                        value: _selectedLanguage,
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(), isDense: true),
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

                      const Text('Select Model:',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<ModelInfo>(
                        value: _selectedModel,
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(), isDense: true),
                        items: languageModels.map((model) {
                          return DropdownMenuItem(value: model, child: Text(model.name));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() {
                              _selectedModel = val;
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
            child: Text(_isInitialized ? 'Deinitialize ASR Engine' : 'Initialize ASR Engine'),
          ),
          const SizedBox(height: 20),

          const Divider(),
          const SizedBox(height: 10),

          // Controls & Log
          if (_isInitialized) ...[
            GestureDetector(
              onTap: () {
                if (_recordState != RecordState.stop) {
                  _stopRecording();
                } else {
                  _startRecording();
                }
              },
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _recordState != RecordState.stop ? Colors.red : Colors.blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_recordState != RecordState.stop ? Icons.stop : Icons.mic,
                        color: Colors.white),
                    const SizedBox(width: 10),
                    Text(
                      _recordState != RecordState.stop ? 'Stop Recording' : 'Start Live ASR',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Recognized Transcript:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _transcriptController,
              maxLines: 8,
              readOnly: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: _recordState != RecordState.stop
                    ? 'Listening...'
                    : 'Transcript will appear here...',
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                onPressed: _sentences.isEmpty && _currentResult.isEmpty
                    ? null
                    : _clearTranscript,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear Transcript'),
                style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
              ),
            ),
          ] else ...[
            const Text(
              'Please initialize the engine first to start recognition.',
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
    _recordSub?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    if (_handle != null) {
      VoiceEngineBridge.instance.destroy(_handle!);
      _handle = null;
    }
    super.dispose();
  }
}
