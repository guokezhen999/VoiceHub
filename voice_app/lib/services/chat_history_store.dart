import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Lightweight index entry shown in the history list.
class ChatHistorySummary {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String firstUserMessage;
  final int messageCount;
  final String? modelName;

  const ChatHistorySummary({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.firstUserMessage,
    required this.messageCount,
    this.modelName,
  });

  factory ChatHistorySummary.fromJson(Map<String, dynamic> json) {
    return ChatHistorySummary(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      firstUserMessage: (json['firstUserMessage'] as String?) ?? '',
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      modelName: json['modelName'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'firstUserMessage': firstUserMessage,
        'messageCount': messageCount,
        if (modelName != null) 'modelName': modelName,
      };
}

class ChatHistoryMessage {
  final String role; // 'user' | 'assistant'
  final String text;
  final DateTime? timestamp;
  final bool isError;

  const ChatHistoryMessage({
    required this.role,
    required this.text,
    this.timestamp,
    this.isError = false,
  });

  factory ChatHistoryMessage.fromJson(Map<String, dynamic> json) {
    return ChatHistoryMessage(
      role: json['role'] as String,
      text: (json['text'] as String?) ?? '',
      timestamp: json['ts'] != null ? DateTime.tryParse(json['ts'] as String) : null,
      isError: json['isError'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        if (timestamp != null) 'ts': timestamp!.toIso8601String(),
        if (isError) 'isError': true,
      };
}

/// Full chat session persisted under `history/chat/sessions/<id>.json`.
class ChatHistorySession {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String firstUserMessage;
  final String? modelName;
  final List<ChatHistoryMessage> messages;

  const ChatHistorySession({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.firstUserMessage,
    required this.messages,
    this.modelName,
  });

  int get messageCount => messages.length;

  ChatHistorySummary toSummary() => ChatHistorySummary(
        id: id,
        createdAt: createdAt,
        updatedAt: updatedAt,
        firstUserMessage: firstUserMessage,
        messageCount: messageCount,
        modelName: modelName,
      );

  factory ChatHistorySession.fromJson(Map<String, dynamic> json) {
    final msgs = (json['messages'] as List<dynamic>? ?? [])
        .map((e) => ChatHistoryMessage.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return ChatHistorySession(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      firstUserMessage: (json['firstUserMessage'] as String?) ?? '',
      modelName: json['modelName'] as String?,
      messages: msgs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'firstUserMessage': firstUserMessage,
        if (modelName != null) 'modelName': modelName,
        'messages': messages.map((m) => m.toJson()).toList(),
      };
}

/// Persists LLM chat sessions under:
///   `<Application Support>/history/chat/index.json`
///   `<Application Support>/history/chat/sessions/<id>.json`
class ChatHistoryStore {
  static final _rand = Random();

  static Future<Directory> _chatDir() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appSupport.path, 'history', 'chat'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _sessionsDir() async {
    final chat = await _chatDir();
    final dir = Directory(p.join(chat.path, 'sessions'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _indexFile() async {
    final chat = await _chatDir();
    return File(p.join(chat.path, 'index.json'));
  }

  static Future<File> _sessionFile(String id) async {
    final sessions = await _sessionsDir();
    return File(p.join(sessions.path, '$id.json'));
  }

  static String newId() {
    final now = DateTime.now().toUtc();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final suffix = List.generate(4, (_) => _rand.nextInt(16).toRadixString(16)).join();
    return '$stamp-$suffix';
  }

  /// Returns summaries sorted by [ChatHistorySummary.updatedAt] descending.
  static Future<List<ChatHistorySummary>> list() async {
    final file = await _indexFile();
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      final items = raw
          .map((e) => ChatHistorySummary.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeIndex(List<ChatHistorySummary> items) async {
    final file = await _indexFile();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(items.map((e) => e.toJson()).toList()),
    );
  }

  static Future<ChatHistorySession?> load(String id) async {
    final file = await _sessionFile(id);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ChatHistorySession.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Creates or overwrites a session and upserts its index entry.
  static Future<void> save(ChatHistorySession session) async {
    final file = await _sessionFile(session.id);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
    );

    final index = await list();
    final summary = session.toSummary();
    final existing = index.indexWhere((e) => e.id == session.id);
    if (existing >= 0) {
      index[existing] = summary;
    } else {
      index.add(summary);
    }
    await _writeIndex(index);
  }

  static Future<void> delete(String id) async {
    final file = await _sessionFile(id);
    if (await file.exists()) {
      await file.delete();
    }
    final index = await list();
    index.removeWhere((e) => e.id == id);
    await _writeIndex(index);
  }

  /// Build a session from UI bubbles. [existingId]/[createdAt] keep continuity when updating.
  static ChatHistorySession buildSession({
    required List<({String role, String text, bool isError})> messages,
    String? existingId,
    DateTime? createdAt,
    String? modelName,
  }) {
    final now = DateTime.now().toUtc();
    final id = existingId ?? newId();
    final created = createdAt ?? now;
    String firstUser = '';
    for (final m in messages) {
      if (m.role == 'user' && m.text.trim().isNotEmpty) {
        firstUser = m.text.trim();
        break;
      }
    }
    return ChatHistorySession(
      id: id,
      createdAt: created,
      updatedAt: now,
      firstUserMessage: firstUser,
      modelName: modelName,
      messages: messages
          .map((m) => ChatHistoryMessage(
                role: m.role,
                text: m.text,
                timestamp: now,
                isError: m.isError,
              ))
          .toList(),
    );
  }
}
