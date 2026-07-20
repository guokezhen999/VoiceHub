import 'dart:async';
import 'dart:typed_data';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

import 'package:voice_app/services/asr_service.dart';
import 'package:voice_app/services/tts_service.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';
import 'package:voice_app/services/native_nmt_service.dart';
import 'package:voice_app/services/llama_nmt_service.dart';
import 'package:voice_app/services/nmt_service_common.dart';
import 'package:voice_app/ffi/voice_engine_ffi_bridge.dart';
import 'package:voice_app/main.dart'; // To access showPerfMetricsNotifier if needed

import 'package:voice_app/services/cascade_history_store.dart';
import 'package:voice_app/services/audio_file_history_store.dart';
import 'package:voice_app/ui/widgets/audio_file_history_sheet.dart';
import 'package:voice_app/models/subtitle_segment.dart';

/// A single segment pairing an ASR sentence with its MT translation.
class _CascadeSegment {
  String asr;
  String mt;
  double start;
  double end;
  _CascadeSegment({
    required this.asr,
    this.mt = '',
    this.start = 0.0,
    this.end = 0.0,
  });
}

class CascadeTranslationScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const CascadeTranslationScreen({Key? key, this.showPerfMetrics = false}) : super(key: key);

  @override
  State<CascadeTranslationScreen> createState() => _CascadeTranslationScreenState();
}

class _CascadeTranslationScreenState extends State<CascadeTranslationScreen> {
  // Services
  NmtBackend? _nmtBackend;
  late final AudioRecorder _audioRecorder;
  late final AudioPlayer _audioPlayer;

  // Stream Subscriptions for Recording
  StreamSubscription<RecordState>? _recordSub;
  StreamSubscription<Uint8List>? _audioStreamSub;

  // ASR Engine State
  final AsrService _asr = AsrService();

  // MT Engine State — isLoaded is tracked via _nmtBackend?.isLoaded

  // TTS Engine State
  final TtsService _ttsService = TtsService();

  // Model Selection Lists
  List<ModelInfo> _allAsrModels = [];
  List<ModelInfo> _allNmtModels = [];
  List<ModelInfo> _allLlmModels = [];
  List<ModelInfo> _allTtsModels = [];
  bool _loadingModels = true;
  bool _isConfigExpanded = true;

  // Selected Options
  String _selectedSourceLang = 'Chinese';
  String _selectedTargetLang = 'English';
  String _mtMode = 'llm'; // 'nmt' (Opus MT) or 'llm' (Llama GGUF)
  bool _useTts = true; // Option to enable/disable TTS

  ModelInfo? _selectedAsrModel;
  ModelInfo? _selectedNmtModel; // Marian ONNX
  ModelInfo? _selectedLlmModel; // Llama GGUF
  ModelInfo? _selectedTtsModel;

  // TTS Settings
  int _selectedSpeakerId = 0;
  double _ttsSpeed = 1.0;

  // Pipeline execution outputs
  String _asrText = "";
  String _mtText = "";
  String _pipelineStatus = "Ready";
  int _currentStep = 0; // 0: Idle, 1: ASR, 2: MT, 3: TTS/Playing, 4: Done

  // ASR Real-time text accumulation
  List<String> _sentences = [];
  String _currentAsrResult = "";
  int _sentenceIndex = 0;

  // Paired ASR+MT segments for unified display
  final List<_CascadeSegment> _cascadeSegments = [];
  int _currentTranslatingIndex = -1;

  // Performance Metrics
  int? _mtInputTokens;
  double? _mtEncoderMs;
  int? _mtDecoderTokens;
  double? _mtDecoderTokensPerSec;

  double? _ttsElapsedSec;
  double? _ttsAudioDurationSec;
  double? _ttsRtf;

  // Real-time sentence-by-sentence queue variables
  final List<Map<String, dynamic>> _sentenceQueue = [];
  bool _isProcessingQueue = false;
  Completer<void>? _playCompleter;

  // Independent TTS playback queue (non-blocking)
  final List<String> _ttsQueue = [];
  bool _isProcessingTtsQueue = false;
  bool _isTtsPlaying = false;

  // Audio recording collection for VAD history
  final List<Float32List> _sessionAudioChunks = [];
  int _recordedSampleCount = 0;
  bool _hasSavedCurrentSession = false;

  // Initialization loading status
  bool _isInitializingASR = false;
  bool _isInitializingMT = false;
  bool _isInitializingTTS = false;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _audioPlayer = AudioPlayer();

