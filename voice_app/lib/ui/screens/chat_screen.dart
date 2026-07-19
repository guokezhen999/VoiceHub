import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/services/chat_history_store.dart';
import 'package:voice_app/services/llama_chat_service.dart';
import 'package:voice_app/services/nmt_service_common.dart';
import 'package:voice_app/services/tts_service.dart';
import 'package:voice_app/ui/widgets/chat_history_sheet.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';


class ChatScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const ChatScreen({Key? key, this.showPerfMetrics = false}) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final LlamaChatService _chatService = LlamaChatService();
  final TtsService _ttsService = TtsService();
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  late final AudioPlayer _audioPlayer;

  bool _isInitialized = false;
  bool _isGenerating = false;
  bool _loadingModels = true;

  List<ModelInfo> _llmModels = [];
  ModelInfo? _selectedModel;

  // Optional TTS
  bool _ttsEnabled = false;
  bool _ttsInitializing = false;
  List<ModelInfo> _ttsModels = [];
  ModelInfo? _selectedTtsModel;
  int _selectedSpeakerId = 0;
  String? _playingBubbleId;
  String? _synthesizingBubbleId;

  // Persisted chat session
  String? _currentSessionId;
  DateTime? _sessionCreatedAt;

  // Edit last user question
  String? _editingBubbleId;
  final TextEditingController _editController = TextEditingController();

  final List<_ChatBubble> _bubbles = [];
  int _bubbleSeq = 0;

  int? _lastInputTokens;
  double? _lastEncoderMs;
  int? _lastDecoderTokens;
  double? _lastDecoderTokensPerSec;
  bool _enableThinking = true;
  bool _isConfigExpanded = true;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() => _playingBubbleId = null);
    });
    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  Future<void> _loadModels() async {
    setState(() => _loadingModels = true);
    final models = await ModelManager.getModels('llm');
    final ttsModels = await ModelManager.getModels('tts');
    setState(() {
      _llmModels = models;
      _ttsModels = ttsModels;
      _loadingModels = false;
      if (_selectedModel != null && !models.any((m) => m.path == _selectedModel!.path)) {
        _selectedModel = null;
        _deinitializeEngine();
      }
      if (_selectedModel == null && models.isNotEmpty) {
        _selectedModel = models.first;
      }
      if (_selectedTtsModel != null &&
          !ttsModels.any((m) => m.path == _selectedTtsModel!.path)) {
        _selectedTtsModel = null;
        _deinitializeTts();
      }
      if (_selectedTtsModel == null && ttsModels.isNotEmpty) {
        _selectedTtsModel = ttsModels.first;
      }
    });
  }

  Future<void> _deinitializeEngine() async {
    await _chatService.release();
    setState(() {
      _isInitialized = false;
      _isConfigExpanded = true;
    });
  }

  void _deinitializeTts() {
    _audioPlayer.stop();
    _ttsService.deinitialize();
    _playingBubbleId = null;
    _synthesizingBubbleId = null;
    _selectedSpeakerId = 0;
  }

  Future<void> _initializeEngine() async {
    if (_selectedModel == null) return;
    try {
      await _chatService.loadModel(
        _selectedModel!,
        enableThinking: _enableThinking,
      );
      setState(() {
        _isInitialized = true;
        _isConfigExpanded = false;
      });
      _syncServiceHistoryFromBubbles();
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Chat engine initialized: ${_selectedModel!.name}'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(milliseconds: 1500),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to initialize chat: $e'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<bool> _ensureTtsInitialized() async {
    if (!_ttsEnabled) {
      _showSnack('Enable TTS in configuration first.');
      return false;
    }
    if (_selectedTtsModel == null) {
      _showSnack('Please select a TTS model.');
      return false;
    }
    if (_ttsService.isInitialized) return true;

    setState(() => _ttsInitializing = true);
    try {
      await _ttsService.initialize(_selectedTtsModel!);
      if (!mounted) return false;
      setState(() {
        _selectedSpeakerId = 0;
        _ttsInitializing = false;
      });
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _ttsInitializing = false);
        _showSnack('Failed to initialize TTS: $e');
      }
      return false;
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _nextBubbleId() => 'b${_bubbleSeq++}';

  void _syncServiceHistoryFromBubbles() {
    if (!_chatService.isLoaded) return;
    _chatService.setHistory(
      _bubbles
          .where((b) => !b.isError && b.text.trim().isNotEmpty)
          .map((b) => ChatMessage(role: b.role, content: b.text))
          .toList(),
    );
  }

  Future<void> _persistSession() async {
    if (_bubbles.isEmpty) return;
    final hasUser = _bubbles.any((b) => b.role == 'user' && b.text.trim().isNotEmpty);
    if (!hasUser) return;

    final session = ChatHistoryStore.buildSession(
      existingId: _currentSessionId,
      createdAt: _sessionCreatedAt,
      modelName: _selectedModel?.name,
      messages: _bubbles
          .map((b) => (role: b.role, text: b.text, isError: b.isError))
          .toList(),
    );
    await ChatHistoryStore.save(session);
    if (!mounted) return;
    setState(() {
      _currentSessionId = session.id;
      _sessionCreatedAt = session.createdAt;
    });
  }

  Future<void> _loadSession(ChatHistorySession session) async {
    await _audioPlayer.stop();
    setState(() {
      _bubbles
        ..clear()
        ..addAll(session.messages.map((m) => _ChatBubble(
              id: _nextBubbleId(),
              role: m.role,
              text: m.text,
              isError: m.isError,
            )));
      _currentSessionId = session.id;
      _sessionCreatedAt = session.createdAt;
      _playingBubbleId = null;
      _synthesizingBubbleId = null;
      _editingBubbleId = null;
      _editController.clear();
      _lastInputTokens = null;
      _lastEncoderMs = null;
      _lastDecoderTokens = null;
      _lastDecoderTokensPerSec = null;
    });
    _syncServiceHistoryFromBubbles();
    _scrollToBottom();
    _showSnack(
      _isInitialized
          ? 'Loaded chat history'
          : 'Loaded for viewing — initialize engine to continue',
    );
  }

  void _openHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ChatHistorySheet(
        currentSessionId: _currentSessionId,
        onLoad: _loadSession,
        onDeleted: (id) async {
          if (_currentSessionId == id) {
            _chatService.clearHistory();
            await _audioPlayer.stop();
            if (!mounted) return;
            setState(() {
              _bubbles.clear();
              _currentSessionId = null;
              _sessionCreatedAt = null;
              _playingBubbleId = null;
              _synthesizingBubbleId = null;
              _editingBubbleId = null;
              _editController.clear();
            });
          }
        },
      ),
    );
  }

  /// Plain text used for copy / TTS (thinking strip for assistant).
  String _plainTextForBubble(_ChatBubble bubble) {
    if (bubble.role == 'user' || bubble.isError) return bubble.text.trim();
    final parsed = ParsedMessage.parse(bubble.text);
    if (parsed.hasThinking) {
      return parsed.isThinkingComplete ? parsed.response.trim() : '';
    }
    return bubble.text.trim();
  }

  Future<void> _copyBubble(_ChatBubble bubble) async {
    final text = _plainTextForBubble(bubble);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('Copied');
  }

  Future<void> _playBubble(_ChatBubble bubble) async {
    final text = _plainTextForBubble(bubble);
    if (text.isEmpty) return;

    // Toggle stop if same bubble is playing.
    if (_playingBubbleId == bubble.id) {
      await _audioPlayer.stop();
      setState(() => _playingBubbleId = null);
      return;
    }

    final ready = await _ensureTtsInitialized();
    if (!ready || !mounted) return;

    setState(() {
      _synthesizingBubbleId = bubble.id;
      _playingBubbleId = null;
    });

    try {
      await _audioPlayer.stop();
      final result = await _ttsService.synthesize(
        text: text,
        model: _selectedTtsModel!,
        speakerId: _selectedSpeakerId,
        speed: 1.0,
        prefix: 'tts-chat',
        suffix: '-${bubble.id}',
      );
      if (!mounted) return;
      setState(() {
        _synthesizingBubbleId = null;
        _playingBubbleId = bubble.id;
      });
      await _audioPlayer.play(DeviceFileSource(result.wavPath));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _synthesizingBubbleId = null;
        _playingBubbleId = null;
      });
      _showSnack('TTS failed: $e');
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || !_isInitialized || _isGenerating) return;

    _cancelEditing();
    setState(() {
      _inputController.clear();
      _isGenerating = true;
      _bubbles.add(_ChatBubble(id: _nextBubbleId(), role: 'user', text: text));
      _bubbles.add(_ChatBubble(id: _nextBubbleId(), role: 'assistant', text: ''));
    });
    _scrollToBottom();
    await _generateAssistantReply(text);
  }

  int? _lastUserBubbleIndex() {
    for (var i = _bubbles.length - 1; i >= 0; i--) {
      if (_bubbles[i].role == 'user') return i;
    }
    return null;
  }

  void _startEditing(_ChatBubble bubble) {
    if (!_isInitialized || _isGenerating) {
      _showSnack('Initialize the engine to edit and re-ask.');
      return;
    }
    final lastUser = _lastUserBubbleIndex();
    if (lastUser == null || _bubbles[lastUser].id != bubble.id) {
      _showSnack('Only the latest question can be edited.');
      return;
    }
    setState(() {
      _editingBubbleId = bubble.id;
      _editController.text = bubble.text;
    });
  }

  void _cancelEditing() {
    if (_editingBubbleId == null) return;
    setState(() {
      _editingBubbleId = null;
      _editController.clear();
    });
  }

  Future<void> _submitEditedMessage() async {
    if (!_isInitialized || _isGenerating || _editingBubbleId == null) return;
    final text = _editController.text.trim();
    if (text.isEmpty) {
      _showSnack('Question cannot be empty.');
      return;
    }

    final userIndex = _bubbles.indexWhere((b) => b.id == _editingBubbleId);
    final lastUser = _lastUserBubbleIndex();
    if (userIndex < 0 || lastUser == null || userIndex != lastUser) {
      _cancelEditing();
      return;
    }

    final bubbleId = _bubbles[userIndex].id;
    setState(() {
      _editingBubbleId = null;
      _editController.clear();
      _isGenerating = true;
      if (userIndex + 1 < _bubbles.length) {
        _bubbles.removeRange(userIndex + 1, _bubbles.length);
      }
      _bubbles[userIndex] = _ChatBubble(id: bubbleId, role: 'user', text: text);
      _bubbles.add(_ChatBubble(id: _nextBubbleId(), role: 'assistant', text: ''));
    });

    // Drop the old turn from LLM context; keep prior messages only.
    _chatService.setHistory(
      _bubbles
          .take(userIndex)
          .where((b) => !b.isError && b.text.trim().isNotEmpty)
          .map((b) => ChatMessage(role: b.role, content: b.text))
          .toList(),
    );

    _scrollToBottom();
    await _generateAssistantReply(text);
  }

  Future<void> _generateAssistantReply(String text) async {
    try {
      await for (final partial in _chatService.chatStream(text, enableThinking: _enableThinking)) {
        setState(() {
          final last = _bubbles.last;
          _bubbles.last = _ChatBubble(
            id: last.id,
            role: 'assistant',
            text: partial,
          );
        });
        _scrollToBottom();
      }

      final timing = _chatService.lastStreamTiming;
      if (timing != null) {
        setState(() {
          _lastInputTokens = timing.inputTokens;
          _lastEncoderMs = timing.encoderMs;
          _lastDecoderTokens = timing.decoderTokens;
          _lastDecoderTokensPerSec =
              timing.decoderTokensPerSecond >= 0 ? timing.decoderTokensPerSecond : null;
        });
      }
    } catch (e) {
      setState(() {
        final last = _bubbles.last;
        _bubbles.last = _ChatBubble(
          id: last.id,
          role: 'assistant',
          text: '[Error: $e]',
          isError: true,
        );
      });
    } finally {
      setState(() => _isGenerating = false);
      await _persistSession();
    }
  }

  void _clearHistory() {
    _chatService.clearHistory();
    _audioPlayer.stop();
    setState(() {
      _bubbles.clear();
      _currentSessionId = null;
      _sessionCreatedAt = null;
      _playingBubbleId = null;
      _synthesizingBubbleId = null;
      _editingBubbleId = null;
      _editController.clear();
      _lastInputTokens = null;
      _lastEncoderMs = null;
      _lastDecoderTokens = null;
      _lastDecoderTokensPerSec = null;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openModelManagement({String initialType = 'llm'}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: initialType,
        onModelsChanged: () => _loadModels(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF1F3F9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildConfigCard(),

          if (_isInitialized || _bubbles.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _isInitialized
                          ? 'Chat Session Active'
                          : 'View only — initialize engine to continue',
                      style: TextStyle(
                        fontSize: 12,
                        color: _isInitialized ? Colors.grey : Colors.orange.shade700,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Chat History',
                        onPressed: _isGenerating ? null : _openHistorySheet,
                        icon: const Icon(Icons.history_rounded, size: 18, color: Color(0xFF1E3C72)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                      ),
                      if (_isInitialized) ...[
                        const SizedBox(width: 4),
                        const Text(
                          'Think',
                          style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          height: 20,
                          width: 36,
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: Switch(
                              value: _enableThinking,
                              activeColor: const Color(0xFF1E3C72),
                              onChanged: (val) {
                                setState(() {
                                  _enableThinking = val;
                                });
                              },
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: (_bubbles.isEmpty || _isGenerating) ? null : _clearHistory,
                        icon: const Icon(Icons.add_comment_outlined, size: 14),
                        label: const Text('New Chat', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red.shade400,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _bubbles.isEmpty
                      ? const Center(
                          child: Text(
                            'Start a conversation or load history.',
                            style: TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : SelectionArea(
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: _bubbles.length,
                            itemBuilder: (context, index) => _buildBubble(
                              _bubbles[index],
                              isStreaming: _isGenerating && index == _bubbles.length - 1,
                            ),
                          ),
                        ),
                ),
              ),
            ),

            if (_isInitialized && widget.showPerfMetrics && _lastEncoderMs != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E3C72).withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF1E3C72).withOpacity(0.15)),
                ),
                child: Text(
                  'Prompt: ${_lastInputTokens}t / ${_lastEncoderMs!.toStringAsFixed(0)}ms  |  '
                  'Decode: ${_lastDecoderTokens}t / ${(_lastDecoderTokensPerSec ?? 0).toStringAsFixed(1)}t/s',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1E3C72)),
                  textAlign: TextAlign.center,
                ),
              ),

            if (_isInitialized)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: TextField(
                          controller: _inputController,
                          focusNode: _inputFocusNode,
                          maxLength: 500,
                          enableInteractiveSelection: true,
                          style: const TextStyle(fontSize: 15, color: Color(0xFF2D3748)),
                          decoration: InputDecoration(
                            hintText: 'Type a message...',
                            hintStyle: TextStyle(color: Colors.grey.shade400),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            counterText: '',
                          ),
                          maxLines: 4,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendMessage(),
                          contextMenuBuilder: (context, editableTextState) {
                            return AdaptiveTextSelectionToolbar.editableText(
                              editableTextState: editableTextState,
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _sendMessage,
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF1E3C72), Color(0xFF2A5298)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  'Initialize the chat engine to continue this conversation.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
          ] else ...[
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Please initialize the engine first to start chatting.',
                      style: TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _openHistorySheet,
                      icon: const Icon(Icons.history_rounded, size: 18),
                      label: const Text('Browse History'),
                    ),
                  ],
                ),
              ),
            ),
          ]
        ],
      ),
    );
  }

  Widget _buildConfigCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                        'LLM Chat Configuration',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
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
                              color: _isInitialized ? Colors.green.shade50 : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: _isInitialized ? Colors.green.shade200 : Colors.grey.shade300),
                            ),
                            child: Text(
                              _isInitialized
                                  ? 'Initialized: ${_selectedModel?.name ?? ""}'
                                  : 'Not Initialized',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: _isInitialized ? Colors.green.shade700 : Colors.grey.shade600,
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
                  onPressed: _isGenerating ? null : _openHistorySheet,
                  icon: const Icon(Icons.history_rounded, color: Color(0xFF1E3C72)),
                  tooltip: 'Chat History',
                ),
                IconButton(
                  onPressed: () => _openModelManagement(),
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
            else if (_llmModels.isEmpty)
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
                        'No GGUF model imported.\nClick the model repository icon to import a model.',
                        style: TextStyle(color: Color(0xFFC05621), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              const Text(
                'Select LLM Model:',
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
                items: _llmModels.map((m) => DropdownMenuItem(value: m, child: Text(m.name))).toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedModel = val;
                    _deinitializeEngine();
                  });
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Optional TTS',
                      style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    _ttsEnabled ? 'Enabled' : 'Disabled',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    height: 24,
                    child: Switch(
                      value: _ttsEnabled,
                      activeColor: const Color(0xFF1E3C72),
                      onChanged: (val) {
                        setState(() {
                          _ttsEnabled = val;
                          if (!val) {
                            _deinitializeTts();
                          }
                        });
                      },
                    ),
                  ),
                ],
              ),
              if (_ttsEnabled) ...[
                const SizedBox(height: 8),
                if (_ttsModels.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.orange.shade600, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No TTS model imported.',
                            style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _openModelManagement(initialType: 'tts'),
                          child: const Text('Import', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  )
                else ...[
                  const Text(
                    'Select TTS Model:',
                    style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<ModelInfo>(
                    value: _ttsModels.contains(_selectedTtsModel) ? _selectedTtsModel : null,
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
                    items: _ttsModels
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text('${m.name} (${m.ttsEngineType})', overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedTtsModel = val;
                        _deinitializeTts();
                      });
                    },
                  ),
                  if (_ttsService.isInitialized && _ttsService.maxSpeakerId > 0) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Speaker ID:',
                      style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<int>(
                      value: _selectedSpeakerId.clamp(0, _ttsService.maxSpeakerId),
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
                      items: List.generate(
                        _ttsService.maxSpeakerId + 1,
                        (i) => DropdownMenuItem(value: i, child: Text('Speaker #$i')),
                      ),
                      onChanged: (val) {
                        if (val != null) setState(() => _selectedSpeakerId = val);
                      },
                    ),
                  ],
                  if (_ttsInitializing)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
              ],
              if (_selectedModel != null) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isInitialized ? _deinitializeEngine : _initializeEngine,
                    icon: Icon(
                      _isInitialized ? Icons.power_settings_new_rounded : Icons.flash_on_rounded,
                      color: Colors.white,
                    ),
                    label: Text(
                      _isInitialized ? 'Deinitialize Chat' : 'Initialize Chat Engine',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isInitialized ? Colors.red.shade600 : const Color(0xFF1E3C72),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 2,
                    ),
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildBubble(_ChatBubble bubble, {required bool isStreaming}) {
    final isUser = bubble.role == 'user';
    final alignment = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final userBgColor = const Color(0xFF1E3C72);
    final assistantBgColor = Colors.grey.shade100;
    final plain = _plainTextForBubble(bubble);
    final isEditing = _editingBubbleId == bubble.id;
    final lastUserIndex = _lastUserBubbleIndex();
    final isLastUser = isUser &&
        lastUserIndex != null &&
        _bubbles[lastUserIndex].id == bubble.id;
    final canEdit = isLastUser && _isInitialized && !_isGenerating && !bubble.isError;
    final showActions = !isStreaming && plain.isNotEmpty && !bubble.isError && !isEditing;
    final isPlaying = _playingBubbleId == bubble.id;
    final isSynthesizing = _synthesizingBubbleId == bubble.id;
    final actionColor = isUser ? Colors.white70 : const Color(0xFF1E3C72);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: bubble.isError ? Colors.red.shade50 : (isUser ? userBgColor : assistantBgColor),
              borderRadius: isUser
                  ? const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(4),
                    )
                  : const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(16),
                    ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isEditing)
                  SelectionContainer.disabled(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _editController,
                          autofocus: true,
                          maxLines: 6,
                          minLines: 1,
                          maxLength: 500,
                          style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.4),
                          cursorColor: Colors.white,
                          decoration: InputDecoration(
                            isDense: true,
                            counterText: '',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Colors.white54),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Colors.white54),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: Colors.white, width: 1.5),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _cancelEditing,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white70,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                            ),
                            const SizedBox(width: 4),
                            ElevatedButton.icon(
                              onPressed: _submitEditedMessage,
                              icon: const Icon(Icons.send_rounded, size: 14, color: Color(0xFF1E3C72)),
                              label: const Text(
                                'Resubmit',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E3C72),
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                elevation: 0,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                else if (isUser)
                  Text(
                    bubble.text,
                    style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.4),
                  )
                else
                  _AssistantMessageWidget(
                    text: bubble.text,
                    isError: bubble.isError,
                    isStreaming: isStreaming,
                  ),
                if (showActions)
                  SelectionContainer.disabled(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _BubbleActionButton(
                            icon: Icons.copy_rounded,
                            tooltip: 'Copy',
                            color: actionColor,
                            onPressed: () => _copyBubble(bubble),
                          ),
                          const SizedBox(width: 4),
                          _BubbleActionButton(
                            icon: isSynthesizing
                                ? Icons.hourglass_top_rounded
                                : (isPlaying ? Icons.stop_rounded : Icons.volume_up_rounded),
                            tooltip: !_ttsEnabled
                                ? 'Enable TTS in configuration'
                                : (isPlaying ? 'Stop' : 'Speak'),
                            color: actionColor,
                            busy: isSynthesizing,
                            onPressed: isSynthesizing
                                ? null
                                : () {
                                    if (!_ttsEnabled || _selectedTtsModel == null) {
                                      _showSnack(
                                        _ttsModels.isEmpty
                                            ? 'Import a TTS model first.'
                                            : 'Enable TTS and select a model in configuration.',
                                      );
                                      return;
                                    }
                                    _playBubble(bubble);
                                  },
                          ),
                          if (canEdit) ...[
                            const SizedBox(width: 4),
                            _BubbleActionButton(
                              icon: Icons.edit_rounded,
                              tooltip: 'Edit & re-ask',
                              color: actionColor,
                              onPressed: () => _startEditing(bubble),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    ModelManager.changeNotifier.removeListener(_loadModels);
    _inputController.dispose();
    _editController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _ttsService.deinitialize();
    _chatService.release();
    super.dispose();
  }
}

class _BubbleActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;
  final bool busy;

  const _BubbleActionButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        tooltip: tooltip,
        onPressed: onPressed,
        icon: busy
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: color,
                ),
              )
            : Icon(icon, size: 16, color: color),
      ),
    );
  }
}

