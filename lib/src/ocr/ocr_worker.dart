import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import '../image/image_preprocess.dart';
import 'ocr_ffi.dart';
import 'ocr_types.dart';

sealed class WorkerCommand {
  const WorkerCommand();
}

final class LoadCommand extends WorkerCommand {
  final String modelPath;
  final String mmprojPath;
  final OcrConfig config;

  const LoadCommand({
    required this.modelPath,
    required this.mmprojPath,
    required this.config,
  });
}

final class RunCommand extends WorkerCommand {
  final Uint8List encodedImage;
  final int longestEdge;
  final OcrMode mode;
  final int maxTokens;
  final int seed;

  const RunCommand({
    required this.encodedImage,
    required this.longestEdge,
    required this.mode,
    required this.maxTokens,
    this.seed = 42,
  });
}

final class CancelCommand extends WorkerCommand {
  const CancelCommand();
}

final class DisposeCommand extends WorkerCommand {
  const DisposeCommand();
}

sealed class WorkerEvent {
  const WorkerEvent();
}

final class LoadingEvent extends WorkerEvent {
  final double fraction;

  const LoadingEvent(this.fraction);
}

final class ProgressEvent extends WorkerEvent {
  final OcrProgress progress;

  const ProgressEvent(this.progress);
}

final class TokenEvent extends WorkerEvent {
  final String text;

  const TokenEvent(this.text);
}

final class DoneEvent extends WorkerEvent {
  final OcrResult result;

  const DoneEvent(this.result);
}

final class EngineReadyEvent extends WorkerEvent {
  final int address;

  const EngineReadyEvent(this.address);
}

final class FailedEvent extends WorkerEvent {
  final String code;
  final String message;

  const FailedEvent(this.code, this.message);
}

abstract class OcrWorker {
  Stream<WorkerEvent> get events;

  Future<void> start();

  Future<void> load({
    required String modelPath,
    required String mmprojPath,
    required OcrConfig config,
  });

  Future<void> run({
    required Uint8List encodedImage,
    required int longestEdge,
    required OcrMode mode,
    required int maxTokens,
    int seed = 42,
  });

  Future<void> cancel();

  Future<void> dispose();
}

class IsolateOcrWorker implements OcrWorker {
  IsolateOcrWorker({this.cancelNative});

  final Future<void> Function(int address)? cancelNative;
  final StreamController<WorkerEvent> _events =
      StreamController<WorkerEvent>.broadcast();

  ReceivePort? _fromWorker;
  RawReceivePort? _exitPort;
  RawReceivePort? _errorPort;
  SendPort? _toWorker;
  Isolate? _isolate;
  Completer<SendPort>? _ready;
  int? _engineAddress;
  bool _running = false;
  bool _disposed = false;

  @override
  Stream<WorkerEvent> get events => _events.stream;

  bool get isRunning => _running;

  @override
  Future<void> start() async {
    if (_running) {
      return;
    }
    if (_disposed) {
      throw StateError('worker has been disposed');
    }

    _fromWorker = ReceivePort();
    _ready = Completer<SendPort>();
    _fromWorker!.listen((message) {
      if (message is SendPort) {
        if (!_ready!.isCompleted) {
          _ready!.complete(message);
        }
        return;
      }
      if (message is WorkerEvent && !_events.isClosed) {
        if (message is EngineReadyEvent) {
          _engineAddress = message.address;
        }
        _events.add(message);
      }
    });

    _isolate = await Isolate.spawn(
      ocrWorkerMain,
      _fromWorker!.sendPort,
    );
    _exitPort = RawReceivePort((_) => _onExit());
    _errorPort = RawReceivePort((message) => _onError(message));
    _isolate!.addOnExitListener(_exitPort!.sendPort);
    _isolate!.addErrorListener(_errorPort!.sendPort);
    try {
      _toWorker = await _ready!.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _fromWorker?.close();
      _fromWorker = null;
      _exitPort?.close();
      _exitPort = null;
      _errorPort?.close();
      _errorPort = null;
      throw StateError('OCR worker did not start');
    }
    _running = true;
  }

  void _onError(Object? message) {
    _running = false;
    if (_disposed || _events.isClosed) {
      return;
    }
    final text = message is List && message.isNotEmpty
        ? message.first.toString()
        : message.toString();
    _events.add(FailedEvent(OcrErrorCode.workerCrash, text));
  }

  void _onExit() {
    _running = false;
    if (!_disposed && !_events.isClosed) {
      _events.add(
        const FailedEvent(OcrErrorCode.workerCrash, 'worker exited'),
      );
    }
  }

  @override
  Future<void> load({
    required String modelPath,
    required String mmprojPath,
    required OcrConfig config,
  }) async {
    _requireRunning();
    _toWorker!.send(LoadCommand(
      modelPath: modelPath,
      mmprojPath: mmprojPath,
      config: config,
    ));
  }

