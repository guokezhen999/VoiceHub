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
        'title': '语音识别 (ASR)',
        'icon': Icons.mic_rounded,
      },
      {
        'type': 'tts',
        'title': '语音合成 (TTS)',
        'icon': Icons.record_voice_over_rounded,
      },
      {
        'type': 'nmt',
        'title': '文本翻译 (NMT)',
        'icon': Icons.translate_rounded,
      },
      {
        'type': 'llm',
        'title': '大语言模型 (LLM)',
        'icon': Icons.psychology_rounded,
      },
      {
        'type': 'simulst',
        'title': '同传大模型 (SimulST)',
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
        title: '音频文件转写',
        subtitle: '音视频长文件转写与翻译历史',
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
        title: '串行同传',
        subtitle: '语音识别+文本翻译串行同传历史',
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
        title: '端到端同传',
        subtitle: '端到端语音大模型同传历史',
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
        title: '双人对话',
        subtitle: '双向实时对话翻译历史',
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
        title: 'AI 问答助手',
        subtitle: '大语言模型智能对话历史',
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
}
