import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:voice_app/ffi/simulst_ffi_bridge.dart';
import 'package:voice_app/models/model_manager.dart';
import 'package:voice_app/services/asr_service.dart';
import 'package:voice_app/utils/utils.dart';

/// Streaming simultaneous interpretation via the simulst native pipeline.
class SimulstService {
  Pointer<Void>? handle;
  bool isInitialized = false;

  bool enableTranscribe = true;
  bool enableTranslate = true;
  String transcribeLang = 'auto';
  String translateLang = 'English';

  static const RecordConfig recordConfig = AsrService.recordConfig;

  Future<void> initialize({
    required ModelInfo model,
    bool? enableTranscribe,
    bool? enableTranslate,
    String? transcribeLang,
    String? translateLang,
  }) async {
    await SimulstBridge.init();
    if (isInitialized) return;

    if (enableTranscribe != null) this.enableTranscribe = enableTranscribe;
    if (enableTranslate != null) this.enableTranslate = enableTranslate;
    if (transcribeLang != null) this.transcribeLang = transcribeLang;
    if (translateLang != null) this.translateLang = translateLang;

    final sileroModelPath = await ModelManager.ensureSileroVad();
    final useGpu = Platform.isMacOS || Platform.isIOS;

    final config = {
      'export_dir': model.path,
      'enable_transcribe': this.enableTranscribe,
      'enable_translate': this.enableTranslate,
      'transcribe_lang': this.transcribeLang,
      'translate_lang': this.translateLang,
      'clear_kv_on_sentence_punct': true,
      'keep_kv_across_segments': true,
      'num_chunks': 1,
      'max_llm_kv_segments_base': 64,
      'encoder_provider': useGpu ? 'coreml' : 'auto',
      'encoder_num_threads': 1,
      'n_ctx': 8192,
      'n_batch': 512,
      'n_threads': 4,
      'n_gpu_layers': useGpu ? -1 : 0,
      'max_new_tokens': 32,
      'repetition_penalty': 1.0,
      'first_token_eos_threshold': 1.0,
      'punct_kv_mode': 1,
      'eos_penalty_only_last_chunk': false,
      ...AsrService.buildAudioPipelineConfig(sileroModelPath),
    };

    handle = SimulstBridge.instance.create(jsonEncode(config));
    isInitialized = true;
  }

  /// Update task toggles and languages without reloading models.
  ///
  /// When the native library lacks [simulst_set_tasks], returns false and the
  /// caller should deinitialize and initialize again with the new settings.
  bool updateTasks({
    bool? enableTranscribe,
    bool? enableTranslate,
    String? transcribeLang,
    String? translateLang,
  }) {
    if (handle == null) return false;
    if (!SimulstBridge.instance.supportsSetTasks) return false;

    if (enableTranscribe != null) this.enableTranscribe = enableTranscribe;
    if (enableTranslate != null) this.enableTranslate = enableTranslate;
    if (transcribeLang != null) this.transcribeLang = transcribeLang;
    if (translateLang != null) this.translateLang = translateLang;

    final tasks = {
      'enable_transcribe': this.enableTranscribe,
      'enable_translate': this.enableTranslate,
      'transcribe_lang': this.transcribeLang,
      'translate_lang': this.translateLang,
      'clear_kv_on_sentence_punct': true,
    };

    final ok = SimulstBridge.instance.setTasks(handle!, jsonEncode(tasks));
    if (!ok) {
      throw Exception(
          'simulst_set_tasks failed: ${SimulstBridge.instance.lastError() ?? "unknown"}');
    }
    return true;
  }

  /// Destroys the native engine handle and resets state.
  void deinitialize() {
    if (handle != null) {
      SimulstBridge.instance.destroy(handle!);
      handle = null;
    }
    isInitialized = false;
  }

  /// Resets the engine's internal buffers without tearing it down.
  Future<void> reset() async {
    await SimulstBridge.init();
    if (handle != null) {
      SimulstBridge.instance.reset(handle!);
    }
  }

  Future<StreamSubscription<Uint8List>> startStream(
    AudioRecorder recorder,
    void Function(SimulstPollResult) onPoll,
  ) async {
    await SimulstBridge.init();
    final audioStream = await recorder.startStream(recordConfig);
    return audioStream.listen((data) {
      if (handle == null) return;
      final samples = convertBytesToFloat32(Uint8List.fromList(data));
      SimulstBridge.instance.acceptWaveform(handle!, samples);
      onPoll(SimulstBridge.instance.poll(handle!));
    });
  }

  /// Flushes the VAD tail and returns the final poll result.
  ///
  /// Call this after stopping the recorder to drain any buffered audio.
  SimulstPollResult flushAndPoll() {
    SimulstBridge.instance.flush(handle!);
    return SimulstBridge.instance.poll(handle!);
  }
}
