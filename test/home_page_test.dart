import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/image/image_source.dart';
import 'package:lighton_ocr_on_device/src/models/model_store.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_service.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_worker.dart';
import 'package:lighton_ocr_on_device/src/ui/home_page.dart';

class _FakeRepository implements ModelRepository {
  _FakeRepository(this.info);
  ModelInfo? info;

  @override
  Future<ModelInfo?> load() async => info;

  @override
  Future<OcrConfig> loadConfig() async => const OcrConfig();

  @override
  Future<void> saveConfig(OcrConfig config) async {}

  @override
  Future<void> deleteAll() async {}
}

class _FakeImageSource implements ImageSourceService {
  _FakeImageSource(this.bytes);
  final Uint8List? bytes;

  @override
  Future<Uint8List?> pickFromGallery() async => bytes;

  @override
  Future<Uint8List?> takePhoto() async => bytes;
}

class _FakeWorker implements OcrWorker {
  _FakeWorker({this.autoComplete = true});
  final bool autoComplete;
  OcrException? runFailure;
  final StreamController<WorkerEvent> _controller =
      StreamController<WorkerEvent>.broadcast();

  int runCalls = 0;

  @override
  Stream<WorkerEvent> get events => _controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> load({
    required String modelPath,
    required String mmprojPath,
    required OcrConfig config,
  }) async {
    _controller.add(const LoadingEvent(1.0));
  }

  @override
  Future<void> run({
    required Uint8List encodedImage,
    required int longestEdge,
    required OcrMode mode,
    required int maxTokens,
    int seed = 42,
  }) async {
    runCalls++;
    if (runFailure != null) {
      _controller.add(FailedEvent(runFailure!.code, runFailure!.message));
      return;
    }
    if (!autoComplete) {
      return;
    }
    _controller.add(const TokenEvent('hello'));
    _controller.add(
      const DoneEvent(
        OcrResult(text: 'hello', stats: OcrStats(outputTokens: 1)),
      ),
    );
  }

  @override
  Future<void> cancel() async {
    _controller.add(
      const FailedEvent(OcrErrorCode.cancelled, 'cancelled'),
    );
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  void emit(WorkerEvent event) {
    _controller.add(event);
  }
}

final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('home_page_test');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ModelInfo info() => ModelInfo(
        main: File('main.gguf'),
        mmproj: File('mmproj.gguf'),
      );

  Future<OcrService> pumpHome(
    WidgetTester tester, {
    required ModelInfo? model,
    required _FakeWorker worker,
    required Uint8List? image,
  }) async {
    final repo = _FakeRepository(model);
    final service = OcrService(
      modelStore: repo,
      workerFactory: () => worker,
    );
    await service.initialize();
    addTearDown(service.dispose);

    final store = ModelStore(
      root: temp,
      minMainBytes: 1,
      minMmprojBytes: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          service: service,
          store: store,
          imageSource: _FakeImageSource(image),
        ),
      ),
    );
    await tester.pump();
    return service;
  }

  testWidgets('unconfigured model shows configure button', (tester) async {
    await pumpHome(
      tester,
      model: null,
      worker: _FakeWorker(),
      image: null,
    );

    expect(find.text('配置模型'), findsWidgets);
  });

  testWidgets('configured model shows run button', (tester) async {
    await pumpHome(
      tester,
      model: info(),
      worker: _FakeWorker(),
      image: null,
    );

    expect(find.text('开始识别'), findsOneWidget);
  });

  testWidgets('gallery selection shows preview', (tester) async {
    await pumpHome(
      tester,
      model: info(),
      worker: _FakeWorker(),
      image: _tinyPng,
    );

    await tester.tap(find.text('相册'));
    await tester.pump();

    expect(find.text('重新选择'), findsOneWidget);
  });

  testWidgets('run navigates to result page', (tester) async {
    await pumpHome(
      tester,
      model: info(),
      worker: _FakeWorker(),
      image: _tinyPng,
    );

    await tester.tap(find.text('相册'));
    await tester.pump();
    await tester.tap(find.text('开始识别'));
    await tester.pumpAndSettle();

    expect(find.text('识别结果'), findsOneWidget);
    expect(find.textContaining('hello', findRichText: true), findsWidgets);
  });

  testWidgets('recognition error is shown in Chinese', (tester) async {
    final worker = _FakeWorker()..runFailure = const OcrException('E_ENCODE', 'bad');
    await pumpHome(
      tester,
      model: info(),
      worker: worker,
      image: _tinyPng,
    );

    await tester.tap(find.text('相册'));
    await tester.pump();
    await tester.tap(find.text('开始识别'));
    await tester.pumpAndSettle();

    expect(find.text('图片编码失败，换一张图片'), findsOneWidget);
  });

  testWidgets('running state shows live recognition result', (tester) async {
    final worker = _FakeWorker(autoComplete: false);
    final service = await pumpHome(
      tester,
      model: info(),
      worker: worker,
      image: _tinyPng,
    );

    await tester.tap(find.text('相册'));
    await tester.pump();
    await tester.tap(find.text('开始识别'));
    await tester.pump();

    worker.emit(const TokenEvent('第一行\n第二行'));
    await tester.pump();

    expect(find.text('识别结果'), findsOneWidget);
    expect(find.textContaining('第一行'), findsOneWidget);

    await service.cancel();
    await tester.pump();
  });

  testWidgets('running state shows cancel', (tester) async {
    final service = await pumpHome(
      tester,
      model: info(),
      worker: _FakeWorker(autoComplete: false),
      image: _tinyPng,
    );

    await tester.tap(find.text('相册'));
    await tester.pump();
    await tester.tap(find.text('开始识别'));
    await tester.pump();

    expect(find.text('取消'), findsOneWidget);
    expect(find.text('图像编码'), findsOneWidget);
    expect(find.text('总耗时'), findsOneWidget);

    await service.cancel();
    await tester.pump();
  });
}
