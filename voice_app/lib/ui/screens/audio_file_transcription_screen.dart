import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

import 'package:voice_app/services/asr_service.dart';
import 'package:voice_app/services/nmt_service_common.dart';
import 'package:voice_app/services/llama_nmt_service.dart';
import 'package:voice_app/services/native_nmt_service.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ffi/voice_engine_ffi_bridge.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:path/path.dart' as p;
import 'package:voice_app/models/subtitle_segment.dart';
import 'package:voice_app/services/audio_file_history_store.dart';
import 'package:voice_app/ui/widgets/audio_file_history_sheet.dart';
import 'package:voice_app/services/subtitle_export_service.dart';

class AudioFileTranscriptionScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const AudioFileTranscriptionScreen({Key? key, this.showPerfMetrics = false}) : super(key: key);

  @override
  State<AudioFileTranscriptionScreen> createState() => _AudioFileTranscriptionScreenState();
}

class _AudioFileTranscriptionScreenState extends State<AudioFileTranscriptionScreen> {
  // Engines & Playback
  final AsrService _asr = AsrService();
  NmtBackend? _nmtBackend;
  late final AudioPlayer _audioPlayer;
  final ScrollController _subtitlesScrollController = ScrollController();

  // Model Lists
  List<ModelInfo> _allAsrModels = [];
  List<ModelInfo> _allNmtModels = [];
  List<ModelInfo> _allLlmModels = [];
  bool _loadingModels = true;
  bool _isConfigExpanded = true;

  // Selected Models & Options
  ModelInfo? _selectedAsrModel;
  ModelInfo? _selectedNmtModel;
  ModelInfo? _selectedLlmModel;
  String _selectedSourceLang = 'Chinese';
  String _selectedTargetLang = 'English';
  String _mtMode = 'llm'; // 'llm' (Llama GGUF) or 'nmt' (Opus MT)
  bool _enableTranslation = true;

  // Audio File State
  String? _selectedFilePath;
  String? _selectedFileName;
  int? _fileSampleSize;
  int? _fileSampleRate;
  double? _fileDuration;
  Float32List? _audioSamples;

  // Execution State
  bool _isProcessing = false;
  double _processProgress = 0.0;
  List<SubtitleSegment> _subtitles = [];
  int _currentPlayingIndex = -1;
  PlayerState _playerState = PlayerState.stopped;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackDuration = Duration.zero;

  // Performance / Stats
  double? _asrTimeSec;
  double? _asrRtf;
  double? _translationTimeSec;
  double? _translationRtf;
  int _totalTranslationTokens = 0;
  double? _translationTokensPerSec;

