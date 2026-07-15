import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'asr_service.dart';
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

  final AsrService _asr = AsrService();

  List<String> _sentences = [];
  String _currentResult = "";
  int _sentenceIndex = 0;

  // Local model configurations
  List<ModelInfo> _allModels = [];
  String? _selectedLanguage;
  ModelInfo? _selectedModel;
  bool _loadingModels = true;

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
    if (_asr.isInitialized) {
      _deinitializeEngine();
    }
  }

  void _deinitializeEngine() {
    _asr.deinitialize();
    setState(() {});
  }

  Future<void> _initializeEngine() async {
    if (_asr.isInitialized) return;
    if (_selectedModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please import/select an ASR model first!')),
      );
      return;
    }

    try {
      await _asr.initialize(_selectedModel!);

      setState(() {});

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
    if (!_asr.isInitialized || _asr.handle == null) return;

    try {
      if (await _audioRecorder.hasPermission()) {
        _asr.reset();

        setState(() {
          _currentResult = "";
          _updateTranscript();
        });

        _audioStreamSub = await _asr.startStream(_audioRecorder, _onPoll);
      }
    } catch (e) {
      debugPrint('ASR Recording Error: $e');
    }
  }

  void _onPoll(VoiceEnginePollResult r) {
    setState(() {
      for (final f in r.finalized) {
        var text = AsrService.stripLeadingPuncs(f);
        text = AsrService.formatTextWithCasing(text, _selectedModel?.casing ?? 'mixed');
        if (text.isNotEmpty) {
          _sentences.add(text);
          _sentenceIndex += 1;
        }
      }

      if (r.speaking) {
        _currentResult = r.partial.isEmpty
            ? "Speaking..."
            : AsrService.formatTextWithCasing(r.partial, _selectedModel?.casing ?? 'mixed');
      } else {
        _currentResult = "";
      }
      _updateTranscript();
    });
  }

  Future<void> _stopRecording() async {
    await _audioStreamSub?.cancel();
    _audioStreamSub = null;
    await _audioRecorder.stop();

    if (_asr.handle != null) {
      final r = _asr.flushAndPoll();
      _onPoll(r);
    }

    setState(() {
      _currentResult = "";
      _updateTranscript();
    });
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

    while (renderedCurrent.isNotEmpty && AsrService.leadingPuncs.contains(renderedCurrent[0])) {
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
                              if (_asr.isInitialized) {
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
                : (_asr.isInitialized ? _deinitializeEngine : _initializeEngine),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(14),
              backgroundColor: _asr.isInitialized ? Colors.red : Colors.blue,
              foregroundColor: Colors.white,
            ),
            child: Text(_asr.isInitialized ? 'Deinitialize ASR Engine' : 'Initialize ASR Engine'),
          ),
          const SizedBox(height: 20),

          const Divider(),
          const SizedBox(height: 10),

          // Controls & Log
          if (_asr.isInitialized) ...[
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
    _asr.deinitialize();
    super.dispose();
  }
}
