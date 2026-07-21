import 'dart:math';
import 'package:flutter/material.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/services/audio_file_history_store.dart';
import 'package:voice_app/services/cascade_history_store.dart';
import 'package:voice_app/services/chat_history_store.dart';
import 'package:voice_app/services/dual_dialogue_history_store.dart';
import 'package:voice_app/services/simulst_history_store.dart';

class ModeCacheInfo {
  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final int count;
  final int sizeInBytes;

  ModeCacheInfo({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.count,
    required this.sizeInBytes,
  });

  bool get hasCache => count > 0 || sizeInBytes > 0;
}

class ModeSessionItem {
  final String id;
  final String title;
  final String subtitle;
  final DateTime updatedAt;
  final String? audioPath;

  ModeSessionItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.updatedAt,
    this.audioPath,
  });
}

class ModelTypeCacheInfo {
  final String type;
  final String title;
  final IconData icon;
  final int count;
  final int sizeInBytes;

  ModelTypeCacheInfo({
    required this.type,
    required this.title,
    required this.icon,
    required this.count,
    required this.sizeInBytes,
  });
}

class ModelCacheSummary {
  final int totalCount;
  final int totalSizeInBytes;
  final List<ModelTypeCacheInfo> details;

  ModelCacheSummary({
    required this.totalCount,
    required this.totalSizeInBytes,
    required this.details,
  });
}

