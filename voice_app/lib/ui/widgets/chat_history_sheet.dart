import 'package:flutter/material.dart';
import 'package:voice_app/services/chat_history_store.dart';

/// Bottom sheet listing saved LLM chat sessions for load / delete / preview.
class ChatHistorySheet extends StatefulWidget {
  final String? currentSessionId;
  final Future<void> Function(ChatHistorySession session) onLoad;
  final Future<void> Function(String id)? onDeleted;

  const ChatHistorySheet({
    Key? key,
    this.currentSessionId,
    required this.onLoad,
    this.onDeleted,
  }) : super(key: key);

  @override
  State<ChatHistorySheet> createState() => _ChatHistorySheetState();
}

class _ChatHistorySheetState extends State<ChatHistorySheet> {
  List<ChatHistorySummary> _items = [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final items = await ChatHistoryStore.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _preview(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '(Empty)';
    if (t.length <= 80) return t;
    return '${t.substring(0, 80)}…';
  }

  Future<void> _loadItem(ChatHistorySummary summary) async {
    setState(() => _busyId = summary.id);
    try {
      final session = await ChatHistoryStore.load(summary.id);
      if (session == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Session file missing.'), behavior: SnackBarBehavior.floating),
          );
          await _reload();
        }
        return;
      }
      await widget.onLoad(session);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _previewItem(ChatHistorySummary summary) async {
    setState(() => _busyId = summary.id);
    try {
      final session = await ChatHistoryStore.load(summary.id);
      if (!mounted) return;
      if (session == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session file missing.'), behavior: SnackBarBehavior.floating),
        );
        await _reload();
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _ChatHistoryPreviewSheet(
          session: session,
          formatTime: _formatTime,
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteItem(ChatHistorySummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(_preview(summary.firstUserMessage)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyId = summary.id);
    try {
      await ChatHistoryStore.delete(summary.id);
      await widget.onDeleted?.call(summary.id);
      await _reload();
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      margin: EdgeInsets.only(bottom: bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Chat History',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : _reload,
                  icon: const Icon(Icons.refresh_rounded, color: Color(0xFF1E3C72)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Use Preview / Load / Delete on each row',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Text(
                          'No saved chats yet.',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          final isCurrent = item.id == widget.currentSessionId;
                          final busy = _busyId == item.id;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            title: Text(
                              _preview(item.firstUserMessage),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF2D3748),
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${_formatTime(item.updatedAt)}'
                                '${item.modelName != null ? ' · ${item.modelName}' : ''}'
                                ' · ${item.messageCount} msgs'
                                '${isCurrent ? ' · Current' : ''}',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                              ),
                            ),
                            trailing: busy
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: 'Preview',
                                        onPressed: () => _previewItem(item),
                                        icon: const Icon(Icons.visibility_outlined, color: Color(0xFF1E3C72), size: 20),
                                      ),
                                      IconButton(
                                        tooltip: 'Load into chat',
                                        onPressed: () => _loadItem(item),
                                        icon: const Icon(Icons.input_rounded, color: Color(0xFF1E3C72), size: 20),
                                      ),
                                      IconButton(
                                        tooltip: 'Delete',
                                        onPressed: () => _deleteItem(item),
                                        icon: Icon(Icons.delete_outline, color: Colors.red.shade400, size: 20),
                                      ),
                                    ],
                                  ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _ChatHistoryPreviewSheet extends StatelessWidget {
  final ChatHistorySession session;
  final String Function(DateTime) formatTime;

  const _ChatHistoryPreviewSheet({
    required this.session,
    required this.formatTime,
  });

  String _displayText(ChatHistoryMessage message) {
    if (message.role != 'assistant') return message.text;
    const thinkStart = '<think>';
    const thinkEnd = '</think>';
    final start = message.text.indexOf(thinkStart);
    if (start == -1) return message.text;
    final end = message.text.indexOf(thinkEnd, start + thinkStart.length);
    if (end == -1) return message.text.substring(start + thinkStart.length).trim();
    final thinking = message.text.substring(start + thinkStart.length, end).trim();
    final response = message.text.substring(end + thinkEnd.length).trim();
    if (thinking.isEmpty) return response;
    if (response.isEmpty) return '[Thinking]\n$thinking';
    return '[Thinking]\n$thinking\n\n$response';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Preview',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${formatTime(session.updatedAt)}'
                '${session.modelName != null ? ' · ${session.modelName}' : ''}'
                ' · ${session.messageCount} msgs\n'
                'Read-only preview — not loaded into chat',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.4),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: session.messages.length,
                itemBuilder: (context, index) {
                  final message = session.messages[index];
                  final isUser = message.role == 'user';
                  final body = _displayText(message);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.85,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: message.isError
                                ? Colors.red.shade50
                                : (isUser ? const Color(0xFF1E3C72) : Colors.grey.shade100),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isUser ? 'User' : (message.isError ? 'Error' : 'Assistant'),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isUser ? Colors.white70 : Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                body.trim().isEmpty ? '...' : body,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  color: message.isError
                                      ? Colors.red
                                      : (isUser ? Colors.white : Colors.black87),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
