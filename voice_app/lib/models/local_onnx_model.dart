import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:voice_app/onnxruntime/onnxruntime.dart';

class LocalOnnxModel {
  late OrtSession _encoderSession;
  late OrtSession _decoderSession;
  late Map<String, int> _vocab; // token -> id
  late Map<int, String> _reverseVocab; // id -> token

  late int eosTokenId;
  late int padTokenId;
  late int unkTokenId;

  final RegExp _specialTokenRegex = RegExp(r'<[^>]+>');

  LocalOnnxModel();

  Future<void> init({
    String? modelBasePath,
    String? encoderPath,
    String? decoderPath,
    String? vocabPath,
    String? tokenizerConfigPath,
    String? generationConfigPath,
  }) async {
    // Compose file paths if modelBasePath is provided.
    // Supports both standard names (encoder.onnx) and legacy names (encoder_model.onnx).
    final base = modelBasePath != null
        ? (modelBasePath!.endsWith('/') ? modelBasePath! : '$modelBasePath/')
        : '';
    if (modelBasePath != null) {
      // Prefer standard names, fall back to legacy names.
      encoderPath ??= () {
        final standard = File('${base}encoder.onnx');
        if (standard.existsSync()) return standard.path;
        return '${base}encoder_model.onnx';
      }();
      decoderPath ??= () {
        final standard = File('${base}decoder.onnx');
        if (standard.existsSync()) return standard.path;
        return '${base}decoder_model.onnx';
      }();
    }
    encoderPath ??= '';
    decoderPath ??= '';
    vocabPath ??= modelBasePath != null
        ? '${modelBasePath.endsWith('/') ? modelBasePath : '$modelBasePath/'}vocab.json'
        : '';
    tokenizerConfigPath ??= modelBasePath != null
        ? '${modelBasePath.endsWith('/') ? modelBasePath : '$modelBasePath/'}tokenizer_config.json'
        : '';
    generationConfigPath ??= modelBasePath != null
        ? '${modelBasePath.endsWith('/') ? modelBasePath : '$modelBasePath/'}generation_config.json'
        : '';

    if (encoderPath.isEmpty || decoderPath.isEmpty || vocabPath.isEmpty) {
      throw Exception('Paths for encoder, decoder, and vocab must not be empty.');
    }

    OrtEnv.instance.init();

    // Load vocabulary JSON from disk
    final vocabFile = File(vocabPath);
    if (!vocabFile.existsSync()) {
      throw Exception("Vocab file not found at: $vocabPath");
    }
    final vocabStr = await vocabFile.readAsString();
    final vocabJson = jsonDecode(vocabStr) as Map<String, dynamic>;
    _vocab = vocabJson.map((k, v) => MapEntry(k, (v as num).toInt()));
    _reverseVocab = Map.fromEntries(_vocab.entries.map((e) => MapEntry(e.value, e.key)));

    // Initialize token IDs with defaults
    eosTokenId = _reverseVocab.entries
        .firstWhere(
          (e) => e.value == '</s>',
          orElse: () => const MapEntry(0, '</s>'),
        )
        .key;
    unkTokenId = _reverseVocab.entries
        .firstWhere(
          (e) => e.value == '<unk>',
          orElse: () => const MapEntry(1, '<unk>'),
        )
        .key;
    padTokenId = _reverseVocab.entries
        .firstWhere(
          (e) => e.value == '<pad>',
          orElse: () => MapEntry(
              (_vocab['<pad>'] ?? -1) >= 0 ? _vocab['<pad>']! : 0, '<pad>'),
        )
        .key;

    // Load tokenizer config if exists
    try {
      final tcfgFile = File(tokenizerConfigPath);
      if (tcfgFile.existsSync()) {
        final tcfg = await tcfgFile.readAsString();
        final tc = jsonDecode(tcfg) as Map<String, dynamic>;
        if (tc.containsKey('pad_token')) {
          final padTok = tc['pad_token'] as String;
          if (_vocab.containsKey(padTok)) padTokenId = _vocab[padTok]!;
        }
        if (tc.containsKey('unk_token')) {
          final unkTok = tc['unk_token'] as String;
          if (_vocab.containsKey(unkTok)) unkTokenId = _vocab[unkTok]!;
        }
      }
    } catch (_) {}

    // Load generation config if exists
    try {
      final gcfgFile = File(generationConfigPath);
      if (gcfgFile.existsSync()) {
        final gcfg = await gcfgFile.readAsString();
        final gc = jsonDecode(gcfg) as Map<String, dynamic>;
        if (gc.containsKey('eos_token_id')) {
          eosTokenId = (gc['eos_token_id'] as num).toInt();
        } else if (gc.containsKey('eos_token')) {
          final tok = gc['eos_token'] as String;
          if (_vocab.containsKey(tok)) eosTokenId = _vocab[tok]!;
        }
      }
    } catch (_) {}

    // Final sanity check
    eosTokenId = eosTokenId >= 0 ? eosTokenId : 0;
    padTokenId = padTokenId >= 0 ? padTokenId : eosTokenId;
    unkTokenId = unkTokenId >= 0 ? unkTokenId : 1;

    // Load ONNX files from disk
    final encFile = File(encoderPath);
    final decFile = File(decoderPath);
    if (!encFile.existsSync()) throw Exception("Encoder model not found at: $encoderPath");
    if (!decFile.existsSync()) throw Exception("Decoder model not found at: $decoderPath");

    final sessionOptions = OrtSessionOptions();
    _encoderSession = OrtSession.fromFile(encFile, sessionOptions);
    _decoderSession = OrtSession.fromFile(decFile, sessionOptions);
  }

