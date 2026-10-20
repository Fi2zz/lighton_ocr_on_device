import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ocr/ocr_types.dart';
import 'gguf_probe.dart';

class ModelInfo {
  final File main;
  final File mmproj;

  const ModelInfo({required this.main, required this.mmproj});

  int get totalBytes => _length(main) + _length(mmproj);

  static int _length(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }
}

abstract class ModelRepository {
  Future<ModelInfo?> load();
  Future<OcrConfig> loadConfig();
  Future<void> saveConfig(OcrConfig config);
  Future<void> deleteAll();
}

class ModelStore implements ModelRepository {
  static const String mainFileName = 'lightonocr3-0.8b.gguf';
  static const String mmprojFileName = 'mmproj-lightonocr3-0.8b.gguf';

  final Directory root;
  final int minMainBytes;
  final int minMmprojBytes;

  ModelStore({
    required this.root,
    this.minMainBytes = 300 * 1024 * 1024,
    this.minMmprojBytes = 50 * 1024 * 1024,
  });

  Directory get _modelsDir => Directory(p.join(root.path, 'models'));
  File get _mainFile => File(p.join(_modelsDir.path, mainFileName));
  File get _mmprojFile => File(p.join(_modelsDir.path, mmprojFileName));
  File get _configFile => File(p.join(_modelsDir.path, 'config.json'));

  File get mainFile => _mainFile;
  File get mmprojFile => _mmprojFile;

  @override
  Future<ModelInfo?> load() async {
    if (!await _mainFile.exists() || !await _mmprojFile.exists()) {
      return null;
    }
    if (await _mainFile.length() < minMainBytes ||
        await _mmprojFile.length() < minMmprojBytes) {
      return null;
    }
    return ModelInfo(main: _mainFile, mmproj: _mmprojFile);
  }

  @override
  Future<OcrConfig> loadConfig() async {
    try {
      if (!await _configFile.exists()) {
        return OcrConfig.forDevice();
      }
      final decoded = jsonDecode(await _configFile.readAsString());
      if (decoded is Map<String, Object?>) {
        return OcrConfig.fromJson(decoded);
      }
      if (decoded is Map) {
        return OcrConfig.fromJson(decoded.cast<String, Object?>());
      }
      return OcrConfig.forDevice();
    } on FormatException {
      return OcrConfig.forDevice();
    } on FileSystemException {
      return OcrConfig.forDevice();
    }
  }

  @override
  Future<void> saveConfig(OcrConfig config) async {
    await _modelsDir.create(recursive: true);
    await _configFile.writeAsString(jsonEncode(config.toJson()));
  }

  Future<void> importMain(
    File source, {
    void Function(double progress)? onProgress,
  }) {
    return _import(
      source: source,
      target: _mainFile,
      expected: GgufKind.main,
      minBytes: minMainBytes,
      onProgress: onProgress,
    );
  }

  Future<void> importMmproj(
    File source, {
    void Function(double progress)? onProgress,
  }) {
    return _import(
      source: source,
      target: _mmprojFile,
      expected: GgufKind.mmproj,
      minBytes: minMmprojBytes,
      onProgress: onProgress,
    );
  }

  Future<void> _import({
    required File source,
    required File target,
    required GgufKind expected,
    required int minBytes,
    void Function(double progress)? onProgress,
  }) async {
    if (!await source.exists()) {
      throw const OcrException(
        OcrErrorCode.ggufInvalid,
        'source file does not exist',
      );
    }

    final kind = await GgufProbe.detect(source);
    if (kind != expected) {
      throw OcrException(
        OcrErrorCode.ggufInvalid,
        expected == GgufKind.main
            ? 'not a LightOnOCR main model'
            : 'not a LightOnOCR mmproj',
      );
    }

    final total = await source.length();
    if (total < minBytes) {
      throw const OcrException(
        OcrErrorCode.ggufInvalid,
        'model file is too small',
      );
    }

    if (p.equals(p.absolute(source.path), p.absolute(target.path))) {
      onProgress?.call(1.0);
      return;
    }

    await _modelsDir.create(recursive: true);
    final part = File('${target.path}.part');
    if (await part.exists()) {
      await part.delete();
    }

    IOSink? sink;
    try {
      sink = part.openWrite();
      var written = 0;
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(total == 0 ? 1.0 : written / total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (await target.exists()) {
        await target.delete();
      }
      await part.rename(target.path);
      onProgress?.call(1.0);
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {
        // Ignore close errors while cleaning up a failed import.
      }
      try {
        if (await part.exists()) {
          await part.delete();
        }
      } catch (_) {
        // Ignore cleanup errors; the original failure is more useful.
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteAll() async {
    if (await _modelsDir.exists()) {
      await _modelsDir.delete(recursive: true);
    }
  }
}
