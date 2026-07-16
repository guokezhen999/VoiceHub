import 'package:flutter/material.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/ui/widgets/model_management_sheet.dart';
import 'package:voice_app/services/llama_chat_service.dart';


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
  bool _isConfigExpanded = true;

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
      if (_selectedModel != null && !models.any((m) => m.path == _selectedModel!.path)) {
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
    setState(() {
      _isInitialized = false;
      _isConfigExpanded = true;
    });
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
    return Container(
      color: const Color(0xFFF1F3F9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildConfigCard(),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isInitialized ? 'Chat Session Active' : 'Chat Session Inactive',
                  style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: _bubbles.isEmpty ? null : _clearHistory,
                      icon: const Icon(Icons.delete_outline, size: 14),
                      label: const Text('Clear History', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
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
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32.0),
                          child: Text(
                            _isInitialized
                                ? 'No messages yet. Start the conversation!'
                                : 'Please initialize the engine first to start chatting.',
                            style: const TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _bubbles.length,
                        itemBuilder: (context, index) => _buildBubble(_bubbles[index]),
                      ),
              ),
            ),
          ),

          if (widget.showPerfMetrics && _lastEncoderMs != null)
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
                      enabled: _isInitialized,
                      maxLength: 500,
                      style: TextStyle(
                        fontSize: 15,
                        color: _isInitialized ? const Color(0xFF2D3748) : Colors.grey.shade400,
                      ),
                      decoration: InputDecoration(
                        hintText: _isInitialized ? 'Type a message...' : 'Engine not initialized',
                        hintStyle: TextStyle(color: Colors.grey.shade400),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        counterText: '',
                      ),
                      maxLines: 4,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _isInitialized ? _sendMessage() : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _isInitialized ? _sendMessage : null,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: _isInitialized
                          ? const LinearGradient(
                              colors: [Color(0xFF1E3C72), Color(0xFF2A5298)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : LinearGradient(
                              colors: [Colors.grey.shade300, Colors.grey.shade400],
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
          ),
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
                'Select Model:',
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

  Widget _buildBubble(_ChatBubble bubble) {
    final isUser = bubble.role == 'user';
    final alignment = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final userBgColor = const Color(0xFF1E3C72);
    final assistantBgColor = Colors.grey.shade100;

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
            child: isUser
                ? Text(
                    bubble.text,
                    style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.4),
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
