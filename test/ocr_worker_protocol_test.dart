import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_worker.dart';

void main() {
  test('worker starts and disposes without loading native', () async {
    final worker = IsolateOcrWorker();
    await worker.start();
    expect(worker.isRunning, isTrue);
    await worker.dispose();
    expect(worker.isRunning, isFalse);
  });

  test('run command carries image bytes', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final command = RunCommand(
      encodedImage: bytes,
      longestEdge: 2048,
      mode: OcrMode.grounding,
      maxTokens: 4096,
    );
    expect(command.encodedImage, bytes);
    expect(command.longestEdge, 2048);
    expect(command.mode, OcrMode.grounding);
    expect(command.maxTokens, 4096);
  });
}
