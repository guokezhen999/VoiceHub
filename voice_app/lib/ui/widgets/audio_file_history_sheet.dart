import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:voice_app/services/audio_file_history_store.dart';
import 'package:voice_app/models/subtitle_segment.dart';
import 'package:voice_app/services/subtitle_export_service.dart';
import 'package:voice_app/ffi/voice_engine_ffi_bridge.dart';

/// Bottom sheet listing saved audio file transcription sessions.
class AudioFileHistorySheet extends StatefulWidget {
  const AudioFileHistorySheet({Key? key}) : super(key: key);

  @override
  State<AudioFileHistorySheet> createState() => _AudioFileHistorySheetState();
}

class _AudioFileHistorySheetState extends State<AudioFileHistorySheet> {
  List<AudioFileHistorySummary> _items = [];
  bool _loading = true;
  String? _busyId;
  
  late final AudioPlayer _listAudioPlayer;
  String? _playingAudioPath;
  PlayerState _listPlayerState = PlayerState.stopped;

  @override
  void initState() {
    super.initState();
    _listAudioPlayer = AudioPlayer();
    _listAudioPlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _listPlayerState = state);
    });
    _listAudioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playingAudioPath = null;
        _listPlayerState = PlayerState.stopped;
      });
    });
    _reload();
  }

  @override
  void dispose() {
    _listAudioPlayer.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final items = await AudioFileHistoryStore.list();
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
    if (t.isEmpty) return '(No Subtitles)';
    if (t.length <= 80) return t;
    return '${t.substring(0, 80)}…';
  }

  Future<void> _togglePlayListAudio(String audioPath) async {
    if (!File(audioPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Audio file not found on disk.'), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    if (_playingAudioPath == audioPath && _listPlayerState == PlayerState.playing) {
      await _listAudioPlayer.pause();
    } else if (_playingAudioPath == audioPath && _listPlayerState == PlayerState.paused) {
      await _listAudioPlayer.resume();
    } else {
      await _listAudioPlayer.stop();
      setState(() {
        _playingAudioPath = audioPath;
      });
      await _listAudioPlayer.play(DeviceFileSource(audioPath));
    }
  }

  Future<void> _previewItem(AudioFileHistorySummary summary) async {
    setState(() => _busyId = summary.id);
    try {
      final session = await AudioFileHistoryStore.load(summary.id);
      if (!mounted) return;
      if (session == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session file missing.'), behavior: SnackBarBehavior.floating),
        );
        await _reload();
        return;
      }
      
      // Stop list player before opening preview
      await _listAudioPlayer.stop();
      setState(() {
        _playingAudioPath = null;
        _listPlayerState = PlayerState.stopped;
      });

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _AudioFileHistoryPreviewSheet(
          session: session,
          formatTime: _formatTime,
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteItem(AudioFileHistorySummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete history?'),
        content: Text(_preview(summary.fileName)),
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
      await AudioFileHistoryStore.delete(summary.id);
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    'Audio Transcription History',
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
                'Browse previous file transcriptions and listen to their audios',
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
                          'No saved history yet.',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade100),
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          final busy = _busyId == item.id;
                          final isPlayingThis = _playingAudioPath == item.audioPath && _listPlayerState == PlayerState.playing;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            leading: GestureDetector(
                              onTap: () => _togglePlayListAudio(item.audioPath),
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isPlayingThis ? Colors.green.shade50 : const Color(0xFF1E3C72).withOpacity(0.08),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isPlayingThis ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                  color: isPlayingThis ? Colors.green.shade700 : const Color(0xFF1E3C72),
                                ),
                              ),
                            ),
                            title: Text(
                              item.fileName,
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
                                ' · ${item.sourceLang}→${item.targetLang}'
                                ' · ${item.duration.toStringAsFixed(1)}s'
                                ' · ${item.segmentCount} segments',
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
                                        tooltip: 'Open chat bubbles',
                                        onPressed: () => _previewItem(item),
                                        icon: const Icon(Icons.forum_outlined, color: Color(0xFF1E3C72), size: 20),
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

/// Detail view of an audio file transcription session. Renders sentences as chat bubbles and syncs with playback.
class _AudioFileHistoryPreviewSheet extends StatefulWidget {
  final AudioFileHistorySession session;
  final String Function(DateTime) formatTime;

  const _AudioFileHistoryPreviewSheet({
    Key? key,
    required this.session,
    required this.formatTime,
  }) : super(key: key);

  @override
  State<_AudioFileHistoryPreviewSheet> createState() => _AudioFileHistoryPreviewSheetState();
}

class _AudioFileHistoryPreviewSheetState extends State<_AudioFileHistoryPreviewSheet> {
  late final AudioPlayer _audioPlayer;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _playerState = PlayerState.stopped;
  int _currentPlayingIndex = -1;
  final ScrollController _scrollController = ScrollController();
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    
    _audioPlayer.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });

    _audioPlayer.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() {
        _position = p;
        _updatePlayingSubtitleIndex();
      });
    });

    _audioPlayer.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _playerState = s);
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _position = Duration.zero;
        _playerState = PlayerState.stopped;
        _currentPlayingIndex = -1;
      });
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updatePlayingSubtitleIndex() {
    final sec = _position.inMilliseconds / 1000.0;
    int foundIdx = -1;
    for (int i = 0; i < widget.session.subtitles.length; i++) {
      if (sec >= widget.session.subtitles[i].start && sec <= widget.session.subtitles[i].end) {
        foundIdx = i;
        break;
      }
    }
    if (foundIdx != _currentPlayingIndex) {
      setState(() {
        _currentPlayingIndex = foundIdx;
      });
      // Optionally scroll the active bubble into view
      // if (foundIdx != -1) {
      //   _scrollToIndex(foundIdx);
      // }
    }
  }

  void _scrollToIndex(int index) {
    if (!_scrollController.hasClients) return;
    
    // Approximate bubble height is ~110px. Scroll to the active bubble.
    final targetOffset = (index * 110.0).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _playPause() async {
    if (!File(widget.session.audioPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Audio file not found on disk.'), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    if (_playerState == PlayerState.playing) {
      await _audioPlayer.pause();
    } else if (_playerState == PlayerState.paused) {
      await _audioPlayer.resume();
    } else {
      await _audioPlayer.play(DeviceFileSource(widget.session.audioPath));
    }
  }

  Future<void> _seekToSegment(SubtitleSegment seg, int index) async {
    if (!File(widget.session.audioPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Audio file not found on disk.'), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    final ms = (seg.start * 1000).round();
    await _audioPlayer.seek(Duration(milliseconds: ms));
    if (_playerState != PlayerState.playing) {
      await _audioPlayer.play(DeviceFileSource(widget.session.audioPath));
    }
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final minutes = two(d.inMinutes.remainder(60));
    final seconds = two(d.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Future<void> _exportSrtFile() async {
    if (widget.session.subtitles.isEmpty) return;
    try {
      final baseAudioName = p.basenameWithoutExtension(widget.session.fileName);
      final srcLang = widget.session.sourceLang.replaceAll(' ', '');
      final tgtLang = widget.session.targetLang.replaceAll(' ', '');
      final now = DateTime.now();
      final timeStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      
      final srtDefaultName = '${baseAudioName}_${srcLang}_${tgtLang}_$timeStr.srt';
      
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Export SRT File',
        fileName: srtDefaultName,
        type: FileType.custom,
        allowedExtensions: ['srt'],
      );
      if (savePath != null) {
        await SubtitleExportService.exportToSrtFile(widget.session.subtitles, savePath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('SRT exported successfully to: ${p.basename(savePath)}'), backgroundColor: Colors.green),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export SRT: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _exportZipArchive() async {
    if (widget.session.subtitles.isEmpty) return;
    try {
      if (!File(widget.session.audioPath).existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved audio file not found on disk.'), backgroundColor: Colors.red),
        );
        return;
      }
      
      // Ensure VoiceEngine FFI bridge is initialized before decoding
      await VoiceEngineBridge.init();
      
      final samples = VoiceEngineBridge.instance.decodeAudioFile(widget.session.audioPath);
      if (samples == null || samples.isEmpty) {
        throw Exception('Decoded samples are empty or null.');
      }
      
      final baseAudioName = p.basenameWithoutExtension(widget.session.fileName);
      final srcLang = widget.session.sourceLang.replaceAll(' ', '');
      final tgtLang = widget.session.targetLang.replaceAll(' ', '');
      final now = DateTime.now();
      final timeStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      
      final zipDefaultName = '${baseAudioName}_${srcLang}_${tgtLang}_$timeStr.zip';
      
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Export ZIP Archive',
        fileName: zipDefaultName,
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      
      if (savePath != null) {
        setState(() {
          _isExporting = true;
        });
        
        await SubtitleExportService.exportToZip(
          audioFileName: widget.session.fileName,
          sourceLang: widget.session.sourceLang,
          targetLang: widget.session.targetLang,
          subtitles: widget.session.subtitles,
          audioSamples: samples,
          targetZipPath: savePath,
        );
        
        setState(() {
          _isExporting = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('ZIP exported successfully to: ${p.basename(savePath)}'), backgroundColor: Colors.green),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isExporting = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export ZIP: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playing = _playerState == PlayerState.playing;
    return Stack(
      children: [
        Container(
          height: MediaQuery.of(context).size.height * 0.85,
          decoration: const BoxDecoration(
            color: Color(0xFFF8FAFC),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Drag bar
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.session.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2D3748)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.formatTime(widget.session.updatedAt)}'
                            ' · ${widget.session.sourceLang}→${widget.session.targetLang}'
                            ' · ${widget.session.duration.toStringAsFixed(1)}s',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.share_rounded, color: Color(0xFF4A5568)),
                      tooltip: 'Share / Export',
                      onSelected: (value) {
                        if (value == 'export_srt') {
                          _exportSrtFile();
                        } else if (value == 'export_zip') {
                          _exportZipArchive();
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'export_srt',
                          child: Row(
                            children: [
                              Icon(Icons.download_rounded, size: 18),
                              SizedBox(width: 8),
                              Text('Export SRT File'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'export_zip',
                          child: Row(
                            children: [
                              Icon(Icons.archive_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('Export ZIP Archive (MD + Audio)'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
          const Divider(height: 1),

          // Audio Player Panel
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  iconSize: 36,
                  color: const Color(0xFF1E3C72),
                  icon: Icon(playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded),
                  onPressed: _playPause,
                ),
                Expanded(
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: const Color(0xFF1E3C72),
                          inactiveTrackColor: Colors.grey.shade200,
                          thumbColor: const Color(0xFF1E3C72),
                        ),
                        child: Slider(
                          value: _position.inMilliseconds.toDouble().clamp(0.0, _duration.inMilliseconds.toDouble()),
                          max: _duration.inMilliseconds > 0 ? _duration.inMilliseconds.toDouble() : 1.0,
                          onChanged: (val) async {
                            await _audioPlayer.seek(Duration(milliseconds: val.toInt()));
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_position),
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                            ),
                            Text(
                              _formatDuration(_duration),
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Chat-like Transcription Bubbles
          // We render the original text (speaker) on one side, and the translation (AI helper) on the other.
          // This represents an LLM chat log format!
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: widget.session.subtitles.length,
                itemBuilder: (context, index) {
                  final seg = widget.session.subtitles[index];
                  final isCurrent = _currentPlayingIndex == index;
                  final hasTranslation = seg.translatedText.isNotEmpty;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      children: [
                        // Timestamp helper
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'Segment #${seg.index} [${seg.formatTime(seg.start)} - ${seg.formatTime(seg.end)}]',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: isCurrent ? const Color(0xFF1E3C72) : Colors.grey.shade600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // Original transcript (Right aligned: User speech bubble)
                        GestureDetector(
                          onTap: () => _seekToSegment(seg, index),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.75,
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: isCurrent ? const Color(0xFF1E3C72) : Colors.indigo.shade50,
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(16),
                                  bottomLeft: Radius.circular(16),
                                  bottomRight: Radius.circular(4),
                                ),
                                border: isCurrent ? null : Border.all(color: Colors.indigo.shade100),
                              ),
                              child: Text(
                                seg.originalText,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                                  color: isCurrent ? Colors.white : const Color(0xFF1A365D),
                                ),
                              ),
                            ),
                          ),
                        ),
                        
                        if (hasTranslation) ...[
                          const SizedBox(height: 6),
                          // Translation result (Left aligned: Assistant translation bubble)
                          GestureDetector(
                            onTap: () => _seekToSegment(seg, index),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isCurrent ? Colors.teal.shade700 : Colors.white,
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(16),
                                    topRight: Radius.circular(16),
                                    bottomLeft: Radius.circular(4),
                                    bottomRight: Radius.circular(16),
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black12,
                                      blurRadius: 2,
                                      offset: Offset(0, 1),
                                    ),
                                  ],
                                  border: Border.all(color: isCurrent ? Colors.teal.shade800 : Colors.grey.shade200),
                                ),
                                child: Text(
                                  seg.translatedText,
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.4,
                                    fontStyle: FontStyle.italic,
                                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                                    color: isCurrent ? Colors.white : Colors.teal.shade900,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          ],
        ),
      ),
      if (_isExporting)
        Positioned.fill(
          child: Container(
            color: Colors.black26,
            child: const Center(
              child: CircularProgressIndicator(),
            ),
          ),
        ),
    ],
  );
}
}
