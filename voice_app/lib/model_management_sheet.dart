import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'model_manager.dart';

class ModelManagementSheet extends StatefulWidget {
  final String initialType; // 'asr' or 'tts'
  final VoidCallback onModelsChanged;

  const ModelManagementSheet({
    Key? key,
    required this.initialType,
    required this.onModelsChanged,
  }) : super(key: key);

  @override
  State<ModelManagementSheet> createState() => _ModelManagementSheetState();
}

class _ModelManagementSheetState extends State<ModelManagementSheet> {
  late String _currentType;
  List<ModelInfo> _models = [];
  bool _loading = true;

  // Import form state
  String _selectedLanguage = supportedLanguages[0];
  String _nmtSourceLanguage = 'Chinese';
  String _nmtTargetLanguage = 'English';
  final TextEditingController _modelNameController = TextEditingController();
  String? _selectedPath;
  bool _isArchive = false;

  bool _isImporting = false;
  double _importProgress = 0.0;
  String _importStatus = '';

  @override
  void initState() {
    super.initState();
    _currentType = widget.initialType;
    _loadModels();
  }

  Future<void> _loadModels() async {
    setState(() {
      _loading = true;
    });
    final models = await ModelManager.getModels(_currentType);
    setState(() {
      _models = models;
      _loading = false;
    });
  }

