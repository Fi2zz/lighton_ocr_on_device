import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ocr_types.dart';

final class OcrEngine extends Opaque {}

final class OcrStatsNative extends Struct {
  @Int32()
  external int promptTokens;

  @Int32()
  external int outputTokens;

  @Int32()
  external int imageTokens;

  @Int32()
  external int pad;

  @Double()
  external double loadMs;

  @Double()
  external double encodeMs;

  @Double()
  external double prefillMs;

  @Double()
  external double decodeMs;

  @Int64()
  external int peakRssKb;
}

typedef OcrTokenNative = Void Function(Pointer<Uint8>, Int32, Pointer<Void>);
typedef OcrProgressNative = Void Function(Pointer<Utf8>, Float, Pointer<Void>);

typedef OcrTokenCallback = void Function(String text);
typedef OcrProgressCallback = void Function(OcrProgress progress);

typedef _OcrCreateNative = Pointer<OcrEngine> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Int32,
  Int32,
  Pointer<NativeFunction<OcrProgressNative>>,
  Pointer<Void>,
  Pointer<Uint8>,
  Size,
);

typedef _OcrCreateDart = Pointer<OcrEngine> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  int,
  int,
  Pointer<NativeFunction<OcrProgressNative>>,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
);

typedef _OcrRunNative = Int32 Function(
  Pointer<OcrEngine>,
  Pointer<Uint8>,
  Int32,
  Int32,
  Pointer<Utf8>,
  Int32,
  Float,
  Uint32,
  Pointer<NativeFunction<OcrTokenNative>>,
  Pointer<NativeFunction<OcrProgressNative>>,
  Pointer<Void>,
  Pointer<OcrStatsNative>,
  Pointer<Uint8>,
  Size,
);

typedef _OcrRunDart = int Function(
  Pointer<OcrEngine>,
  Pointer<Uint8>,
  int,
  int,
  Pointer<Utf8>,
  int,
  double,
  int,
  Pointer<NativeFunction<OcrTokenNative>>,
  Pointer<NativeFunction<OcrProgressNative>>,
  Pointer<Void>,
  Pointer<OcrStatsNative>,
  Pointer<Uint8>,
  int,
);

typedef _OcrCancelNative = Void Function(Pointer<OcrEngine>);
typedef _OcrCancelDart = void Function(Pointer<OcrEngine>);

typedef _OcrDestroyNative = Void Function(Pointer<OcrEngine>);
typedef _OcrDestroyDart = void Function(Pointer<OcrEngine>);

typedef _OcrStatsSizeNative = Size Function();
typedef _OcrStatsSizeDart = int Function();

class OcrFfi {
  static const int _errorBufferSize = 1024;

  static final Pointer<NativeFunction<OcrTokenNative>> _nullToken =
      Pointer<NativeFunction<OcrTokenNative>>.fromAddress(0);
  static final Pointer<NativeFunction<OcrProgressNative>> _nullProgress =
      Pointer<NativeFunction<OcrProgressNative>>.fromAddress(0);

  final DynamicLibrary _lib;
  late final _OcrCreateDart _create =
      _lib.lookupFunction<_OcrCreateNative, _OcrCreateDart>('ocr_create');
  late final _OcrRunDart _run =
      _lib.lookupFunction<_OcrRunNative, _OcrRunDart>('ocr_run');
  late final _OcrCancelDart _cancel =
      _lib.lookupFunction<_OcrCancelNative, _OcrCancelDart>('ocr_cancel');
  late final _OcrDestroyDart _destroy =
      _lib.lookupFunction<_OcrDestroyNative, _OcrDestroyDart>('ocr_destroy');
  late final _OcrStatsSizeDart _statsSize =
      _lib.lookupFunction<_OcrStatsSizeNative, _OcrStatsSizeDart>('ocr_stats_size');

  OcrFfi._(this._lib);

  factory OcrFfi.open({String? libraryPath}) {
    final path = libraryPath ??
        (Platform.isAndroid ? 'libocrshim.so' : 'libocrshim.dylib');
    final ffi = OcrFfi._(DynamicLibrary.open(path));
    final expected = sizeOf<OcrStatsNative>();
    final actual = ffi.statsSize();
    if (actual != expected) {
      throw StateError(
        'ocr_stats ABI mismatch: dart=$expected native=$actual',
      );
    }
    return ffi;
  }