class CacheStatisticsService {
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = (log(bytes) / log(1024)).floor();
    if (i >= suffixes.length) i = suffixes.length - 1;
    double num = bytes / pow(1024, i);
    return '${num.toStringAsFixed(num < 10 && i > 0 ? 2 : 1)} ${suffixes[i]}';
  }

  static Future<ModelCacheSummary> getModelCacheSummary() async {
    final types = [
      {
        'type': 'asr',
        'title': 'ASR',
        'icon': Icons.mic_rounded,
      },
      {
        'type': 'tts',
        'title': 'TTS',
        'icon': Icons.record_voice_over_rounded,
      },
      {
        'type': 'nmt',
        'title': 'NMT',
        'icon': Icons.translate_rounded,
      },
      {
        'type': 'llm',
        'title': 'LLM',
        'icon': Icons.psychology_rounded,
      },
      {
        'type': 'simulst',
        'title': 'SimulST',
        'icon': Icons.graphic_eq_rounded,
      },
    ];

    int grandTotalCount = 0;
    int grandTotalSize = 0;
    List<ModelTypeCacheInfo> details = [];

    for (final t in types) {
      final typeStr = t['type'] as String;
      final models = await ModelManager.getModels(typeStr);
      int typeSize = 0;
      for (final m in models) {
        typeSize += await m.getDirectorySize();
      }
      if (models.isNotEmpty || typeSize > 0) {
        details.add(ModelTypeCacheInfo(
          type: typeStr,
          title: t['title'] as String,
          icon: t['icon'] as IconData,
          count: models.length,
          sizeInBytes: typeSize,
        ));
        grandTotalCount += models.length;
        grandTotalSize += typeSize;
      }
    }

    return ModelCacheSummary(
      totalCount: grandTotalCount,
      totalSizeInBytes: grandTotalSize,
      details: details,
    );
  }

  static Future<List<ModeCacheInfo>> getModeCacheInfos() async {
    final List<ModeCacheInfo> list = [];

    // 1. Audio File Transcription
    final audioFileItems = await AudioFileHistoryStore.list();
    final audioFileSize = await AudioFileHistoryStore.getStorageSize();
    if (audioFileItems.isNotEmpty || audioFileSize > 0) {
      list.add(ModeCacheInfo(
        key: 'audio_file',
        title: 'Audio File Transcription',
        subtitle: 'Long audio/video transcription & translation history',
        icon: Icons.audio_file_rounded,
        color: const Color(0xFF4A90E2),
        count: audioFileItems.length,
        sizeInBytes: audioFileSize,
      ));
    }

    // 2. Cascade Translation
    final cascadeItems = await CascadeHistoryStore.list();
    final cascadeSize = await CascadeHistoryStore.getStorageSize();
    if (cascadeItems.isNotEmpty || cascadeSize > 0) {
      list.add(ModeCacheInfo(
        key: 'cascade',
        title: 'Cascade Interpretation',
        subtitle: 'ASR + MT cascade translation history',
        icon: Icons.subtitles_rounded,
        color: const Color(0xFF9B51E0),
        count: cascadeItems.length,
        sizeInBytes: cascadeSize,
      ));
    }

    // 3. Simultaneous Translation
    final simulstItems = await SimulstHistoryStore.list();
    final simulstSize = await SimulstHistoryStore.getStorageSize();
    if (simulstItems.isNotEmpty || simulstSize > 0) {
      list.add(ModeCacheInfo(
        key: 'simulst',
        title: 'End-to-End Interpretation',
        subtitle: 'Speech LLM simultaneous translation history',
        icon: Icons.graphic_eq_rounded,
        color: const Color(0xFF27AE60),
        count: simulstItems.length,
        sizeInBytes: simulstSize,
      ));
    }

    // 4. Dual Dialogue
    final dualItems = await DualDialogueHistoryStore.list();
    final dualSize = await DualDialogueHistoryStore.getStorageSize();
    if (dualItems.isNotEmpty || dualSize > 0) {
      list.add(ModeCacheInfo(
        key: 'dual_dialogue',
        title: 'Dual Dialogue',
        subtitle: 'Two-way real-time dialogue history',
        icon: Icons.forum_rounded,
        color: const Color(0xFFF2994A),
        count: dualItems.length,
        sizeInBytes: dualSize,
      ));
    }

    // 5. AI Chat
    final chatItems = await ChatHistoryStore.list();
    final chatSize = await ChatHistoryStore.getStorageSize();
    if (chatItems.isNotEmpty || chatSize > 0) {
      list.add(ModeCacheInfo(
        key: 'chat',
        title: 'AI Chat Assistant',
        subtitle: 'LLM intelligent conversation history',
        icon: Icons.smart_toy_rounded,
        color: const Color(0xFFEB5757),
        count: chatItems.length,
        sizeInBytes: chatSize,
      ));
    }

    return list;
  }

  static Future<void> clearModeHistory(String modeKey) async {
    switch (modeKey) {
      case 'audio_file':
        await AudioFileHistoryStore.clearAll();
        break;
      case 'cascade':
        await CascadeHistoryStore.clearAll();
        break;
      case 'simulst':
        await SimulstHistoryStore.clearAll();
        break;
      case 'dual_dialogue':
        await DualDialogueHistoryStore.clearAll();
        break;
      case 'chat':
        await ChatHistoryStore.clearAll();
        break;
    }
  }

  static Future<void> clearAllModeHistories() async {
    await AudioFileHistoryStore.clearAll();
    await CascadeHistoryStore.clearAll();
    await SimulstHistoryStore.clearAll();
    await DualDialogueHistoryStore.clearAll();
    await ChatHistoryStore.clearAll();
  }

  static Future<List<ModeSessionItem>> getModeSessionItems(String modeKey) async {
    final List<ModeSessionItem> items = [];

    if (modeKey == 'audio_file') {
      final list = await AudioFileHistoryStore.list();
      for (final e in list) {
        final name = e.fileName.isNotEmpty ? e.fileName : 'Untitled Audio Transcription';
        final detail = '${e.sourceLang.toUpperCase()} ➔ ${e.targetLang.toUpperCase()} · ${e.duration.toStringAsFixed(1)}s · ${e.segmentCount} segments';
        items.add(ModeSessionItem(
          id: e.id,
          title: name,
          subtitle: detail,
          updatedAt: e.updatedAt,
          audioPath: e.audioPath,
        ));
      }
    } else if (modeKey == 'cascade') {
      final list = await CascadeHistoryStore.list();
      for (final e in list) {
        final name = e.fileName.isNotEmpty ? e.fileName : 'Cascade Session';
        final detail = '${e.sourceLang.toUpperCase()} ➔ ${e.targetLang.toUpperCase()} · ${e.duration.toStringAsFixed(1)}s · ${e.segmentCount} segments';
        items.add(ModeSessionItem(
          id: e.id,
          title: name,
          subtitle: detail,
          updatedAt: e.updatedAt,
          audioPath: e.audioPath,
        ));
      }
    } else if (modeKey == 'simulst') {
      final list = await SimulstHistoryStore.list();
      for (final e in list) {
        final name = e.fileName.isNotEmpty ? e.fileName : 'End-to-End Session';
        final detail = '${e.sourceLang.toUpperCase()} ➔ ${e.targetLang.toUpperCase()} · ${e.duration.toStringAsFixed(1)}s · ${e.segmentCount} segments';
        items.add(ModeSessionItem(
          id: e.id,
          title: name,
          subtitle: detail,
          updatedAt: e.updatedAt,
          audioPath: e.audioPath,
        ));
      }
    } else if (modeKey == 'dual_dialogue') {
      final list = await DualDialogueHistoryStore.list();
      for (final e in list) {
        final name = e.title.isNotEmpty ? e.title : 'Dual Dialogue Session';
        final detail = '${e.langA} ↔ ${e.langB} · ${e.turnCount} turns';
        items.add(ModeSessionItem(
          id: e.id,
          title: name,
          subtitle: detail,
          updatedAt: e.updatedAt,
          audioPath: e.audioPath,
        ));
      }
    } else if (modeKey == 'chat') {
      final list = await ChatHistoryStore.list();
      for (final e in list) {
        final name = e.firstUserMessage.isNotEmpty ? e.firstUserMessage : 'AI Chat Session';
        final detail = '${e.modelName ?? "LLM"} · ${e.messageCount} msgs';
        items.add(ModeSessionItem(
          id: e.id,
          title: name,
          subtitle: detail,
          updatedAt: e.updatedAt,
        ));
      }
    }

    return items;
  }

  static Future<void> deleteSessionItem(String modeKey, String id) async {
    switch (modeKey) {
      case 'audio_file':
        await AudioFileHistoryStore.delete(id);
        break;
      case 'cascade':
        await CascadeHistoryStore.delete(id);
        break;
      case 'simulst':
        await SimulstHistoryStore.delete(id);
        break;
      case 'dual_dialogue':
        await DualDialogueHistoryStore.delete(id);
        break;
      case 'chat':
        await ChatHistoryStore.delete(id);
        break;
    }
  }
}