  @override
  Future<void> run({
    required Uint8List encodedImage,
    required int longestEdge,
    required OcrMode mode,
    required int maxTokens,
    int seed = 42,
  }) async {
    _requireRunning();
    _toWorker!.send(RunCommand(
      encodedImage: encodedImage,
      longestEdge: longestEdge,
      mode: mode,
      maxTokens: maxTokens,
      seed: seed,
    ));
  }

  @override
  Future<void> cancel() async {
    _requireRunning();
    final address = _engineAddress;
    if (address == null) {
      _toWorker!.send(const CancelCommand());
      return;
    }
    try {
      final nativeCancel = cancelNative;
      if (nativeCancel != null) {
        await nativeCancel(address);
      } else {
        await Isolate.run(() {
          final ffi = OcrFfi.open();
          ffi.cancel(Pointer<OcrEngine>.fromAddress(address));
        });
      }
    } catch (_) {
      // Fall back to the worker message if the cancel isolate cannot start.
      if (_toWorker != null) {
        _toWorker!.send(const CancelCommand());
      }
    }
  }

  void _requireRunning() {
    if (!_running || _toWorker == null) {
      throw StateError('worker is not running');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _running = false;

    _toWorker?.send(const DisposeCommand());
    _fromWorker?.close();
    _fromWorker = null;
    _exitPort?.close();
    _exitPort = null;
    _errorPort?.close();
    _errorPort = null;

    final isolate = _isolate;
    _isolate = null;
    if (isolate != null) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      isolate.kill(priority: Isolate.immediate);
    }
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}

Future<void> ocrWorkerMain(SendPort uiPort) async {
  final receive = ReceivePort();
  uiPort.send(receive.sendPort);

  OcrFfi? ffi;
  Pointer<OcrEngine>? engine;

  Future<void> destroyEngine() async {
    if (engine != null && ffi != null) {
      ffi.destroy(engine!);
      engine = null;
    }
  }

  await for (final message in receive) {
    if (message is LoadCommand) {
      try {
        ffi ??= OcrFfi.open();
        await destroyEngine();
        engine = ffi.create(
          modelPath: message.modelPath,
          mmprojPath: message.mmprojPath,
          config: message.config,
          onProgress: (progress) {
            uiPort.send(LoadingEvent(progress.fraction));
          },
        );
        uiPort.send(EngineReadyEvent(engine!.address));
        uiPort.send(const LoadingEvent(1.0));
      } on OcrException catch (error) {
        uiPort.send(FailedEvent(error.code, error.message));
      } catch (error) {
        uiPort.send(FailedEvent(OcrErrorCode.load, error.toString()));
      }
      continue;
    }

    if (message is RunCommand) {
      if (engine == null || ffi == null) {
        uiPort.send(
          const FailedEvent(OcrErrorCode.load, 'model is not loaded'),
        );
        continue;
      }
      try {
        final runWatch = Stopwatch()..start();
        uiPort.send(
          const ProgressEvent(OcrProgress(stage: 'preprocess', fraction: 0)),
        );
        final preprocessWatch = Stopwatch()..start();
        final prepared = await prepareImage(
          message.encodedImage,
          longestEdge: message.longestEdge,
        );
        preprocessWatch.stop();
        uiPort.send(
          const ProgressEvent(OcrProgress(stage: 'preprocess', fraction: 1)),
        );

        final output = StringBuffer();
        final tokenBuffer = StringBuffer();
        var tokenCount = 0;
        final nativeStats = ffi.run(
          engine: engine!,
          rgb: prepared.rgb,
          width: prepared.width,
          height: prepared.height,
          mode: message.mode,
          maxTokens: message.maxTokens,
          seed: message.seed,
          onToken: (text) {
            output.write(text);
            tokenBuffer.write(text);
            tokenCount++;
            if (tokenCount % 16 == 0) {
              uiPort.send(TokenEvent(tokenBuffer.toString()));
              tokenBuffer.clear();
            }
          },
          onProgress: (progress) => uiPort.send(ProgressEvent(progress)),
        );
        if (tokenBuffer.isNotEmpty) {
          uiPort.send(TokenEvent(tokenBuffer.toString()));
        }
        runWatch.stop();
        final stats = nativeStats.copyWith(
          preprocessMs: preprocessWatch.elapsedMicroseconds / 1000.0,
          endToEndMs: runWatch.elapsedMicroseconds / 1000.0,
        );
        uiPort.send(DoneEvent(OcrResult(text: output.toString(), stats: stats)));
      } on OcrException catch (error) {
        uiPort.send(FailedEvent(error.code, error.message));
      } catch (error) {
        uiPort.send(FailedEvent(OcrErrorCode.decode, error.toString()));
      }
      continue;
    }

    if (message is CancelCommand) {
      if (engine != null && ffi != null) {
        ffi.cancel(engine!);
      }
      continue;
    }

    if (message is DisposeCommand) {
      await destroyEngine();
      receive.close();
      break;
    }
  }
}
