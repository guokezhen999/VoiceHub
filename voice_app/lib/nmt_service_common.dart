/// Shared types used by both Marian ONNX and Llama GGUF NMT services.
///
/// Both [NativeNmtService] and [LlamaNmtService] return [TranslationResult]
/// and use the same Isolate communication protocol.

import 'dart:isolate';

import 'model_manager.dart';

/// Structured result from NMT translation, including timing metrics.
class TranslationResult {
  final String text;
  final int inputTokens;
  final double encoderMs;   // For LLMs: prompt processing time
  final double decoderMs;   // Token generation time
  final int decoderTokens;

  /// Decoder throughput in tokens per second.
  double get decoderTokensPerSecond {
    if (decoderMs <= 0.0) return 0.0;
    return decoderTokens / (decoderMs / 1000.0);
  }

  const TranslationResult({
    required this.text,
    required this.inputTokens,
    required this.encoderMs,
    required this.decoderMs,
    required this.decoderTokens,
  });
}

// ---- Background-isolate protocol (shared between both services) ------------
// These are internal to the service implementations.

/// Sentinel sent by the worker to signal it has finished loading.
const kNmtReady = 1;

/// Sentinel sent to the worker to request shutdown.
const kNmtShutdown = 2;

/// Initialisation message sent to the worker isolate.
class NmtWorkerInit {
  final SendPort sendPort;
  final String modelPath; // For LLM: .gguf path; for Marian: model dir
  final int numBeams;     // Marian only
  final int maxLength;
  final int numThreads;
  final int nGpuLayers;   // Llama only (-1 = all)
  final String? sourceLang;  // Llama only
  final String? targetLang;  // Llama only
  const NmtWorkerInit({
    required this.sendPort,
    required this.modelPath,
    this.numBeams = 1,
    this.maxLength = 512,
    this.numThreads = 4,
    this.nGpuLayers = -1,
    this.sourceLang,
    this.targetLang,
  });
}

/// Request the worker to translate [text], reply on [replyPort].
class NmtTranslateRequest {
  final String text;
  final SendPort replyPort;
  const NmtTranslateRequest({required this.text, required this.replyPort});
}

/// Request the worker to translate [text] with streaming, reply on [replyPort].
class NmtTranslateStreamRequest {
  final String text;
  final SendPort replyPort;
  const NmtTranslateStreamRequest({required this.text, required this.replyPort});
}

/// Error response from the worker.
class NmtWorkerError {
  final String error;
  const NmtWorkerError(this.error);
}

/// A single message in a multi-turn chat conversation.
class ChatMessage {
  final String role; // 'user' or 'assistant'
  final String content;

  const ChatMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] as String,
      content: json['content'] as String,
    );
  }
}

/// Request the worker to generate a chat response with conversation history.
class NmtChatRequest {
  final List<ChatMessage> messages;
  final SendPort replyPort;
  const NmtChatRequest({required this.messages, required this.replyPort});
}

/// Request the worker to toggle thinking mode dynamically.
class NmtToggleThinkingRequest {
  final bool enableThinking;
  const NmtToggleThinkingRequest({required this.enableThinking});
}

/// A streaming partial translation token sent from the worker to the main isolate.
class NmtStreamToken {
  final String text;
  const NmtStreamToken(this.text);
}


// ============================================================================
// NmtBackend — unified interface for all NMT service implementations.
// ============================================================================

/// Abstract interface shared by [NativeNmtService] (Opus-MT / Marian ONNX)
/// and [LlamaNmtService] (llama.cpp GGUF).
///
/// Both services expose the same surface:
///   - [isLoaded]          — whether a model is currently loaded and ready.
///   - [loadModel]         — load (or hot-swap) a model.  The [sourceLang] /
///                           [targetLang] params are only used by the Llama
///                           backend; the Marian backend ignores them.
///   - [translateStream]   — stream partial tokens, completes when done.
///   - [lastStreamTiming]  — timing metrics from the most-recent stream call.
///   - [release]           — tear down the background isolate / free memory.
abstract class NmtBackend {
  /// Whether a model has been successfully loaded and is ready to translate.
  bool get isLoaded;

  /// Load [model].  For the Llama backend, pass [sourceLang] / [targetLang]
  /// so the prompt can be constructed correctly; for the Marian backend these
  /// parameters are ignored.
  Future<void> loadModel(
    ModelInfo model, {
    String? sourceLang,
    String? targetLang,
  });

  /// Translate [text] with per-token streaming.  Yields cumulative partial
  /// output after each token; the stream closes when translation is complete.
  Stream<String> translateStream(String text);

  /// Timing / performance metrics from the most-recent [translateStream] call.
  /// Returns `null` before any translation has been performed.
  TranslationResult? get lastStreamTiming;

  /// Release the loaded model and free all associated resources.
  void release();
}
