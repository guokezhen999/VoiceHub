import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'package:voice_app/ffi/voice_engine_ffi_bridge.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/services/asr_service.dart';
import 'package:voice_app/services/dual_dialogue_history_store.dart';
import 'package:voice_app/services/llama_nmt_service.dart';
import 'package:voice_app/services/native_nmt_service.dart';
import 'package:voice_app/services/nmt_service_common.dart';
import 'package:voice_app/services/tts_service.dart';
import 'package:voice_app/ui/widgets/audio_file_history_sheet.dart';
import 'package:voice_app/ui/widgets/responsive_bilingual_text.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';

enum _SpeakerSide { a, b }

class _SideEngines {
  final AsrService asr = AsrService();
  NmtBackend? nmt;
  final TtsService tts = TtsService();
  ModelInfo? asrModel;
  ModelInfo? nmtModel;
  ModelInfo? ttsModel;
  int speakerId = 0;
  double ttsSpeed = 1.0;
}

class _DialogueBubble {
  final String id;
  final _SpeakerSide side;
  String asr;
  String mt;
  final DateTime at;
  double start;
  double end;
  bool mtDone;

  _DialogueBubble({
    required this.id,
    required this.side,
    required this.asr,
    this.mt = '',
    required this.at,
    this.start = 0.0,
    this.end = 0.0,
    this.mtDone = false,
  });
}

/// Dual-person dialogue: two ASR/MT/TTS sets, shared LLM MT, exclusive mic.
class DualDialogueScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const DualDialogueScreen({Key? key, this.showPerfMetrics = false}) : super(key: key);

  @override
  State<DualDialogueScreen> createState() => _DualDialogueScreenState();
}

class _DualDialogueScreenState extends State<DualDialogueScreen> {
  late final AudioRecorder _audioRecorder;
  late final AudioPlayer _audioPlayer;
  StreamSubscription<RecordState>? _recordSub;
  StreamSubscription<Uint8List>? _audioStreamSub;

  final _sideA = _SideEngines();
  final _sideB = _SideEngines();
  LlamaNmtService? _sharedLlm;

  List<ModelInfo> _allAsrModels = [];
  List<ModelInfo> _allNmtModels = [];
  List<ModelInfo> _allLlmModels = [];
  List<ModelInfo> _allTtsModels = [];
  bool _loadingModels = true;
  bool _isConfigExpanded = true;

  String _langA = 'Chinese';
  String _langB = 'English';
  String _mtMode = 'llm'; // 'nmt' | 'llm'
  ModelInfo? _selectedLlmModel;
  bool _useTts = true;

  bool _isInitializing = false;
  _SpeakerSide? _activeSide;
  bool _isRecording = false;
  String _livePartial = '';
  String _status = 'Ready';

  final List<_DialogueBubble> _bubbles = [];
  int _bubbleSeq = 0;
  final ScrollController _scrollController = ScrollController();

  // Sentence → MT → TTS queue
  final List<Map<String, dynamic>> _sentenceQueue = [];
  bool _isProcessingQueue = false;
  final List<Map<String, dynamic>> _ttsQueue = [];
  bool _isProcessingTtsQueue = false;
  bool _isTtsPlaying = false;
  _SpeakerSide? _currentlyPlayingSide;
  Completer<void>? _playCompleter;

  // History session (one init = one session)
  String? _currentSessionId;
  DateTime? _sessionCreatedAt;
  String? _sessionTitle;
  Timer? _persistDebounce;
  Future<void>? _persistInFlight;

