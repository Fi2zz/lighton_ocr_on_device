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

  DateTime? _runStartedAt;
  final Map<String, Duration> _stageTimings = {};
  String? _activeStage;
  DateTime? _activeStageStartedAt;
  DateTime? _loadStartedAt;
  Duration? _loadDuration;
  Timer? _ticker;

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

  /// Current stage of the OCR run, including the implicit prefill phase.
  String? get activeStage => _activeStage;

  /// Wall-clock time since the current run started.
  Duration get runElapsed {
    final startedAt = _runStartedAt;
    return startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
  }

  /// Completed or currently running time for [stage].
  ///
  /// Returns null when the stage has not been reached yet.
  Duration? stageTiming(String stage) {
    if (_activeStage == stage && _activeStageStartedAt != null) {
      return DateTime.now().difference(_activeStageStartedAt!);
    }
    return _stageTimings[stage];
  }

  /// Time spent loading the model, live while loading.
  Duration? get loadElapsed {
    if (_state == OcrServiceState.loading && _loadStartedAt != null) {
      return DateTime.now().difference(_loadStartedAt!);
    }
    return _loadDuration;
  }

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
    _loadStartedAt = DateTime.now();
    _loadDuration = null;
    _startTicker();
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
      _stopTicker();
      final loadStartedAt = _loadStartedAt;
      if (loadStartedAt != null) {
        _loadDuration = DateTime.now().difference(loadStartedAt);
      }
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

    _progress = const OcrProgress(stage: 'preprocess', fraction: 0);
    _startRunTimings();
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
      _finishRunTimings();
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
      _finishRunTimings();
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
    _stopTicker();
    _resetRunTimings();
    _loadStartedAt = null;
    _loadDuration = null;
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
        final loadStartedAt = _loadStartedAt;
        if (loadStartedAt != null) {
          _loadDuration = DateTime.now().difference(loadStartedAt);
        }
        _stopTicker();
        if (_state == OcrServiceState.loading) {
          _state = OcrServiceState.ready;
        }
        _completeLoad();
      }
      _notify();
      return;
    }

    if (event is ProgressEvent) {
      _recordProgress(event.progress);
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
      _finishRunTimings();
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
      _finishRunTimings();
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

  void _startTicker() {
    if (_ticker != null) {
      return;
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_disposed) {
        return;
      }
      if (_state == OcrServiceState.running ||
          _state == OcrServiceState.cancelling ||
          _state == OcrServiceState.loading) {
        _notify();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _resetRunTimings() {
    _runStartedAt = null;
    _stageTimings.clear();
    _activeStage = null;
    _activeStageStartedAt = null;
  }

  void _startRunTimings() {
    _resetRunTimings();
    _runStartedAt = DateTime.now();
    _startTicker();
  }

  void _finishRunTimings() {
    _finishActiveStage();
    _stopTicker();
  }

  void _recordProgress(OcrProgress progress) {
    if (_activeStage != progress.stage) {
      _finishActiveStage();
      _beginStage(progress.stage);
    }
    if (progress.fraction < 1.0) {
      return;
    }

    // The native shim has no explicit prefill event. The image embedding
    // prefill starts right after encode completes and ends when decode starts.
    if (progress.stage == 'encode') {
      _finishActiveStage();
      _beginStage('prefill');
    } else {
      _finishActiveStage();
    }
  }

  void _beginStage(String stage) {
    _activeStage = stage;
    _activeStageStartedAt = DateTime.now();
  }

  void _finishActiveStage() {
    final stage = _activeStage;
    final startedAt = _activeStageStartedAt;
    if (stage != null && startedAt != null) {
      _stageTimings[stage] = DateTime.now().difference(startedAt);
    }
    _activeStage = null;
    _activeStageStartedAt = null;
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
    _stopTicker();
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
