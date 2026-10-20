import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/models/model_store.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';
import 'package:path/path.dart' as p;

Future<File> _fakeGguf(
  Directory dir,
  String name,
  String marker, {
  int size = 2048,
}) async {
  final bytes = Uint8List(size);
  final header = utf8.encode('GGUF$marker');
  bytes.setAll(0, header);
  final file = File(p.join(dir.path, name));
  return file.writeAsBytes(bytes);
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('model_store_test');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ModelStore store() => ModelStore(
        root: temp,
        minMainBytes: 1024,
        minMmprojBytes: 512,
      );

  test('imports both files with progress', () async {
    final main = await _fakeGguf(temp, 'source-main.gguf', 'qwen35');
    final mmproj = await _fakeGguf(temp, 'source-mmproj.gguf', 'clip.');

    final progress = <double>[];
    final s = store();
    await s.importMain(main, onProgress: progress.add);
    await s.importMmproj(mmproj, onProgress: progress.add);

    final info = await s.load();
    expect(info, isNotNull);
    expect(info!.main.path, endsWith('lightonocr3-0.8b.gguf'));
    expect(info.mmproj.path, endsWith('mmproj-lightonocr3-0.8b.gguf'));
    expect(info.totalBytes, greaterThan(0));
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
  });

  test('rejects invalid magic and leaves no part file', () async {
    final bad = await _fakeGguf(temp, 'bad.gguf', 'nope');
    final s = store();

    await expectLater(
      s.importMain(bad),
      throwsA(isA<OcrException>().having((e) => e.code, 'code', 'E_GGUF_INVALID')),
    );
    expect(await s.load(), isNull);

    final modelsDir = Directory(p.join(temp.path, 'models'));
    if (await modelsDir.exists()) {
      final leftover = modelsDir
          .listSync()
          .where((entry) => entry.path.endsWith('.part'));
      expect(leftover, isEmpty);
    }
  });

  test('rejects files below size threshold', () async {
    final small = await _fakeGguf(temp, 'small.gguf', 'qwen35', size: 64);
    final s = store();
    await expectLater(
      s.importMain(small),
      throwsA(isA<OcrException>().having((e) => e.code, 'code', 'E_GGUF_INVALID')),
    );
  });

  test('config round trip', () async {
    final s = store();
    const config = OcrConfig(
      longestEdge: 1536,
      maxTokens: 2048,
      nThreads: 4,
      seed: 7,
    );
    await s.saveConfig(config);
    final loaded = await s.loadConfig();
    expect(loaded.toJson(), config.toJson());
  });

  test('corrupt config falls back to defaults', () async {
    final configFile = File(p.join(temp.path, 'models', 'config.json'));
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString('{not json');

    final loaded = await store().loadConfig();
    expect(loaded.longestEdge, 2048);
    expect(loaded.maxTokens, 4096);
  });

  test('deleteAll removes files and config', () async {
    final main = await _fakeGguf(temp, 'source-main.gguf', 'qwen35');
    final mmproj = await _fakeGguf(temp, 'source-mmproj.gguf', 'clip.');
    final s = store();
    await s.importMain(main);
    await s.importMmproj(mmproj);
    await s.saveConfig(const OcrConfig());

    await s.deleteAll();
    expect(await s.load(), isNull);
  });
}
