import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';
import 'package:voice_app/services/native_nmt_service.dart';
import 'package:voice_app/services/llama_nmt_service.dart';
import 'package:voice_app/services/nmt_service_common.dart';

class TranslationScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const TranslationScreen({Key? key, this.showPerfMetrics = false}) : super(key: key);

  @override
  State<TranslationScreen> createState() => _TranslationScreenState();
}

class _TranslationScreenState extends State<TranslationScreen> {
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _targetController = TextEditingController();

  NmtBackend? _nmtBackend;
  bool _isTranslating = false;

  // Backend selection
  String _backendType = 'nmt'; // 'nmt' = Marian ONNX, 'llm' = Llama GGUF
  static const _backendLabels = {'nmt': 'Marian ONNX', 'llm': 'Llama GGUF'};

  // Model selection and language pairs
  List<ModelInfo> _nmtModels = [];
  ModelInfo? _selectedNmtModel;
  bool _loadingModels = true;
  bool _isConfigExpanded = true;

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

  bool get _isLlamaBackend => _backendType == 'llm';

  void _deinitializeEngine() {
    _nmtBackend?.release();
    _nmtBackend = null;
    setState(() {
      _isConfigExpanded = true;
    });
  }

  void _applyLlmLanguages() {
    final backend = _nmtBackend;
    if (backend is LlamaNmtService && backend.isLoaded) {
      backend.setLanguages(_selectedSourceLang, _selectedTargetLang);
    }
  }

  void _onLlmLanguageChanged({String? sourceLang, String? targetLang}) {
    setState(() {
      if (sourceLang != null) _selectedSourceLang = sourceLang;
      if (targetLang != null) _selectedTargetLang = targetLang;
    });
    _applyLlmLanguages();
  }

  void _swapLanguages() {
    setState(() {
      final temp = _selectedSourceLang;
      _selectedSourceLang = _selectedTargetLang;
      _selectedTargetLang = temp;
      if (_isLlamaBackend) {
        _applyLlmLanguages();
      } else {
        _updateSelectedNmtModel();
      }
    });
  }

