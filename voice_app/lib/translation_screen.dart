import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'model_manager.dart';
import 'model_management_sheet.dart';
import 'native_nmt_service.dart';
import 'llama_nmt_service.dart';

class TranslationScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const TranslationScreen({Key? key, this.showPerfMetrics = false}) : super(key: key);

  @override
  State<TranslationScreen> createState() => _TranslationScreenState();
}

class _TranslationScreenState extends State<TranslationScreen> {
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _targetController = TextEditingController();

  final NativeNmtService _marianService = NativeNmtService();
  final LlamaNmtService _llamaService = LlamaNmtService();
  bool _isTranslating = false;
  bool _isInitialized = false;

  // Backend selection
  String _backendType = 'nmt'; // 'nmt' = Marian ONNX, 'llm' = Llama GGUF
  static const _backendLabels = {'nmt': 'Marian ONNX', 'llm': 'Llama GGUF'};

  // Model selection and language pairs
  List<ModelInfo> _nmtModels = [];
  ModelInfo? _selectedNmtModel;
  bool _loadingModels = true;

  String _selectedSourceLang = 'Chinese';
  String _selectedTargetLang = 'English';

  // Last translation performance metrics.
  int? _lastInputTokens;
  double? _lastEncoderMs;
  int? _lastDecoderTokens;
  double? _lastDecoderTokensPerSec;

