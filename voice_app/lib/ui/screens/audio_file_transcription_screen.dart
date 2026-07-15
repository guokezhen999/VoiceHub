import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';

import 'package:voice_app/services/asr_service.dart';
import 'package:voice_app/services/nmt_service_common.dart';
import 'package:voice_app/services/llama_nmt_service.dart';
import 'package:voice_app/services/native_nmt_service.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ffi/voice_engine_ffi_bridge.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

class SubtitleSegment {
  final int index;
  final double start; // seconds
  final double end;   // seconds
  final String originalText;
  String translatedText;

  SubtitleSegment({
    required this.index,
    required this.start,
    required this.end,
    required this.originalText,
    this.translatedText = '',
  });

  String formatTime(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).round());
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final secs = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$secs,$ms';
  }

  String toSrtString() {
    final buffer = StringBuffer();
    buffer.writeln(index);
    buffer.writeln('${formatTime(start)} --> ${formatTime(end)}');
    buffer.writeln(originalText);
    if (translatedText.isNotEmpty) {
      buffer.writeln(translatedText);
    }
    buffer.writeln();
    return buffer.toString();
  }
}

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
  String _mtMode = 'nmt'; // 'nmt' (Opus MT) or 'llm' (Llama GGUF)
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
  double? _processingTimeSec;
  double? _rtf;

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

  void _deinitializeAll() {
    _asr.deinitialize();
    _nmtBackend?.release();
    _nmtBackend = null;
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
        allowedExtensions: ['wav'],
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        
        setState(() {
          _isProcessing = true;
          _processProgress = 0.0;
        });

        // Initialize sherpa_onnx bindings to read wave
        sherpa_onnx.initBindings();
        final waveData = sherpa_onnx.readWave(path);

        if (waveData.samples.isEmpty) {
          throw Exception("Could not read WAV file or file is empty.");
        }

        Float32List processedSamples = waveData.samples;
        if (waveData.sampleRate != 16000) {
          processedSamples = _resample(waveData.samples, waveData.sampleRate, 16000);
        }

        setState(() {
          _selectedFilePath = path;
          _selectedFileName = result.files.single.name;
          _fileSampleSize = processedSamples.length;
          _fileSampleRate = waveData.sampleRate;
          _fileDuration = processedSamples.length / 16000.0;
          _audioSamples = processedSamples;
          _isProcessing = false;
          _subtitles = [];
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded WAV file: $_selectedFileName (${_fileDuration!.toStringAsFixed(1)}s, ${waveData.sampleRate}Hz)'),
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
      _processProgress = 0.0;
      _subtitles = [];
      _processingTimeSec = null;
      _rtf = null;
    });

    final stopwatch = Stopwatch()..start();

    try {
      // 1. Initialize ASR engine
      if (!_asr.isInitialized) {
        await _asr.initialize(_selectedAsrModel!);
      } else {
        _asr.reset();
      }

      // 2. Initialize Translation engine if needed
      if (_enableTranslation) {
        if (_mtMode == 'llm') {
          if (_nmtBackend == null || _nmtBackend is! LlamaNmtService) {
            _nmtBackend?.release();
            _nmtBackend = LlamaNmtService();
            await _nmtBackend!.loadModel(
              _selectedLlmModel!,
              sourceLang: _selectedSourceLang,
              targetLang: _selectedTargetLang,
            );
          }
        } else {
          if (_nmtBackend == null || _nmtBackend is! NativeNmtService) {
            _nmtBackend?.release();
            _nmtBackend = NativeNmtService();
            await _nmtBackend!.loadModel(_selectedNmtModel!);
          }
        }
      }

      final samples = _audioSamples!;
      final totalSamples = samples.length;
      
      // We feed the audio in chunks of 1600 samples (100ms)
      const chunkSize = 1600;
      int chunkCount = (totalSamples / chunkSize).ceil();
      int currentIdx = 0;

      for (int i = 0; i < totalSamples; i += chunkSize) {
        if (!mounted || !_isProcessing) break;

        final end = (i + chunkSize < totalSamples) ? i + chunkSize : totalSamples;
        final chunk = samples.sublist(i, end);

        VoiceEngineBridge.instance.acceptWaveform(_asr.handle!, chunk);
        final pollResult = VoiceEngineBridge.instance.poll(_asr.handle!);

        await _handlePollResult(pollResult);

        currentIdx++;
        setState(() {
          _processProgress = currentIdx / chunkCount;
        });

        // Yield to the event loop so the UI is updated and doesn't freeze
        await Future.delayed(Duration.zero);
      }

      // Flush VAD tail
      if (mounted && _isProcessing) {
        final lastPoll = _asr.flushAndPoll();
        await _handlePollResult(lastPoll);
      }

      stopwatch.stop();

      setState(() {
        _isProcessing = false;
        _processProgress = 1.0;
        _processingTimeSec = stopwatch.elapsedMilliseconds / 1000.0;
        if (_fileDuration != null && _fileDuration! > 0) {
          _rtf = _processingTimeSec! / _fileDuration!;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transcription & Translation complete!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      stopwatch.stop();
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
        // Translate asynchronously
        _translateSegment(subIndex, text);
      }
    }
  }

  void _translateSegment(int index, String text) async {
    try {
      final Stream<String> translationStream = _nmtBackend!.translateStream(text);
      await for (final partial in translationStream) {
        if (!mounted) return;
        setState(() {
          if (index < _subtitles.length) {
            _subtitles[index].translatedText = partial.trim();
          }
        });
      }
    } catch (e) {
      debugPrint("Translation error for segment $index: $e");
      if (mounted && index < _subtitles.length) {
        setState(() {
          _subtitles[index].translatedText = "[Translation Error: $e]";
        });
      }
    }
  }

  void _stopProcessing() {
    setState(() {
      _isProcessing = false;
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
                    if (_processingTimeSec != null) ...[
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

  Widget _buildTitleCard() {
    return Container(
      padding: const EdgeInsets.all(16),
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
      child: const Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.subtitles_rounded, size: 28, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'Audio Transcription & Subtitles',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          SizedBox(height: 6),
          Text(
            'Offline audio file transcription with auto translation & timestamps',
            style: TextStyle(fontSize: 12, color: Colors.white70),
            textAlign: TextAlign.center,
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
                                if (val != null) {
                                  setState(() {
                                    _selectedSourceLang = val;
                                    _updateSelectedModels();
                                    _deinitializeAll();
                                  });
                                }
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
                                if (val != null) {
                                  setState(() {
                                    _selectedTargetLang = val;
                                    _updateSelectedModels();
                                    _deinitializeAll();
                                  });
                                }
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
                        ButtonSegment(value: 'nmt', label: Text('Opus MT'), icon: Icon(Icons.translate_rounded)),
                        ButtonSegment(value: 'llm', label: Text('Llama LLM'), icon: Icon(Icons.psychology_rounded)),
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
                            _deinitializeAll();
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
                            _deinitializeAll();
                          });
                        },
                      ),
                    ],
                  ],
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
          items: supportedLanguages.map((lang) {
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
              'Audio File Source',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            if (_selectedFileName == null)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  side: const BorderSide(color: Colors.indigo, width: 1.5),
                ),
                onPressed: _pickAudioFile,
                icon: const Icon(Icons.audio_file_rounded),
                label: const Text('Pick 16kHz WAV Audio File'),
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
                          _selectedFilePath = null;
                          _selectedFileName = null;
                          _fileSampleSize = null;
                          _fileSampleRate = null;
                          _fileDuration = null;
                          _audioSamples = null;
                          _subtitles = [];
                        });
                      },
                    ),
                  ],
                ),
              ),
            
            if (_selectedFileName != null) ...[
              const SizedBox(height: 16),
              if (_isProcessing) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Processing: ${(_processProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.indigo),
                    ),
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.indigo),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _processProgress,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: Colors.grey.shade200,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.indigo),
                ),
                const SizedBox(height: 8),
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Column(
              children: [
                const Text('Processing Time', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 4),
                Text('${_processingTimeSec!.toStringAsFixed(2)}s', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.indigo)),
              ],
            ),
            Container(height: 24, width: 1, color: Colors.grey.shade300),
            Column(
              children: [
                const Text('Audio Duration', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 4),
                Text('${_fileDuration!.toStringAsFixed(1)}s', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            Container(height: 24, width: 1, color: Colors.grey.shade300),
            Column(
              children: [
                const Text('Real-time Factor (RTF)', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 4),
                Text(
                  _rtf != null ? _rtf!.toStringAsFixed(3) : 'N/A',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: (_rtf != null && _rtf! < 1.0) ? Colors.green : Colors.orange,
                  ),
                ),
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
                if (_subtitles.isNotEmpty)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (value) {
                      if (value == 'copy_srt') {
                        _copyToClipboard(_generateSrt());
                      } else if (value == 'copy_text') {
                        _copyToClipboard(_generatePlainText());
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
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
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
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }
}
