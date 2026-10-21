import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/models/model_store.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_service.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_worker.dart';

class FakeModelRepository implements ModelRepository {
  ModelInfo? info;
  OcrConfig config = const OcrConfig();
  int saveCalls = 0;

  @override
  Future<ModelInfo?> load() async => info;

  @override
  Future<OcrConfig> loadConfig() async => config;

  @override
  Future<void> saveConfig(OcrConfig value) async {
    config = value;
    saveCalls++;
  }

  @override
  Future<void> deleteAll() async {
    info = null;
  }
}

class FakeOcrWorker implements OcrWorker {
  final StreamController<WorkerEvent> _controller =
      StreamController<WorkerEvent>.broadcast();

  int startCalls = 0;
  int loadCalls = 0;
  int runCalls = 0;
  int cancelCalls = 0;
  OcrException? loadFailure;
  OcrException? runFailure;
  RunCommand? lastRun;

  @override
  Stream<WorkerEvent> get events => _controller.stream;

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> load({
    required String modelPath,
    required String mmprojPath,
    required OcrConfig config,
  }) async {
    loadCalls++;
    if (loadFailure != null) {
      _controller.add(FailedEvent(loadFailure!.code, loadFailure!.message));
    } else {
      _controller.add(const LoadingEvent(1.0));
    }
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
    lastRun = RunCommand(
      encodedImage: encodedImage,
      longestEdge: longestEdge,
      mode: mode,
      maxTokens: maxTokens,
    );
    if (runFailure != null) {
      _controller.add(FailedEvent(runFailure!.code, runFailure!.message));
    }
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
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

void main() {
  late FakeModelRepository repo;
  late FakeOcrWorker worker;
  late OcrService service;

  ModelInfo info() => ModelInfo(
        main: File('main.gguf'),
        mmproj: File('mmproj.gguf'),
      );

  setUp(() {
    repo = FakeModelRepository();
    worker = FakeOcrWorker();
    service = OcrService(
      modelStore: repo,
      workerFactory: () => worker,
      initialConfig: const OcrConfig(),
    );
  });

  tearDown(() async {
    service.dispose();
  });

  test('initialize without model is unconfigured', () async {
    await service.initialize();
    expect(service.state, OcrServiceState.unconfigured);
  });

  test('initialize with model is ready', () async {
    repo.info = info();
    await service.initialize();
    expect(service.state, OcrServiceState.ready);
  });

  test('recognize loads once and returns result', () async {
    repo.info = info();
    await service.initialize();

    final future = service.recognize(
      encodedImage: Uint8List.fromList([1, 2, 3]),
    );
    await pumpEventQueue();
    expect(service.state, OcrServiceState.running);
    expect(worker.startCalls, 1);
    expect(worker.loadCalls, 1);
    expect(worker.runCalls, 1);

    worker.emit(const TokenEvent('hel'));
    worker.emit(DoneEvent(
      const OcrResult(text: 'hello', stats: OcrStats(outputTokens: 1)),
    ));
    await future;

    expect(service.state, OcrServiceState.ready);
    expect(service.result?.text, 'hello');
    expect(service.partialText, 'hello');
  });

  test('second recognize does not reload', () async {
    repo.info = info();
    await service.initialize();

    var future = service.recognize(encodedImage: Uint8List.fromList([1]));
    await pumpEventQueue();
    worker.emit(DoneEvent(const OcrResult(text: 'one', stats: OcrStats())));
    await future;

    future = service.recognize(encodedImage: Uint8List.fromList([2]));
    await pumpEventQueue();
    worker.emit(DoneEvent(const OcrResult(text: 'two', stats: OcrStats())));
    await future;

    expect(worker.loadCalls, 1);
    expect(worker.runCalls, 2);
  });

  test('cancel returns to ready and clears partial text', () async {
    repo.info = info();
    await service.initialize();

    final future = service.recognize(encodedImage: Uint8List.fromList([1]));
    await pumpEventQueue();
    worker.emit(const TokenEvent('partial'));

    final cancelFuture = service.cancel();
    await cancelFuture;
    await future;

    expect(worker.cancelCalls, 1);
    expect(service.state, OcrServiceState.ready);
    expect(service.partialText, isEmpty);
  });

  test('initialize during a run keeps running state', () async {
    repo.info = info();
    await service.initialize();

    final future = service.recognize(encodedImage: Uint8List.fromList([1]));
    await pumpEventQueue();
    await service.initialize();
    expect(service.state, OcrServiceState.running);

    worker.emit(DoneEvent(const OcrResult(text: 'done', stats: OcrStats())));
    await future;
  });

  test('load failure can be retried', () async {
    repo.info = info();
    await service.initialize();
    worker.loadFailure = const OcrException('E_LOAD', 'boom');

    await service.loadModel();
    expect(service.state, OcrServiceState.failed);
    expect(service.error?.code, 'E_LOAD');

    worker.loadFailure = null;
    final future = service.recognize(encodedImage: Uint8List.fromList([1]));
    await pumpEventQueue();
    worker.emit(DoneEvent(const OcrResult(text: 'ok', stats: OcrStats())));
    await future;

    expect(service.state, OcrServiceState.ready);
    expect(service.result?.text, 'ok');
  });

  test('recognize while running reports busy', () async {
    repo.info = info();
    await service.initialize();

    final future = service.recognize(encodedImage: Uint8List.fromList([1]));
    await pumpEventQueue();
    await service.recognize(encodedImage: Uint8List.fromList([2]));
    expect(service.error?.code, OcrErrorCode.busy);

    worker.emit(DoneEvent(const OcrResult(text: 'done', stats: OcrStats())));
    await future;
  });

  test('recognize without model does not start worker', () async {
    await service.initialize();
    await service.recognize(encodedImage: Uint8List.fromList([1]));
    expect(service.state, OcrServiceState.unconfigured);
    expect(service.error?.code, OcrErrorCode.modelMissing);
    expect(worker.startCalls, 0);
  });
}
