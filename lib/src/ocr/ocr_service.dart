import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/model_store.dart';
import 'ocr_types.dart';
import 'ocr_worker.dart';

enum OcrServiceState {
  unconfigured,
  loading,
  ready,
  running,
  cancelling,
  failed,
}

class OcrService extends ChangeNotifier {
  final ModelRepository modelStore;
  final OcrWorker Function() workerFactory;

  OcrWorker? _worker;
  StreamSubscription<WorkerEvent>? _subscription;
  ModelInfo? _modelInfo;
  OcrConfig _config;

  OcrServiceState _state = OcrServiceState.unconfigured;
  OcrResult? _result;
  OcrException? _error;
  String _partialText = '';
  OcrProgress? _progress;
  bool _engineLoaded = false;
  bool _requiresReload = false;
  bool _disposed = false;
  DateTime _lastTokenNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Completer<void>? _loadCompleter;
  Completer<void>? _runCompleter;

  OcrService({
    required this.modelStore,
    required this.workerFactory,
    OcrConfig? initialConfig,
  }) : _config = initialConfig ?? const OcrConfig();

  OcrServiceState get state => _state;
  OcrResult? get result => _result;
  OcrException? get error => _error;
  String get partialText => _partialText;
  OcrProgress? get progress => _progress;
  OcrConfig get config => _config;
  ModelInfo? get modelInfo => _modelInfo;
  bool get isModelConfigured => _modelInfo != null;
  bool get requiresReload => _requiresReload;

  Future<void> initialize() async {
    final busy = _state == OcrServiceState.running ||
        _state == OcrServiceState.loading ||
        _state == OcrServiceState.cancelling;
    try {
      _config = await modelStore.loadConfig();
    } catch (_) {
      _config = OcrConfig.forDevice();
    }
    _modelInfo = await modelStore.load();
    if (!busy) {
      _state = _modelInfo == null
          ? OcrServiceState.unconfigured
          : OcrServiceState.ready;
    }
    _notify();
  }