class _ChatBubble {
  final String id;
  final String role;
  final String text;
  final bool isError;

  const _ChatBubble({
    required this.id,
    required this.role,
    required this.text,
    this.isError = false,
  });
}

class ParsedMessage {
  final String thinking;
  final String response;
  final bool isThinkingComplete;
  final bool hasThinking;

  ParsedMessage({
    required this.thinking,
    required this.response,
    required this.isThinkingComplete,
    required this.hasThinking,
  });

  factory ParsedMessage.parse(String text) {
    const thinkStartTag = '<think>';
    const thinkEndTag = '</think>';

    final startIdx = text.indexOf(thinkStartTag);
    if (startIdx == -1) {
      return ParsedMessage(
        thinking: '',
        response: text,
        isThinkingComplete: false,
        hasThinking: false,
      );
    }

    final endIdx = text.indexOf(thinkEndTag, startIdx + thinkStartTag.length);
    if (endIdx == -1) {
      // Still thinking
      final thinking = text.substring(startIdx + thinkStartTag.length);
      return ParsedMessage(
        thinking: thinking,
        response: '',
        isThinkingComplete: false,
        hasThinking: true,
      );
    } else {
      // Thinking completed
      final thinking = text.substring(startIdx + thinkStartTag.length, endIdx);
      final response = text.substring(endIdx + thinkEndTag.length);
      return ParsedMessage(
        thinking: thinking,
        response: response,
        isThinkingComplete: true,
        hasThinking: true,
      );
    }
  }
}

