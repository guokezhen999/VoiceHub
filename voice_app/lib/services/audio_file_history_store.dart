import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:voice_app/models/subtitle_segment.dart';

/// Summary of an audio file transcription session to be listed in history.
class AudioFileHistorySummary {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String fileName;
  final String sourceLang;
  final String targetLang;
  final double duration;
  final int segmentCount;
  final String audioPath;

  const AudioFileHistorySummary({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.fileName,
    required this.sourceLang,
    required this.targetLang,
    required this.duration,
    required this.segmentCount,
    required this.audioPath,
  });

  factory AudioFileHistorySummary.fromJson(Map<String, dynamic> json) {
    return AudioFileHistorySummary(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      fileName: json['fileName'] as String? ?? '',
      sourceLang: json['sourceLang'] as String? ?? '',
      targetLang: json['targetLang'] as String? ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      segmentCount: json['segmentCount'] as int? ?? 0,
      audioPath: json['audioPath'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'fileName': fileName,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'duration': duration,
        'segmentCount': segmentCount,
        'audioPath': audioPath,
      };
}

/// Full details of an audio file transcription session.
class AudioFileHistorySession {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String fileName;
  final String sourceLang;
  final String targetLang;
  final double duration;
  final String audioPath;
  final List<SubtitleSegment> subtitles;

  const AudioFileHistorySession({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.fileName,
    required this.sourceLang,
    required this.targetLang,
    required this.duration,
    required this.audioPath,
    required this.subtitles,
  });

  int get segmentCount => subtitles.length;

  AudioFileHistorySession copyWith({
    String? fileName,
    DateTime? updatedAt,
  }) {
    return AudioFileHistorySession(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      fileName: fileName ?? this.fileName,
      sourceLang: sourceLang,
      targetLang: targetLang,
      duration: duration,
      audioPath: audioPath,
      subtitles: subtitles,
    );
  }

  AudioFileHistorySummary toSummary() => AudioFileHistorySummary(
        id: id,
        createdAt: createdAt,
        updatedAt: updatedAt,
        fileName: fileName,
        sourceLang: sourceLang,
        targetLang: targetLang,
        duration: duration,
        segmentCount: segmentCount,
        audioPath: audioPath,
      );

  factory AudioFileHistorySession.fromJson(Map<String, dynamic> json) {
    final subs = (json['subtitles'] as List<dynamic>? ?? [])
        .map((e) => SubtitleSegment(
              index: e['index'] as int,
              start: (e['start'] as num).toDouble(),
              end: (e['end'] as num).toDouble(),
              originalText: e['originalText'] as String,
              translatedText: e['translatedText'] as String? ?? '',
            ))
        .toList();
    return AudioFileHistorySession(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      fileName: json['fileName'] as String? ?? '',
      sourceLang: json['sourceLang'] as String? ?? '',
      targetLang: json['targetLang'] as String? ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      audioPath: json['audioPath'] as String? ?? '',
      subtitles: subs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'fileName': fileName,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'duration': duration,
        'audioPath': audioPath,
        'subtitles': subtitles
            .map((s) => {
                  'index': s.index,
                  'start': s.start,
                  'end': s.end,
                  'originalText': s.originalText,
                  'translatedText': s.translatedText,
                })
            .toList(),
      };
}

/// Persistent store manager for audio file transcription history.
class AudioFileHistoryStore {
  static final _rand = Random();

  static Future<Directory> _historyDir() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appSupport.path, 'history', 'audio_file'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _sessionsDir() async {
    final base = await _historyDir();
    final dir = Directory(p.join(base.path, 'sessions'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _audioDir() async {
    final base = await _historyDir();
    final dir = Directory(p.join(base.path, 'audio'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _indexFile() async {
    final base = await _historyDir();
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
    return 'file-$stamp-$suffix';
  }

  /// Lists all transcription history summaries, sorted by [AudioFileHistorySummary.updatedAt] descending.
  static Future<List<AudioFileHistorySummary>> list() async {
    final file = await _indexFile();
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      final items = raw
          .map((e) => AudioFileHistorySummary.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeIndex(List<AudioFileHistorySummary> items) async {
    final file = await _indexFile();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(items.map((e) => e.toJson()).toList()),
    );
  }

  /// Loads full details of a session.
  static Future<AudioFileHistorySession?> load(String id) async {
    final file = await _sessionFile(id);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return AudioFileHistorySession.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Saves a session and updates the index.
  static Future<void> save(AudioFileHistorySession session) async {
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

  /// Renames a session and updates the index.
  static Future<void> rename(String id, String newName) async {
    final session = await load(id);
    if (session == null) return;
    final updated = session.copyWith(
      fileName: newName.trim(),
      updatedAt: DateTime.now(),
    );
    await save(updated);
  }

  /// Deletes a session, its copied media file, and updates the index.
  static Future<void> delete(String id) async {
    // Load session to get audioPath
    final session = await load(id);
    if (session != null) {
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

  /// Copies the source media file to history folder.
  /// Returns the absolute path of the saved file.
  static Future<String> saveAudioFile(String id, String sourcePath) async {
    final audioDir = await _audioDir();
    final ext = p.extension(sourcePath);
    final targetPath = p.join(audioDir.path, '$id$ext');
    
    final file = File(sourcePath);
    if (await file.exists()) {
      await file.copy(targetPath);
    } else {
      throw Exception("Source audio file not found: $sourcePath");
    }
    
    return targetPath;
  }
}