  int statsSize() => _statsSize();

  Pointer<OcrEngine> create({
    required String modelPath,
    required String mmprojPath,
    required OcrConfig config,
    OcrProgressCallback? onProgress,
  }) {
    final model = modelPath.toNativeUtf8();
    final mmproj = mmprojPath.toNativeUtf8();
    final error = calloc<Uint8>(_errorBufferSize);
    NativeCallable<OcrProgressNative>? progressCallable;

    try {
      if (onProgress != null) {
        progressCallable = NativeCallable<OcrProgressNative>.isolateLocal(
          (Pointer<Utf8> stage, double fraction, Pointer<Void> _) {
            onProgress(
              OcrProgress(stage: stage.toDartString(), fraction: fraction),
            );
          },
        );
      }

      final engine = _create(
        model,
        mmproj,
        config.nThreads,
        config.nCtx,
        config.nBatch,
        config.imageMaxTokens,
        progressCallable?.nativeFunction ?? _nullProgress,
        nullptr,
        error,
        _errorBufferSize,
      );
      if (engine == nullptr) {
        throw _readError(error);
      }
      return engine;
    } finally {
      progressCallable?.close();
      malloc.free(model);
      malloc.free(mmproj);
      calloc.free(error);
    }
  }

  OcrStats run({
    required Pointer<OcrEngine> engine,
    required Uint8List rgb,
    required int width,
    required int height,
    required OcrMode mode,
    required int maxTokens,
    double temperature = 0.2,
    int seed = 42,
    OcrTokenCallback? onToken,
    OcrProgressCallback? onProgress,
  }) {
    final rgbPtr = malloc<Uint8>(rgb.length);
    rgbPtr.asTypedList(rgb.length).setAll(0, rgb);
    final modePtr = mode.name.toNativeUtf8();
    final error = calloc<Uint8>(_errorBufferSize);
    final stats = calloc<OcrStatsNative>();
    NativeCallable<OcrTokenNative>? tokenCallable;
    NativeCallable<OcrProgressNative>? progressCallable;

    try {
      if (onToken != null) {
        tokenCallable = NativeCallable<OcrTokenNative>.isolateLocal(
          (Pointer<Uint8> data, int len, Pointer<Void> _) {
            if (len > 0) {
              onToken(utf8.decode(data.asTypedList(len)));
            }
          },
        );
      }
      if (onProgress != null) {
        progressCallable = NativeCallable<OcrProgressNative>.isolateLocal(
          (Pointer<Utf8> stage, double fraction, Pointer<Void> _) {
            onProgress(
              OcrProgress(stage: stage.toDartString(), fraction: fraction),
            );
          },
        );
      }

      final rc = _run(
        engine,
        rgbPtr,
        width,
        height,
        modePtr,
        maxTokens,
        temperature,
        seed,
        tokenCallable?.nativeFunction ?? _nullToken,
        progressCallable?.nativeFunction ?? _nullProgress,
        nullptr,
        stats,
        error,
        _errorBufferSize,
      );
      if (rc != 0) {
        throw _readError(error);
      }

      final native = stats.ref;
      return OcrStats(
        promptTokens: native.promptTokens,
        outputTokens: native.outputTokens,
        imageTokens: native.imageTokens,
        loadMs: native.loadMs,
        encodeMs: native.encodeMs,
        prefillMs: native.prefillMs,
        decodeMs: native.decodeMs,
        peakRssKb: native.peakRssKb,
      );
    } finally {
      tokenCallable?.close();
      progressCallable?.close();
      malloc.free(rgbPtr);
      malloc.free(modePtr);
      calloc.free(error);
      calloc.free(stats);
    }
  }

  void cancel(Pointer<OcrEngine> engine) => _cancel(engine);

  void destroy(Pointer<OcrEngine> engine) => _destroy(engine);

  OcrException _readError(Pointer<Uint8> error) {
    final message = error.cast<Utf8>().toDartString();
    final index = message.indexOf(':');
    if (index > 0) {
      return OcrException(
        message.substring(0, index),
        message.substring(index + 1).trim(),
      );
    }
    return OcrException(
      OcrErrorCode.load,
      message.isEmpty ? 'unknown native error' : message,
    );
  }
}