  Future<void> _initializeEngine() async {
    if (_selectedNmtModel == null) return;
    try {
      if (_isLlamaBackend) {
        _nmtBackend = LlamaNmtService();
        await _nmtBackend!.loadModel(
          _selectedNmtModel!,
          sourceLang: _selectedSourceLang,
          targetLang: _selectedTargetLang,
        );
      } else {
        _nmtBackend = NativeNmtService();
        await _nmtBackend!.loadModel(_selectedNmtModel!);
      }
      setState(() {
        _isConfigExpanded = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('NMT Engine initialized: ${_selectedNmtModel!.name}')),
        );
      }
    } catch (e) {
      _nmtBackend = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize NMT: $e')),
        );
      }
    }
  }

  Future<void> _translate() async {
    if (!(_nmtBackend?.isLoaded ?? false)) {
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
      await for (final partial in _nmtBackend!.translateStream(text)) {
        setState(() {
          _targetController.text = partial;
        });
      }
      // Stream complete — capture timing from the final result.
      final timing = _nmtBackend!.lastStreamTiming;
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
  }  @override
  Widget build(BuildContext context) {
    final targetPair = '$_selectedSourceLang-$_selectedTargetLang';
    final currentPairModels = _isLlamaBackend
        ? _nmtModels  // LLM: show all models regardless of pair
        : _nmtModels.where((m) => m.language == targetPair).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF1F3F9),
      body: SafeArea(
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
                  Icon(Icons.translate_rounded, size: 26, color: Color(0xFF1E3C72)),
                  SizedBox(width: 8),
                  Text(
                    'Offline Text Translation',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3748),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // --- Backend Selector ---
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.02),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Backend Engine:',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                    ),
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
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        selectedBackgroundColor: const Color(0xFF1E3C72),
                        selectedForegroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // --- Models Configuration Card ---
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
                                  'Language Settings',
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
                                        color: (_nmtBackend?.isLoaded ?? false) ? Colors.green.shade50 : Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: (_nmtBackend?.isLoaded ?? false) ? Colors.green.shade200 : Colors.grey.shade300),
                                      ),
                                      child: Text(
                                        (_nmtBackend?.isLoaded ?? false)
                                            ? 'Initialized: ${_selectedNmtModel?.name ?? ""}'
                                            : 'Not Initialized',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: (_nmtBackend?.isLoaded ?? false) ? Colors.green.shade700 : Colors.grey.shade600,
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
                        if (_isLlamaBackend) ...[
                          // LLM: select model first, then languages (prompt-only change)
                          if (_nmtModels.isEmpty) ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.orange.shade200),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded, color: Colors.orange.shade600),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'No GGUF model installed.\nPlease click the model repository icon to import a model.',
                                      style: TextStyle(color: Color(0xFFC05621), fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final isWide = constraints.maxWidth > 450;

                                final modelField = Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Select LLM Model:',
                                      style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 6),
                                    DropdownButtonFormField<ModelInfo>(
                                      value: _selectedNmtModel,
                                      isExpanded: true,
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
                                      items: _nmtModels.map((model) {
                                        return DropdownMenuItem(
                                          value: model,
                                          child: Text(model.name, overflow: TextOverflow.ellipsis),
                                        );
                                      }).toList(),
                                      onChanged: (val) {
                                        setState(() {
                                          _selectedNmtModel = val;
                                          _deinitializeEngine();
                                        });
                                      },
                                    ),
                                  ],
                                );

                                final langField = Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Target Language:',
                                      style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 6),
                                    DropdownButtonFormField<String>(
                                      value: _selectedTargetLang,
                                      isExpanded: true,
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
                                      items: LanguageManager.languages.map((lang) {
                                        return DropdownMenuItem(
                                          value: lang,
                                          child: Text(lang, overflow: TextOverflow.ellipsis),
                                        );
                                      }).toList(),
                                      onChanged: (val) {
                                        if (val != null) _onLlmLanguageChanged(targetLang: val);
                                      },
                                    ),
                                  ],
                                );

                                if (isWide) {
                                  return Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: modelField),
                                      const SizedBox(width: 12),
                                      Expanded(child: langField),
                                    ],
                                  );
                                } else {
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      modelField,
                                      const SizedBox(height: 12),
                                      langField,
                                    ],
                                  );
                                }
                              },
                            ),
                          ],
                        ] else ...[
                          // Marian NMT: language pair first, then model
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _selectedSourceLang,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Source',
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
                                  items: LanguageManager.languages.map((lang) {
                                    return DropdownMenuItem(
                                      value: lang,
                                      child: Text(lang, overflow: TextOverflow.ellipsis),
                                    );
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
                                  icon: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF1E3C72)),
                                  onPressed: _swapLanguages,
                                  tooltip: 'Swap languages',
                                ),
                              ),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _selectedTargetLang,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Target',
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
                                  items: LanguageManager.languages.map((lang) {
                                    return DropdownMenuItem(
                                      value: lang,
                                      child: Text(lang, overflow: TextOverflow.ellipsis),
                                    );
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
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.orange.shade200),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded, color: Colors.orange.shade600),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'No local NMT model installed for $_selectedSourceLang to $_selectedTargetLang.\n'
                                          'Please click the model repository icon above to import a model.',
                                      style: const TextStyle(color: Color(0xFFC05621), fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            if (currentPairModels.length > 1) ...[
                              const Text(
                                'Select NMT Model:',
                                style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<ModelInfo>(
                                value: _selectedNmtModel,
                                isExpanded: true,
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
                                items: currentPairModels.map((model) {
                                  return DropdownMenuItem(
                                    value: model,
                                    child: Text(model.name, overflow: TextOverflow.ellipsis),
                                  );
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
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.green),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                            ],
                          ],
                        ],
                      ],
                      const SizedBox(height: 12),

                      // Init / Deinit Button
                      if (_selectedNmtModel != null)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: (_nmtBackend?.isLoaded ?? false) ? _deinitializeEngine : _initializeEngine,
                            icon: Icon(
                              (_nmtBackend?.isLoaded ?? false)
                                  ? Icons.power_settings_new_rounded
                                  : Icons.flash_on_rounded,
                              color: Colors.white,
                            ),
                            label: Text(
                              (_nmtBackend?.isLoaded ?? false) ? 'Deinitialize NMT Engine' : 'Initialize NMT Engine',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: (_nmtBackend?.isLoaded ?? false) ? Colors.red.shade600 : const Color(0xFF1E3C72),
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

              // --- Translation Workspace Card (only visible after init) ---
              if (_nmtBackend?.isLoaded ?? false) ...[
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
                      // Source Input Title
                      const Text(
                        'Source Text',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _sourceController,
                        maxLines: 5,
                        style: const TextStyle(fontSize: 15, height: 1.4, color: Color(0xFF2D3748)),
                        decoration: InputDecoration(
                          hintText: 'Type text here to translate...',
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
                      const SizedBox(height: 16),

                      // Translation Action Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: (_isTranslating || !(_nmtBackend?.isLoaded ?? false)) ? null : _translate,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E3C72),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 2,
                          ),
                          icon: _isTranslating
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                )
                              : const Icon(Icons.translate_rounded, color: Colors.white),
                          label: const Text(
                            'Translate Text',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Target Output Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Translation',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                          ),
                          if (_targetController.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.copy_rounded, color: Color(0xFF1E3C72), size: 20),
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
                      const SizedBox(height: 10),
                      TextField(
                        controller: _targetController,
                        maxLines: 5,
                        readOnly: true,
                        style: const TextStyle(fontSize: 15, height: 1.4, color: Color(0xFF2D3748)),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.grey.shade100,
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

                      // Performance metrics display
                      if (widget.showPerfMetrics && _lastEncoderMs != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E3C72).withOpacity(0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF1E3C72).withOpacity(0.15)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Performance Metrics',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1E3C72)),
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
                    ],
                  ),
                ),
              ] else ...[
                Container(
                  height: 120,
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
                    'Please initialize the engine first to start translation.',
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
          Text(value, style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.grey)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    ModelManager.changeNotifier.removeListener(_loadModels);
    _sourceController.dispose();
    _targetController.dispose();
    _nmtBackend?.release();
    super.dispose();
  }
}