  // Session audio (continuous across turns, like cascade)
  final List<Float32List> _sessionAudioChunks = [];
  int _recordedSampleCount = 0;
  int _samplesAtRecordingStart = 0;

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
    _persistDebounce?.cancel();
    _deinitializeAll();
    _recordSub?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _scrollController.dispose();
    ModelManager.changeNotifier.removeListener(_loadModels);
    super.dispose();
  }

  Future<void> _loadModels() async {
    setState(() => _loadingModels = true);
    final asrs = await ModelManager.getModels('asr');
    final nmts = await ModelManager.getModels('nmt');
    final llms = await ModelManager.getModels('llm');
    final ttss = await ModelManager.getModels('tts');
    if (!mounted) return;
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
    final asrA = _allAsrModels.where((m) => m.languages.contains(_langA)).toList();
    if (asrA.isNotEmpty) {
      if (_sideA.asrModel == null || !asrA.contains(_sideA.asrModel)) {
        _sideA.asrModel = asrA.first;
      }
    } else {
      _sideA.asrModel = null;
    }

    final asrB = _allAsrModels.where((m) => m.languages.contains(_langB)).toList();
    if (asrB.isNotEmpty) {
      if (_sideB.asrModel == null || !asrB.contains(_sideB.asrModel)) {
        _sideB.asrModel = asrB.first;
      }
    } else {
      _sideB.asrModel = null;
    }

    if (_mtMode == 'nmt') {
      final pairA = '$_langA-$_langB';
      final nmtA = _allNmtModels.where((m) => m.language == pairA).toList();
      if (nmtA.isNotEmpty) {
        if (_sideA.nmtModel == null || !nmtA.contains(_sideA.nmtModel)) {
          _sideA.nmtModel = nmtA.first;
        }
      } else {
        _sideA.nmtModel = null;
      }

      final pairB = '$_langB-$_langA';
      final nmtB = _allNmtModels.where((m) => m.language == pairB).toList();
      if (nmtB.isNotEmpty) {
        if (_sideB.nmtModel == null || !nmtB.contains(_sideB.nmtModel)) {
          _sideB.nmtModel = nmtB.first;
        }
      } else {
        _sideB.nmtModel = null;
      }
      _selectedLlmModel = null;
    } else {
      if (_allLlmModels.isNotEmpty) {
        if (_selectedLlmModel == null || !_allLlmModels.contains(_selectedLlmModel)) {
          _selectedLlmModel = _allLlmModels.first;
        }
      } else {
        _selectedLlmModel = null;
      }
      _sideA.nmtModel = null;
      _sideB.nmtModel = null;
    }

    // TTS: A speaks langA → translate to langB → play with TTS_B (langB)
    //      B speaks langB → translate to langA → play with TTS_A (langA)
    final ttsA = _allTtsModels.where((m) => m.languages.contains(_langA)).toList();
    if (ttsA.isNotEmpty) {
      if (_sideA.ttsModel == null || !ttsA.contains(_sideA.ttsModel)) {
        _sideA.ttsModel = ttsA.first;
      }
    } else {
      _sideA.ttsModel = null;
    }

    final ttsB = _allTtsModels.where((m) => m.languages.contains(_langB)).toList();
    if (ttsB.isNotEmpty) {
      if (_sideB.ttsModel == null || !ttsB.contains(_sideB.ttsModel)) {
        _sideB.ttsModel = ttsB.first;
      }
    } else {
      _sideB.ttsModel = null;
    }
  }

  _SideEngines _engines(_SpeakerSide side) => side == _SpeakerSide.a ? _sideA : _sideB;

  bool get _isEnginesReady {
    final asrOk = _sideA.asr.isInitialized && _sideB.asr.isInitialized;
    final mtOk = _mtMode == 'llm'
        ? (_sharedLlm?.isLoaded ?? false)
        : ((_sideA.nmt?.isLoaded ?? false) && (_sideB.nmt?.isLoaded ?? false));
    final ttsOk = !_useTts || (_sideA.tts.isInitialized && _sideB.tts.isInitialized);
    return asrOk && mtOk && ttsOk;
  }

  Future<void> _deinitializeAll() async {
    await _stopRecordingInternal(flush: false);
    await _sideA.asr.deinitialize();
    await _sideB.asr.deinitialize();
    await _sideA.nmt?.release();
    _sideA.nmt = null;
    await _sideB.nmt?.release();
    _sideB.nmt = null;
    await _sharedLlm?.release();
    _sharedLlm = null;
    _sideA.tts.deinitialize();
    _sideB.tts.deinitialize();
    _sentenceQueue.clear();
    _isProcessingQueue = false;
    _ttsQueue.clear();
    _isProcessingTtsQueue = false;
    _isTtsPlaying = false;
    _currentlyPlayingSide = null;
    _playCompleter?.complete();
    _playCompleter = null;
  }

  Future<void> _initializeAllEngines() async {
    if (_isInitializing) return;

    if (_sideA.asrModel == null || _sideB.asrModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select ASR models for both sides.')),
      );
      return;
    }
    if (_mtMode == 'llm' && _selectedLlmModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a shared LLM model.')),
      );
      return;
    }
    if (_mtMode == 'nmt' && (_sideA.nmtModel == null || _sideB.nmtModel == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select Opus MT models for both directions.')),
      );
      return;
    }
    if (_useTts && (_sideA.ttsModel == null || _sideB.ttsModel == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select TTS models for both sides.')),
      );
      return;
    }

    setState(() {
      _isInitializing = true;
      _status = 'Initializing...';
    });

    try {
      await _deinitializeAll();

      // Each ASR loads in its own background isolate (same pattern as 同传).
      setState(() => _status = 'Loading ASR A...');
      await _sideA.asr.initialize(_sideA.asrModel!);
      if (!mounted) return;

      setState(() => _status = 'Loading ASR B...');
      await _sideB.asr.initialize(_sideB.asrModel!);
      if (!mounted) return;

      if (_mtMode == 'llm') {
        setState(() => _status = 'Loading shared LLM...');
        final llm = LlamaNmtService();
        await llm.loadModel(
          _selectedLlmModel!,
          sourceLang: _langA,
          targetLang: _langB,
        );
        _sharedLlm = llm;
      } else {
        setState(() => _status = 'Loading NMT A→B...');
        final nmtA = NativeNmtService();
        await nmtA.loadModel(_sideA.nmtModel!);
        _sideA.nmt = nmtA;
        if (!mounted) return;

        setState(() => _status = 'Loading NMT B→A...');
        final nmtB = NativeNmtService();
        await nmtB.loadModel(_sideB.nmtModel!);
        _sideB.nmt = nmtB;
      }
      if (!mounted) return;

      if (_useTts) {
        // Yield between TTS loads so the UI can keep painting.
        setState(() => _status = 'Loading TTS A...');
        await Future<void>.delayed(Duration.zero);
        await _sideA.tts.initialize(_sideA.ttsModel!);
        _sideA.speakerId = 0;
        if (!mounted) return;

        setState(() => _status = 'Loading TTS B...');
        await Future<void>.delayed(Duration.zero);
        await _sideB.tts.initialize(_sideB.ttsModel!);
        _sideB.speakerId = 0;
      }

      // New session for this initialization
      final now = DateTime.now();
      _currentSessionId = DualDialogueHistoryStore.newId();
      _sessionCreatedAt = now;
      _sessionTitle = DualDialogueHistoryStore.defaultTitle(now);
      _bubbles.clear();
      _bubbleSeq = 0;
      _sessionAudioChunks.clear();
      _recordedSampleCount = 0;
      _samplesAtRecordingStart = 0;

      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _isConfigExpanded = false;
        _status = 'Ready';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Dual dialogue engines initialized successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      await _deinitializeAll();
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _status = 'Init failed';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Initialization failed: $e')),
      );
    }
  }

  void _swapLanguages() {
    setState(() {
      final tmp = _langA;
      _langA = _langB;
      _langB = tmp;

      final asrTmp = _sideA.asrModel;
      _sideA.asrModel = _sideB.asrModel;
      _sideB.asrModel = asrTmp;

      final nmtTmp = _sideA.nmtModel;
      _sideA.nmtModel = _sideB.nmtModel;
      _sideB.nmtModel = nmtTmp;

      final ttsTmp = _sideA.ttsModel;
      _sideA.ttsModel = _sideB.ttsModel;
      _sideB.ttsModel = ttsTmp;

      _updateSelectedModels();
    });
    _deinitializeAll();
  }

  Future<void> _toggleRecording(_SpeakerSide side) async {
    if (!_isEnginesReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please initialize the engines first!')),
      );
      return;
    }

    // Same side → stop
    if (_activeSide == side) {
      await _stopRecording();
      return;
    }

    // Other side recording → stop them first, then start this side
    if (_activeSide != null) {
      await _stopRecordingInternal(flush: true);
    }

    await _startRecording(side);
  }

  Future<void> _startRecording(_SpeakerSide side) async {
    if (!_isEnginesReady) return;
    if (_activeSide != null) return;

    try {
      if (!await _audioRecorder.hasPermission()) return;

      final engines = _engines(side);
      await engines.asr.reset();
      _samplesAtRecordingStart = _recordedSampleCount;

      setState(() {
        _activeSide = side;
        _livePartial = '';
        _status = side == _SpeakerSide.a ? 'Listening (A)...' : 'Listening (B)...';
      });

      _audioStreamSub = await engines.asr.startStream(
        _audioRecorder,
        (r) => _onAsrPoll(side, r),
        onAudioSamples: (samples) {
          _sessionAudioChunks.add(Float32List.fromList(samples));
          _recordedSampleCount += samples.length;
        },
      );
    } catch (e) {
      debugPrint('Dual dialogue recording error: $e');
      setState(() {
        _activeSide = null;
        _status = 'Ready';
      });
    }
  }

  Future<void> _stopRecording() async {
    await _stopRecordingInternal(flush: true);
  }

  Future<void> _stopRecordingInternal({required bool flush}) async {
    final side = _activeSide;
    try {
      await _audioRecorder.stop();
      await _audioStreamSub?.cancel();
      _audioStreamSub = null;

      if (flush && side != null) {
        final engines = _engines(side);
        if (engines.asr.isInitialized) {
          final r = await engines.asr.flushAndPoll();
          _consumeFinalized(side, r);
        }
      }
    } catch (e) {
      debugPrint('Dual dialogue stop error: $e');
    }

    if (mounted) {
      setState(() {
        _activeSide = null;
        _livePartial = '';
        if (!_isProcessingQueue && !_isProcessingTtsQueue) {
          _status = 'Ready';
        }
      });
    } else {
      _activeSide = null;
      _livePartial = '';
    }
  }

  void _onAsrPoll(_SpeakerSide side, VoiceEnginePollResult r) {
    _consumeFinalized(side, r);
    final engines = _engines(side);
    setState(() {
      _livePartial = (r.speaking && r.partial.isNotEmpty)
          ? AsrService.formatTextWithCasing(r.partial, engines.asrModel?.casing ?? 'mixed')
          : (r.speaking ? 'Speaking...' : '');
    });
  }

  void _consumeFinalized(_SpeakerSide side, VoiceEnginePollResult r) {
    final engines = _engines(side);
    final offsetSec = _samplesAtRecordingStart / 16000.0;

    for (int i = 0; i < r.finalized.length; i++) {
      final f = r.finalized[i];
      var text = AsrService.stripLeadingPuncs(f);
      text = AsrService.formatTextWithCasing(text, engines.asrModel?.casing ?? 'mixed');
      if (text.isEmpty) continue;

      double segStart = 0.0;
      double segEnd = 0.0;
      if (i < r.segments.length) {
        segStart = offsetSec + r.segments[i].start;
        segEnd = offsetSec + r.segments[i].end;
      }
      if (segEnd <= segStart) {
        segEnd = _recordedSampleCount / 16000.0;
        segStart = (segEnd - 2.0).clamp(offsetSec, segEnd);
      }

      final bubble = _DialogueBubble(
        id: 'b${_bubbleSeq++}',
        side: side,
        asr: text,
        at: DateTime.now(),
        start: segStart,
        end: segEnd,
      );
      setState(() {
        _bubbles.add(bubble);
      });
      _scrollToBottom();
      _persistHistory(immediate: true);

      _sentenceQueue.add({'bubbleId': bubble.id, 'side': side, 'text': text});
      _processQueue();
    }
  }

  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    while (_sentenceQueue.isNotEmpty) {
      final entry = _sentenceQueue.removeAt(0);
      final bubbleId = entry['bubbleId'] as String;
      final side = entry['side'] as _SpeakerSide;
      final sentence = entry['text'] as String;

      setState(() => _status = 'Translating...');

      final srcLang = side == _SpeakerSide.a ? _langA : _langB;
      final tgtLang = side == _SpeakerSide.a ? _langB : _langA;

      NmtBackend? backend;
      if (_mtMode == 'llm') {
        final llm = _sharedLlm;
        if (llm != null && llm.isLoaded) {
          await llm.setLanguages(srcLang, tgtLang);
          backend = llm;
        }
      } else {
        backend = _engines(side).nmt;
      }

      if (backend == null || !backend.isLoaded) {
        _updateBubbleMt(bubbleId, '[Error] MT not ready', done: true);
        _persistHistory(immediate: true);
        continue;
      }

      String translated = '';
      try {
        await for (final partial in backend.translateStream(sentence)) {
          translated = partial;
          _updateBubbleMt(bubbleId, partial, done: false);
          _persistHistory(immediate: false);
        }
      } catch (e) {
        _updateBubbleMt(bubbleId, '[Error] $e', done: true);
        _persistHistory(immediate: true);
        continue;
      }

      final finalized = translated.trim();
      if (finalized.isEmpty) {
        _updateBubbleMt(bubbleId, '', done: true);
        _persistHistory(immediate: true);
        continue;
      }

      _updateBubbleMt(bubbleId, finalized, done: true);
      _persistHistory(immediate: true);

      if (_useTts) {
        // A spoke → play with TTS_B (target language); B spoke → TTS_A
        final ttsSide = side == _SpeakerSide.a ? _SpeakerSide.b : _SpeakerSide.a;
        _ttsQueue.add({'text': finalized, 'ttsSide': ttsSide});
        _processTtsQueue();
      }
    }

    _isProcessingQueue = false;
    if (mounted && !_isRecording && !_isProcessingTtsQueue) {
      setState(() => _status = 'Ready');
    }
  }

  void _updateBubbleMt(String bubbleId, String mt, {required bool done}) {
    final idx = _bubbles.indexWhere((b) => b.id == bubbleId);
    if (idx < 0) return;
    if (!mounted) {
      _bubbles[idx].mt = mt;
      _bubbles[idx].mtDone = done;
      return;
    }
    setState(() {
      _bubbles[idx].mt = mt;
      _bubbles[idx].mtDone = done;
    });
  }

  Future<void> _processTtsQueue() async {
    if (_isProcessingTtsQueue) return;
    _isProcessingTtsQueue = true;

    while (_ttsQueue.isNotEmpty) {
      final entry = _ttsQueue.removeAt(0);
      final text = entry['text'] as String;
      final ttsSide = entry['ttsSide'] as _SpeakerSide;
      final engines = _engines(ttsSide);

      if (!engines.tts.isInitialized || engines.ttsModel == null) continue;

      setState(() {
        _status = 'Speaking...';
        _isTtsPlaying = true;
        _currentlyPlayingSide = ttsSide;
      });

      try {
        final result = await engines.tts.synthesize(
          text: text,
          model: engines.ttsModel!,
          speakerId: engines.speakerId,
          speed: engines.ttsSpeed,
          prefix: 'tts-dual-${ttsSide == _SpeakerSide.a ? 'a' : 'b'}',
          suffix: '-sid-${engines.speakerId}-speed-${engines.ttsSpeed.toStringAsFixed(1)}',
        );

        _playCompleter = Completer<void>();
        await _audioPlayer.play(DeviceFileSource(result.wavPath));
        await _playCompleter!.future;
      } catch (e) {
        debugPrint('Dual dialogue TTS error: $e');
      } finally {
        if (mounted) {
          setState(() {
            _isTtsPlaying = false;
            _currentlyPlayingSide = null;
          });
        } else {
          _isTtsPlaying = false;
          _currentlyPlayingSide = null;
        }
      }
    }

    _isProcessingTtsQueue = false;
    if (mounted && !_isRecording && !_isProcessingQueue) {
      setState(() => _status = 'Ready');
    }
  }

  /// Stop all TTS playback and clear the queue.
  Future<void> _stopTts() async {
    _ttsQueue.clear();
    await _audioPlayer.stop();
    _playCompleter?.complete();
    _playCompleter = null;
    if (!mounted) return;
    setState(() {
      _isProcessingTtsQueue = false;
      _isTtsPlaying = false;
      _currentlyPlayingSide = null;
      _status = _isRecording
          ? (_activeSide == _SpeakerSide.a ? 'Listening (A)...' : 'Listening (B)...')
          : 'Ready';
    });
  }

  /// Stop TTS if the specified side is currently playing.
  Future<void> _stopTtsForSide(_SpeakerSide side) async {
    if (_currentlyPlayingSide == side) {
      await _stopTts();
    }
  }

  bool _canStopTtsForSide(_SpeakerSide side) {
    return _useTts && (_isTtsPlaying || _isProcessingTtsQueue) && _currentlyPlayingSide == side;
  }

  /// Replay the latest translation from the counterpart of [side].
  Future<void> _replayTtsForSide(_SpeakerSide side) async {
    if (!_useTts) return;

    // Ensure only one audio plays at a time: stop any ongoing playback first
    await _stopTts();
    if (_isRecording) {
      await _stopRecording();
    }

    final counterpart = side == _SpeakerSide.a ? _SpeakerSide.b : _SpeakerSide.a;

    _DialogueBubble? lastCounterpartBubble;
    for (int i = _bubbles.length - 1; i >= 0; i--) {
      if (_bubbles[i].side == counterpart &&
          _bubbles[i].mt.trim().isNotEmpty &&
          !_bubbles[i].mt.startsWith('[Error]')) {
        lastCounterpartBubble = _bubbles[i];
        break;
      }
    }

    if (lastCounterpartBubble == null) return;

    final engines = _engines(side);
    if (!engines.tts.isInitialized || engines.ttsModel == null) return;

    _ttsQueue.add({'text': lastCounterpartBubble.mt.trim(), 'ttsSide': side});
    _processTtsQueue();
  }

  bool _canReplayTtsForSide(_SpeakerSide side) {
    if (!_useTts) return false;
    final engines = _engines(side);
    if (!engines.tts.isInitialized || engines.ttsModel == null) return false;

    final counterpart = side == _SpeakerSide.a ? _SpeakerSide.b : _SpeakerSide.a;
    return _bubbles.any((b) =>
        b.side == counterpart && b.mt.trim().isNotEmpty && !b.mt.startsWith('[Error]'));
  }

  Float32List _concatSessionAudio() {
    if (_sessionAudioChunks.isEmpty || _recordedSampleCount <= 0) {
      return Float32List(1600);
    }
    final all = Float32List(_recordedSampleCount);
    int offset = 0;
    for (final chunk in _sessionAudioChunks) {
      final remaining = all.length - offset;
      if (remaining <= 0) break;
      final n = chunk.length < remaining ? chunk.length : remaining;
      all.setRange(offset, offset + n, chunk);
      offset += n;
    }
    return all;
  }

  void _persistHistory({required bool immediate}) {
    if (_currentSessionId == null || _bubbles.isEmpty) return;

    Future<void> enqueueSave() {
      final prev = _persistInFlight ?? Future<void>.value();
      final next = prev.catchError((_) {}).then((_) => _writeHistorySnapshot());
      _persistInFlight = next;
      return next;
    }

    if (immediate) {
      _persistDebounce?.cancel();
      enqueueSave();
    } else {
      _persistDebounce?.cancel();
      _persistDebounce = Timer(const Duration(milliseconds: 300), enqueueSave);
    }
  }

  Future<void> _writeHistorySnapshot() async {
    if (_currentSessionId == null || _bubbles.isEmpty) return;

    try {
      final samples = _concatSessionAudio();
      final audioPath = await DualDialogueHistoryStore.saveVadAudioWav(
        id: _currentSessionId!,
        samples: samples,
      );

      // Preserve any translations already on disk if a concurrent ASR-only
      // snapshot races ahead of MT completion.
      final existing = await DualDialogueHistoryStore.load(_currentSessionId!);
      final existingMtByKey = <String, String>{};
      if (existing != null) {
        for (final t in existing.turns) {
          final key = '${t.side}|${t.asr}';
          if (t.mt.trim().isNotEmpty) {
            existingMtByKey[key] = t.mt;
          }
        }
      }

      final turns = _bubbles.map((b) {
        final side = b.side == _SpeakerSide.a ? 'A' : 'B';
        var mt = b.mt;
        if (mt.trim().isEmpty) {
          mt = existingMtByKey['$side|${b.asr}'] ?? '';
        }
        return DualDialogueTurn(
          side: side,
          asr: b.asr,
          mt: mt,
          at: b.at,
          start: b.start,
          end: b.end > b.start ? b.end : b.start + 1.0,
        );
      }).toList();

      double duration = samples.length / 16000.0;
      for (final t in turns) {
        if (t.end > duration) duration = t.end;
      }

      final session = DualDialogueHistoryStore.buildSession(
        turns: turns,
        langA: _langA,
        langB: _langB,
        mtMode: _mtMode,
        existingId: _currentSessionId,
        createdAt: _sessionCreatedAt,
        title: _sessionTitle,
        audioPath: audioPath,
        duration: duration,
      );
      await DualDialogueHistoryStore.save(session);
    } catch (e) {
      debugPrint('Failed to save dual dialogue history: $e');
    } finally {
      // Clear only if we are still the tail of the chain.
      // (Subsequent enqueues replace _persistInFlight with a longer chain.)
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _clearConversation() {
    _stopTts();
    _sentenceQueue.clear();
    setState(() {
      _bubbles.clear();
      _bubbleSeq = 0;
      _livePartial = '';
      _status = _isEnginesReady ? 'Ready' : 'Ready (Not Initialized)';
    });
    _sessionAudioChunks.clear();
    _recordedSampleCount = 0;
    _samplesAtRecordingStart = 0;
    if (_isEnginesReady) {
      final now = DateTime.now();
      _currentSessionId = DualDialogueHistoryStore.newId();
      _sessionCreatedAt = now;
      _sessionTitle = DualDialogueHistoryStore.defaultTitle(now);
    } else {
      _currentSessionId = null;
      _sessionCreatedAt = null;
      _sessionTitle = null;
    }
  }

  void _openHistory() {
    _audioPlayer.stop();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AudioFileHistorySheet(
        title: '双人对话历史记录',
        subtitle: '浏览双人对话历史，回放录音并导出字幕 / ZIP',
        fetchItems: DualDialogueHistoryStore.listAsAudioSummaries,
        loadSession: DualDialogueHistoryStore.loadAsAudioSession,
        deleteItem: DualDialogueHistoryStore.delete,
        renameItem: DualDialogueHistoryStore.rename,
        stackedTranslationPreview: true,
      ),
    );
  }

  void _openModelManagement(String type) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: type,
        onModelsChanged: _loadModels,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asrAList = _allAsrModels.where((m) => m.languages.contains(_langA)).toList();
    final asrBList = _allAsrModels.where((m) => m.languages.contains(_langB)).toList();
    final nmtAList = _allNmtModels.where((m) => m.language == '$_langA-$_langB').toList();
    final nmtBList = _allNmtModels.where((m) => m.language == '$_langB-$_langA').toList();
    final ttsAList = _allTtsModels.where((m) => m.languages.contains(_langA)).toList();
    final ttsBList = _allTtsModels.where((m) => m.languages.contains(_langB)).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F9),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Keep a large chat pane while allowing the config block to scroll.
                  final chatHeight = (constraints.maxHeight * 0.72).clamp(420.0, 900.0);
                  return SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.people_alt_rounded, size: 24, color: Color(0xFF1E3C72)),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: ResponsiveBilingualText(
                                          english: 'Dual Dialogue',
                                          chinese: '双人对话',
                                          style: const TextStyle(
                                            fontSize: 18,
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
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Text(
                              _status,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _buildLanguageCard(),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _buildConfigCard(
                              asrAList: asrAList,
                              asrBList: asrBList,
                              nmtAList: nmtAList,
                              nmtBList: nmtBList,
                              ttsAList: ttsAList,
                              ttsBList: ttsBList,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: chatHeight,
                            child: _buildChatArea(),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            _buildMicBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildLanguageCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Speaker A', style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                _buildLangDropdown(
                  value: _langA,
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _langA = v;
                      _updateSelectedModels();
                    });
                    _deinitializeAll();
                  },
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _swapLanguages,
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E3C72).withOpacity(0.06),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF1E3C72), size: 20),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Speaker B', style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                _buildLangDropdown(
                  value: _langB,
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _langB = v;
                      _updateSelectedModels();
                    });
                    _deinitializeAll();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLangDropdown({
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey, size: 18),
          items: LanguageManager.languages
              .map((lang) => DropdownMenuItem(
                    value: lang,
                    child: Text(lang, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildConfigCard({
    required List<ModelInfo> asrAList,
    required List<ModelInfo> asrBList,
    required List<ModelInfo> nmtAList,
    required List<ModelInfo> nmtBList,
    required List<ModelInfo> ttsAList,
    required List<ModelInfo> ttsBList,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _isConfigExpanded = !_isConfigExpanded),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.settings_outlined, size: 18, color: Color(0xFF1E3C72)),
                  const SizedBox(width: 8),
                  const Text(
                    'Engine Model Settings',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                  Icon(
                    _isConfigExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: Colors.grey.shade600,
                    size: 20,
                  ),
                  const Spacer(),
                  _buildReadyBadge(),
                ],
              ),
            ),
          ),
          if (_isConfigExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  _dropdownLabel('ASR A ($_langA)', 'asr'),
                  const SizedBox(height: 4),
                  _modelDropdown(
                    value: _sideA.asrModel,
                    items: asrAList,
                    hint: 'Select ASR A',
                    onChanged: (v) {
                      setState(() {
                        _sideA.asrModel = v;
                        _sideA.asr.deinitialize();
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  _dropdownLabel('ASR B ($_langB)', 'asr'),
                  const SizedBox(height: 4),
                  _modelDropdown(
                    value: _sideB.asrModel,
                    items: asrBList,
                    hint: 'Select ASR B',
                    onChanged: (v) {
                      setState(() {
                        _sideB.asrModel = v;
                        _sideB.asr.deinitialize();
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text('Translation Method', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(child: _mtModeButton('Llama GGUF', 'llm', Icons.psychology_rounded)),
                      const SizedBox(width: 8),
                      Expanded(child: _mtModeButton('Opus MT', 'nmt', Icons.shuffle_on_rounded)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_mtMode == 'llm') ...[
                    _dropdownLabel('Shared LLM', 'llm'),
                    const SizedBox(height: 4),
                    _modelDropdown(
                      value: _selectedLlmModel,
                      items: _allLlmModels,
                      hint: 'Select LLM',
                      onChanged: (v) {
                        setState(() {
                          _selectedLlmModel = v;
                        });
                        _sharedLlm?.release();
                        _sharedLlm = null;
                      },
                    ),
                  ] else ...[
                    _dropdownLabel('NMT A→B ($_langA-$_langB)', 'nmt'),
                    const SizedBox(height: 4),
                    _modelDropdown(
                      value: _sideA.nmtModel,
                      items: nmtAList,
                      hint: 'Select NMT A→B',
                      onChanged: (v) {
                        setState(() => _sideA.nmtModel = v);
                        _sideA.nmt?.release();
                        _sideA.nmt = null;
                      },
                    ),
                    const SizedBox(height: 10),
                    _dropdownLabel('NMT B→A ($_langB-$_langA)', 'nmt'),
                    const SizedBox(height: 4),
                    _modelDropdown(
                      value: _sideB.nmtModel,
                      items: nmtBList,
                      hint: 'Select NMT B→A',
                      onChanged: (v) {
                        setState(() => _sideB.nmtModel = v);
                        _sideB.nmt?.release();
                        _sideB.nmt = null;
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Enable TTS', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    value: _useTts,
                    onChanged: (v) {
                      setState(() => _useTts = v);
                      if (!v) {
                        _sideA.tts.deinitialize();
                        _sideB.tts.deinitialize();
                      }
                    },
                  ),
                  if (_useTts) ...[
                    _dropdownLabel('TTS A ($_langA, plays B→A)', 'tts'),
                    const SizedBox(height: 4),
                    _modelDropdown(
                      value: _sideA.ttsModel,
                      items: ttsAList,
                      hint: 'Select TTS A',
                      onChanged: (v) {
                        setState(() {
                          _sideA.ttsModel = v;
                          _sideA.tts.deinitialize();
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    _dropdownLabel('TTS B ($_langB, plays A→B)', 'tts'),
                    const SizedBox(height: 4),
                    _modelDropdown(
                      value: _sideB.ttsModel,
                      items: ttsBList,
                      hint: 'Select TTS B',
                      onChanged: (v) {
                        setState(() {
                          _sideB.ttsModel = v;
                          _sideB.tts.deinitialize();
                        });
                      },
                    ),
                  ],
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    onPressed: (_loadingModels || _isInitializing) ? null : _initializeAllEngines,
                    icon: _isInitializing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.flash_on_rounded, color: Colors.white),
                    label: Text(
                      _isInitializing ? 'Initializing...' : 'Initialize Both Sides',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3C72),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReadyBadge() {
    final ready = _isEnginesReady;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ready ? Colors.green.shade50 : Colors.amber.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ready ? Colors.green.shade200 : Colors.amber.shade200),
      ),
      child: Text(
        ready ? 'Ready' : 'Not Setup',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: ready ? Colors.green : Colors.amber.shade800,
        ),
      ),
    );
  }

  Widget _dropdownLabel(String label, String type) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
        ),
        InkWell(
          onTap: () => _openModelManagement(type),
          child: Text(
            'Manage',
            style: TextStyle(
              fontSize: 11,
              color: Colors.blue.shade700,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    );
  }

  Widget _modelDropdown({
    required ModelInfo? value,
    required List<ModelInfo> items,
    required String hint,
    required ValueChanged<ModelInfo?> onChanged,
  }) {
    final effective = (value != null && items.contains(value)) ? value : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ModelInfo>(
          value: effective,
          isExpanded: true,
          hint: Text(hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey, size: 18),
          items: items
              .map((m) => DropdownMenuItem(
                    value: m,
                    child: Text(
                      m.name,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _mtModeButton(String label, String value, IconData icon) {
    final selected = _mtMode == value;
    return GestureDetector(
      onTap: () {
        setState(() {
          _mtMode = value;
          _updateSelectedModels();
        });
        _sideA.nmt?.release();
        _sideA.nmt = null;
        _sideB.nmt?.release();
        _sideB.nmt = null;
        _sharedLlm?.release();
        _sharedLlm = null;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1E3C72) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? const Color(0xFF1E3C72) : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: selected ? Colors.white : Colors.grey.shade600),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: selected ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatArea() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: _bubbles.isEmpty && _livePartial.isEmpty
          ? Center(
              child: Text(
                _isEnginesReady
                    ? '按底部两侧麦克风开始对话\nOnly one side can record at a time'
                    : '请先初始化两边模型',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade500, height: 1.5),
              ),
            )
          : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              itemCount: _bubbles.length + (_livePartial.isNotEmpty ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _bubbles.length) {
                  final side = _activeSide ?? _SpeakerSide.a;
                  return _bubbleWidget(
                    side: side,
                    asr: _livePartial,
                    mt: '',
                    isLive: true,
                  );
                }
                final b = _bubbles[index];
                return _bubbleWidget(side: b.side, asr: b.asr, mt: b.mt, isLive: false);
              },
            ),
    );
  }

  Widget _bubbleWidget({
    required _SpeakerSide side,
    required String asr,
    required String mt,
    required bool isLive,
  }) {
    final isA = side == _SpeakerSide.a;
    final bg = isA ? const Color(0xFFE8EEF7) : const Color(0xFFE6F5F2);
    final border = isA ? const Color(0xFFC5D4EA) : const Color(0xFFB7E0D8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: isA ? Alignment.centerLeft : Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isLive ? bg.withOpacity(0.7) : bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asr.isEmpty ? '...' : asr,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: const Color(0xFF2D3748),
                    fontStyle: isLive ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
                if (mt.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: border)),
                    ),
                    child: Text(
                      mt,
                      style: TextStyle(fontSize: 13, height: 1.3, color: Colors.grey.shade700),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMicBar() {
    final ready = _isEnginesReady && !_isInitializing;
    final aRecording = _activeSide == _SpeakerSide.a && _isRecording;
    final bRecording = _activeSide == _SpeakerSide.b && _isRecording;

    final aCanStop = _canStopTtsForSide(_SpeakerSide.a);
    final aCanReplay = _canReplayTtsForSide(_SpeakerSide.a);

    final bCanStop = _canStopTtsForSide(_SpeakerSide.b);
    final bCanReplay = _canReplayTtsForSide(_SpeakerSide.b);

    final aPlaying = _currentlyPlayingSide == _SpeakerSide.a;
    final bPlaying = _currentlyPlayingSide == _SpeakerSide.b;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Speaker A section
          _sideControlGroup(
            side: _SpeakerSide.a,
            label: 'A ($_langA)',
            color: const Color(0xFF1E3C72),
            recording: aRecording,
            enabled: ready,
            canStop: aCanStop,
            canReplay: aCanReplay,
            onMicPressed: () => _toggleRecording(_SpeakerSide.a),
            onStopPressed: () => _stopTtsForSide(_SpeakerSide.a),
            onReplayPressed: () => _replayTtsForSide(_SpeakerSide.a),
          ),

          // Center Status & Clear section
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                aRecording
                    ? 'A 收音中'
                    : bRecording
                        ? 'B 收音中'
                        : aPlaying
                            ? 'A 播放中'
                            : bPlaying
                                ? 'B 播放中'
                                : '点一侧开始 · 可切换',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: (aRecording || bRecording || aPlaying || bPlaying)
                      ? FontWeight.bold
                      : FontWeight.normal,
                  color: (aRecording || bRecording)
                      ? Colors.redAccent
                      : (aPlaying || bPlaying)
                          ? const Color(0xFF1E3C72)
                          : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _clearConversation,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline_rounded, size: 16, color: Colors.grey.shade700),
                        const SizedBox(width: 4),
                        Text(
                          '清空',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Speaker B section
          _sideControlGroup(
            side: _SpeakerSide.b,
            label: 'B ($_langB)',
            color: const Color(0xFF2A9D8F),
            recording: bRecording,
            enabled: ready,
            canStop: bCanStop,
            canReplay: bCanReplay,
            onMicPressed: () => _toggleRecording(_SpeakerSide.b),
            onStopPressed: () => _stopTtsForSide(_SpeakerSide.b),
            onReplayPressed: () => _replayTtsForSide(_SpeakerSide.b),
          ),
        ],
      ),
    );
  }

  Widget _sideControlGroup({
    required _SpeakerSide side,
    required String label,
    required Color color,
    required bool recording,
    required bool enabled,
    required bool canStop,
    required bool canReplay,
    required VoidCallback onMicPressed,
    required VoidCallback onStopPressed,
    required VoidCallback onReplayPressed,
  }) {
    final isA = side == _SpeakerSide.a;

    final stopBtn = _sideActionButton(
      icon: Icons.stop_rounded,
      tooltip: '停止播放 ($label)',
      color: Colors.deepOrange.shade600,
      enabled: canStop,
      isFilledWhenEnabled: true,
      onTap: onStopPressed,
    );

    final replayBtn = _sideActionButton(
      icon: Icons.replay_rounded,
      tooltip: '重播对方翻译 ($label)',
      color: color,
      enabled: canReplay,
      onTap: onReplayPressed,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: recording ? Colors.redAccent : color,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isA) ...[
              stopBtn,
              const SizedBox(width: 4),
              _micButtonCircle(
                color: color,
                recording: recording,
                enabled: enabled,
                onPressed: onMicPressed,
              ),
              const SizedBox(width: 4),
              replayBtn,
            ] else ...[
              replayBtn,
              const SizedBox(width: 4),
              _micButtonCircle(
                color: color,
                recording: recording,
                enabled: enabled,
                onPressed: onMicPressed,
              ),
              const SizedBox(width: 4),
              stopBtn,
            ],
          ],
        ),
      ],
    );
  }

  Widget _sideActionButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
    bool isFilledWhenEnabled = false,
  }) {
    final activeBg = isFilledWhenEnabled ? color : color.withOpacity(0.12);
    final activeIconColor = isFilledWhenEnabled ? Colors.white : color;

    return Tooltip(
      message: tooltip,
      child: AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.3,
        duration: const Duration(milliseconds: 180),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            customBorder: const CircleBorder(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? activeBg : Colors.grey.shade100,
                border: Border.all(
                  color: enabled ? color.withOpacity(0.4) : Colors.grey.shade300,
                ),
                boxShadow: (enabled && isFilledWhenEnabled)
                    ? [
                        BoxShadow(
                          color: color.withOpacity(0.35),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                icon,
                color: enabled ? activeIconColor : Colors.grey.shade400,
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _micButtonCircle({
    required Color color,
    required bool recording,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !enabled
                ? Colors.grey.shade300
                : recording
                    ? Colors.redAccent
                    : color,
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: (recording ? Colors.redAccent : color).withOpacity(0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            recording ? Icons.stop_rounded : Icons.mic_rounded,
            color: Colors.white,
            size: 26,
          ),
        ),
      ),
    );
  }
}
