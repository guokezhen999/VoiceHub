import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:record/record.dart';
import 'package:voice_app/ffi/simulst_ffi_bridge.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/services/simulst_service.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';
import 'package:voice_app/services/vad_settings.dart';
import 'package:voice_app/services/advanced_settings.dart';

import 'package:voice_app/services/simulst_history_store.dart';
import 'package:voice_app/services/audio_file_history_store.dart';
import 'package:voice_app/ui/widgets/audio_file_history_sheet.dart';
import 'package:voice_app/ui/widgets/responsive_bilingual_text.dart';
import 'package:voice_app/models/subtitle_segment.dart';

class _SimulstSegmentRow {
  String transcript;
  String translation;
  double start;
  double end;

  _SimulstSegmentRow({
    this.transcript = '',
    this.translation = '',
    this.start = 0.0,
    this.end = 0.0,
  });
}

class SimultaneousTranslationScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const SimultaneousTranslationScreen({Key? key, this.showPerfMetrics = false})
      : super(key: key);

  @override
  State<SimultaneousTranslationScreen> createState() =>
      _SimultaneousTranslationScreenState();
}

class _SimultaneousTranslationScreenState
    extends State<SimultaneousTranslationScreen> {
  final SimulstService _simulst = SimulstService();
  late final AudioRecorder _audioRecorder;

  StreamSubscription<RecordState>? _recordSub;
  StreamSubscription<Uint8List>? _audioStreamSub;
  RecordState _recordState = RecordState.stop;

  final TextEditingController _transcriptController = TextEditingController();
  final TextEditingController _translationController = TextEditingController();

  late final ScrollController _pageScrollController;
  late final ScrollController _outputScrollController;

  List<ModelInfo> _models = [];
  ModelInfo? _selectedModel;
  bool _loadingModels = true;
  bool _isConfigExpanded = true;
  bool _isInitializing = false;

  String _transcribeLang = 'auto';
  String _translateLang = 'English';
  bool _enableTranscribe = true;
  bool _enableTranslate = true;
  int _numChunks = 1;

  final List<_SimulstSegmentRow> _segments = [];
  String _partialTranscript = '';
  String _partialTranslation = '';
  bool _userScrolledUp = false;
  int _currentSessionStartIndex = 0;

  final List<Float32List> _sessionAudioChunks = [];
  int _recordedSampleCount = 0;

  @override
  void initState() {
    super.initState();
    _pageScrollController = ScrollController();
    _outputScrollController = ScrollController();
    _outputScrollController.addListener(_onScroll);
    _audioRecorder = AudioRecorder();
    _recordSub = _audioRecorder.onStateChanged().listen((state) {
      setState(() => _recordState = state);
    });
    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  @override
  void dispose() {
    ModelManager.changeNotifier.removeListener(_loadModels);
    _recordSub?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    _transcriptController.dispose();
    _translationController.dispose();
    _pageScrollController.dispose();
    _outputScrollController.dispose();
    _simulst.deinitialize();
    super.dispose();
  }

  Future<void> _loadModels() async {
    setState(() => _loadingModels = true);
    final models = await ModelManager.getModels('simulst');
    setState(() {
      _models = models;
      _loadingModels = false;
      if (_selectedModel == null ||
          !_models.any((m) => m.path == _selectedModel!.path)) {
        _selectedModel = _models.isNotEmpty ? _models.first : null;
      }
      if (_simulst.isInitialized) {
        _deinitializeEngine();
      }
    });
  }

  void _deinitializeEngine() {
    _simulst.deinitialize();
    setState(() => _isConfigExpanded = true);
  }

  Future<void> _initializeEngine() async {
    if (_selectedModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please import a SpeechLLM model first.')),
      );
      return;
    }
    if (!_enableTranscribe && !_enableTranslate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enable transcription or translation.')),
      );
      return;
    }

    setState(() => _isInitializing = true);
    try {
      await _simulst.initialize(
        model: _selectedModel!,
        enableTranscribe: _enableTranscribe,
        enableTranslate: _enableTranslate,
        transcribeLang: _transcribeLang,
        translateLang: _translateLang,
        numChunks: _numChunks,
        repetitionPenalty: AdvancedSettings.repetitionPenalty,
        vadThreshold: VadSettings.simulstMode.threshold,
        vadMinSilenceDuration: VadSettings.simulstMode.minSilenceDuration,
        vadMinSpeechDuration: VadSettings.simulstMode.minSpeechDuration,
      );
      setState(() {
        _isConfigExpanded = false;
        _segments.clear();
        _partialTranscript = '';
        _partialTranslation = '';
        _updateDisplays();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Engine initialized: ${_selectedModel!.name}')),
        );
      }
    } catch (e) {
      _simulst.deinitialize();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isInitializing = false);
    }
  }

  Future<void> _applyTaskSettings() async {
    if (!_simulst.isInitialized) return;
    try {
      final ok = await _simulst.updateTasks(
        enableTranscribe: _enableTranscribe,
        enableTranslate: _enableTranslate,
        transcribeLang: _transcribeLang,
        translateLang: _translateLang,
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Runtime task update is unavailable. Please reinitialize the engine.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update tasks: $e')),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    if (!_simulst.isInitialized || _simulst.handle == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please initialize the engine first.')),
      );
      return;
    }
    if (!await _audioRecorder.hasPermission()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is required.')),
      );
      return;
    }

    try {
      _sessionAudioChunks.clear();
      _recordedSampleCount = 0;
      await _simulst.reset();
      setState(() {
        _currentSessionStartIndex = _segments.length;
        _partialTranscript = '';
        _partialTranslation = '';
        _userScrolledUp = false;
        _updateDisplays();
      });

      _audioStreamSub = await _simulst.startStream(
        _audioRecorder,
        _onPoll,
        onAudioSamples: (samples) {
          _sessionAudioChunks.add(samples);
          _recordedSampleCount += samples.length;
        },
      );
    } catch (e) {
      debugPrint('Simulst recording error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start recording: $e')),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    final sub = _audioStreamSub;
    if (sub == null) return;
    _audioStreamSub = null; // Prevent double trigger immediately

    // Continue recording for a short delay to capture the final spoken speech tail (real audio)
    await Future.delayed(const Duration(milliseconds: 600));

    await sub.cancel();
    await _audioRecorder.stop();

    if (_simulst.handle != null) {
      final pollResult = await _simulst.flushAndPoll();
      _onPoll(pollResult);
    }

    setState(() {
      if (_partialTranscript.isNotEmpty || _partialTranslation.isNotEmpty) {
        final segEnd = _recordedSampleCount / 16000.0;
        final segStart = (segEnd - 2.0).clamp(0.0, segEnd);
        _segments.add(_SimulstSegmentRow(
          transcript: _partialTranscript,
          translation: _partialTranslation,
          start: segStart,
          end: segEnd,
        ));
      }
      _partialTranscript = '';
      _partialTranslation = '';
      _updateDisplays();
    });

    _checkAndSaveHistory();
  }

  void _onPoll(SimulstPollResult r) {
    setState(() {
      if (r.segments.isNotEmpty) {
        for (final seg in r.segments) {
          final transcript = seg.transcript.trim();
          final translation = seg.translation.trim();
          if (transcript.isEmpty && translation.isEmpty) continue;

          double segStart = seg.start;
          double segEnd = seg.end;
          if (segEnd <= segStart) {
            segEnd = _recordedSampleCount / 16000.0;
            segStart = (segEnd - 2.0).clamp(0.0, segEnd);
          }

          _segments.add(_SimulstSegmentRow(
            transcript: transcript,
            translation: translation,
            start: segStart,
            end: segEnd,
          ));
        }
        _partialTranscript = '';
        _partialTranslation = '';
      } else {
        for (final t in r.finalizedTranscripts) {
          final text = t.trim();
          if (text.isEmpty) continue;
          final segEnd = _recordedSampleCount / 16000.0;
          final segStart = (segEnd - 2.0).clamp(0.0, segEnd);
          _segments.add(_SimulstSegmentRow(
            transcript: text,
            start: segStart,
            end: segEnd,
          ));
        }
        for (final t in r.finalizedTranslations) {
          final text = t.trim();
          if (text.isEmpty) continue;
          if (_segments.isNotEmpty &&
              _segments.length - 1 >= _currentSessionStartIndex &&
              _segments.last.translation.isEmpty) {
            _segments.last.translation = text;
          } else {
            final segEnd = _recordedSampleCount / 16000.0;
            final segStart = (segEnd - 2.0).clamp(0.0, segEnd);
            _segments.add(_SimulstSegmentRow(
              translation: text,
              start: segStart,
              end: segEnd,
            ));
          }
        }
      }

      if (_enableTranscribe) {
        _partialTranscript = r.partialTranscript.trim();
      } else {
        _partialTranscript = '';
      }
      if (_enableTranslate) {
        _partialTranslation = r.partialTranslation.trim();
      } else {
        _partialTranslation = '';
      }
      _updateDisplays();
    });
  }

  Float32List _buildVadAudioSamples() {
    int totalMicSamples = 0;
    for (final chunk in _sessionAudioChunks) {
      totalMicSamples += chunk.length;
    }
    if (totalMicSamples == 0 || _segments.isEmpty) {
      return Float32List(1600);
    }

    final allMicSamples = Float32List(totalMicSamples);
    int offset = 0;
    for (final chunk in _sessionAudioChunks) {
      allMicSamples.setAll(offset, chunk);
      offset += chunk.length;
    }

    double maxEnd = 0.0;
    for (final seg in _segments) {
      if (seg.end > maxEnd) maxEnd = seg.end;
    }
    if (maxEnd <= 0.0) {
      maxEnd = totalMicSamples / 16000.0;
    }

    final int totalVadSamples = (maxEnd * 16000).ceil();
    final vadSamples = Float32List(totalVadSamples);

    for (final seg in _segments) {
      final int startIdx = (seg.start * 16000).floor().clamp(0, totalMicSamples);
      final int endIdx = (seg.end * 16000).ceil().clamp(startIdx, totalMicSamples);

      if (endIdx > startIdx) {
        final int targetStart = (seg.start * 16000).floor().clamp(0, vadSamples.length);
        final int lengthToCopy = (endIdx - startIdx).clamp(0, vadSamples.length - targetStart);

        for (int i = 0; i < lengthToCopy; i++) {
          vadSamples[targetStart + i] = allMicSamples[startIdx + i];
        }
      }
    }

    return vadSamples;
  }

  Future<void> _checkAndSaveHistory() async {
    if (_segments.isEmpty) return;

    try {
      final id = SimulstHistoryStore.newId();
      final vadSamples = _buildVadAudioSamples();
      final audioPath = await SimulstHistoryStore.saveVadAudioWav(
        id: id,
        samples: vadSamples,
      );

      final subtitles = <SubtitleSegment>[];
      for (int i = 0; i < _segments.length; i++) {
        final seg = _segments[i];
        subtitles.add(SubtitleSegment(
          index: i + 1,
          start: seg.start,
          end: seg.end > seg.start ? seg.end : seg.start + 1.0,
          originalText: seg.transcript,
          translatedText: seg.translation,
        ));
      }

      final double totalDuration = subtitles.isNotEmpty ? subtitles.last.end : 0.0;
      final now = DateTime.now();

      final session = AudioFileHistorySession(
        id: id,
        createdAt: now,
        updatedAt: now,
        fileName: '同声传译_${_formatSessionTime(now)}',
        sourceLang: _transcribeLang,
        targetLang: _translateLang,
        duration: totalDuration,
        audioPath: audioPath,
        subtitles: subtitles,
      );

      await SimulstHistoryStore.save(session);
      debugPrint('Simultaneous translation history saved: $id');
    } catch (e) {
      debugPrint('Failed to save simulst translation history: $e');
    }
  }

  String _formatSessionTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}_${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
  }

  void _openHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AudioFileHistorySheet(
        title: '同声传译历史记录',
        subtitle: '浏览同声传译历史，回放 VAD 识别语音段与对应字幕',
        fetchItems: SimulstHistoryStore.list,
        loadSession: SimulstHistoryStore.load,
        deleteItem: SimulstHistoryStore.delete,
        renameItem: SimulstHistoryStore.rename,
      ),
    );
  }

  void _clearResults() {
    setState(() {
      _segments.clear();
      _partialTranscript = '';
      _partialTranslation = '';
      _userScrolledUp = false;
      _updateDisplays();
    });
  }

  void _onScroll() {
    if (_outputScrollController.hasClients) {
      final position = _outputScrollController.position;
      final isAtBottom = position.pixels >= position.maxScrollExtent - 10;
      if (isAtBottom) {
        if (_userScrolledUp) {
          setState(() {
            _userScrolledUp = false;
          });
        }
      } else {
        if (position.userScrollDirection != ScrollDirection.idle) {
          if (!_userScrolledUp) {
            setState(() {
              _userScrolledUp = true;
            });
          }
        }
      }
    }
  }

  void _scrollToBottom() {
    if (_outputScrollController.hasClients) {
      final position = _outputScrollController.position;

      // If the user has scrolled up, do not force scroll to bottom
      if (_userScrolledUp) {
        return;
      }

      // Check if the user is currently at the bottom (within a 10px tolerance)
      // before the new layout rendering occurs.
      final isAtBottom = position.pixels >= position.maxScrollExtent - 10;
      final shouldScroll = isAtBottom || position.maxScrollExtent == 0;

      if (shouldScroll) {
        Future.delayed(const Duration(milliseconds: 50), () {
          if (_outputScrollController.hasClients) {
            _outputScrollController.animateTo(
              _outputScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }
  }

  void _updateDisplays() {
    final combinedLines = <String>[];

    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final segmentLines = <String>[];
      if (_enableTranscribe && seg.transcript.isNotEmpty) {
        segmentLines.add(_removeSpacesBetweenChinese(seg.transcript));
      }
      if (_enableTranslate && seg.translation.isNotEmpty) {
        segmentLines.add(_removeSpacesBetweenChinese(seg.translation));
      }
      if (segmentLines.isNotEmpty) {
        combinedLines.add(segmentLines.join('\n'));
      }
    }

    final partialLines = <String>[];
    if (_partialTranscript.isNotEmpty && _enableTranscribe) {
      partialLines.add(_removeSpacesBetweenChinese(_partialTranscript));
    }
    if (_partialTranslation.isNotEmpty && _enableTranslate) {
      partialLines.add(_removeSpacesBetweenChinese(_partialTranslation));
    }
    if (partialLines.isNotEmpty) {
      combinedLines.add(partialLines.join('\n'));
    }

    final combinedText = combinedLines.join('\n\n');

    _transcriptController.value = TextEditingValue(
      text: combinedText,
      selection: TextSelection.collapsed(offset: combinedText.length),
    );

    _scrollToBottom();
  }

  String _removeSpacesBetweenChinese(String text) {
    // Remove spaces between Chinese characters/punctuation
    final regExp = RegExp(
        r'(?<=[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef])\s+(?=[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef])');
    return text.replaceAll(regExp, '');
  }

  void _openModelManagement() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: 'simulst',
        onModelsChanged: _loadModels,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = _recordState != RecordState.stop;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F9),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _pageScrollController,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.hearing_rounded,
                                  size: 26, color: Color(0xFF1E3C72)),
                              const SizedBox(width: 8),
                              Flexible(
                                child: ResponsiveBilingualText(
                                  english: 'Simultaneous Interpretation',
                                  chinese: '同声传译',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF2D3748),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: _openHistory,
                          icon: const Icon(Icons.history_rounded, color: Color(0xFF1E3C72)),
                          tooltip: 'History',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildConfigCard(),
                    const SizedBox(height: 16),
                    if (_simulst.isInitialized) ...[
                      _buildOutputCard(
                        title: 'Interpretation Results',
                        enabled: true,
                        hint: isRecording ? 'Listening & Translating...' : 'Results appear here...',
                      ),
                    ] else
                      _buildPlaceholderCard(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            if (_simulst.isInitialized) _buildMicPanel(isRecording),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigCard() {
    return Container(
      padding: const EdgeInsets.all(16),
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
            onTap: () => setState(() => _isConfigExpanded = !_isConfigExpanded),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Engine Settings',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3748),
                    ),
                  ),
                ),
                Icon(
                  _isConfigExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: Colors.grey.shade600,
                ),
                IconButton(
                  onPressed: _openModelManagement,
                  icon: const Icon(Icons.inventory_2_outlined,
                      color: Color(0xFF1E3C72)),
                  tooltip: 'Model Repository',
                ),
              ],
            ),
          ),
          if (_isConfigExpanded) ...[
            const SizedBox(height: 12),
            if (_loadingModels)
              const Center(child: CircularProgressIndicator())
            else if (_models.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: const Text(
                  'No SpeechLLM model installed.\n'
                  'Import a simulst export bundle via the model repository.',
                  style: TextStyle(color: Color(0xFFC05621), fontSize: 12),
                ),
              )
            else ...[
              const Text(
                'SpeechLLM Model',
                style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<ModelInfo>(
                value: _selectedModel,
                isExpanded: true,
                decoration: _inputDecoration(),
                items: _models
                    .map((m) => DropdownMenuItem(value: m, child: Text(m.name)))
                    .toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedModel = val;
                    if (_simulst.isInitialized) _deinitializeEngine();
                  });
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Streaming Latency (num_chunks)',
                style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<int>(
                value: _numChunks,
                isExpanded: true,
                decoration: _inputDecoration(),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1 (Low Latency / Fast)')),
                  DropdownMenuItem(value: 2, child: Text('2 (Medium Latency)')),
                  DropdownMenuItem(value: 4, child: Text('4 (High Latency / Better Quality)')),
                ],
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _numChunks = val;
                    if (_simulst.isInitialized) _deinitializeEngine();
                  });
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Transcribe', style: TextStyle(fontSize: 13)),
                      value: _enableTranscribe,
                      onChanged: (v) {
                        setState(() => _enableTranscribe = v ?? false);
                        _applyTaskSettings();
                      },
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ),
                  Expanded(
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Translate', style: TextStyle(fontSize: 13)),
                      value: _enableTranslate,
                      onChanged: (v) {
                        setState(() => _enableTranslate = v ?? false);
                        _applyTaskSettings();
                      },
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ),
                ],
              ),
              if (_enableTranscribe) ...[
                const Text(
                  'Source Language (transcribe)',
                  style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: _transcribeLang,
                  isExpanded: true,
                  decoration: _inputDecoration(),
                  items: [
                    const DropdownMenuItem(value: 'auto', child: Text('Auto detect')),
                    ...LanguageManager.languages.map(
                      (lang) => DropdownMenuItem(value: lang, child: Text(lang)),
                    ),
                  ],
                  onChanged: (val) {
                    if (val == null) return;
                    setState(() => _transcribeLang = val);
                    _applyTaskSettings();
                  },
                ),
                const SizedBox(height: 12),
              ],
              if (_enableTranslate) ...[
                const Text(
                  'Target Language (translate)',
                  style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: _translateLang,
                  isExpanded: true,
                  decoration: _inputDecoration(),
                  items: LanguageManager.languages
                      .map((lang) => DropdownMenuItem(value: lang, child: Text(lang)))
                      .toList(),
                  onChanged: (val) {
                    if (val == null) return;
                    setState(() => _translateLang = val);
                    _applyTaskSettings();
                  },
                ),
                const SizedBox(height: 12),
              ],
            ],
            if (_selectedModel != null) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isInitializing
                      ? null
                      : (_simulst.isInitialized
                          ? _deinitializeEngine
                          : _initializeEngine),
                  icon: _isInitializing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(
                          _simulst.isInitialized
                              ? Icons.power_settings_new_rounded
                              : Icons.flash_on_rounded,
                          color: Colors.white,
                        ),
                  label: Text(
                    _simulst.isInitialized
                        ? 'Deinitialize Engine'
                        : 'Initialize Engine',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _simulst.isInitialized
                        ? Colors.red.shade600
                        : const Color(0xFF1E3C72),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildOutputCard({
    required String title,
    required bool enabled,
    required String hint,
  }) {
    if (!enabled) return const SizedBox.shrink();

    // Collect all elements to display
    final widgets = <Widget>[];

    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final segmentWidgets = <Widget>[];
      
      if (_enableTranscribe && seg.transcript.isNotEmpty) {
        segmentWidgets.add(
          Text(
            _removeSpacesBetweenChinese(seg.transcript),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Color(0xFF4A5568), // Transcription: Charcoal
              height: 1.4,
            ),
          ),
        );
      }
      
      if (_enableTranslate && seg.translation.isNotEmpty) {
        if (segmentWidgets.isNotEmpty) {
          segmentWidgets.add(const SizedBox(height: 4));
        }
        segmentWidgets.add(
          Text(
            _removeSpacesBetweenChinese(seg.translation),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1E3C72), // Translation: Deep Indigo/Blue
              height: 1.4,
            ),
          ),
        );
      }

      if (segmentWidgets.isNotEmpty) {
        widgets.add(
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: segmentWidgets,
            ),
          ),
        );
      }
    }

    // Append partial (in-progress) segment
    final partialWidgets = <Widget>[];
    if (_partialTranscript.isNotEmpty && _enableTranscribe) {
      partialWidgets.add(
        Text(
          _removeSpacesBetweenChinese(_partialTranscript),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF4A5568).withOpacity(0.5), // Faded transcription
            height: 1.4,
          ),
        ),
      );
    }

    if (_partialTranslation.isNotEmpty && _enableTranslate) {
      if (partialWidgets.isNotEmpty) {
        partialWidgets.add(const SizedBox(height: 4));
      }
      partialWidgets.add(
        Text(
          _removeSpacesBetweenChinese(_partialTranslation),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF1E3C72).withOpacity(0.5), // Faded translation
            height: 1.4,
          ),
        ),
      );
    }

    if (partialWidgets.isNotEmpty) {
      widgets.add(
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.shade50.withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.shade100.withOpacity(0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: partialWidgets,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
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
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3748),
            ),
          ),
          const SizedBox(height: 12),
          if (widgets.isEmpty)
            Container(
              height: 200,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Text(
                hint,
                style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
              ),
            )
          else
            Container(
              height: 480,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Scrollbar(
                controller: _outputScrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _outputScrollController,
                  physics: const BouncingScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: widgets,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderCard() {
    return Container(
      height: 160,
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
        'Initialize the engine to start simultaneous interpretation.',
        style: TextStyle(color: Colors.grey),
        textAlign: TextAlign.center,
      ),
    );
  }

  InputDecoration _inputDecoration() {
    return InputDecoration(
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
    );
  }

  Widget _buildMicPanel(bool isRecording) {
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
            isRecording ? 'Listening & Translating...' : 'Ready to Record',
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              SizedBox(
                width: 52,
                height: 52,
                child: IconButton(
                  onPressed: (_segments.isEmpty &&
                          _partialTranscript.isEmpty &&
                          _partialTranslation.isEmpty)
                      ? null
                      : _clearResults,
                  icon: const Icon(Icons.delete_outline, size: 26),
                  color: Colors.red.shade400,
                  disabledColor: Colors.grey.shade300,
                  tooltip: 'Clear',
                ),
              ),
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
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (isRecording
                                ? Colors.red.shade300
                                : const Color(0xFF1E3C72))
                            .withOpacity(0.4),
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
              const SizedBox(width: 52, height: 52),
            ],
          ),
        ],
      ),
    );
  }
}
