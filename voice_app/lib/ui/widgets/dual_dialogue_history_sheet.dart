import 'package:flutter/material.dart';
import 'package:voice_app/services/dual_dialogue_history_store.dart';

/// Bottom sheet listing saved dual-dialogue sessions for preview / delete.
class DualDialogueHistorySheet extends StatefulWidget {
  final String? currentSessionId;
  final Future<void> Function(DualDialogueSession session)? onLoad;
  final Future<void> Function(String id)? onDeleted;

  const DualDialogueHistorySheet({
    Key? key,
    this.currentSessionId,
    this.onLoad,
    this.onDeleted,
  }) : super(key: key);

  @override
  State<DualDialogueHistorySheet> createState() => _DualDialogueHistorySheetState();
}

class _DualDialogueHistorySheetState extends State<DualDialogueHistorySheet> {
  List<DualDialogueHistorySummary> _items = [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final items = await DualDialogueHistoryStore.list();
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

  Future<void> _previewItem(DualDialogueHistorySummary summary) async {
    setState(() => _busyId = summary.id);
    try {
      final session = await DualDialogueHistoryStore.load(summary.id);
      if (!mounted) return;
      if (session == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session file missing.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _reload();
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _DualDialoguePreviewSheet(
          session: session,
          formatTime: _formatTime,
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _loadItem(DualDialogueHistorySummary summary) async {
    if (widget.onLoad == null) {
      await _previewItem(summary);
      return;
    }
    setState(() => _busyId = summary.id);
    try {
      final session = await DualDialogueHistoryStore.load(summary.id);
      if (session == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session file missing.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          await _reload();
        }
        return;
      }
      await widget.onLoad!(session);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteItem(DualDialogueHistorySummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除双人对话记录？'),
        content: Text(_preview(summary.preview.isNotEmpty ? summary.preview : summary.title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyId = summary.id);
    try {
      await DualDialogueHistoryStore.delete(summary.id);
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
                    '双人对话历史',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3748),
                    ),
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
                '一次模型初始化对应一条记录，可含多轮对话',
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
                          '暂无双人对话记录',
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
                              item.title.isNotEmpty ? item.title : _preview(item.preview),
                              maxLines: 1,
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
                                ' · ${item.langA} ↔ ${item.langB}'
                                ' · ${item.mtMode.toUpperCase()}'
                                ' · ${item.turnCount} turns'
                                '${isCurrent ? ' · Current' : ''}\n'
                                '${_preview(item.preview)}',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.35),
                              ),
                            ),
                            isThreeLine: true,
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
                                        icon: const Icon(
                                          Icons.visibility_outlined,
                                          color: Color(0xFF1E3C72),
                                          size: 20,
                                        ),
                                      ),
                                      if (widget.onLoad != null)
                                        IconButton(
                                          tooltip: 'Load',
                                          onPressed: () => _loadItem(item),
                                          icon: const Icon(
                                            Icons.input_rounded,
                                            color: Color(0xFF1E3C72),
                                            size: 20,
                                          ),
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

class _DualDialoguePreviewSheet extends StatelessWidget {
  final DualDialogueSession session;
  final String Function(DateTime) formatTime;

  const _DualDialoguePreviewSheet({
    required this.session,
    required this.formatTime,
  });

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
                Expanded(
                  child: Text(
                    session.title.isNotEmpty ? session.title : 'Preview',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3748),
                    ),
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
                ' · ${session.langA} ↔ ${session.langB}'
                ' · ${session.mtMode.toUpperCase()}'
                ' · ${session.turnCount} turns',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.4),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: session.turns.isEmpty
                ? Center(
                    child: Text('无对话内容', style: TextStyle(color: Colors.grey.shade600)),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: session.turns.length,
                      itemBuilder: (context, index) {
                        final turn = session.turns[index];
                        final isA = turn.side == 'A';
                        final bg = isA ? const Color(0xFFE8EEF7) : const Color(0xFFE6F5F2);
                        final border = isA ? const Color(0xFFC5D4EA) : const Color(0xFFB7E0D8);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Align(
                            alignment: isA ? Alignment.centerLeft : Alignment.centerRight,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.8,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: bg,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      turn.asr.trim().isEmpty ? '...' : turn.asr,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.4,
                                        color: Color(0xFF2D3748),
                                      ),
                                    ),
                                    if (turn.mt.trim().isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.only(top: 6),
                                        decoration: BoxDecoration(
                                          border: Border(top: BorderSide(color: border)),
                                        ),
                                        child: Text(
                                          turn.mt,
                                          style: TextStyle(
                                            fontSize: 13,
                                            height: 1.35,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                      ),
                                    ],
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
