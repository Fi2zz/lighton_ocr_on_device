import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/models/gguf_probe.dart';
import 'package:path/path.dart' as p;

Future<File> _file(Directory dir, String name, String content) {
  final file = File(p.join(dir.path, name));
  return file.writeAsString(content);
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gguf_probe_test');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('detects main model', () async {
    final file = await _file(
      temp,
      'main.gguf',
      'GGUFgeneral.architectureqwen35',
    );
    expect(await GgufProbe.detect(file), GgufKind.main);
  });

  test('detects mmproj', () async {
    final file = await _file(
      temp,
      'mmproj.gguf',
      'GGUFclip.projector_typeqwen3vl_merger',
    );
    expect(await GgufProbe.detect(file), GgufKind.mmproj);
  });

  test('rejects non-gguf', () async {
    final file = await _file(temp, 'bad.bin', 'not a gguf');
    expect(await GgufProbe.detect(file), GgufKind.unknown);
  });

  test('magic check needs four bytes', () {
    expect(GgufProbe.hasGgufMagic(Uint8List.fromList(utf8.encode('GGUF'))), isTrue);
    expect(GgufProbe.hasGgufMagic(Uint8List.fromList(utf8.encode('GUF'))), isFalse);
  });
}
