import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'utils.dart';
import 'model_manager.dart';
import 'model_management_sheet.dart';

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
  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OfflineRecognizer? _offlineRecognizer;
  sher_onnx_StreamDisposeWrap? _streamWrap;
  sherpa_onnx.VoiceActivityDetector? _vad;
  sherpa_onnx.CircularBuffer? _circularBuffer;

  List<String> _sentences = [];
  String _currentResult = "";
  int _sentenceIndex = 0;

  // Pre-speech buffer: cache audio before VAD first triggers,
  // then replay into the recognizer to avoid losing speech onset.
  bool _vadEverDetected = false;
  final List<Float32List> _preSpeechBuffer = [];
  static const int _maxPreSpeechSamples = 8000; // 0.5 seconds
  int _preSpeechBufferSize = 0;

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
    // De-initialize if the active model changes
    if (_isInitialized) {
      _deinitializeEngine();
    }
  }

  void _deinitializeEngine() {
    _streamWrap?.free();
    _streamWrap = null;
    _recognizer?.free();
    _recognizer = null;
    _offlineRecognizer?.free();
    _offlineRecognizer = null;
    _vad?.free();
    _vad = null;
    _circularBuffer?.free();
    _circularBuffer = null;
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
      sherpa_onnx.initBindings();

      final encoder = _selectedModel!.asrEncoderPath!;
      final decoder = _selectedModel!.asrDecoderPath!;
      final joiner = _selectedModel!.asrJoinerPath!;
      final tokens = _selectedModel!.tokensPath!;

      // Check if it is a non-streaming/offline model based on metadata
      _isOfflineModel = !_selectedModel!.isStreamingASR;

      final sileroModelPath = await ModelManager.ensureSileroVad();
      final vadConfig = sherpa_onnx.VadModelConfig(
        sileroVad: sherpa_onnx.SileroVadModelConfig(
          model: sileroModelPath,
          threshold: 0.5,
          minSilenceDuration: 0.5,
          minSpeechDuration: 0.25,
          windowSize: 512,
          maxSpeechDuration: 20.0,
        ),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      );
      _vad = sherpa_onnx.VoiceActivityDetector(config: vadConfig, bufferSizeInSeconds: 60);
      _circularBuffer = sherpa_onnx.CircularBuffer(capacity: 30 * 16000);

      if (_isOfflineModel) {
        final modelConfig = sherpa_onnx.OfflineModelConfig(
          transducer: sherpa_onnx.OfflineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner,
          ),
          tokens: tokens,
          modelType: 'zipformer2',
        );

        final config = sherpa_onnx.OfflineRecognizerConfig(
          model: modelConfig,
          decodingMethod: 'greedy_search',
        );

        _offlineRecognizer = sherpa_onnx.OfflineRecognizer(config);
      } else {
        final modelConfig = sherpa_onnx.OnlineModelConfig(
          transducer: sherpa_onnx.OnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner,
          ),
          tokens: tokens,
          modelType: 'zipformer2', // default for zipformer-transducer
        );

        final config = sherpa_onnx.OnlineRecognizerConfig(
          model: modelConfig,
          ruleFsts: '',
          enableEndpoint: true,
          rule1MinTrailingSilence: 2.4,
          rule2MinTrailingSilence: 1.0,
          decodingMethod: 'greedy_search',
        );

        _recognizer = sherpa_onnx.OnlineRecognizer(config);
        final stream = _recognizer!.createStream();
        _streamWrap = sher_onnx_StreamDisposeWrap(stream);
      }

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
    if (!_isInitialized) {
      await _initializeEngine();
    }

    if (_isOfflineModel) {
      if (_offlineRecognizer == null || _vad == null || _circularBuffer == null) return;
      try {
        if (await _audioRecorder.hasPermission()) {
          const config = RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
          );

          _vad!.reset();
          _circularBuffer!.reset();

          setState(() {
            _currentResult = "";
            _updateTranscript();
          });

          final audioStream = await _audioRecorder.startStream(config);

          _audioStreamSub = audioStream.listen((data) {
            if (_offlineRecognizer == null || _vad == null || _circularBuffer == null) return;

            final samplesFloat32 = convertBytesToFloat32(Uint8List.fromList(data));
            _circularBuffer!.push(samplesFloat32);

            const windowSize = 512;
            while (_circularBuffer!.size >= windowSize) {
              final samples = _circularBuffer!.get(startIndex: _circularBuffer!.head, n: windowSize);
              _circularBuffer!.pop(windowSize);
              _vad!.acceptWaveform(samples);
            }

            if (_vad!.isDetected()) {
              if (_currentResult != "Speaking...") {
                setState(() {
                  _currentResult = "Speaking...";
                  _updateTranscript();
                });
              }
            } else {
              if (_currentResult == "Speaking...") {
                setState(() {
                  _currentResult = "";
                  _updateTranscript();
                });
              }
            }

            while (!_vad!.isEmpty()) {
              final segment = _vad!.front();
              _vad!.pop();

              final stream = _offlineRecognizer!.createStream();
              stream.acceptWaveform(samples: segment.samples, sampleRate: 16000);
              _offlineRecognizer!.decode(stream);
              final text = _offlineRecognizer!.getResult(stream).text;
              stream.free();

              if (text.isNotEmpty) {
                String finalizedText = text;
                final leadingPuncs = ['，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';'];
                while (finalizedText.isNotEmpty) {
                  final firstChar = finalizedText[0];
                  if (leadingPuncs.contains(firstChar)) {
                    finalizedText = finalizedText.substring(1);
                  } else {
                    break;
                  }
                }
                finalizedText = _formatTextWithCasing(finalizedText);
                if (finalizedText.isNotEmpty) {
                  setState(() {
                    _sentences.add(finalizedText);
                    _sentenceIndex += 1;
                    _currentResult = "";
                    _updateTranscript();
                  });
                }
              }
            }
          });
        }
      } catch (e) {
        debugPrint('ASR Offline Recording Error: $e');
      }
    } else {
      if (_recognizer == null || _streamWrap == null || _vad == null || _circularBuffer == null) return;

      try {
        if (await _audioRecorder.hasPermission()) {
          const config = RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
          );

          _vad!.reset();
          _circularBuffer!.reset();
          _vadEverDetected = false;
          _preSpeechBuffer.clear();
          _preSpeechBufferSize = 0;

          setState(() {
            _currentResult = "";
            _updateTranscript();
          });

          final audioStream = await _audioRecorder.startStream(config);

          _audioStreamSub = audioStream.listen((data) {
            if (_streamWrap == null || _recognizer == null || _vad == null || _circularBuffer == null) return;

            final samplesFloat32 = convertBytesToFloat32(Uint8List.fromList(data));
            _circularBuffer!.push(samplesFloat32);

            const windowSize = 512;
            while (_circularBuffer!.size >= windowSize) {
              final samples = _circularBuffer!.get(startIndex: _circularBuffer!.head, n: windowSize);
              _circularBuffer!.pop(windowSize);
              _vad!.acceptWaveform(samples);

              if (_vad!.isDetected()) {
                if (!_vadEverDetected) {
                  // First time VAD triggers: replay buffered pre-speech audio
                  // into the recognizer to avoid losing the speech onset.
                  _vadEverDetected = true;
                  for (final buffered in _preSpeechBuffer) {
                    _streamWrap!.stream.acceptWaveform(samples: buffered, sampleRate: 16000);
                  }
                  _preSpeechBuffer.clear();
                  _preSpeechBufferSize = 0;
                }
                _streamWrap!.stream.acceptWaveform(samples: samples, sampleRate: 16000);
              } else if (!_vadEverDetected) {
                // VAD hasn't triggered yet; buffer audio for later replay (sliding window).
                _preSpeechBuffer.add(samples);
                _preSpeechBufferSize += samples.length;
                while (_preSpeechBufferSize > _maxPreSpeechSamples) {
                  final removed = _preSpeechBuffer.removeAt(0);
                  _preSpeechBufferSize -= removed.length;
                }
              }

              // Check if a segment has finished immediately inside the loop to avoid losing subsequent audio
              while (!_vad!.isEmpty()) {
                _vad!.pop();

                while (_recognizer!.isReady(_streamWrap!.stream)) {
                  _recognizer!.decode(_streamWrap!.stream);
                }

                final finalT = _recognizer!.getResult(_streamWrap!.stream).text;
                _streamWrap?.free();
                final stream = _recognizer!.createStream();
                _streamWrap = sher_onnx_StreamDisposeWrap(stream);
                // Reset VAD detection state so the next speech onset
                // also gets its own pre-speech buffer replay.
                _vadEverDetected = false;
                _preSpeechBuffer.clear();
                _preSpeechBufferSize = 0;

                if (finalT.isNotEmpty) {
                  String finalizedText = finalT;
                  final leadingPuncs = ['，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';'];
                  while (finalizedText.isNotEmpty) {
                    final firstChar = finalizedText[0];
                    if (leadingPuncs.contains(firstChar)) {
                      finalizedText = finalizedText.substring(1);
                    } else {
                      break;
                    }
                  }
                  finalizedText = _formatTextWithCasing(finalizedText);
                  if (finalizedText.isNotEmpty) {
                    _sentences.add(finalizedText);
                    _sentenceIndex += 1;
                  }
                }
                _currentResult = "";
                _updateTranscript();
              }
            }

            while (_recognizer!.isReady(_streamWrap!.stream)) {
              _recognizer!.decode(_streamWrap!.stream);
            }

            final text = _recognizer!.getResult(_streamWrap!.stream).text;

            if (text.isNotEmpty) {
              setState(() {
                _currentResult = _formatTextWithCasing(text);
                _updateTranscript();
              });
            }
          });
        }
      } catch (e) {
        debugPrint('ASR Recording Error: $e');
      }
    }
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

    final leadingPuncs = ['，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';'];
    while (renderedCurrent.isNotEmpty) {
      final firstChar = renderedCurrent[0];
      if (leadingPuncs.contains(firstChar)) {
        renderedCurrent = renderedCurrent.substring(1);
      } else {
        break;
      }
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

  Future<void> _stopRecording() async {
    if (_isOfflineModel) {
      await _audioStreamSub?.cancel();
      _audioStreamSub = null;
      await _audioRecorder.stop();

      if (_offlineRecognizer != null && _vad != null) {
        _vad!.flush();

        while (!_vad!.isEmpty()) {
          final segment = _vad!.front();
          _vad!.pop();

          final stream = _offlineRecognizer!.createStream();
          stream.acceptWaveform(samples: segment.samples, sampleRate: 16000);
          _offlineRecognizer!.decode(stream);
          final text = _offlineRecognizer!.getResult(stream).text;
          stream.free();

          if (text.isNotEmpty) {
            String finalizedText = text;
            final leadingPuncs = ['，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';'];
            while (finalizedText.isNotEmpty) {
              final firstChar = finalizedText[0];
              if (leadingPuncs.contains(firstChar)) {
                finalizedText = finalizedText.substring(1);
              } else {
                break;
              }
            }
            finalizedText = _formatTextWithCasing(finalizedText);
            if (finalizedText.isNotEmpty) {
              _sentences.add(finalizedText);
              _sentenceIndex += 1;
            }
          }
        }
      }

      setState(() {
        _currentResult = "";
        _updateTranscript();
      });
    } else {
      await _audioStreamSub?.cancel();
      _audioStreamSub = null;
      await _audioRecorder.stop();

      if (_recognizer != null && _vad != null && _streamWrap != null) {
        _vad!.flush();

        while (!_vad!.isEmpty()) {
          _vad!.pop();

          final finalT = _recognizer!.getResult(_streamWrap!.stream).text;
          _recognizer!.reset(_streamWrap!.stream);

          if (finalT.isNotEmpty) {
            String finalizedText = finalT;
            final leadingPuncs = ['，', '。', '？', '！', '、', '；', ',', '.', '?', '!', ';'];
            while (finalizedText.isNotEmpty) {
              final firstChar = finalizedText[0];
              if (leadingPuncs.contains(firstChar)) {
                finalizedText = finalizedText.substring(1);
              } else {
                break;
              }
            }
            finalizedText = _formatTextWithCasing(finalizedText);
            if (finalizedText.isNotEmpty) {
              _sentences.add(finalizedText);
              _sentenceIndex += 1;
            }
          }
        }
      }

      setState(() {
        _currentResult = "";
        _updateTranscript();
      });

      _streamWrap?.free();
      if (_recognizer != null) {
        final stream = _recognizer!.createStream();
        _streamWrap = sher_onnx_StreamDisposeWrap(stream);
      }
    }
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
    final languageModels = _allModels.where((m) => m.languages.contains(_selectedLanguage)).toList();

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
                    Icon(_recordState != RecordState.stop ? Icons.stop : Icons.mic, color: Colors.white),
                    const SizedBox(width: 10),
                    Text(
                      _recordState != RecordState.stop ? 'Stop Recording' : 'Start Live ASR',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Recognized Transcript:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _transcriptController,
              maxLines: 8,
              readOnly: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: _recordState != RecordState.stop ? 'Listening...' : 'Transcript will appear here...',
              ),
            ),
            const SizedBox(height: 12),
            // Clear transcript button
            Center(
              child: TextButton.icon(
                onPressed: _sentences.isEmpty && _currentResult.isEmpty ? null : _clearTranscript,
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
    _streamWrap?.free();
    _recognizer?.free();
    _offlineRecognizer?.free();
    _vad?.free();
    _circularBuffer?.free();
    super.dispose();
  }
}

// Helper wrapper to dispose streams cleanly
class sher_onnx_StreamDisposeWrap {
  final sherpa_onnx.OnlineStream stream;
  sher_onnx_StreamDisposeWrap(this.stream);
  void free() {
    try {
      stream.free();
    } catch (_) {}
  }
}

