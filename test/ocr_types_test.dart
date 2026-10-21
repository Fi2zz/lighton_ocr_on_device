import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';

void main() {
  test('defaults match spec', () {
    const c = OcrConfig();
    expect(c.longestEdge, 1280);
    expect(c.maxTokens, 4096);
    expect(c.nCtx, 12288);
    expect(c.nBatch, 2048);
    expect(c.imageMaxTokens, 4096);
    expect(c.seed, 42);
    expect(c.nThreads, greaterThan(0));
  });

  test('json round trip', () {
    const c = OcrConfig(longestEdge: 1536, maxTokens: 2048, nThreads: 4);
    expect(OcrConfig.fromJson(c.toJson()).toJson(), c.toJson());
  });

  test('stats tokens per second', () {
    const s = OcrStats(
      promptTokens: 100,
      outputTokens: 50,
      imageTokens: 300,
      loadMs: 100,
      encodeMs: 100,
      prefillMs: 100,
      decodeMs: 1000,
      peakRssKb: 1000,
    );
    expect(s.totalMs, 1300);
    expect(s.tokensPerSecond, 50);
  });

  test('exception carries code and message', () {
    final e = OcrException('E_LOAD', 'boom');
    expect(e.code, 'E_LOAD');
    expect(e.toString(), contains('E_LOAD'));
  });
}
