import 'package:flutter/material.dart';
import 'model_manager.dart';
import 'model_management_sheet.dart';
import 'llama_chat_service.dart';


class ChatScreen extends StatefulWidget {
  final bool showPerfMetrics;
  const ChatScreen({Key? key, this.showPerfMetrics = false}) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final LlamaChatService _chatService = LlamaChatService();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isInitialized = false;
  bool _isGenerating = false;
  bool _loadingModels = true;

  List<ModelInfo> _llmModels = [];
  ModelInfo? _selectedModel;

  final List<_ChatBubble> _bubbles = [];

  int? _lastInputTokens;
  double? _lastEncoderMs;
  int? _lastDecoderTokens;
  double? _lastDecoderTokensPerSec;
  bool _enableThinking = true;

  @override
  void initState() {
    super.initState();
    _loadModels();
    ModelManager.changeNotifier.addListener(_loadModels);
  }

  Future<void> _loadModels() async {
    setState(() => _loadingModels = true);
    final models = await ModelManager.getModels('llm');
    setState(() {
      _llmModels = models;
      _loadingModels = false;
      if (_selectedModel != null &&
          !models.any((m) => m.name == _selectedModel!.name && m.path == _selectedModel!.path)) {
        _selectedModel = null;
        _deinitializeEngine();
      }
      if (_selectedModel == null && models.isNotEmpty) {
        _selectedModel = models.first;
      }
    });
  }

  void _deinitializeEngine() {
    _chatService.release();
    setState(() => _isInitialized = false);
  }

  Future<void> _initializeEngine() async {
    if (_selectedModel == null) return;
    try {
      await _chatService.loadModel(
        _selectedModel!,
        enableThinking: _enableThinking,
      );
      setState(() => _isInitialized = true);
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

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || !_isInitialized || _isGenerating) return;

    setState(() {
      _inputController.clear();
      _isGenerating = true;
      _bubbles.add(_ChatBubble(role: 'user', text: text));
      _bubbles.add(_ChatBubble(role: 'assistant', text: ''));
    });
    _scrollToBottom();

    try {
      await for (final partial in _chatService.chatStream(text, enableThinking: _enableThinking)) {
        setState(() {
          _bubbles.last = _ChatBubble(role: 'assistant', text: partial);
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
        _bubbles.last = _ChatBubble(role: 'assistant', text: '[Error: $e]', isError: true);
      });
    } finally {
      setState(() => _isGenerating = false);
    }
  }

  void _clearHistory() {
    _chatService.clearHistory();
    setState(() {
      _bubbles.clear();
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

  void _openModelManagement() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ModelManagementSheet(
        initialType: 'llm',
        onModelsChanged: () => _loadModels(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildConfigCard(),

        if (_selectedModel != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ElevatedButton(
              onPressed: _isInitialized ? _deinitializeEngine : _initializeEngine,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(12),
                backgroundColor: _isInitialized ? Colors.red : Colors.blue,
                foregroundColor: Colors.white,
              ),
              child: Text(_isInitialized ? 'Deinitialize Chat' : 'Initialize Chat Engine'),
            ),
          ),

        if (_isInitialized) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Chat — ${_selectedModel!.name}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Think', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 24,
                      width: 38,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: Switch(
                          value: _enableThinking,
                          onChanged: (val) {
                            setState(() {
                              _enableThinking = val;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: _bubbles.isEmpty ? null : _clearHistory,
                      icon: const Icon(Icons.delete_outline, size: 14),
                      label: const Text('Clear', style: TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(
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
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade200),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _bubbles.length,
                  itemBuilder: (context, index) => _buildBubble(_bubbles[index]),
                ),
              ),
            ),
          ),

          if (widget.showPerfMetrics && _lastEncoderMs != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Prompt: ${_lastInputTokens}t / ${_lastEncoderMs!.toStringAsFixed(0)}ms  |  '
                'Decode: ${_lastDecoderTokens}t / ${(_lastDecoderTokensPerSec ?? 0).toStringAsFixed(1)}t/s',
                style: const TextStyle(fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      counterText: '',
                    ),
                    maxLines: 4,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isGenerating ? null : _sendMessage,
                  icon: _isGenerating
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_rounded, color: Colors.blue),
                  tooltip: 'Send',
                ),
              ],
            ),
          ),
        ] else
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey[300]),
                  const SizedBox(height: 12),
                  Text(
                    _selectedModel == null
                        ? 'No LLM model installed.\nClick the settings icon to import a model.'
                        : 'Initialize the chat engine to start.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildConfigCard() {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'LLM Chat Configuration',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: _openModelManagement,
                  icon: const Icon(Icons.settings, color: Colors.blue),
                  tooltip: 'Manage LLM Models',
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loadingModels)
              const Center(child: CircularProgressIndicator())
            else if (_llmModels.isEmpty)
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
                        'No GGUF model imported.\nClick the settings icon to import a model.',
                        style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              Row(
                children: [
                  const Text('Model:', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<ModelInfo>(
                      value: _selectedModel,
                      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                      items: _llmModels.map((m) => DropdownMenuItem(value: m, child: Text(m.name))).toList(),
                      onChanged: (val) {
                        setState(() {
                          _selectedModel = val;
                          _deinitializeEngine();
                        });
                      },
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(_ChatBubble bubble) {
    final isUser = bubble.role == 'user';
    final alignment = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bgColor = isUser ? Colors.blue : Colors.grey.shade200;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bubble.isError ? Colors.red.shade50 : bgColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: isUser
                ? Text(
                    bubble.text,
                    style: const TextStyle(fontSize: 14, color: Colors.white),
                  )
                : _AssistantMessageWidget(
                    text: bubble.text,
                    isError: bubble.isError,
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
    _scrollController.dispose();
    _chatService.release();
    super.dispose();
  }
}

class _ChatBubble {
  final String role;
  final String text;
  final bool isError;

  const _ChatBubble({required this.role, required this.text, this.isError = false});
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
  const _AssistantMessageWidget({
    Key? key,
    required this.text,
    required this.isError,
  }) : super(key: key);

  @override
  State<_AssistantMessageWidget> createState() => _AssistantMessageWidgetState();
}

class _AssistantMessageWidgetState extends State<_AssistantMessageWidget> {
  bool? _isCollapsed;

  @override
  Widget build(BuildContext context) {
    final parsed = ParsedMessage.parse(widget.text);

    if (!parsed.hasThinking) {
      return Text(
        widget.text.isEmpty ? '...' : widget.text,
        style: TextStyle(
          fontSize: 14,
          color: widget.isError ? Colors.red : Colors.black87,
        ),
      );
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
            child: Text(
              parsed.response.trim().isEmpty ? '...' : parsed.response.trim(),
              style: TextStyle(
                fontSize: 14,
                color: widget.isError ? Colors.red : Colors.black87,
                height: 1.4,
              ),
            ),
          ),
      ],
    );
  }
}