  Future<void> _pickDirectory() async {
    try {
      final dir = await FilePicker.getDirectoryPath();
      if (dir != null) {
        setState(() {
          _selectedPath = dir;
          _isArchive = false;
          _modelNameController.text = p.basename(dir);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick directory: $e')),
      );
    }
  }

  Future<void> _pickArchiveFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'tar', 'gz', 'tgz', 'bz2', 'tbz2'],
      );
      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        setState(() {
          _selectedPath = path;
          _isArchive = true;
          // Determine the model name by stripping archive extension
          final filename = p.basename(path);
          if (filename.endsWith('.tar.gz')) {
            _modelNameController.text = filename.substring(0, filename.length - 7);
          } else if (filename.endsWith('.tar.bz2')) {
            _modelNameController.text = filename.substring(0, filename.length - 8);
          } else {
            _modelNameController.text = p.basenameWithoutExtension(path);
          }
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick archive file: $e')),
      );
    }
  }

  Future<void> _importModel() async {
    final modelName = _modelNameController.text.trim();
    final srcPath = _selectedPath;

    if (modelName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a model name.')),
      );
      return;
    }
    if (srcPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a directory or archive file.')),
      );
      return;
    }

    setState(() {
      _isImporting = true;
      _importProgress = 0.0;
      _importStatus = 'Preparing import...';
    });

    final targetLanguage = _currentType == 'nmt'
        ? '$_nmtSourceLanguage-$_nmtTargetLanguage'
        : _currentType == 'llm'
        ? 'multi'
        : _selectedLanguage;

    try {
      if (_isArchive) {
        await ModelManager.importModelFromArchive(
          archivePath: srcPath,
          type: _currentType,
          language: targetLanguage,
          modelName: modelName,
          onProgress: (progress) {
            setState(() {
              _importProgress = progress;
              _importStatus = 'Extracting: ${(progress * 100).toStringAsFixed(0)}%';
            });
          },
        );
      } else {
        await ModelManager.importModelFromDirectory(
          srcPath: srcPath,
          type: _currentType,
          language: targetLanguage,
          modelName: modelName,
          onProgress: (progress) {
            setState(() {
              _importProgress = progress;
              _importStatus = 'Copying: ${(progress * 100).toStringAsFixed(0)}%';
            });
          },
        );
      }

      // Check if it's actually valid
      final models = await ModelManager.getModels(_currentType);
      final imported = models.firstWhere(
        (m) => m.name == modelName && m.language == targetLanguage,
        orElse: () => ModelInfo(name: '', language: '', path: '', type: ''),
      );

      if (imported.name.isEmpty || !imported.isValid) {
        // Show validation error (but keep the files, user might need to fix naming/structure)
        throw Exception(
          'Model was imported, but validation failed.\n'
          'For ASR: ensure encoder.onnx, decoder.onnx, joiner.onnx, tokens.txt are present.\n'
          'For TTS: ensure a .onnx file and tokens.txt are present.\n'
          'For NMT: ensure encoder_model.onnx, decoder_model.onnx, vocab.json are present.\n'
          'For LLM: ensure a .gguf file is present.'
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Successfully imported model: $modelName')),
      );

      setState(() {
        _selectedPath = null;
        _modelNameController.clear();
      });

      widget.onModelsChanged();
      _loadModels();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e'), duration: const Duration(seconds: 6)),
      );
    } finally {
      setState(() {
        _isImporting = false;
      });
    }
  }

  Future<void> _deleteModel(ModelInfo model) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Model'),
        content: Text('Are you sure you want to delete "${model.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ModelManager.deleteModel(model);
      widget.onModelsChanged();
      _loadModels();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted model: ${model.name}')),
      );
    }
  }

  Future<void> _renameModel(ModelInfo model) async {
    final controller = TextEditingController(text: model.name);
    final formKey = GlobalKey<FormState>();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Model'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'New Model Name',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter a valid name';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final newName = controller.text.trim();
      if (newName == model.name) return; // no change

      try {
        await ModelManager.renameModel(model, newName);
        widget.onModelsChanged();
        _loadModels();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Successfully renamed model to: $newName')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to rename: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle bar
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Local Models Manager',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),

            // Segmented selector for ASR vs TTS vs NMT
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'asr', label: Text('ASR (Speech-to-Text)'), icon: Icon(Icons.mic)),
                        ButtonSegment(value: 'tts', label: Text('TTS (Text-to-Speech)'), icon: Icon(Icons.speaker_notes)),
                        ButtonSegment(value: 'nmt', label: Text('NMT (Translation)'), icon: Icon(Icons.translate)),
                        ButtonSegment(value: 'llm', label: Text('LLM (Translate)'), icon: Icon(Icons.psychology)),
                      ],
                      selected: {_currentType},
                      onSelectionChanged: (value) {
                        setState(() {
                          _currentType = value.first;
                          _selectedPath = null;
                          _modelNameController.clear();
                        });
                        _loadModels();
                      },
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // Form Card for Importing Models
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Import ${_currentType.toUpperCase()} Model',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 16),
                          if (_currentType == 'nmt') ...[
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    value: _nmtSourceLanguage,
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
                                          _nmtSourceLanguage = val;
                                        });
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    value: _nmtTargetLanguage,
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
                                          _nmtTargetLanguage = val;
                                        });
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ] else ...[
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    value: _selectedLanguage,
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
                                          _selectedLanguage = val;
                                        });
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 16),
                          TextField(
                            controller: _modelNameController,
                            decoration: const InputDecoration(
                              labelText: 'Model Custom Name',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _isImporting ? null : _pickDirectory,
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('Folder'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _isImporting ? null : _pickArchiveFile,
                                  icon: const Icon(Icons.archive_outlined),
                                  label: const Text('ZIP / TAR Archive'),
                                ),
                              ),
                            ],
                          ),
                          if (_selectedPath != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.grey[100],
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey[300]!),
                              ),
                              child: Row(
                                children: [
                                  Icon(_isArchive ? Icons.archive : Icons.folder, color: Colors.blue),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _selectedPath!,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (_isImporting) ...[
                            LinearProgressIndicator(value: _importProgress),
                            const SizedBox(height: 8),
                            Text(
                              _importStatus,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ] else ...[
                            ElevatedButton(
                              onPressed: (_selectedPath == null) ? null : _importModel,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: const Text('Import Model Files'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Existing Models List
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Installed Local Models',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      if (_loading)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (!_loading && _models.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      alignment: Alignment.center,
                      child: Text(
                        'No local ${_currentType.toUpperCase()} models found.\nPlease import a model above.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  else
                    ..._models.map((model) {
                      return ModelTile(
                        model: model,
                        onRename: () => _renameModel(model),
                        onDelete: () => _deleteModel(model),
                      );
                    }).toList(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ModelTile extends StatefulWidget {
  final ModelInfo model;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const ModelTile({
    Key? key,
    required this.model,
    required this.onRename,
    required this.onDelete,
  }) : super(key: key);

  @override
  State<ModelTile> createState() => _ModelTileState();
}

class _ModelTileState extends State<ModelTile> {
  String _sizeStr = 'Calculating size...';
  List<Map<String, dynamic>> _files = [];
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    _calculateSize();
  }

  @override
  void didUpdateWidget(ModelTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      _calculateSize();
    }
  }

  Future<void> _calculateSize() async {
    final size = await widget.model.getDirectorySize();
    final files = await widget.model.getFilesWithSize();
    if (mounted) {
      setState(() {
        _sizeStr = _formatBytes(size);
        _files = files;
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return "0 B";
    if (bytes < 1024) return "$bytes B";
    double kb = bytes / 1024;
    if (kb < 1024) return "${kb.toStringAsFixed(1)} KB";
    double mb = kb / 1024;
    if (mb < 1024) return "${mb.toStringAsFixed(1)} MB";
    double gb = mb / 1024;
    return "${gb.toStringAsFixed(1)} GB";
  }

  Future<void> _manageLanguages(BuildContext context) async {
    List<String> currentLangs = List.from(widget.model.languages);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Manage Supported Languages'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: supportedLanguages.map((lang) {
                    final isChecked = currentLangs.contains(lang);
                    return CheckboxListTile(
                      title: Text(lang),
                      value: isChecked,
                      onChanged: (val) {
                        setDialogState(() {
                          if (val == true) {
                            currentLangs.add(lang);
                          } else {
                            currentLangs.remove(lang);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (currentLangs.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please select at least one language.')),
                      );
                      return;
                    }
                    Navigator.pop(context, true);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == true) {
      await widget.model.updateLanguages(currentLangs);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1,
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.blue[50],
              foregroundColor: Colors.blue,
              child: Text(widget.model.languages.isNotEmpty
                  ? (widget.model.languages.first.length >= 2
                      ? widget.model.languages.first.substring(0, 2).toUpperCase()
                      : widget.model.languages.first.toUpperCase())
                  : '??'),
            ),
            title: Text(widget.model.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Languages: ${widget.model.languages.join(", ")}', style: const TextStyle(fontSize: 12)),
                if (widget.model.type == 'asr' || widget.model.type == 'tts') ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: widget.model.isStreaming ? Colors.green[50] : Colors.orange[50],
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: widget.model.isStreaming ? Colors.green[200]! : Colors.orange[200]!,
                      ),
                    ),
                    child: Text(
                      widget.model.isStreaming ? 'Streaming' : 'Non-Streaming',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: widget.model.isStreaming ? Colors.green[700] : Colors.orange[700],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text('Size: $_sizeStr', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.blue)),
                Text('Location: ${p.basename(widget.model.path)}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(_showDetails ? Icons.expand_less : Icons.info_outline, color: Colors.grey[700]),
                  onPressed: () {
                    setState(() {
                      _showDetails = !_showDetails;
                    });
                  },
                  tooltip: 'View Files',
                ),
                IconButton(
                  icon: const Icon(Icons.language, color: Colors.teal),
                  onPressed: () => _manageLanguages(context),
                  tooltip: 'Manage Languages',
                ),
                IconButton(
                  icon: const Icon(Icons.edit, color: Colors.blue),
                  onPressed: widget.onRename,
                  tooltip: 'Rename Model',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: widget.onDelete,
                  tooltip: 'Delete Model',
                ),
              ],
            ),
          ),
          if (_showDetails)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  const Text(
                    'Files in Directory:',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  if (_files.isEmpty)
                    const Text('No files found', style: TextStyle(fontSize: 11, color: Colors.grey))
                  else
                    ..._files.map((file) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                file['name'] as String,
                                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatBytes(file['size'] as int),
                              style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  const SizedBox(height: 8),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