  @override
  void initState() {
    super.initState();
    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
    });

    final nmtList = await ModelManager.getModels(_backendType);

    setState(() {
      _nmtModels = nmtList;
      _loadingModels = false;

      // Check if current pair is available in the new models list
      final currentPair = '$_selectedSourceLang-$_selectedTargetLang';
      final hasCurrentPair = _isLlamaBackend
          ? _nmtModels.isNotEmpty  // LLM: any model works for any pair
          : _nmtModels.any((m) => m.language == currentPair);

      // If current selected pair is not available, but we have some models,
      // auto-select the language pair of the first available model.
      if (!hasCurrentPair && _nmtModels.isNotEmpty) {
        if (_nmtModels.first.language == 'multi') {
          // LLM model: keep current language selection
        } else {
          final parts = _nmtModels.first.language.split('-');
          if (parts.length == 2) {
            _selectedSourceLang = parts[0];
            _selectedTargetLang = parts[1];
          }
        }
      }
      _updateSelectedNmtModel();
    });
  }

  void _updateSelectedNmtModel() {
    if (_isLlamaBackend) {
      // LLM: any model works for all pairs
      _selectedNmtModel = _nmtModels.isNotEmpty ? _nmtModels.first : null;
      return;
    }

    final targetPair = '$_selectedSourceLang-$_selectedTargetLang';
    final matchingModels = _nmtModels.where((m) => m.language == targetPair).toList();

    if (matchingModels.isNotEmpty) {
      // Pick first matching model or preserve current selection if still valid
      if (_selectedNmtModel != null && matchingModels.contains(_selectedNmtModel)) {
        // Keep selected
      } else {
        _selectedNmtModel = matchingModels.first;
      }
    } else {
      _selectedNmtModel = null;
    }
    _deinitializeEngine();
  }

  dynamic get _activeService => _backendType == 'llm' ? _llamaService : _marianService;
  bool get _isLlamaBackend => _backendType == 'llm';

  void _deinitializeEngine() {
    _marianService.release();
    _llamaService.release();
    setState(() {
      _isInitialized = false;
    });
  }

  Future<void> _initializeEngine() async {
    if (_selectedNmtModel == null) return;
    try {
      if (_isLlamaBackend) {
        await _llamaService.loadModel(
          _selectedNmtModel!,
          sourceLang: _selectedSourceLang,
          targetLang: _selectedTargetLang,
        );
      } else {
        await _marianService.loadModel(_selectedNmtModel!);
      }
      setState(() {
        _isInitialized = true;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('NMT Engine initialized: ${_selectedNmtModel!.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize NMT: $e')),
        );
      }
    }
  }

  Future<void> _translate() async {
    if (!_isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please initialize the NMT engine first.')),
      );
      return;
    }

    final text = _sourceController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter text to translate.')),
      );
      return;
    }

    setState(() {
      _isTranslating = true;
      _targetController.text = '';
    });

    try {
      final svc = _activeService;
      await for (final partial in svc.translateStream(text)) {
        setState(() {
          _targetController.text = partial;
        });
      }
      // Stream complete — capture timing from the final result.
      final timing = svc.lastStreamTiming;
      if (timing != null) {
        setState(() {
          _lastInputTokens = timing.inputTokens;
          _lastEncoderMs = timing.encoderMs;
          _lastDecoderTokens = timing.decoderTokens;
          _lastDecoderTokensPerSec = timing.decoderTokensPerSecond >= 0
              ? timing.decoderTokensPerSecond
              : null;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Translation error: $e')),
      );
    } finally {
      setState(() {
        _isTranslating = false;
      });
    }
  }

  void _swapLanguages() {
    setState(() {
      final temp = _selectedSourceLang;
      _selectedSourceLang = _selectedTargetLang;
      _selectedTargetLang = temp;
      _updateSelectedNmtModel();
    });
  }

  void _openModelManagement() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: _backendType,
        onModelsChanged: () {
          _loadModels();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final targetPair = '$_selectedSourceLang-$_selectedTargetLang';
    final currentPairModels = _isLlamaBackend
        ? _nmtModels  // LLM: show all models regardless of pair
        : _nmtModels.where((m) => m.language == targetPair).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.translate_rounded, size: 28, color: Colors.blue),
              SizedBox(width: 8),
              Text(
                'Offline Text Translation',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Backend selector
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Backend: ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'nmt', label: Text('Marian ONNX')),
                  ButtonSegment(value: 'llm', label: Text('Llama GGUF')),
                ],
                selected: {_backendType},
                onSelectionChanged: (selected) {
                  setState(() {
                    _backendType = selected.first;
                    _deinitializeEngine();
                    _loadModels();
                  });
                },
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Models Configuration Section
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
                        'Language Settings',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        onPressed: _openModelManagement,
                        icon: const Icon(Icons.settings, color: Colors.blue),
                        tooltip: 'Manage Translation Models',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (_loadingModels)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    // Language pickers
                    if (_isLlamaBackend)
                      // LLM: only target language is needed
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedTargetLang,
                              decoration: const InputDecoration(
                                labelText: 'Target Language',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: supportedLanguages.map((lang) {
                                return DropdownMenuItem(value: lang, child: Text(lang));
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _selectedTargetLang = val;
                                    _deinitializeEngine();
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      )
                    else
                      // Marian NMT: source + target language pair
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedSourceLang,
                              decoration: const InputDecoration(
                                labelText: 'Source Language',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: supportedLanguages.map((lang) {
                                return DropdownMenuItem(value: lang, child: Text(lang));
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _selectedSourceLang = val;
                                    _updateSelectedNmtModel();
                                  });
                                }
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4.0),
                            child: IconButton(
                              icon: const Icon(Icons.swap_horiz_rounded, color: Colors.blue),
                              onPressed: _swapLanguages,
                              tooltip: 'Swap languages',
                            ),
                          ),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _selectedTargetLang,
                              decoration: const InputDecoration(
                                labelText: 'Target Language',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: supportedLanguages.map((lang) {
                                return DropdownMenuItem(value: lang, child: Text(lang));
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _selectedTargetLang = val;
                                    _updateSelectedNmtModel();
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),

                    if (_selectedNmtModel == null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _isLlamaBackend
                                    ? 'No GGUF model installed.\nPlease click the settings icon to import a model.'
                                    : 'No local NMT model installed for $_selectedSourceLang to $_selectedTargetLang.\n'
                                        'Please click the settings icon above to import a model.',
                                style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      // If there are multiple models for the same language pair, let the user select
                      if (currentPairModels.length > 1) ...[
                        const Text('Select NMT Model:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<ModelInfo>(
                          value: _selectedNmtModel,
                          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                          items: currentPairModels.map((model) {
                            return DropdownMenuItem(value: model, child: Text(model.name));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _selectedNmtModel = val;
                              _deinitializeEngine();
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                      ] else ...[
                        Row(
                          children: [
                            const Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Active Model: ${_selectedNmtModel!.name}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.green),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],

                    ],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Init / Deinit Button
          if (_selectedNmtModel != null)
            ElevatedButton(
              onPressed: _isInitialized ? _deinitializeEngine : _initializeEngine,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(14),
                backgroundColor: _isInitialized ? Colors.red : Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: Text(_isInitialized ? 'Deinitialize NMT Engine' : 'Initialize NMT Engine'),
            ),
          const SizedBox(height: 20),

          // Translation UI — only visible after init
          if (_isInitialized) ...[
          // Source Input
          const Text('Source Text:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          TextField(
            controller: _sourceController,
            maxLines: 5,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Type text here to translate...',
            ),
          ),
          const SizedBox(height: 16),

          // Translation Button
          ElevatedButton.icon(
            onPressed: (_isTranslating || !_isInitialized) ? null : _translate,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: _isTranslating
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.translate_rounded),
            label: const Text('Translate Text', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 20),

          // Target Output
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Translation:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              if (_targetController.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy_rounded, color: Colors.blue, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _targetController.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied translation to clipboard')),
                    );
                  },
                  tooltip: 'Copy translation',
                ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _targetController,
            maxLines: 5,
            readOnly: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white12,
            ),
          ),
          // Performance metrics display
          if (widget.showPerfMetrics && _lastEncoderMs != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Performance Metrics',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue),
                  ),
                  const SizedBox(height: 8),
                  _buildMetricRow(
                    _isLlamaBackend ? 'Prompt:' : 'Encode:',
                    '${_lastInputTokens} tokens, ${_lastEncoderMs!.toStringAsFixed(1)} ms',
                  ),
                  if (_lastDecoderTokensPerSec != null)
                    _buildMetricRow(
                      'Decode:',
                      '${_lastDecoderTokens} tokens, ${_lastDecoderTokensPerSec!.toStringAsFixed(1)} tokens/s',
                    ),
                ],
              ),
            ),
          ],
          ], // End of _isInitialized block
        ],
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    ModelManager.changeNotifier.removeListener(_loadModels);
    _sourceController.dispose();
    _targetController.dispose();
    _marianService.release();
    _llamaService.release();
    super.dispose();
  }
}