    _recordSub = _audioRecorder.onStateChanged().listen((recordState) {
      setState(() {
        _isRecording = recordState == RecordState.record;
      });
    });

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed || state == PlayerState.stopped) {
        _playCompleter?.complete();
        _playCompleter = null;
      }
    });

    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  @override
  void dispose() {
    _deinitializeAll();
    _recordSub?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    ModelManager.changeNotifier.removeListener(_loadModels);
    super.dispose();
  }

  bool _isRecording = false;

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
    });

    final asrs = await ModelManager.getModels('asr');
    final nmts = await ModelManager.getModels('nmt');
    final llms = await ModelManager.getModels('llm');
    final ttss = await ModelManager.getModels('tts');

    setState(() {
      _allAsrModels = asrs;
      _allNmtModels = nmts;
      _allLlmModels = llms;
      _allTtsModels = ttss;
      _loadingModels = false;

      _updateSelectedModels();
    });
  }

  void _updateSelectedModels() {
    // 1. ASR model based on source language
    final asrList = _allAsrModels.where((m) => m.languages.contains(_selectedSourceLang)).toList();
    if (asrList.isNotEmpty) {
      if (_selectedAsrModel == null || !asrList.contains(_selectedAsrModel)) {
        _selectedAsrModel = asrList.first;
      }
    } else {
      _selectedAsrModel = null;
    }

    // 2. MT model based on target language + MT mode
    if (_mtMode == 'nmt') {
      final targetPair = '$_selectedSourceLang-$_selectedTargetLang';
      final mtList = _allNmtModels.where((m) => m.language == targetPair).toList();
      if (mtList.isNotEmpty) {
        if (_selectedNmtModel == null || !mtList.contains(_selectedNmtModel)) {
          _selectedNmtModel = mtList.first;
        }
      } else {
        _selectedNmtModel = null;
      }
    } else {
      if (_allLlmModels.isNotEmpty) {
        if (_selectedLlmModel == null || !_allLlmModels.contains(_selectedLlmModel)) {
          _selectedLlmModel = _allLlmModels.first;
        }
      } else {
        _selectedLlmModel = null;
      }
    }

    // 3. TTS model based on target language
    final ttsList = _allTtsModels.where((m) => m.languages.contains(_selectedTargetLang)).toList();
    if (ttsList.isNotEmpty) {
      if (_selectedTtsModel == null || !ttsList.contains(_selectedTtsModel)) {
        _selectedTtsModel = ttsList.first;
      }
    } else {
      _selectedTtsModel = null;
    }
  }

  Future<void> _deinitializeAll() async {
    _deinitializeAsr();
    await _deinitializeMt();
    _deinitializeTts();
    _sentenceQueue.clear();
    _isProcessingQueue = false;
    _ttsQueue.clear();
    _isProcessingTtsQueue = false;
    _isTtsPlaying = false;
    _playCompleter?.complete();
    _playCompleter = null;
    _cascadeSegments.clear();
    _currentTranslatingIndex = -1;
    setState(() {
      _pipelineStatus = "Ready (Not Initialized)";
      _currentStep = 0;
      _asrText = "";
      _mtText = "";
      _isConfigExpanded = true;
    });
  }

  void _deinitializeAsr() {
    _asr.deinitialize();
  }

  Future<void> _deinitializeMt() async {
    await _nmtBackend?.release();
    _nmtBackend = null;
  }

  void _applyLlmLanguages() {
    final backend = _nmtBackend;
    if (backend is LlamaNmtService && backend.isLoaded) {
      backend.setLanguages(_selectedSourceLang, _selectedTargetLang);
    }
  }

  void _onSourceLanguageChanged(String val) {
    setState(() {
      _selectedSourceLang = val;
      _updateSelectedModels();
    });
    _deinitializeAsr();
    _deinitializeTts();
    if (_mtMode == 'llm') {
      _applyLlmLanguages();
    } else {
      _deinitializeMt();
    }
  }

  void _onTargetLanguageChanged(String val) {
    setState(() {
      _selectedTargetLang = val;
      _updateSelectedModels();
    });
    _deinitializeTts();
    if (_mtMode == 'llm') {
      _applyLlmLanguages();
    } else {
      _deinitializeMt();
    }
  }

  void _deinitializeTts() {
    _ttsService.deinitialize();
  }

  Future<void> _initializeAllEngines() async {
    _deinitializeAll();

    // 1. Initialize ASR
    if (_selectedAsrModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an ASR model first.')),
      );
      return;
    }
    setState(() => _isInitializingASR = true);
    try {
      await _asr.initialize(_selectedAsrModel!);

      setState(() {
        _isInitializingASR = false;
      });
    } catch (e) {
      setState(() => _isInitializingASR = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ASR Initialization Failed: $e')),
      );
      return;
    }

    // 2. Initialize MT
    if (_mtMode == 'llm') {
      if (_selectedLlmModel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an LLM model first.')),
        );
        return;
      }
      setState(() => _isInitializingMT = true);
      try {
        _nmtBackend = LlamaNmtService();
        await _nmtBackend!.loadModel(
          _selectedLlmModel!,
          sourceLang: _selectedSourceLang,
          targetLang: _selectedTargetLang,
        );
        setState(() => _isInitializingMT = false);
      } catch (e) {
        _nmtBackend = null;
        setState(() => _isInitializingMT = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('LLM Initialization Failed: $e')),
        );
        return;
      }
    } else {
      if (_selectedNmtModel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an Opus MT model first.')),
        );
        return;
      }
      setState(() => _isInitializingMT = true);
      try {
        _nmtBackend = NativeNmtService();
        await _nmtBackend!.loadModel(_selectedNmtModel!);
        setState(() => _isInitializingMT = false);
      } catch (e) {
        _nmtBackend = null;
        setState(() => _isInitializingMT = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Opus MT Initialization Failed: $e')),
        );
        return;
      }
    }

    // 3. Initialize TTS (if enabled)
    if (_useTts) {
      if (_selectedTtsModel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a TTS model first.')),
        );
        return;
      }
      setState(() => _isInitializingTTS = true);
      try {
        await _ttsService.initialize(_selectedTtsModel!);

        setState(() {
          _selectedSpeakerId = 0;
          _isInitializingTTS = false;
          _pipelineStatus = "Ready";
          _isConfigExpanded = false;
        });
      } catch (e) {
        setState(() => _isInitializingTTS = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('TTS Initialization Failed: $e')),
        );
        return;
      }
    } else {
      setState(() {
        _pipelineStatus = "Ready";
        _isConfigExpanded = false;
      });
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_useTts
            ? 'All Cascade Translation Engines initialized successfully!'
            : 'ASR and MT Engines initialized successfully!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  bool get _isEnginesReady {
    return _asr.isInitialized &&
        (_nmtBackend?.isLoaded ?? false) &&
        (!_useTts || _ttsService.isInitialized);
  }

  Future<void> _startRecording() async {
    if (!_isEnginesReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please initialize the engines first!')),
      );
      return;
    }

    try {
      if (await _audioRecorder.hasPermission()) {
        await _audioPlayer.stop();

        _asr.reset();

        setState(() {
          _asrText = _sentences.join(" ");
          _mtText = "";
          _currentAsrResult = "";
          _currentStep = 1; // Step 1: ASR
          _pipelineStatus = "Listening...";

          _sentenceQueue.clear();
          _isProcessingQueue = false;
          _ttsQueue.clear();
          _isProcessingTtsQueue = false;
          _isTtsPlaying = false;
          _playCompleter = null;

          // Reset performance metrics
          _mtInputTokens = null;
          _mtEncoderMs = null;
          _mtDecoderTokens = null;
          _mtDecoderTokensPerSec = null;
          _ttsElapsedSec = null;
          _ttsAudioDurationSec = null;
          _ttsRtf = null;
        });

        _sessionAudioChunks.clear();
        _recordedSampleCount = 0;
        _hasSavedCurrentSession = false;

        _audioStreamSub = await _asr.startStream(
          _audioRecorder,
          _onAsrPoll,
          onAudioSamples: (samples) {
            _sessionAudioChunks.add(samples);
            _recordedSampleCount += samples.length;
          },
        );
      }
    } catch (e) {
      debugPrint('Cascade ASR Recording Error: $e');
    }
  }

  /// Process a poll result from the voice_engine pipeline: append finalized
  /// sentences to the cascade pipeline and update the live ASR display.
  void _onAsrPoll(VoiceEnginePollResult r) {
    for (int i = 0; i < r.finalized.length; i++) {
      final f = r.finalized[i];
      var text = AsrService.stripLeadingPuncs(f);
      text = AsrService.formatTextWithCasing(text, _selectedAsrModel?.casing ?? 'mixed');
      if (text.isNotEmpty) {
        final segIdx = _cascadeSegments.length;
        _sentences.add(text);
        _sentenceIndex += 1;

        double segStart = 0.0;
        double segEnd = 0.0;
        if (i < r.segments.length) {
          segStart = r.segments[i].start;
          segEnd = r.segments[i].end;
        }
        if (segEnd <= segStart) {
          segEnd = _recordedSampleCount / 16000.0;
          segStart = (segEnd - 2.0).clamp(0.0, segEnd);
        }

        _cascadeSegments.add(_CascadeSegment(
          asr: text,
          start: segStart,
          end: segEnd,
        ));
        _addSentenceToPipeline(text, segIdx);
      }
    }

    setState(() {
      final partialText = (r.speaking && r.partial.isNotEmpty)
          ? AsrService.formatTextWithCasing(r.partial, _selectedAsrModel?.casing ?? 'mixed')
          : "";
      _currentAsrResult = r.speaking
          ? (r.partial.isEmpty ? "Speaking..." : partialText)
          : "";
      _asrText = (_sentences.join(" ") + " " + partialText).trim();
    });
  }

  Future<void> _stopRecording() async {
    try {
      await _audioRecorder.stop();
      await _audioStreamSub?.cancel();
      _audioStreamSub = null;

      // Flush the VAD tail and drain any remaining finalized segments.
      if (_asr.handle != null) {
        final r = _asr.flushAndPoll();
        for (int i = 0; i < r.finalized.length; i++) {
          final f = r.finalized[i];
          var text = AsrService.stripLeadingPuncs(f);
          text = AsrService.formatTextWithCasing(text, _selectedAsrModel?.casing ?? 'mixed');
          if (text.isNotEmpty) {
            final segIdx = _cascadeSegments.length;
            _sentences.add(text);
            _sentenceIndex += 1;

            double segStart = 0.0;
            double segEnd = 0.0;
            if (i < r.segments.length) {
              segStart = r.segments[i].start;
              segEnd = r.segments[i].end;
            }
            if (segEnd <= segStart) {
              segEnd = _recordedSampleCount / 16000.0;
              segStart = (segEnd - 2.0).clamp(0.0, segEnd);
            }

            _cascadeSegments.add(_CascadeSegment(
              asr: text,
              start: segStart,
              end: segEnd,
            ));
            _addSentenceToPipeline(text, segIdx);
          }
        }
      }

      _currentAsrResult = "";
      final fullText = _sentences.join(" ").trim();

      setState(() {
        _asrText = fullText;
        _isRecording = false;
      });

      if (fullText.isEmpty && _sentenceQueue.isEmpty && !_isProcessingQueue) {
        setState(() {
          _currentStep = 0;
          _pipelineStatus = "No Speech Detected";
        });
      }

      if (!_isProcessingQueue) {
        _checkAndSaveHistory();
      }
    } catch (e) {
      debugPrint('Cascade Stop Recording Error: $e');
    }
  }

  void _addSentenceToPipeline(String sentence, int segmentIndex) {
    _sentenceQueue.add({'text': sentence, 'index': segmentIndex});
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    while (_sentenceQueue.isNotEmpty) {
      final entry = _sentenceQueue.removeAt(0);
      final sentence = entry['text'] as String;
      final segIdx = entry['index'] as int;

      setState(() {
        _currentTranslatingIndex = segIdx;
        _pipelineStatus = "Translating sentence...";
      });

      String translatedText = "";
      try {
        final Stream<String> translationStream = _nmtBackend!.translateStream(sentence);

        await for (final partial in translationStream) {
          translatedText = partial;
          setState(() {
            _mtText = partial;
            if (segIdx < _cascadeSegments.length) {
              _cascadeSegments[segIdx].mt = partial;
            }
          });
        }

        final timing = _nmtBackend!.lastStreamTiming;
        if (timing != null) {
          setState(() {
            _mtInputTokens = timing.inputTokens;
            _mtEncoderMs = timing.encoderMs;
            _mtDecoderTokens = timing.decoderTokens;
            _mtDecoderTokensPerSec = timing.decoderTokensPerSecond >= 0 ? timing.decoderTokensPerSecond : null;
          });
        }
      } catch (e) {
        setState(() {
          _mtText = "Translation error: $e";
          if (segIdx < _cascadeSegments.length) {
            _cascadeSegments[segIdx].mt = "[Error] $e";
          }
        });
        continue;
      }

      final finalizedTranslation = translatedText.trim();
      if (finalizedTranslation.isEmpty) continue;

      // Finalize segment MT
      if (segIdx < _cascadeSegments.length) {
        setState(() {
          _cascadeSegments[segIdx].mt = finalizedTranslation;
        });
      }

      // Enqueue to independent TTS queue (non-blocking)
      if (_useTts) {
        _ttsQueue.add(finalizedTranslation);
        _processTtsQueue(); // fire-and-forget
      }
    }

    setState(() {
      _isProcessingQueue = false;
      _currentTranslatingIndex = -1;
    });

    _checkAndSaveHistory();
  }

  /// Independent TTS playback queue - runs concurrently with ASR/MT.
  Future<void> _processTtsQueue() async {
    if (_isProcessingTtsQueue) return;
    _isProcessingTtsQueue = true;

    while (_ttsQueue.isNotEmpty) {
      final text = _ttsQueue.removeAt(0);

      setState(() {
        _pipelineStatus = "Synthesizing speech...";
      });

      try {
        if (!_ttsService.isInitialized) continue;

        final result = await _ttsService.synthesize(
          text: text,
          model: _selectedTtsModel!,
          speakerId: _selectedSpeakerId,
          speed: _ttsSpeed,
          prefix: 'tts-cascade',
          suffix: '-sid-$_selectedSpeakerId-speed-${_ttsSpeed.toStringAsFixed(1)}',
        );

        setState(() {
          _ttsElapsedSec = result.elapsedSec;
          _ttsAudioDurationSec = result.audioDurationSec;
          _ttsRtf = result.rtf;
          _pipelineStatus = "Speaking translation...";
          _isTtsPlaying = true;
        });

        _playCompleter = Completer<void>();
        await _audioPlayer.play(DeviceFileSource(result.wavPath));
        await _playCompleter!.future;

        setState(() {
          _isTtsPlaying = false;
        });
      } catch (e) {
        setState(() {
          _pipelineStatus = "TTS error: $e";
          _isTtsPlaying = false;
        });
      }
    }

    setState(() {
      _isProcessingTtsQueue = false;
      _isTtsPlaying = false;
      if (!_isRecording && !_isProcessingQueue) {
        _pipelineStatus = "Ready";
      }
    });
  }

  /// Stop all TTS playback and clear the queue.
  Future<void> _stopTts() async {
    _ttsQueue.clear();
    await _audioPlayer.stop();
    setState(() {
      _isProcessingTtsQueue = false;
      _isTtsPlaying = false;
      _pipelineStatus = _isRecording ? "Listening..." : "Ready";
    });
  }

  Future<void> _runTts(String text) async {
    if (!_ttsService.isInitialized) {
      setState(() {
        _currentStep = 0;
        _pipelineStatus = "TTS engine not initialized.";
      });
      return;
    }

    setState(() {
      _currentStep = 3; // Step 3: TTS / Playback
      _pipelineStatus = "Synthesizing translation...";
    });

    try {
      final result = await _ttsService.synthesize(
        text: text,
        model: _selectedTtsModel!,
        speakerId: _selectedSpeakerId,
        speed: _ttsSpeed,
        prefix: 'tts-cascade',
        suffix: '-sid-$_selectedSpeakerId-speed-${_ttsSpeed.toStringAsFixed(1)}',
      );

      setState(() {
        _ttsElapsedSec = result.elapsedSec;
        _ttsAudioDurationSec = result.audioDurationSec;
        _ttsRtf = result.rtf;
        _pipelineStatus = "Speaking translation...";
      });

      await _audioPlayer.play(DeviceFileSource(result.wavPath));
    } catch (e) {
      setState(() {
        _currentStep = 0;
        _pipelineStatus = "TTS Synthesis Error: $e";
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('TTS synthesis failed: $e')),
      );
    }
  }

  Float32List _buildVadAudioSamples() {
    int totalMicSamples = 0;
    for (final chunk in _sessionAudioChunks) {
      totalMicSamples += chunk.length;
    }
    if (totalMicSamples == 0 || _cascadeSegments.isEmpty) {
      return Float32List(1600);
    }

    final allMicSamples = Float32List(totalMicSamples);
    int offset = 0;
    for (final chunk in _sessionAudioChunks) {
      allMicSamples.setAll(offset, chunk);
      offset += chunk.length;
    }

    double maxEnd = 0.0;
    for (final seg in _cascadeSegments) {
      if (seg.end > maxEnd) maxEnd = seg.end;
    }
    if (maxEnd <= 0.0) {
      maxEnd = totalMicSamples / 16000.0;
    }

    final int totalVadSamples = (maxEnd * 16000).ceil();
    final vadSamples = Float32List(totalVadSamples);

    for (final seg in _cascadeSegments) {
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
    if (_hasSavedCurrentSession) return;
    if (_isRecording) return;
    if (_isProcessingQueue) return;
    if (_cascadeSegments.isEmpty) return;

    _hasSavedCurrentSession = true;
    try {
      final id = CascadeHistoryStore.newId();
      final vadSamples = _buildVadAudioSamples();
      final audioPath = await CascadeHistoryStore.saveVadAudioWav(
        id: id,
        samples: vadSamples,
      );

      final subtitles = <SubtitleSegment>[];
      for (int i = 0; i < _cascadeSegments.length; i++) {
        final seg = _cascadeSegments[i];
        subtitles.add(SubtitleSegment(
          index: i + 1,
          start: seg.start,
          end: seg.end > seg.start ? seg.end : seg.start + 1.0,
          originalText: seg.asr,
          translatedText: seg.mt,
        ));
      }

      final double totalDuration = subtitles.isNotEmpty ? subtitles.last.end : 0.0;
      final now = DateTime.now();

      final session = AudioFileHistorySession(
        id: id,
        createdAt: now,
        updatedAt: now,
        fileName: '级联翻译_${_formatSessionTime(now)}',
        sourceLang: _selectedSourceLang,
        targetLang: _selectedTargetLang,
        duration: totalDuration,
        audioPath: audioPath,
        subtitles: subtitles,
      );

      await CascadeHistoryStore.save(session);
      debugPrint('Cascade translation history saved: $id');
    } catch (e) {
      debugPrint('Failed to save cascade translation history: $e');
    }
  }

  String _formatSessionTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}_${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
  }

  void _openHistory() {
    _audioPlayer.stop();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AudioFileHistorySheet(
        title: '级联翻译历史记录',
        subtitle: '浏览级联翻译历史，回放 VAD 识别语音段与对应字幕',
        fetchItems: CascadeHistoryStore.list,
        loadSession: CascadeHistoryStore.load,
        deleteItem: CascadeHistoryStore.delete,
        renameItem: CascadeHistoryStore.rename,
      ),
    );
  }

  void _clearConversation() {
    _audioPlayer.stop();
    setState(() {
      _sentences = [];
      _currentAsrResult = "";
      _sentenceIndex = 0;
      _asrText = "";
      _mtText = "";
      _cascadeSegments.clear();
      _currentTranslatingIndex = -1;
      _sentenceQueue.clear();
      _isProcessingQueue = false;
      _ttsQueue.clear();
      _isProcessingTtsQueue = false;
      _isTtsPlaying = false;
      _playCompleter?.complete();
      _playCompleter = null;
      _mtInputTokens = null;
      _mtEncoderMs = null;
      _mtDecoderTokens = null;
      _mtDecoderTokensPerSec = null;
      _ttsElapsedSec = null;
      _ttsAudioDurationSec = null;
      _ttsRtf = null;
    });
  }
  void _swapLanguages() {
    setState(() {
      final temp = _selectedSourceLang;
      _selectedSourceLang = _selectedTargetLang;
      _selectedTargetLang = temp;
      _updateSelectedModels();
    });
    _deinitializeAsr();
    _deinitializeTts();
    if (_mtMode == 'llm') {
      _applyLlmLanguages();
    } else {
      _deinitializeMt();
    }
  }

  void _openModelManagement(String type) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: type,
        onModelsChanged: () {
          _loadModels();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showPerfMetrics = widget.showPerfMetrics || MyHomePage.showPerfMetricsNotifier.value;

    // Filtered lists for display in configuration dropdowns
    final filteredAsrModels = _allAsrModels.where((m) => m.languages.contains(_selectedSourceLang)).toList();
    
    final targetPair = '$_selectedSourceLang-$_selectedTargetLang';
    final filteredNmtModels = _allNmtModels.where((m) => m.language == targetPair).toList();
    final filteredLlmModels = _allLlmModels; // LLM models support all pairs
    
    final filteredTtsModels = _allTtsModels.where((m) => m.languages.contains(_selectedTargetLang)).toList();

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
                    // --- Title Section ---
                    Row(
                      children: [
                        const Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.layers_rounded, size: 26, color: Color(0xFF1E3C72)),
                              SizedBox(width: 8),
                              Text(
                                'Cascade Translation (级联式翻译)',
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                                textAlign: TextAlign.center,
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

                    // --- Step Visualization Bar ---
                    _buildStepVisualizer(),
                    const SizedBox(height: 16),

                    // --- Language Selector Card ---
                    _buildLanguageSelectorCard(),
                    const SizedBox(height: 16),

                    // --- Model Management & Initialization Card ---
                    _buildModelConfigurationCard(filteredAsrModels, filteredNmtModels, filteredLlmModels, filteredTtsModels),
                    const SizedBox(height: 16),

                    // --- Pipeline Result Screen Card ---
                    _buildResultsCard(showPerfMetrics),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            // --- Floating Mic Control Panel ---
            _buildMicControlPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildStepVisualizer() {
    final steps = [
      {'icon': Icons.mic_rounded, 'label': 'Speech'},
      {'icon': Icons.translate_rounded, 'label': 'Translate'},
      if (_useTts) {'icon': Icons.volume_up_rounded, 'label': 'Speech Out'},
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(steps.length * 2 - 1, (index) {
          if (index.isOdd) {
            final stepIdx = index ~/ 2;
            final isPassed = _currentStep > stepIdx + 1;
            return Expanded(
              child: Container(
                height: 3,
                color: isPassed ? const Color(0xFF1E3C72) : Colors.grey.shade300,
              ),
            );
          } else {
            final stepIdx = index ~/ 2;
            final isActive = _currentStep == stepIdx + 1;
            final isPassed = _currentStep > stepIdx + 1;

            Color bgColor = Colors.grey.shade100;
            Color iconColor = Colors.grey.shade400;
            Border border = Border.all(color: Colors.grey.shade300, width: 2);

            if (isActive) {
              bgColor = const Color(0xFF1E3C72).withOpacity(0.1);
              iconColor = const Color(0xFF1E3C72);
              border = Border.all(color: const Color(0xFF1E3C72), width: 2);
            } else if (isPassed) {
              bgColor = const Color(0xFF1E3C72);
              iconColor = Colors.white;
              border = Border.all(color: const Color(0xFF1E3C72), width: 2);
            }

            return Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: bgColor,
                    shape: BoxShape.circle,
                    border: border,
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: const Color(0xFF1E3C72).withOpacity(0.2),
                              blurRadius: 8,
                              spreadRadius: 2,
                            )
                          ]
                        : null,
                  ),
                  child: Icon(
                    steps[stepIdx]['icon'] as IconData,
                    color: iconColor,
                    size: 20,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  steps[stepIdx]['label'] as String,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isActive || isPassed ? FontWeight.bold : FontWeight.normal,
                    color: isActive || isPassed ? const Color(0xFF1E3C72) : Colors.grey,
                  ),
                )
              ],
            );
          }
        }),
      ),
    );
  }

  Widget _buildLanguageSelectorCard() {
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
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Source Language', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                _buildLanguageDropdown(
                  value: _selectedSourceLang,
                  onChanged: (val) {
                    if (val != null) _onSourceLanguageChanged(val);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: IconButton(
              onPressed: _swapLanguages,
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E3C72).withOpacity(0.05),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF1E3C72)),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Target Language', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                _buildLanguageDropdown(
                  value: _selectedTargetLang,
                  onChanged: (val) {
                    if (val != null) _onTargetLanguageChanged(val);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageDropdown({
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey),
          items: LanguageManager.languages.map((lang) {
            return DropdownMenuItem<String>(
              value: lang,
              child: Text(
                lang,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildModelConfigurationCard(
    List<ModelInfo> filteredAsrs,
    List<ModelInfo> filteredNmts,
    List<ModelInfo> filteredLlms,
    List<ModelInfo> filteredTtss,
  ) {
    final targetPair = '$_selectedSourceLang-$_selectedTargetLang';
    return Container(
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _isConfigExpanded = !_isConfigExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  const Icon(Icons.settings_outlined, size: 20, color: Color(0xFF1E3C72)),
                  const SizedBox(width: 8),
                  const Text(
                    'Engine Model Settings',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _isConfigExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.grey.shade600,
                    size: 20,
                  ),
                  const Spacer(),
                  _buildSetupIndicator(),
                ],
              ),
            ),
          ),
          if (_isConfigExpanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1, color: Color(0xFFEEEEEE)),
                  const SizedBox(height: 16),

                  // --- ASR Model Dropdown ---
                  _buildDropdownLabel("1. Speech Recognition Model (ASR)", 'asr'),
                  const SizedBox(height: 6),
                  _buildModelDropdown<ModelInfo>(
                    value: _selectedAsrModel,
                    items: filteredAsrs,
                    hintText: 'Select ASR Model',
                    onChanged: (val) {
                      setState(() {
                        _selectedAsrModel = val;
                        _deinitializeAsr();
                      });
                    },
                    displayString: (model) => "${model.name} (${model.isStreaming ? 'Streaming' : 'Offline'})",
                  ),
                  const SizedBox(height: 16),

                  // --- MT Mode Selector ---
                  const Text('2. Translation (MT) Method', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMtModeButton(
                          label: 'Llama GGUF',
                          value: 'llm',
                          icon: Icons.psychology_rounded,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMtModeButton(
                          label: 'Opus MT (ONNX)',
                          value: 'nmt',
                          icon: Icons.shuffle_on_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // --- MT Model Dropdown ---
                  _buildDropdownLabel(
                    _mtMode == 'llm' ? "Translation Model (LLM)" : "Translation Model (Opus MT)",
                    _mtMode == 'llm' ? 'llm' : 'nmt',
                  ),
                  const SizedBox(height: 6),
                  _mtMode == 'llm'
                      ? _buildModelDropdown<ModelInfo>(
                          value: _selectedLlmModel,
                          items: filteredLlms,
                          hintText: 'Select LLM Model',
                          onChanged: (val) {
                            setState(() {
                              _selectedLlmModel = val;
                              _deinitializeMt();
                            });
                          },
                          displayString: (model) => model.name,
                        )
                      : _buildModelDropdown<ModelInfo>(
                          value: _selectedNmtModel,
                          items: filteredNmts,
                          hintText: 'No Marian Model for $targetPair',
                          onChanged: (val) {
                            setState(() {
                              _selectedNmtModel = val;
                              _deinitializeMt();
                            });
                          },
                          displayString: (model) => model.name,
                        ),
                  const SizedBox(height: 16),

                  // --- TTS Enabled Toggle ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "3. Speech Synthesis (TTS)",
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                      Row(
                        children: [
                          Text(
                            _useTts ? "Enabled" : "Disabled",
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
                          ),
                          const SizedBox(width: 4),
                          Switch(
                            value: _useTts,
                            activeColor: const Color(0xFF1E3C72),
                            onChanged: (val) {
                              setState(() {
                                _useTts = val;
                                if (!val) {
                                  _deinitializeTts();
                                }
                                _updateSelectedModels();
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  if (_useTts) ...[
                    // --- TTS Model Dropdown ---
                    _buildDropdownLabel("Select TTS Model", 'tts'),
                    const SizedBox(height: 6),
                    _buildModelDropdown<ModelInfo>(
                      value: _selectedTtsModel,
                      items: filteredTtss,
                      hintText: 'Select TTS Model',
                      onChanged: (val) {
                        setState(() {
                          _selectedTtsModel = val;
                          _deinitializeTts();
                        });
                      },
                      displayString: (model) => "${model.name} (${model.ttsEngineType})",
                    ),

                    // --- TTS Speaker & Speed Settings ---
                    if (_ttsService.isInitialized && _ttsService.maxSpeakerId > 0) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('TTS Speaker ID', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade50,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: Colors.grey.shade200),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<int>(
                                      value: _selectedSpeakerId,
                                      isExpanded: true,
                                      items: List.generate(_ttsService.maxSpeakerId + 1, (i) {
                                        return DropdownMenuItem<int>(
                                          value: i,
                                          child: Text('Speaker #$i'),
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
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Speed: ${_ttsSpeed.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                                Slider(
                                  value: _ttsSpeed,
                                  min: 0.5,
                                  max: 2.0,
                                  divisions: 15,
                                  label: '${_ttsSpeed.toStringAsFixed(1)}x',
                                  activeColor: const Color(0xFF1E3C72),
                                  onChanged: (val) {
                                    setState(() {
                                      _ttsSpeed = val;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],

                  const SizedBox(height: 20),

                  // --- Initialize Button ---
                  ElevatedButton.icon(
                    onPressed: _loadingModels
                        ? null
                        : () {
                            _initializeAllEngines();
                          },
                    icon: const Icon(Icons.flash_on_rounded, color: Colors.white),
                    label: const Text('Initialize Selected Engines', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3C72),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSetupIndicator() {
    if (_asr.isInitialized && (_nmtBackend?.isLoaded ?? false) && _ttsService.isInitialized) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.green.shade200),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline_rounded, size: 12, color: Colors.green),
            SizedBox(width: 4),
            Text('Ready', style: TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    } else {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.amber.shade200),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 12, color: Colors.amber),
            SizedBox(width: 4),
            Text('Not Setup', style: TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }
  }

  Widget _buildDropdownLabel(String label, String modelType) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
        InkWell(
          onTap: () => _openModelManagement(modelType),
          child: Text(
            'Manage Models',
            style: TextStyle(fontSize: 11, color: Colors.blue.shade700, fontWeight: FontWeight.w600, decoration: TextDecoration.underline),
          ),
        ),
      ],
    );
  }

  Widget _buildModelDropdown<T>({
    required T? value,
    required List<T> items,
    required String hintText,
    required ValueChanged<T?> onChanged,
    required String Function(T) displayString,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          hint: Text(hintText, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey),
          items: items.map((item) {
            return DropdownMenuItem<T>(
              value: item,
              child: Text(
                displayString(item),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF2D3748)),
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildMtModeButton({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final isSelected = _mtMode == value;
    return GestureDetector(
      onTap: () {
        setState(() {
          _mtMode = value;
          _updateSelectedModels();
          _deinitializeMt();
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1E3C72) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? const Color(0xFF1E3C72) : Colors.grey.shade300),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF1E3C72).withOpacity(0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: isSelected ? Colors.white : Colors.grey.shade600),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build interleaved TextSpan children: for each segment show ASR line then MT line.
  List<TextSpan> _buildSegmentSpans() {
    final spans = <TextSpan>[];

    for (int i = 0; i < _cascadeSegments.length; i++) {
      final seg = _cascadeSegments[i];
      if (i > 0) {
        spans.add(const TextSpan(text: '\n\n')); // blank line between sentence groups
      }

      // ASR line - source language color
      spans.add(TextSpan(
        text: seg.asr,
        style: const TextStyle(
          fontSize: 14,
          color: Color(0xFF2D3748),
          fontWeight: FontWeight.w500,
        ),
      ));

      // MT line - translated text in accent color
      if (seg.mt.isNotEmpty) {
        spans.add(const TextSpan(text: '\n'));
        final bool isTranslating = (i == _currentTranslatingIndex && _currentStep == 2);
        spans.add(TextSpan(
          text: seg.mt + (isTranslating ? ' ▍' : ''),
          style: TextStyle(
            fontSize: 14,
            color: const Color(0xFF1E3C72),
            fontStyle: isTranslating ? FontStyle.italic : FontStyle.normal,
          ),
        ));
      } else if (i == _currentTranslatingIndex && _currentStep == 2) {
        // Waiting for translation
        spans.add(const TextSpan(text: '\n'));
        spans.add(const TextSpan(
          text: 'Translating... ▍',
          style: TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
        ));
      }
    }

    // Append the currently-being-recognized partial ASR text
    if (_currentAsrResult.isNotEmpty) {
      if (_cascadeSegments.isNotEmpty) {
        spans.add(const TextSpan(text: '\n\n'));
      }
      spans.add(TextSpan(
        text: '$_currentAsrResult ▍',
        style: const TextStyle(
          fontSize: 14,
          color: Color(0xFF718096),
          fontStyle: FontStyle.italic,
        ),
      ));
    }

    return spans;
  }

  Widget _buildResultsCard(bool showPerfMetrics) {
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
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Translation Output',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Unified ASR + Translation display
          const Text('Conversation (ASR → MT)', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(minHeight: 80),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade100),
            ),
            child: _cascadeSegments.isEmpty && _currentAsrResult.isEmpty
                ? Text(
                    _isRecording ? 'Listening...' : 'No transcription yet.',
                    style: const TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
                  )
                : SelectableText.rich(
                    TextSpan(
                      children: _buildSegmentSpans(),
                    ),
                  ),
          ),
          const SizedBox(height: 12),

          // Performance Metrics
          if (showPerfMetrics && (_mtEncoderMs != null || _ttsElapsedSec != null)) ...[
            const SizedBox(height: 16),
            const Text('Performance Metrics', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.indigo.shade50),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_mtEncoderMs != null) ...[
                    Text(
                      'Translation (MT):\n'
                      ' - Input Tokens: ${_mtInputTokens ?? "N/A"}\n'
                      ' - Prompt Time: ${_mtEncoderMs!.toStringAsFixed(1)} ms\n'
                      ' - Output Tokens: ${_mtDecoderTokens ?? "N/A"}\n'
                      ' - Decode Speed: ${_mtDecoderTokensPerSec?.toStringAsFixed(1) ?? "N/A"} tok/s',
                      style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.indigo.shade900),
                    ),
                  ],
                  if (_mtEncoderMs != null && _ttsElapsedSec != null)
                    const Divider(height: 12, color: Colors.black12),
                  if (_ttsElapsedSec != null) ...[
                    Text(
                      'Speech Synthesis (TTS):\n'
                      ' - Elapsed Time: ${_ttsElapsedSec!.toStringAsFixed(3)} s\n'
                      ' - Audio Duration: ${_ttsAudioDurationSec!.toStringAsFixed(3)} s\n'
                      ' - RTF (Real-Time Factor): ${_ttsRtf!.toStringAsFixed(3)}',
                      style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.indigo.shade900),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMicControlPanel() {
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
            _pipelineStatus,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
          ),
          const SizedBox(height: 12),

          // Symmetrically balanced Row containing Clear, Stop TTS, Microphone, Replay TTS, and Spacers
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // 1. Clear Button
              SizedBox(
                width: 52,
                height: 52,
                child: IconButton(
                  onPressed: (_cascadeSegments.isEmpty && _currentAsrResult.isEmpty)
                      ? null
                      : _clearConversation,
                  icon: const Icon(Icons.delete_outline, size: 26),
                  color: Colors.red.shade400,
                  disabledColor: Colors.grey.shade300,
                  tooltip: 'Clear Conversation',
                ),
              ),

              // 2. Stop TTS Button (visible when TTS is active)
              SizedBox(
                width: 52,
                height: 52,
                child: AnimatedOpacity(
                  opacity: (_isTtsPlaying || _isProcessingTtsQueue) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !(_isTtsPlaying || _isProcessingTtsQueue),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _stopTts,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.orange.shade600, Colors.orange.shade400],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.orange.shade300.withOpacity(0.4),
                              blurRadius: 12,
                              spreadRadius: 1,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.volume_off_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
              ),

              // 3. Microphone Button
              GestureDetector(
                onTap: () {
                  if (_isRecording) {
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
                      colors: _isRecording
                          ? [Colors.red.shade600, Colors.red.shade400]
                          : (_isEnginesReady
                              ? [const Color(0xFF1E3C72), const Color(0xFF2A5298)]
                              : [Colors.grey.shade400, Colors.grey.shade500]),
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (_isRecording
                                ? Colors.red.shade300
                                : (_isEnginesReady ? const Color(0xFF1E3C72) : Colors.grey))
                            .withOpacity(0.4),
                        blurRadius: _isRecording ? 20 : 12,
                        spreadRadius: _isRecording ? 4 : 1,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Icon(
                    _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),

              // 4. Replay TTS Button
              SizedBox(
                width: 52,
                height: 52,
                child: AnimatedOpacity(
                  opacity: (_useTts && _ttsService.isInitialized && _cascadeSegments.isNotEmpty) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !(_useTts && _ttsService.isInitialized && _cascadeSegments.isNotEmpty),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: (_isTtsPlaying || _isProcessingTtsQueue)
                          ? null
                          : () {
                              final lastMt = _cascadeSegments.lastOrNull?.mt;
                              if (lastMt != null && lastMt.isNotEmpty) {
                                _ttsQueue.add(lastMt);
                                _processTtsQueue();
                              } else if (_mtText.isNotEmpty) {
                                _runTts(_mtText);
                              }
                            },
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [const Color(0xFF1E3C72), const Color(0xFF2A5298)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF1E3C72).withOpacity(0.3),
                              blurRadius: 12,
                              spreadRadius: 1,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.volume_up_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
              ),

              // 5. Spacer to balance layout (width 52)
              const SizedBox(width: 52, height: 52),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _isRecording
                ? 'Tap to Stop'
                : (_isEnginesReady ? 'Tap to Speak' : 'Initialize Models to Speak'),
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
