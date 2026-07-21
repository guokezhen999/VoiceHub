import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:voice_app/models/subtitle_segment.dart';
import 'package:voice_app/services/audio_file_history_store.dart';

/// One spoken turn from speaker A or B.
class DualDialogueTurn {
  final String side; // 'A' | 'B'
  final String asr;
  final String mt;
  final DateTime at;
  final double start; // seconds in session audio
  final double end;

  const DualDialogueTurn({
    required this.side,
    required this.asr,
    required this.mt,
    required this.at,
    this.start = 0.0,
    this.end = 0.0,
  });

  DualDialogueTurn copyWith({String? asr, String? mt, double? start, double? end}) {
    return DualDialogueTurn(
      side: side,
      asr: asr ?? this.asr,
      mt: mt ?? this.mt,
      at: at,
      start: start ?? this.start,
      end: end ?? this.end,
    );
  }

  factory DualDialogueTurn.fromJson(Map<String, dynamic> json) {
    return DualDialogueTurn(
      side: (json['side'] as String?) ?? 'A',
      asr: (json['asr'] as String?) ?? '',
      mt: (json['mt'] as String?) ?? '',
      at: json['at'] != null
          ? (DateTime.tryParse(json['at'] as String) ?? DateTime.now())
          : DateTime.now(),
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'side': side,
        'asr': asr,
        'mt': mt,
        'at': at.toIso8601String(),
        'start': start,
        'end': end,
      };
}

/// Lightweight index entry for the history list (AudioFileHistorySheet compatible).
class DualDialogueHistorySummary {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String title;
  final String langA;
  final String langB;
  final String mtMode;
  final int turnCount;
  final String preview;
  final String audioPath;
  final double duration;

  const DualDialogueHistorySummary({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.title,
    required this.langA,
    required this.langB,
    required this.mtMode,
    required this.turnCount,
    required this.preview,
    this.audioPath = '',
    this.duration = 0.0,
  });

  AudioFileHistorySummary toAudioSummary() => AudioFileHistorySummary(
        id: id,
        createdAt: createdAt,
        updatedAt: updatedAt,
        fileName: title,
        sourceLang: langA,
        targetLang: langB,
        duration: duration,
        segmentCount: turnCount,
        audioPath: audioPath,
      );

  factory DualDialogueHistorySummary.fromJson(Map<String, dynamic> json) {
    return DualDialogueHistorySummary(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      title: (json['title'] as String?) ?? (json['fileName'] as String?) ?? '',
      langA: (json['langA'] as String?) ?? (json['sourceLang'] as String?) ?? '',
      langB: (json['langB'] as String?) ?? (json['targetLang'] as String?) ?? '',
      mtMode: (json['mtMode'] as String?) ?? 'llm',
      turnCount: (json['turnCount'] as num?)?.toInt() ??
          (json['segmentCount'] as num?)?.toInt() ??
          0,
      preview: (json['preview'] as String?) ?? '',
      audioPath: (json['audioPath'] as String?) ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'title': title,
        'langA': langA,
        'langB': langB,
        'mtMode': mtMode,
        'turnCount': turnCount,
        'preview': preview,
        'audioPath': audioPath,
        'duration': duration,
      };
}

/// Full dual-dialogue session under `history/dual_dialogue/sessions/<id>.json`.
class DualDialogueSession {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String title;
  final String langA;
  final String langB;
  final String mtMode;
  final List<DualDialogueTurn> turns;
  final String audioPath;
  final double duration;

  const DualDialogueSession({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.title,
    required this.langA,
    required this.langB,
    required this.mtMode,
    required this.turns,
    this.audioPath = '',
    this.duration = 0.0,
  });

  int get turnCount => turns.length;

  DualDialogueHistorySummary toSummary() {
    String preview = '';
    for (final t in turns) {
      final text = t.asr.trim();
      if (text.isNotEmpty) {
        preview = text;
        break;
      }
    }
    return DualDialogueHistorySummary(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
      title: title,
      langA: langA,
      langB: langB,
      mtMode: mtMode,
      turnCount: turnCount,
      preview: preview,
      audioPath: audioPath,
      duration: duration,
    );
  }

  /// Convert for [AudioFileHistorySheet] playback / export.
  AudioFileHistorySession toAudioFileSession() {
    final subs = <SubtitleSegment>[];
    for (int i = 0; i < turns.length; i++) {
      final t = turns[i];
      final end = t.end > t.start ? t.end : t.start + 1.0;
      subs.add(SubtitleSegment(
        index: i + 1,
        start: t.start,
        end: end,
        originalText: t.asr,
        translatedText: t.mt,
        side: t.side,
      ));
    }
    return AudioFileHistorySession(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
      fileName: title,
      sourceLang: langA,
      targetLang: langB,
      duration: duration > 0
          ? duration
          : (subs.isNotEmpty ? subs.last.end : 0.0),
      audioPath: audioPath,
      subtitles: subs,
    );
  }

  DualDialogueSession copyWith({
    String? title,
    DateTime? updatedAt,
    List<DualDialogueTurn>? turns,
    String? audioPath,
    double? duration,
  }) {
    return DualDialogueSession(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      title: title ?? this.title,
      langA: langA,
      langB: langB,
      mtMode: mtMode,
      turns: turns ?? this.turns,
      audioPath: audioPath ?? this.audioPath,
      duration: duration ?? this.duration,
    );
  }