class _AssistantMessageWidget extends StatefulWidget {
  final String text;
  final bool isError;
  final bool isStreaming;

  const _AssistantMessageWidget({
    Key? key,
    required this.text,
    required this.isError,
    this.isStreaming = false,
  }) : super(key: key);

  @override
  State<_AssistantMessageWidget> createState() => _AssistantMessageWidgetState();
}

class _AssistantMessageWidgetState extends State<_AssistantMessageWidget> {
  bool? _isCollapsed;

  static const _baseTextStyle = TextStyle(
    fontSize: 14,
    color: Colors.black87,
    height: 1.4,
  );

  MarkdownStyleSheet _markdownStyle(BuildContext context) {
    final theme = Theme.of(context);
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: _baseTextStyle,
      a: _baseTextStyle.copyWith(
        color: const Color(0xFF1E3C72),
        decoration: TextDecoration.underline,
      ),
      h1: _baseTextStyle.copyWith(fontSize: 20, fontWeight: FontWeight.bold),
      h2: _baseTextStyle.copyWith(fontSize: 18, fontWeight: FontWeight.bold),
      h3: _baseTextStyle.copyWith(fontSize: 16, fontWeight: FontWeight.bold),
      h4: _baseTextStyle.copyWith(fontSize: 15, fontWeight: FontWeight.bold),
      strong: _baseTextStyle.copyWith(fontWeight: FontWeight.bold),
      em: _baseTextStyle.copyWith(fontStyle: FontStyle.italic),
      listBullet: _baseTextStyle,
      blockquote: _baseTextStyle.copyWith(color: Colors.grey.shade700),
      blockquoteDecoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(4),
        border: Border(
          left: BorderSide(color: Colors.grey.shade400, width: 3),
        ),
      ),
      code: TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        color: const Color(0xFF2D3748),
        backgroundColor: Colors.grey.shade200,
      ),
      codeblockDecoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey.shade300, width: 1),
        ),
      ),
    );
  }

  Widget _buildResponseBody(String text) {
    if (text.isEmpty) {
      return const Text('...', style: _baseTextStyle);
    }
    if (widget.isError) {
      return Text(
        text,
        style: _baseTextStyle.copyWith(color: Colors.red),
      );
    }
    // Stream incomplete markdown as plain text to avoid flicker / broken parsing.
    if (widget.isStreaming) {
      return Text(text, style: _baseTextStyle);
    }
    // selectable: false — parent SelectionArea owns selection/copy (more
    // reliable on desktop than MarkdownBody's SelectableText).
    return MarkdownBody(
      data: text,
      selectable: false,
      styleSheet: _markdownStyle(context),
      softLineBreak: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final parsed = ParsedMessage.parse(widget.text);

    if (!parsed.hasThinking) {
      return _buildResponseBody(widget.text);
    }

    // Default to expanded while thinking, and collapsed when thinking is complete
    final collapsed = _isCollapsed ?? parsed.isThinkingComplete;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Thinking process header
        InkWell(
          onTap: () {
            setState(() {
              _isCollapsed = !collapsed;
            });
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 16,
                  color: Colors.blue.shade700,
                ),
                const SizedBox(width: 6),
                Text(
                  parsed.isThinkingComplete ? 'Thinking process' : 'Thinking...',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.blue.shade700,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  collapsed ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                  size: 16,
                  color: Colors.blue.shade700,
                ),
              ],
            ),
          ),
        ),

        // Thinking process body
        if (!collapsed)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4, bottom: 8),
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: Colors.blue.shade100,
                  width: 3,
                ),
              ),
            ),
            child: Text(
              parsed.thinking.trim().isEmpty ? '...' : parsed.thinking.trim(),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                height: 1.4,
              ),
            ),
          ),

        // Actual response
        if (parsed.isThinkingComplete)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _buildResponseBody(parsed.response.trim()),
          ),
      ],
    );
  }
}
