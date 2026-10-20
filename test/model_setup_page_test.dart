import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/models/model_file_picker.dart';
import 'package:lighton_ocr_on_device/src/models/model_store.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_service.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_worker.dart';
import 'package:lighton_ocr_on_device/src/ui/model_setup_page.dart';

class _FakePicker implements ModelFilePicker {
  _FakePicker(this.file);
  final File? file;

  @override
  Future<File?> pickGgufFile() async => file;
}

class _NoopWorker implements OcrWorker {
  final StreamController<WorkerEvent> _controller =
      StreamController<WorkerEvent>.broadcast();

  @override
  Stream<WorkerEvent> get events => _controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> load({
    required String modelPath,
    required String mmprojPath,
    required OcrConfig config,
  }) async {}

  @override
  Future<void> run({
    required Uint8List encodedImage,
    required int longestEdge,
    required OcrMode mode,
    required int maxTokens,
  }) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('model_setup_test');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  testWidgets('shows two empty model slots', (tester) async {
    final store = ModelStore(
      root: temp,
      minMainBytes: 1,
      minMmprojBytes: 1,
    );
    final service = OcrService(
      modelStore: store,
      workerFactory: _NoopWorker.new,
    );
    await tester.runAsync(() async {
      await service.initialize();
    });
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ModelSetupPage(
          store: store,
          picker: _FakePicker(null),
          service: service,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.text('主模型'), findsOneWidget);
    expect(find.text('mmproj'), findsOneWidget);
    expect(find.text('未导入'), findsNWidgets(2));
  });

}
