import 'dart:io';

enum OcrMode { plain, grounding }

class OcrConfig {
  final int longestEdge;
  final int maxTokens;
  final int nThreads;
  final int seed;
  final int nCtx;
  final int nBatch;
  final int imageMaxTokens;

  const OcrConfig({
    this.longestEdge = 1280,
    this.maxTokens = 2048,
    this.nThreads = 4,
    this.seed = 42,
    this.nCtx = 8192,
    this.nBatch = 2048,
    this.imageMaxTokens = 4096,
  });

  factory OcrConfig.forDevice() {
    final threads = Platform.numberOfProcessors < 8 ? Platform.numberOfProcessors : 8;
    return OcrConfig(nThreads: threads < 1 ? 1 : threads);
  }

  OcrConfig copyWith({
    int? longestEdge,
    int? maxTokens,
    int? nThreads,
    int? seed,
    int? nCtx,
    int? nBatch,
    int? imageMaxTokens,
  }) {
    return OcrConfig(
      longestEdge: longestEdge ?? this.longestEdge,
      maxTokens: maxTokens ?? this.maxTokens,
      nThreads: nThreads ?? this.nThreads,
      seed: seed ?? this.seed,
      nCtx: nCtx ?? this.nCtx,
      nBatch: nBatch ?? this.nBatch,
      imageMaxTokens: imageMaxTokens ?? this.imageMaxTokens,
    );
  }

  Map<String, Object?> toJson() => {
        'longestEdge': longestEdge,
        'maxTokens': maxTokens,
        'nThreads': nThreads,
        'seed': seed,
        'nCtx': nCtx,
        'nBatch': nBatch,
        'imageMaxTokens': imageMaxTokens,
      };

  factory OcrConfig.fromJson(Map<String, Object?> json) {
    int readInt(String key, int fallback) {
      final value = json[key];
      return value is int ? value : fallback;
    }

    return OcrConfig(
      longestEdge: readInt('longestEdge', 1280),
      maxTokens: readInt('maxTokens', 2048),
      nThreads: readInt('nThreads', 4),
      seed: readInt('seed', 42),
      nCtx: readInt('nCtx', 8192),
      nBatch: readInt('nBatch', 2048),
      imageMaxTokens: readInt('imageMaxTokens', 4096),
    );
  }
}

class OcrStats {
  final int promptTokens;
  final int outputTokens;
  final int imageTokens;
  final double loadMs;
  final double encodeMs;
  final double prefillMs;
  final double decodeMs;
  final int peakRssKb;
  final double preprocessMs;
  final double endToEndMs;

  const OcrStats({
    this.promptTokens = 0,
    this.outputTokens = 0,
    this.imageTokens = 0,
    this.loadMs = 0,
    this.encodeMs = 0,
    this.prefillMs = 0,
    this.decodeMs = 0,
    this.peakRssKb = 0,
    this.preprocessMs = 0,
    this.endToEndMs = 0,
  });

  OcrStats copyWith({
    int? promptTokens,
    int? outputTokens,
    int? imageTokens,
    double? loadMs,
    double? encodeMs,
    double? prefillMs,
    double? decodeMs,
    int? peakRssKb,
    double? preprocessMs,
    double? endToEndMs,
  }) {
    return OcrStats(
      promptTokens: promptTokens ?? this.promptTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      imageTokens: imageTokens ?? this.imageTokens,
      loadMs: loadMs ?? this.loadMs,
      encodeMs: encodeMs ?? this.encodeMs,
      prefillMs: prefillMs ?? this.prefillMs,
      decodeMs: decodeMs ?? this.decodeMs,
      peakRssKb: peakRssKb ?? this.peakRssKb,
      preprocessMs: preprocessMs ?? this.preprocessMs,
      endToEndMs: endToEndMs ?? this.endToEndMs,
    );
  }

  double get totalMs => loadMs + encodeMs + prefillMs + decodeMs;

  double get tokensPerSecond =>
      decodeMs <= 0 ? 0 : outputTokens * 1000 / decodeMs;
}

class OcrResult {
  final String text;
  final OcrStats stats;

  const OcrResult({required this.text, required this.stats});
}

class OcrProgress {
  final String stage;
  final double fraction;

  const OcrProgress({required this.stage, required this.fraction});
}

class OcrException implements Exception {
  final String code;
  final String message;

  const OcrException(this.code, this.message);

  @override
  String toString() => 'OcrException($code): $message';
}

abstract final class OcrErrorCode {
  static const modelMissing = 'E_MODEL_MISSING';
  static const ggufInvalid = 'E_GGUF_INVALID';
  static const load = 'E_LOAD';
  static const oom = 'E_OOM';
  static const encode = 'E_ENCODE';
  static const decode = 'E_DECODE';
  static const mode = 'E_MODE';
  static const cancelled = 'E_CANCELLED';
  static const workerCrash = 'E_WORKER_CRASH';
  static const busy = 'E_BUSY';
}