  Future<void> loadModel() async {
    if (_modelInfo == null) {
      _state = OcrServiceState.unconfigured;
      _error = const OcrException(
        OcrErrorCode.modelMissing,
        '主模型或 mmproj 未配置',
      );
      _notify();
      return;
    }
    if (_engineLoaded) {
      _state = OcrServiceState.ready;
      _notify();
      return;
    }

    _state = OcrServiceState.loading;
    _error = null;
    _progress = const OcrProgress(stage: 'load', fraction: 0);
    _notify();

    try {
      await _ensureWorker();
      final completer = Completer<void>();
      _loadCompleter = completer;
      await _worker!.load(
        modelPath: _modelInfo!.main.path,
        mmprojPath: _modelInfo!.mmproj.path,
        config: _config,
      );
      await completer.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          _error = const OcrException(
            OcrErrorCode.load,
            '模型加载超时',
          );
          _state = OcrServiceState.failed;
          _completeLoad();
        },
      );
    } on OcrException catch (error) {
      _error = error;
      _state = OcrServiceState.failed;
    } catch (error) {
      _error = OcrException(OcrErrorCode.load, error.toString());
      _state = OcrServiceState.failed;
    } finally {
      _loadCompleter = null;
    }

    if (_state == OcrServiceState.loading) {
      _state = _engineLoaded ? OcrServiceState.ready : OcrServiceState.failed;
    }
    _notify();
  }

  Future<void> recognize({
    required Uint8List encodedImage,
    OcrMode mode = OcrMode.grounding,
  }) async {
    if (_state == OcrServiceState.running ||
        _state == OcrServiceState.loading ||
        _state == OcrServiceState.cancelling) {
      _error = const OcrException(
        OcrErrorCode.busy,
        '正在识别，请稍候',
      );
      _notify();
      return;
    }

    if (_modelInfo == null) {
      _error = const OcrException(
        OcrErrorCode.modelMissing,
        '请先导入主模型和 mmproj',
      );
      _state = OcrServiceState.unconfigured;
      _notify();
      return;
    }

    _partialText = '';
    _result = null;
    _error = null;
    _progress = null;
    _lastTokenNotify = DateTime.fromMillisecondsSinceEpoch(0);

    if (!_engineLoaded) {
      await loadModel();
      if (!_engineLoaded) {
        return;
      }
    }

    _state = OcrServiceState.running;
    _notify();

    final completer = Completer<void>();
    _runCompleter = completer;
    try {
      await _worker!.run(
        encodedImage: encodedImage,
        longestEdge: _config.longestEdge,
        mode: mode,
        maxTokens: _config.maxTokens,
        seed: _config.seed,
      );
      await completer.future;
    } on OcrException catch (error) {
      _error = error;
      _state = OcrServiceState.failed;
    } catch (error) {
      _error = OcrException(OcrErrorCode.decode, error.toString());
      _state = OcrServiceState.failed;
    } finally {
      _runCompleter = null;
      _notify();
    }
  }

  Future<void> cancel() async {
    if (_state != OcrServiceState.running || _worker == null) {
      return;
    }
    _state = OcrServiceState.cancelling;
    _notify();

    await _worker!.cancel();
    final completer = _runCompleter;
    if (completer != null) {
      try {
        await completer.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        _completeRun();
        await _restartWorker();
      }
    }

    if (_state == OcrServiceState.cancelling) {
      _state = OcrServiceState.ready;
      _partialText = '';
      _progress = null;
      _notify();
    }
  }

  Future<void> reset() async {
    if (_state == OcrServiceState.running ||
        _state == OcrServiceState.cancelling) {
      await cancel();
    }

    await _subscription?.cancel();
    _subscription = null;
    await _worker?.dispose();
    _worker = null;
    _engineLoaded = false;
    _result = null;
    _error = null;
    _partialText = '';
    _progress = null;
    _requiresReload = false;
    _state = _modelInfo == null
        ? OcrServiceState.unconfigured
        : OcrServiceState.ready;
    _notify();
  }

  Future<void> updateConfig(OcrConfig config) async {
    final needsReload = _engineLoaded &&
        (config.nCtx != _config.nCtx || config.nThreads != _config.nThreads);
    _config = config;
    await modelStore.saveConfig(config);
    if (needsReload) {
      _requiresReload = true;
    }
    _notify();
  }

  Future<void> _ensureWorker() async {
    if (_worker != null) {
      return;
    }
    final worker = workerFactory();
    _worker = worker;
    _subscription = worker.events.listen(_onEvent);
    try {
      await worker.start();
    } catch (error) {
      _worker = null;
      await _subscription?.cancel();
      _subscription = null;
      throw OcrException(OcrErrorCode.workerCrash, error.toString());
    }
  }

  Future<void> _restartWorker() async {
    await _subscription?.cancel();
    _subscription = null;
    await _worker?.dispose();
    _worker = null;
    _engineLoaded = false;
  }

  void _onEvent(WorkerEvent event) {
    if (_disposed) {
      return;
    }

    if (event is LoadingEvent) {
      _progress = OcrProgress(stage: 'load', fraction: event.fraction);
      if (event.fraction >= 1.0) {
        _engineLoaded = true;
        if (_state == OcrServiceState.loading) {
          _state = OcrServiceState.ready;
        }
        _completeLoad();
      }
      _notify();
      return;
    }

    if (event is ProgressEvent) {
      _progress = event.progress;
      _notify();
      return;
    }

    if (event is TokenEvent) {
      _partialText += event.text;
      final now = DateTime.now();
      if (now.difference(_lastTokenNotify).inMilliseconds >= 200) {
        _lastTokenNotify = now;
        _notify();
      }
      return;
    }

    if (event is DoneEvent) {
      _result = event.result;
      _partialText = event.result.text;
      _error = null;
      _progress = null;
      _state = OcrServiceState.ready;
      _completeRun();
      _notify();
      return;
    }

    if (event is FailedEvent) {
      if (event.code == OcrErrorCode.cancelled) {
        _state = OcrServiceState.ready;
        _partialText = '';
        _progress = null;
        _error = null;
      } else {
        _error = OcrException(event.code, event.message);
        _state = OcrServiceState.failed;
        if (event.code == OcrErrorCode.workerCrash) {
          _engineLoaded = false;
          final worker = _worker;
          _worker = null;
          _subscription?.cancel();
          _subscription = null;
          if (worker != null) {
            unawaited(worker.dispose());
          }
        }
      }
      _completeLoad();
      _completeRun();
      _notify();
    }
  }

  void _completeLoad() {
    final completer = _loadCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _completeRun() {
    final completer = _runCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _subscription = null;
    final worker = _worker;
    _worker = null;
    if (worker != null) {
      unawaited(worker.dispose());
    }
    super.dispose();
  }
}