  List<int> tokenize(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return [eosTokenId];

    final tokenIds = <int>[];
    final tokens = _vocab.keys.toList()..sort((a, b) => b.length.compareTo(a.length));

    int pos = 0;
    while (pos < normalized.length) {
      final match = _specialTokenRegex.matchAsPrefix(normalized, pos);
      if (match != null) {
        final specialTok = match.group(0)!;
        if (_vocab.containsKey(specialTok)) {
          tokenIds.add(_vocab[specialTok]!);
          pos += specialTok.length;
          while (pos < normalized.length && normalized[pos] == ' ') {
            pos++;
          }
          continue;
        }
      }

      bool matched = false;
      for (final tok in tokens) {
        if (tok.length > normalized.length - pos) continue;
        final substr = normalized.substring(pos, pos + tok.length);

        if (substr == tok) {
          tokenIds.add(_vocab[tok]!);
          pos += tok.length;
          matched = true;
          break;
        }
        if (tok.startsWith('▁')) {
          final plainTok = tok.substring(1);
          if ((pos == 0 || normalized[pos - 1] == ' ') &&
              normalized.substring(pos, pos + plainTok.length) == plainTok) {
            tokenIds.add(_vocab[tok]!);
            pos += plainTok.length;
            matched = true;
            break;
          }
        }
      }

      if (!matched) {
        tokenIds.add(unkTokenId);
        pos += 1;
      } else {
        while (pos < normalized.length && normalized[pos] == ' ') {
          pos++;
        }
      }
    }

    tokenIds.add(eosTokenId);
    return tokenIds;
  }

  List<double> softmax(List<double> logits) {
    final maxValue = logits.reduce(max);
    final exps = logits.map((l) => exp(l - maxValue)).toList();
    final sumExp = exps.fold<double>(0.0, (a, b) => a + b);
    return exps.map((e) => e / sumExp).toList();
  }

  bool _isPunctuation(String token) {
    const punctuations = {
      '.', ',', '!', '?', ':', ';', '-', '—', '(', ')', '[', ']', '"', '\''
    };
    return punctuations.contains(token);
  }

  String detokenize(List<int> tokenIds) {
    final tokens = tokenIds.map((id) => _reverseVocab[id] ?? '<unk>').toList();
    final buffer = StringBuffer();

    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];

      if (tok == '</s>') continue;

      if (tok.startsWith('<') && tok.endsWith('>')) {
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(tok);
        continue;
      }

      if (tok.startsWith('▁')) {
        if (buffer.isNotEmpty) buffer.write(' ');
        buffer.write(tok.substring(1));
      } else if (_isPunctuation(tok)) {
        buffer.write(tok);
      } else {
        buffer.write(tok);
      }
    }

    return buffer.toString().trim();
  }

  Future<String> runModel(
    String inputText, {
    String? initialLangToken,
    int maxNewTokens = 50,
  }) async {
    String textToTokenize = inputText;
    if (initialLangToken != null && initialLangToken.isNotEmpty) {
      textToTokenize = '$initialLangToken $inputText';
    }

    final inputIds = tokenize(textToTokenize);
    final seqLen = inputIds.length;

    final attentionMask = List<int>.filled(seqLen, 1);

    final inputTensor = OrtValueTensor.createTensorWithDataList(inputIds, [1, seqLen]);
    final attentionMaskTensor = OrtValueTensor.createTensorWithDataList(attentionMask, [1, seqLen]);

    final encoderInputs = {
      'input_ids': inputTensor,
      'attention_mask': attentionMaskTensor,
    };

    final encoderOutputs = await _encoderSession.runAsync(OrtRunOptions(), encoderInputs);
    final encoderHiddenStates = encoderOutputs![0];

    final decoderInputIds = <int>[padTokenId];
    final generatedIds = <int>[];

    for (int step = 0; step < maxNewTokens; step++) {
      final decInputTensor = OrtValueTensor.createTensorWithDataList(
          decoderInputIds, [1, decoderInputIds.length]);

      final decoderInputs = {
        'input_ids': decInputTensor,
        'encoder_hidden_states': encoderHiddenStates!,
        'encoder_attention_mask': attentionMaskTensor,
      };

      if (_decoderSession.inputNames.contains('use_cache_branch')) {
        decoderInputs['use_cache_branch'] = OrtValueTensor.createTensorWithDataList([false], [1]);
        for (final name in _decoderSession.inputNames) {
          if (decoderInputs.containsKey(name)) continue;
          if (name.startsWith('past_key_values')) {
            decoderInputs[name] = OrtValueTensor.createTensorWithDataList(List<double>.empty(), [1, 8, 0, 64]);
          }
        }
      }

      final decoderOutputs = await _decoderSession.runAsync(OrtRunOptions(), decoderInputs);

      final logitsTensor = decoderOutputs![0];
      if (logitsTensor == null || logitsTensor.value == null) break;

      final raw = logitsTensor.value as List<dynamic>;
      final lastStepLogits = (raw[0] as List<dynamic>).last as List<dynamic>;

      final logits = lastStepLogits.map((e) => (e as num).toDouble()).toList();
      final probs = softmax(logits);

      int nextToken = 0;
      double best = double.negativeInfinity;
      for (int i = 0; i < probs.length; i++) {
        if (probs[i] > best) {
          best = probs[i];
          nextToken = i;
        }
      }

      generatedIds.add(nextToken);

      if (nextToken == eosTokenId) break;

      decoderInputIds.add(nextToken);
    }

    final translated = detokenize(generatedIds);
    return translated;
  }

  void release() {
    try {
      _encoderSession.release();
      _decoderSession.release();
      OrtEnv.instance.release();
    } catch (_) {}
  }
}
