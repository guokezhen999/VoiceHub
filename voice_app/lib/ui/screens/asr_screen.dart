import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:voice_app/services/asr_service.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';
import 'package:voice_app/ffi/voice_engine_ffi_bridge.dart';

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
  bool _isConfigExpanded = true;

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
    setState(() {
      _isConfigExpanded = true;
    });
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

      setState(() {
        _isConfigExpanded = false;
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
    if (!_asr.isInitialized) return;

    try {
      if (await _audioRecorder.hasPermission()) {
        await _asr.reset();

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

    if (_asr.isInitialized) {
      final r = await _asr.flushAndPoll();
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

    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F9),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
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
                        Icon(Icons.mic_rounded, size: 26, color: Color(0xFF1E3C72)),
                        SizedBox(width: 8),
                        Text(
                          'ASR Speech Recognition',
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
                                        'ASR Model Setup',
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
                                              color: _asr.isInitialized ? Colors.green.shade50 : Colors.grey.shade100,
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: _asr.isInitialized ? Colors.green.shade200 : Colors.grey.shade300),
                                            ),
                                            child: Text(
                                              _asr.isInitialized
                                                  ? 'Initialized: ${_selectedModel?.name ?? ""}'
                                                  : 'Not Initialized',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: _asr.isInitialized ? Colors.green.shade700 : Colors.grey.shade600,
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
                                          'No local ASR models found. Please click the model repository icon to import one.',
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
                                        if (_asr.isInitialized) {
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
                                    : (_asr.isInitialized ? _deinitializeEngine : _initializeEngine),
                                icon: Icon(
                                  _asr.isInitialized
                                      ? Icons.power_settings_new_rounded
                                      : Icons.flash_on_rounded,
                                  color: Colors.white,
                                ),
                                label: Text(
                                  _asr.isInitialized ? 'Deinitialize ASR Engine' : 'Initialize ASR Engine',
                                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _asr.isInitialized ? Colors.red.shade600 : const Color(0xFF1E3C72),
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

                    // --- Transcript Results Card ---
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
                            'Recognized Transcript',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF2D3748),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_asr.isInitialized) ...[
                            TextField(
                              controller: _transcriptController,
                              maxLines: 8,
                              readOnly: true,
                              style: const TextStyle(fontSize: 15, height: 1.4, color: Color(0xFF2D3748)),
                              decoration: InputDecoration(
                                hintText: _recordState != RecordState.stop
                                    ? 'Listening...'
                                    : 'Transcript will appear here...',
                                hintStyle: TextStyle(color: Colors.grey.shade400),
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
                          ] else ...[
                            Container(
                              height: 120,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              child: const Text(
                                'Please initialize the engine first to start recognition.',
                                style: TextStyle(color: Colors.grey),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            if (_asr.isInitialized) _buildMicControlPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildMicControlPanel() {
    final isRecording = _recordState != RecordState.stop;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 16,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isRecording ? 'Listening and Transcribing...' : 'Ready to Record',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // 1. Clear Button
              SizedBox(
                width: 52,
                height: 52,
                child: IconButton(
                  onPressed: (_sentences.isEmpty && _currentResult.isEmpty) ? null : _clearTranscript,
                  icon: const Icon(Icons.delete_outline, size: 26),
                  color: Colors.red.shade400,
                  disabledColor: Colors.grey.shade300,
                  tooltip: 'Clear Transcript',
                ),
              ),

              // 2. Microphone Button
              GestureDetector(
                onTap: () {
                  if (isRecording) {
                    _stopRecording();
                  } else {
                    _startRecording();
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isRecording
                          ? [Colors.red.shade600, Colors.red.shade400]
                          : [const Color(0xFF1E3C72), const Color(0xFF2A5298)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (isRecording ? Colors.red.shade300 : const Color(0xFF1E3C72)).withOpacity(0.4),
                        blurRadius: isRecording ? 20 : 12,
                        spreadRadius: isRecording ? 4 : 1,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Icon(
                    isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),

              // 3. Balanced Spacer
              const SizedBox(width: 52, height: 52),
            ],
          ),
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