  factory DualDialogueSession.fromJson(Map<String, dynamic> json) {
    final turns = (json['turns'] as List<dynamic>? ?? [])
        .map((e) => DualDialogueTurn.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return DualDialogueSession(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      title: (json['title'] as String?) ?? (json['fileName'] as String?) ?? '',
      langA: (json['langA'] as String?) ?? (json['sourceLang'] as String?) ?? '',
      langB: (json['langB'] as String?) ?? (json['targetLang'] as String?) ?? '',
      mtMode: (json['mtMode'] as String?) ?? 'llm',
      turns: turns,
      audioPath: (json['audioPath'] as String?) ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'title': title,
        'langA': langA,
        'langB': langB,
        'mtMode': mtMode,
        'turns': turns.map((t) => t.toJson()).toList(),
        'audioPath': audioPath,
        'duration': duration,
      };
}

/// Persists dual-dialogue sessions under:
///   `<Application Support>/history/dual_dialogue/index.json`
///   `<Application Support>/history/dual_dialogue/sessions/<id>.json`
///   `<Application Support>/history/dual_dialogue/audio/<id>.wav`
class DualDialogueHistoryStore {
  static final _rand = Random();

  static Future<Directory> _baseDir() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appSupport.path, 'history', 'dual_dialogue'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _sessionsDir() async {
    final base = await _baseDir();
    final dir = Directory(p.join(base.path, 'sessions'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _audioDir() async {
    final base = await _baseDir();
    final dir = Directory(p.join(base.path, 'audio'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _indexFile() async {
    final base = await _baseDir();
    return File(p.join(base.path, 'index.json'));
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
    return 'dual-$stamp-$suffix';
  }

  static String defaultTitle(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    final local = dt.toLocal();
    return '双人对话_${local.year}${two(local.month)}${two(local.day)}_'
        '${two(local.hour)}${two(local.minute)}${two(local.second)}';
  }

  static Future<List<DualDialogueHistorySummary>> list() async {
    final file = await _indexFile();
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      final items = raw
          .map((e) => DualDialogueHistorySummary.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  static Future<List<AudioFileHistorySummary>> listAsAudioSummaries() async {
    final items = await list();
    return items.map((e) => e.toAudioSummary()).toList();
  }

  static Future<void> _writeIndex(List<DualDialogueHistorySummary> items) async {
    final file = await _indexFile();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(items.map((e) => e.toJson()).toList()),
    );
  }

  static Future<DualDialogueSession?> load(String id) async {
    final file = await _sessionFile(id);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return DualDialogueSession.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static Future<AudioFileHistorySession?> loadAsAudioSession(String id) async {
    final session = await load(id);
    return session?.toAudioFileSession();
  }

  static Future<void> save(DualDialogueSession session) async {
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

  static Future<void> rename(String id, String newName) async {
    final session = await load(id);
    if (session == null) return;
    await save(session.copyWith(
      title: newName.trim(),
      updatedAt: DateTime.now(),
    ));
  }

  static Future<void> delete(String id) async {
    final session = await load(id);
    if (session != null && session.audioPath.isNotEmpty) {
      final audioFile = File(session.audioPath);
      if (await audioFile.exists()) {
        await audioFile.delete();
      }
    }

    final file = await _sessionFile(id);
    if (await file.exists()) {
      await file.delete();
    }

    final index = await list();
    index.removeWhere((e) => e.id == id);
    await _writeIndex(index);
  }

  /// Saves Float32 PCM samples into a 16kHz WAV file. Returns absolute path.
  static Future<String> saveVadAudioWav({
    required String id,
    required Float32List samples,
    int sampleRate = 16000,
  }) async {
    final audioDir = await _audioDir();
    final targetPath = p.join(audioDir.path, '$id.wav');

    sherpa_onnx.initBindings();
    final ok = sherpa_onnx.writeWave(
      filename: targetPath,
      samples: samples,
      sampleRate: sampleRate,
    );
    if (!ok) {
      throw Exception('Failed to write dual dialogue audio WAV: $targetPath');
    }
    return targetPath;
  }

  /// Build a session from UI turns. [existingId]/[createdAt] keep continuity.
  static DualDialogueSession buildSession({
    required List<DualDialogueTurn> turns,
    required String langA,
    required String langB,
    required String mtMode,
    String? existingId,
    DateTime? createdAt,
    String? title,
    String audioPath = '',
    double duration = 0.0,
  }) {
    final now = DateTime.now();
    final created = createdAt ?? now;
    final id = existingId ?? newId();
    return DualDialogueSession(
      id: id,
      createdAt: created,
      updatedAt: now,
      title: title ?? defaultTitle(created),
      langA: langA,
      langB: langB,
      mtMode: mtMode,
      turns: turns,
      audioPath: audioPath,
      duration: duration,
    );
  }

  /// Calculates total size of all files in dual_dialogue history store.
  static Future<int> getStorageSize() async {
    final dir = await _baseDir();
    if (!await dir.exists()) return 0;
    int size = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        size += await entity.length();
      }
    }
    return size;
  }

  /// Clears all history sessions and audio files in dual_dialogue history store.
  static Future<void> clearAll() async {
    final dir = await _baseDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
