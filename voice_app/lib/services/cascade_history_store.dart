import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:voice_app/services/audio_file_history_store.dart';

/// Persistent store manager for Cascade Translation history.
class CascadeHistoryStore {
  static final _rand = Random();

  static Future<Directory> _historyDir() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appSupport.path, 'history', 'cascade'));
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
    return 'cascade-$stamp-$suffix';
  }

  /// Lists all cascade translation history summaries, sorted by updatedAt descending.
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

  /// Saves a session and updates index.
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

  /// Deletes a session, its saved audio file, and updates index.
  static Future<void> delete(String id) async {
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

  /// Saves VAD detected Float32 audio samples into a 16kHz WAV file.
  /// Returns the absolute path of the saved file.
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
      throw Exception("Failed to write VAD audio WAV file: $targetPath");
    }
    return targetPath;
  }

  /// Calculates total size of all files in cascade history store.
  static Future<int> getStorageSize() async {
    final dir = await _historyDir();
    if (!await dir.exists()) return 0;
    int size = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        size += await entity.length();
      }
    }
    return size;
  }

  /// Clears all history sessions and audio files in cascade history store.
  static Future<void> clearAll() async {
    final dir = await _historyDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