  double _asrProgress = 0.0;
  double _translationProgress = 0.0;
  int _totalSegmentsCount = 0;
  int _translatedSegmentsCount = 0;
  final List<Future<void>> _translationFutures = [];
  Stopwatch? _processingStopwatch;
  String _partialText = "";

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    
    _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) {
        setState(() {
          _playbackPosition = pos;
          _updatePlayingSubtitleIndex();
        });
      }
    });

    _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) {
        setState(() {
          _playbackDuration = dur;
        });
      }
    });

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _playerState = state;
        });
      }
    });

    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  @override
  void dispose() {
    ModelManager.changeNotifier.removeListener(_loadModels);
    _deinitializeAll();
    _audioPlayer.dispose();
    _subtitlesScrollController.dispose();

    // Clean up temporary audio file on iOS if copied
    if (_selectedFilePath != null && _selectedFilePath!.contains('temp_transcribe_')) {
      try {
        final file = File(_selectedFilePath!);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (e) {
        print('Failed to delete temp file on dispose: $e');
      }
    }

    super.dispose();
  }

  Future<void> _loadModels() async {
    if (!mounted) return;
    setState(() => _loadingModels = true);

    final asrs = await ModelManager.getModels('asr');
    final nmts = await ModelManager.getModels('nmt');
    final llms = await ModelManager.getModels('llm');

    if (!mounted) return;
    setState(() {
      _allAsrModels = asrs;
      _allNmtModels = nmts;
      _allLlmModels = llms;
      _loadingModels = false;

      _updateSelectedModels();
    });
  }

  void _updateSelectedModels() {
    // 1. Choose ASR model
    final targetAsrPair = '$_selectedSourceLang-$_selectedTargetLang';
    final targetLangAsrs = _allAsrModels.where((m) => m.languages.contains(_selectedSourceLang)).toList();
    if (targetLangAsrs.isNotEmpty) {
      if (_selectedAsrModel == null || !targetLangAsrs.contains(_selectedAsrModel)) {
        _selectedAsrModel = targetLangAsrs.first;
      }
    } else if (_allAsrModels.isNotEmpty) {
      _selectedAsrModel = _allAsrModels.first;
    } else {
      _selectedAsrModel = null;
    }

    // 2. Choose NMT model
    final pairNmts = _allNmtModels.where((m) => m.path.contains(targetAsrPair) || m.name.contains(targetAsrPair)).toList();
    if (pairNmts.isNotEmpty) {
      _selectedNmtModel = pairNmts.first;
    } else if (_allNmtModels.isNotEmpty) {
      _selectedNmtModel = _allNmtModels.first;
    } else {
      _selectedNmtModel = null;
    }

    // 3. Choose LLM model
    if (_allLlmModels.isNotEmpty) {
      _selectedLlmModel = _allLlmModels.first;
    } else {
      _selectedLlmModel = null;
    }
  }

  Future<void> _deinitializeAll() async {
    _asr.deinitialize();
    await _nmtBackend?.release();
    _nmtBackend = null;
    setState(() {
      _selectedFilePath = null;
      _selectedFileName = null;
      _audioSamples = null;
      _subtitles = [];
    });
  }

  Future<void> _deinitializeMt() async {
    await _nmtBackend?.release();
    _nmtBackend = null;
    setState(() {
      _selectedFilePath = null;
      _selectedFileName = null;
      _audioSamples = null;
      _subtitles = [];
    });
  }

  Future<void> _initializeModels() async {
    if (_selectedAsrModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an ASR model.')),
      );
      return;
    }

    if (_enableTranslation) {
      if (_mtMode == 'nmt' && _selectedNmtModel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an Opus NMT model.')),
        );
        return;
      }
      if (_mtMode == 'llm' && _selectedLlmModel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an LLM model.')),
        );
        return;
      }
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      if (!_asr.isInitialized) {
        await _asr.initialize(_selectedAsrModel!);
      } else {
        _asr.reset();
      }

      if (_enableTranslation) {
        if (_mtMode == 'llm') {
          final llmBackend = _nmtBackend is LlamaNmtService
              ? _nmtBackend as LlamaNmtService
              : null;
          final needReload = llmBackend == null ||
              llmBackend.currentModel?.path != _selectedLlmModel!.path;
          if (needReload) {
            _nmtBackend?.release();
            _nmtBackend = LlamaNmtService();
            await _nmtBackend!.loadModel(
              _selectedLlmModel!,
              sourceLang: _selectedSourceLang,
              targetLang: _selectedTargetLang,
            );
          } else {
            await llmBackend!.setLanguages(_selectedSourceLang, _selectedTargetLang);
          }
        } else {
          if (_nmtBackend == null || _nmtBackend is! NativeNmtService) {
            _nmtBackend?.release();
            _nmtBackend = NativeNmtService();
            await _nmtBackend!.loadModel(_selectedNmtModel!);
          }
        }
      }

      setState(() {
        _isProcessing = false;
        _isConfigExpanded = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Models loaded successfully! You can now pick a media file.'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load models: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _releaseModels() async {
    setState(() {
      _isProcessing = true;
    });
    await _deinitializeAll();
    setState(() {
      _isProcessing = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Models released.')),
      );
    }
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
    _asr.deinitialize();
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
    if (_mtMode == 'llm') {
      _applyLlmLanguages();
    } else {
      _deinitializeMt();
    }
  }

  void _updatePlayingSubtitleIndex() {
    final sec = _playbackPosition.inMilliseconds / 1000.0;
    int foundIdx = -1;
    for (int i = 0; i < _subtitles.length; i++) {
      if (sec >= _subtitles[i].start && sec <= _subtitles[i].end) {
        foundIdx = i;
        break;
      }
    }
    if (foundIdx != _currentPlayingIndex) {
      _currentPlayingIndex = foundIdx;
    }
  }

  Float32List _resample(Float32List input, int fromRate, int toRate) {
    if (fromRate == toRate) return input;
    final ratio = toRate / fromRate;
    final numOutputSamples = (input.length * ratio).round();
    final output = Float32List(numOutputSamples);
    for (int i = 0; i < numOutputSamples; i++) {
      final srcIndex = i / ratio;
      final indexIdx = srcIndex.floor();
      final fraction = srcIndex - indexIdx;
      if (indexIdx >= input.length - 1) {
        output[i] = input[input.length - 1];
      } else {
        output[i] = input[indexIdx] * (1.0 - fraction) + input[indexIdx + 1] * fraction;
      }
    }
    return output;
  }

  Future<void> _pickAudioFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'm4a', 'aac', 'mp4', 'mov', 'm4v'],
      );

      if (result != null && result.files.single.path != null) {
        final originalPath = result.files.single.path!;
        String path = originalPath;

        // On iOS, files from document picker may reside in Inbox folders with restricted access for system frameworks.
        // Copying the file to the app's standard temporary directory resolves any permission/sandbox issues.
        if (Platform.isIOS) {
          final tempDir = await getTemporaryDirectory();
          final ext = result.files.single.extension ?? 'wav';
          final safePath = '${tempDir.path}/temp_transcribe_${DateTime.now().millisecondsSinceEpoch}.$ext';
          
          // Delete the previously copied temp file if it exists
          if (_selectedFilePath != null && _selectedFilePath!.contains('temp_transcribe_')) {
            try {
              final oldFile = File(_selectedFilePath!);
              if (await oldFile.exists()) {
                await oldFile.delete();
              }
            } catch (e) {
              print('Failed to delete old temp file: $e');
            }
          }

          await File(originalPath).copy(safePath);
          path = safePath;
        }

        setState(() {
          _isProcessing = true;
          _processProgress = 0.0;
        });

        // Initialize FFI bindings
        await VoiceEngineBridge.init();
        final decodedSamples = VoiceEngineBridge.instance.decodeAudioFile(path);

        if (decodedSamples == null || decodedSamples.isEmpty) {
          throw Exception("Could not read/decode audio file or file is empty.");
        }

        setState(() {
          _selectedFilePath = path;
          _selectedFileName = result.files.single.name;
          _fileSampleSize = decodedSamples.length;
          _fileSampleRate = 16000; // Audotoolbox natively resampled to 16kHz mono
          _fileDuration = decodedSamples.length / 16000.0;
          _audioSamples = decodedSamples;
          _isProcessing = false;
          _subtitles = [];
          _asrProgress = 0.0;
          _translationProgress = 0.0;
          _totalSegmentsCount = 0;
          _translatedSegmentsCount = 0;
          _asrTimeSec = null;
          _asrRtf = null;
          _translationTimeSec = null;
          _translationRtf = null;
          _totalTranslationTokens = 0;
          _translationTokensPerSec = null;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded & decoded media file: $_selectedFileName (${_fileDuration!.toStringAsFixed(1)}s, 16kHz mono)'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading audio file: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _startProcessing() async {
    if (_audioSamples == null || _selectedFilePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an audio file first.')),
      );
      return;
    }

    if (_selectedAsrModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an ASR model.')),
      );
      return;
    }

    if (_enableTranslation) {
      if (_mtMode == 'nmt' && _selectedNmtModel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an Opus NMT model.')),
        );
        return;
      }
      if (_mtMode == 'llm' && _selectedLlmModel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an LLM model.')),
        );
        return;
      }
    }

    setState(() {
      _isProcessing = true;
      _asrProgress = 0.0;
      _translationProgress = 0.0;
      _totalSegmentsCount = 0;
      _translatedSegmentsCount = 0;
      _totalTranslationTokens = 0;
      _translationFutures.clear();
      _subtitles = [];
      _asrTimeSec = null;
      _asrRtf = null;
      _translationTimeSec = null;
      _translationRtf = null;
      _translationTokensPerSec = null;
    });

    _processingStopwatch = Stopwatch()..start();

    try {
      // Models are already loaded since we enforced flow: load models -> pick file.
      _asr.reset();

      final samples = _audioSamples!;
      final totalSamples = samples.length;
      
      // We feed the audio in chunks of 1600 samples (100ms)
      const chunkSize = 1600;
      int chunkCount = (totalSamples / chunkSize).ceil();
      int currentIdx = 0;

      int lastProgressPercent = -1;
      for (int i = 0; i < totalSamples; i += chunkSize) {
        if (!mounted || !_isProcessing) break;

        final end = (i + chunkSize < totalSamples) ? i + chunkSize : totalSamples;
        final chunk = samples.sublist(i, end);

        VoiceEngineBridge.instance.acceptWaveform(_asr.handle!, chunk);
        final pollResult = VoiceEngineBridge.instance.poll(_asr.handle!);

        await _handlePollResult(pollResult);

        // Update real-time partial transcription
        if (pollResult.partial != _partialText) {
          setState(() {
            _partialText = pollResult.partial;
          });
        }

        currentIdx++;

        // 1. Throttle progress updates to avoid too many rebuilds
        final progress = currentIdx / chunkCount;
        final progressPercent = (progress * 100).round();
        if (progressPercent != lastProgressPercent) {
          lastProgressPercent = progressPercent;
          setState(() {
            _asrProgress = progress;
          });
        }

        // 2. Yield to the event loop every 5 chunks (500ms of audio) instead of every chunk
        if (currentIdx % 5 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }

      // Flush VAD tail
      if (mounted && _isProcessing) {
        final lastPoll = _asr.flushAndPoll();
        await _handlePollResult(lastPoll);
      }

      // ASR completed!
      final double asrElapsed = _processingStopwatch!.elapsedMilliseconds / 1000.0;
      setState(() {
        _asrProgress = 1.0;
        _asrTimeSec = asrElapsed;
        _partialText = ""; // Clear partial text when ASR completes
        if (_fileDuration != null && _fileDuration! > 0) {
          _asrRtf = _asrTimeSec! / _fileDuration!;
        }
      });

      // Await all background translations to complete
      if (_enableTranslation && _translationFutures.isNotEmpty) {
        await Future.wait(_translationFutures);
      }

      _processingStopwatch!.stop();
      final double totalElapsed = _processingStopwatch!.elapsedMilliseconds / 1000.0;

      setState(() {
        _isProcessing = false;
        _translationProgress = 1.0;
        _translationTimeSec = totalElapsed;
        if (_fileDuration != null && _fileDuration! > 0) {
          _translationRtf = _translationTimeSec! / _fileDuration!;
        }
        if (_totalTranslationTokens > 0 && _translationTimeSec! > 0) {
          _translationTokensPerSec = _totalTranslationTokens / _translationTimeSec!;
        }
      });

      // Save to history on successful completion
      if (_subtitles.isNotEmpty && _selectedFilePath != null) {
        try {
          final id = AudioFileHistoryStore.newId();
          final copiedAudioPath = await AudioFileHistoryStore.saveAudioFile(id, _selectedFilePath!);
          
          final session = AudioFileHistorySession(
            id: id,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            fileName: _selectedFileName ?? 'Unnamed Audio',
            sourceLang: _selectedSourceLang,
            targetLang: _selectedTargetLang,
            duration: _fileDuration ?? 0.0,
            audioPath: copiedAudioPath,
            subtitles: List.from(_subtitles),
          );
          
          await AudioFileHistoryStore.save(session);
        } catch (e) {
          debugPrint('Failed to save audio file transcription history: $e');
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transcription & Translation complete!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      _processingStopwatch?.stop();
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error during processing: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handlePollResult(VoiceEnginePollResult r) async {
    if (r.segments.isEmpty) return;

    for (final seg in r.segments) {
      var text = AsrService.stripLeadingPuncs(seg.text);
      text = AsrService.formatTextWithCasing(text, _selectedAsrModel?.casing ?? 'mixed');
      if (text.isEmpty) continue;

      final subSeg = SubtitleSegment(
        index: _subtitles.length + 1,
        start: seg.start,
        end: seg.end,
        originalText: text,
      );

      setState(() {
        _subtitles.add(subSeg);
      });

      if (_enableTranslation && _nmtBackend != null) {
        final subIndex = _subtitles.length - 1;
        _totalSegmentsCount++;
        final future = _translateSegment(subIndex, text);
        _translationFutures.add(future);
      }
    }
  }

  Future<void> _translateSegment(int index, String text) async {
    try {
      final Stream<String> translationStream = _nmtBackend!.translateStream(text);
      String lastResult = "";
      int lastUpdateMs = 0;

      await for (final partial in translationStream) {
        lastResult = partial;

        // Throttle UI updates to at most once per 100ms to prevent frame drops
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastUpdateMs > 100) {
          lastUpdateMs = now;
          if (mounted) {
            setState(() {
              if (index < _subtitles.length) {
                _subtitles[index].translatedText = lastResult.trim();
              }
            });
          }
        }
      }
      if (!mounted) return;

      final timing = _nmtBackend!.lastStreamTiming;
      if (timing != null) {
        _totalTranslationTokens += timing.decoderTokens;
      }

      setState(() {
        if (index < _subtitles.length) {
          _subtitles[index].translatedText = lastResult.trim();
        }
        _translatedSegmentsCount++;
        
        double translatedDuration = 0.0;
        for (final seg in _subtitles) {
          if (seg.translatedText.isNotEmpty) {
            translatedDuration += (seg.end - seg.start);
          }
        }
        if (_fileDuration != null && _fileDuration! > 0) {
          _translationProgress = (translatedDuration / _fileDuration!).clamp(0.0, 1.0);
        }

        if (_processingStopwatch != null) {
          final double elapsed = _processingStopwatch!.elapsedMilliseconds / 1000.0;
          if (elapsed > 0) {
            _translationTokensPerSec = _totalTranslationTokens / elapsed;
          }
        }
      });
    } catch (e) {
      debugPrint("Translation error for segment $index: $e");
      if (mounted && index < _subtitles.length) {
        setState(() {
          _subtitles[index].translatedText = "[Translation Error: $e]";
          _translatedSegmentsCount++;
          
          double translatedDuration = 0.0;
          for (final seg in _subtitles) {
            if (seg.translatedText.isNotEmpty) {
              translatedDuration += (seg.end - seg.start);
            }
          }
          if (_fileDuration != null && _fileDuration! > 0) {
            _translationProgress = (translatedDuration / _fileDuration!).clamp(0.0, 1.0);
          }

          if (_processingStopwatch != null) {
            final double elapsed = _processingStopwatch!.elapsedMilliseconds / 1000.0;
            if (elapsed > 0) {
              _translationTokensPerSec = _totalTranslationTokens / elapsed;
            }
          }
        });
      }
    }
  }

  void _stopProcessing() {
    _processingStopwatch?.stop();
    setState(() {
      _isProcessing = false;
      _partialText = ""; // Clear partial text on stop
    });
  }

  void _togglePlayback() async {
    if (_selectedFilePath == null) return;

    if (_playerState == PlayerState.playing) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play(DeviceFileSource(_selectedFilePath!));
    }
  }

  void _seekToSegment(SubtitleSegment seg) async {
    if (_selectedFilePath == null) return;
    final ms = (seg.start * 1000).round();
    await _audioPlayer.seek(Duration(milliseconds: ms));
    if (_playerState != PlayerState.playing) {
      await _audioPlayer.play(DeviceFileSource(_selectedFilePath!));
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard!')),
    );
  }

  String _generateSrt() {
    final buffer = StringBuffer();
    for (final seg in _subtitles) {
      buffer.write(seg.toSrtString());
    }
    return buffer.toString();
  }

  String _generatePlainText() {
    final buffer = StringBuffer();
    for (final seg in _subtitles) {
      buffer.writeln('[${seg.formatTime(seg.start)} --> ${seg.formatTime(seg.end)}]');
      buffer.writeln(seg.originalText);
      if (seg.translatedText.isNotEmpty) {
        buffer.writeln(seg.translatedText);
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    // Dropdown filters
    final filteredAsrs = _allAsrModels.where((m) => m.languages.contains(_selectedSourceLang)).toList();
    final targetPair = '$_selectedSourceLang-$_selectedTargetLang';
    final filteredNmts = _allNmtModels.where((m) => m.path.contains(targetPair) || m.name.contains(targetPair)).toList();

    return Scaffold(
      body: SafeArea(
        child: _loadingModels
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // --- Title Card ---
                    _buildTitleCard(),
                    const SizedBox(height: 16),

                    // --- Config Section (Accordion style) ---
                    _buildConfigurationAccordion(filteredAsrs, filteredNmts),
                    const SizedBox(height: 16),

                    // --- File Picker and Transcription Card ---
                    _buildFileAndProcessingCard(),
                    const SizedBox(height: 16),

                    // --- Stats / Metrics (If completed) ---
                    if (_asrTimeSec != null) ...[
                      _buildStatsCard(),
                      const SizedBox(height: 16),
                    ],

                    // --- Subtitles Display Card ---
                    _buildSubtitlesCard(),
                  ],
                ),
              ),
      ),
    );
  }

  void _openHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const AudioFileHistorySheet(),
    );
  }

  Widget _buildTitleCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
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
                Row(
                  children: const [
                    Icon(Icons.subtitles_rounded, size: 24, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      'Audio File Transcription',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Offline transcription & translation with timestamps',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _openHistory,
            icon: const Icon(Icons.history_rounded, color: Colors.white, size: 24),
            tooltip: 'Transcription History',
          ),
        ],
      ),
    );
  }

  Widget _buildConfigurationAccordion(List<ModelInfo> filteredAsrs, List<ModelInfo> filteredNmts) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ExpansionPanelList(
        elevation: 0,
        expandedHeaderPadding: EdgeInsets.zero,
        expansionCallback: (index, isExpanded) {
          setState(() {
            _isConfigExpanded = isExpanded;
          });
        },
        children: [
          ExpansionPanel(
            canTapOnHeader: true,
            isExpanded: _isConfigExpanded,
            headerBuilder: (context, isOpen) {
              return const ListTile(
                leading: Icon(Icons.settings_outlined, color: Colors.indigo),
                title: Text(
                  'Engine and Model Configurations',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              );
            },
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Source & Target Languages
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Source Language (ASR)', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Target Language (MT)', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
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
                  const SizedBox(height: 12),

                  // ASR Model Selection
                  const Text('ASR Speech Recognition Model', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<ModelInfo>(
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    isExpanded: true,
                    value: filteredAsrs.contains(_selectedAsrModel) ? _selectedAsrModel : null,
                    hint: const Text('Select ASR Model'),
                    items: filteredAsrs.map((m) {
                      return DropdownMenuItem(
                        value: m,
                        child: Text(m.name, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (model) {
                      setState(() {
                        _selectedAsrModel = model;
                        _deinitializeAll();
                      });
                    },
                  ),
                  const SizedBox(height: 12),

                  // Translation Switcher
                  SwitchListTile(
                    title: const Text('Enable Translation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: const Text('Translate subtitle segments streamingly'),
                    value: _enableTranslation,
                    onChanged: (val) {
                      setState(() {
                        _enableTranslation = val;
                      });
                    },
                    secondary: const Icon(Icons.g_translate_rounded, color: Colors.indigo),
                  ),

                  if (_enableTranslation) ...[
                    const Divider(),
                    // MT Mode Select (Opus or LLM)
                    const Text('Translation Engine', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'llm', label: Text('Llama LLM'), icon: Icon(Icons.psychology_rounded)),
                        ButtonSegment(value: 'nmt', label: Text('Opus MT'), icon: Icon(Icons.translate_rounded)),
                      ],
                      selected: {_mtMode},
                      onSelectionChanged: (selection) {
                        setState(() {
                          _mtMode = selection.first;
                          _deinitializeAll();
                        });
                      },
                    ),
                    const SizedBox(height: 12),

                    // MT Model selection dropdown
                    if (_mtMode == 'nmt') ...[
                      const Text('Opus NMT Model', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<ModelInfo>(
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                        ),
                        isExpanded: true,
                        value: filteredNmts.contains(_selectedNmtModel) ? _selectedNmtModel : null,
                        hint: const Text('Select Opus Model'),
                        items: filteredNmts.map((m) {
                          return DropdownMenuItem(
                            value: m,
                            child: Text(m.name, overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: (model) {
                          setState(() {
                            _selectedNmtModel = model;
                            _deinitializeMt();
                          });
                        },
                      ),
                    ] else ...[
                      const Text('Llama GGUF Model', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<ModelInfo>(
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                        ),
                        isExpanded: true,
                        value: _allLlmModels.contains(_selectedLlmModel) ? _selectedLlmModel : null,
                        hint: const Text('Select LLM Model'),
                        items: _allLlmModels.map((m) {
                          return DropdownMenuItem(
                            value: m,
                            child: Text(m.name, overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: (model) {
                          setState(() {
                            _selectedLlmModel = model;
                            _deinitializeMt();
                          });
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _asr.isInitialized ? Colors.green.shade600 : const Color(0xFF1E3C72),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: _isProcessing ? null : (_asr.isInitialized ? _releaseModels : _initializeModels),
                          icon: Icon(_asr.isInitialized ? Icons.check_circle_rounded : Icons.cloud_download_rounded),
                          label: Text(
                            _asr.isInitialized ? 'Models Loaded (Tap to Release)' : 'Load & Initialize Models',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
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
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildFileAndProcessingCard() {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Media File Source (Audio/Video)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            if (_selectedFileName == null)
              _asr.isInitialized
                  ? OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: const BorderSide(color: Colors.indigo, width: 1.5),
                      ),
                      onPressed: _pickAudioFile,
                      icon: const Icon(Icons.audio_file_rounded),
                      label: const Text('Pick Media File (WAV, MP3, MP4, MOV, etc.)'),
                    )
                  : Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        border: Border.all(color: Colors.orange.shade200),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: const [
                          Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
                          SizedBox(height: 8),
                          Text(
                            'Please load and initialize models above before picking a media file.',
                            style: TextStyle(color: Color(0xFFC05621), fontSize: 13, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.indigo.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.indigo.withOpacity(0.1)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.audiotrack_rounded, color: Colors.indigo, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedFileName!,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Duration: ${_fileDuration!.toStringAsFixed(1)}s  |  Sample Rate: ${_fileSampleRate}Hz',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.grey),
                      onPressed: () {
                        setState(() {
                          _asrProgress = 0.0;
                          _translationProgress = 0.0;
                          _totalSegmentsCount = 0;
                          _translatedSegmentsCount = 0;
                          _asrTimeSec = null;
                          _asrRtf = null;
                          _translationTimeSec = null;
                          _translationRtf = null;
                          _totalTranslationTokens = 0;
                          _translationTokensPerSec = null;
                          _processingStopwatch = null;
                          _partialText = "";
                        });
                      },
                    ),
                  ],
                ),
              ),
            
            if (_selectedFileName != null) ...[
              const SizedBox(height: 16),
              if (_isProcessing) ...[
                // ASR Progress Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'ASR Progress: ${(_asrProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.indigo),
                    ),
                    if (!_enableTranslation || _asrProgress < 1.0)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.indigo),
                      )
                    else
                      const Icon(Icons.check_circle_rounded, color: Colors.green, size: 14),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: _asrProgress,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: Colors.grey.shade200,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.indigo),
                ),
                
                if (_enableTranslation) ...[
                  const SizedBox(height: 12),
                  // Translation Progress Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Translation Progress: ${(_translationProgress * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.teal),
                      ),
                      if (_translationProgress < 1.0)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.teal),
                        )
                      else
                        const Icon(Icons.check_circle_rounded, color: Colors.green, size: 14),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tokens: $_totalTranslationTokens  |  Speed: ${_translationTokensPerSec != null ? _translationTokensPerSec!.toStringAsFixed(1) : '0.0'} tok/s',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.purple),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: _translationProgress,
                    borderRadius: BorderRadius.circular(4),
                    backgroundColor: Colors.grey.shade200,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.teal),
                  ),
                ],
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _stopProcessing,
                  icon: const Icon(Icons.stop_circle_rounded, color: Colors.red),
                  label: const Text('Cancel Processing', style: TextStyle(color: Colors.red)),
                )
              ] else
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _startProcessing,
                  icon: const Icon(Icons.rocket_launch_rounded),
                  label: const Text('Start Transcription & Translation', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Processing Metrics',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87),
                ),
                Text(
                  'Audio Duration: ${_fileDuration!.toStringAsFixed(1)}s',
                  style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                // ASR Metrics Group
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ASR (Speech Recognition)',
                        style: TextStyle(fontSize: 11, color: Colors.indigo, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Time: ${_asrTimeSec != null ? _asrTimeSec!.toStringAsFixed(2) : 'N/A'}s',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'RTF: ${_asrRtf != null ? _asrRtf!.toStringAsFixed(3) : 'N/A'}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: (_asrRtf != null && _asrRtf! < 1.0) ? Colors.green : Colors.orange,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(height: 48, width: 1, color: Colors.grey.shade200),
                const SizedBox(width: 16),
                // MT Metrics Group (only if translation is enabled)
                if (_enableTranslation) ...[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'MT (Translation)',
                          style: TextStyle(fontSize: 11, color: Colors.teal, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Time: ${_translationTimeSec != null ? _translationTimeSec!.toStringAsFixed(2) : 'N/A'}s',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              'RTF: ${_translationRtf != null ? _translationRtf!.toStringAsFixed(3) : 'N/A'}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: (_translationRtf != null && _translationRtf! < 1.0) ? Colors.green : Colors.orange,
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (_translationTokensPerSec != null)
                              Text(
                                '${_translationTokensPerSec!.toStringAsFixed(1)} tok/s ($_totalTranslationTokens tokens)',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.purple),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const Expanded(
                    child: Center(
                      child: Text(
                        'Translation Disabled',
                        style: TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitlesCard() {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Subtitles (${_subtitles.length})',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                if (_subtitles.isNotEmpty && !_isProcessing)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.share_rounded, color: Colors.indigo),
                    tooltip: 'Share / Export',
                    onSelected: (value) {
                      if (value == 'copy_srt') {
                        _copyToClipboard(_generateSrt());
                      } else if (value == 'copy_text') {
                        _copyToClipboard(_generatePlainText());
                      } else if (value == 'export_srt') {
                        _exportSrtFile();
                      } else if (value == 'export_zip') {
                        _exportZipArchive();
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'copy_srt',
                        child: Row(
                          children: [
                            Icon(Icons.copy_rounded, size: 18),
                            SizedBox(width: 8),
                            Text('Copy SRT Format'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'copy_text',
                        child: Row(
                          children: [
                            Icon(Icons.text_format_rounded, size: 18),
                            SizedBox(width: 8),
                            Text('Copy Plain Text'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'export_srt',
                        child: Row(
                          children: [
                            Icon(Icons.download_rounded, size: 18),
                            SizedBox(width: 8),
                            Text('Export SRT File'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'export_zip',
                        child: Row(
                          children: [
                            Icon(Icons.archive_outlined, size: 18),
                            SizedBox(width: 8),
                            Text('Export ZIP Archive (MD + Audio)'),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const Divider(),

            if (_selectedFilePath != null && _subtitles.isNotEmpty) ...[
              // Audio Playback Bar
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _playerState == PlayerState.playing
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        size: 36,
                        color: Colors.indigo,
                      ),
                      onPressed: _togglePlayback,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              trackHeight: 3,
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                            ),
                            child: Slider(
                              value: _playbackPosition.inMilliseconds.toDouble(),
                              max: _playbackDuration.inMilliseconds.toDouble() > 0
                                  ? _playbackDuration.inMilliseconds.toDouble()
                                  : 1.0,
                              onChanged: (val) {
                                _audioPlayer.seek(Duration(milliseconds: val.round()));
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(_playbackPosition),
                                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                                ),
                                Text(
                                  _formatDuration(_playbackDuration),
                                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (_subtitles.isEmpty)
              Container(
                height: 200,
                alignment: Alignment.center,
                child: Text(
                  _isProcessing
                      ? 'Analyzing and generating subtitles...'
                      : 'No subtitles generated yet.',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              )
            else
              Container(
                constraints: const BoxConstraints(maxHeight: 450),
                child: ListView.builder(
                  controller: _subtitlesScrollController,
                  shrinkWrap: false,
                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                  itemCount: _subtitles.length,
                  itemBuilder: (context, index) {
                    final seg = _subtitles[index];
                    final isCurrent = _currentPlayingIndex == index;

                    return GestureDetector(
                      onTap: () => _seekToSegment(seg),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? Colors.indigo.withOpacity(0.08)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isCurrent ? Colors.indigo : Colors.grey.shade200,
                            width: isCurrent ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '#${seg.index}',
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${seg.formatTime(seg.start)} --> ${seg.formatTime(seg.end)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isCurrent ? Colors.indigo : Colors.grey,
                                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                const Spacer(),
                                const Icon(Icons.play_arrow_rounded, size: 16, color: Colors.grey),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              seg.originalText,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                                  color: isCurrent ? Colors.indigo.shade900 : Colors.black87,
                              ),
                            ),
                            if (seg.translatedText.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                seg.translatedText,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontStyle: FontStyle.italic,
                                  color: isCurrent ? Colors.indigo.shade700 : Colors.indigo.shade400,
                                ),
                              ),
                            ] else if (_enableTranslation) ...[
                              const SizedBox(height: 4),
                              const SizedBox(
                                height: 10,
                                width: 10,
                                child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.indigo),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_isProcessing && _partialText.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.indigo.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Transcribing...',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.redAccent),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _partialText,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }

  Future<void> _exportSrtFile() async {
    if (_subtitles.isEmpty) return;
    try {
      final baseAudioName = _selectedFileName != null 
          ? p.basenameWithoutExtension(_selectedFileName!) 
          : 'audio';
      
      final srcLang = _selectedSourceLang.replaceAll(' ', '');
      final tgtLang = _selectedTargetLang.replaceAll(' ', '');
      final now = DateTime.now();
      final timeStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
          
      final srtDefaultName = '${baseAudioName}_${srcLang}_${tgtLang}_$timeStr.srt';
          
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Export SRT File',
        fileName: srtDefaultName,
        type: FileType.custom,
        allowedExtensions: ['srt'],
      );
      
      if (savePath != null) {
        await SubtitleExportService.exportToSrtFile(_subtitles, savePath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('SRT exported successfully to: ${p.basename(savePath)}'), backgroundColor: Colors.green),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export SRT: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _exportZipArchive() async {
    if (_subtitles.isEmpty || _audioSamples == null) return;
    try {
      final baseAudioName = _selectedFileName != null 
          ? p.basenameWithoutExtension(_selectedFileName!) 
          : 'audio';
      
      final srcLang = _selectedSourceLang.replaceAll(' ', '');
      final tgtLang = _selectedTargetLang.replaceAll(' ', '');
      
      final now = DateTime.now();
      final timeStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      
      final zipDefaultName = '${baseAudioName}_${srcLang}_${tgtLang}_$timeStr.zip';
      
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Export ZIP Archive',
        fileName: zipDefaultName,
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      
      if (savePath != null) {
        setState(() {
          _isProcessing = true;
        });
        
        await SubtitleExportService.exportToZip(
          audioFileName: _selectedFileName ?? 'audio.wav',
          sourceLang: _selectedSourceLang,
          targetLang: _selectedTargetLang,
          subtitles: _subtitles,
          audioSamples: _audioSamples!,
          targetZipPath: savePath,
        );
        
        setState(() {
          _isProcessing = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('ZIP exported successfully to: ${p.basename(savePath)}'), backgroundColor: Colors.green),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export ZIP: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }
}
