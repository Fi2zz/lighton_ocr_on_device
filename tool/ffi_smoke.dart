import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lighton_ocr_on_device/src/ocr/ocr_ffi.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';

void main(List<String> args) {
  final path = Platform.environment['OCR_SHIM_LIB'] ??
      'build/ocr_cli/ocr_shim/libocrshim.dylib';
  final ffi = OcrFfi.open(libraryPath: path);
  final size = ffi.statsSize();
  stdout.writeln('stats_size=$size');
  if (size != 56) {
    exitCode = 1;
    return;
  }

  if (!args.contains('--run')) {
    return;
  }

  final ppm = _readPpm('build/eval/report-1-2048.ppm');
  final engine = ffi.create(
    modelPath: 'build-models/lightonocr3-0.8b-Q8_0.gguf',
    mmprojPath: 'build-models/mmproj-lightonocr3-0.8b-f16.gguf',
    config: OcrConfig.forDevice(),
  );

  final text = StringBuffer();
  try {
    final stats = ffi.run(
      engine: engine,
      rgb: ppm.rgb,
      width: ppm.width,
      height: ppm.height,
      mode: OcrMode.grounding,
      maxTokens: 32,
      onToken: text.write,
    );
    stdout.writeln('text_len=${text.length}');
    stdout.writeln(
      'stats=${stats.promptTokens}/${stats.outputTokens}/${stats.imageTokens} '
      'encode=${stats.encodeMs.toStringAsFixed(0)}ms '
      'decode=${stats.decodeMs.toStringAsFixed(0)}ms',
    );
  } finally {
    ffi.destroy(engine);
  }
}

class _Ppm {
  _Ppm(this.width, this.height, this.rgb);
  final int width;
  final int height;
  final Uint8List rgb;
}

_Ppm _readPpm(String path) {
  final bytes = File(path).readAsBytesSync();
  var i = 0;

  bool isSpace(int byte) =>
      byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09;

  String next() {
    while (i < bytes.length && isSpace(bytes[i])) {
      i++;
    }
    final start = i;
    while (i < bytes.length && !isSpace(bytes[i])) {
      i++;
    }
    return ascii.decode(bytes.sublist(start, i));
  }

  final magic = next();
  final width = int.parse(next());
  final height = int.parse(next());
  final maxValue = int.parse(next());
  if (magic != 'P6' || maxValue != 255) {
    throw StateError('unsupported PPM header');
  }
  i++; // exactly one separator before the raster
  final expected = width * height * 3;
  final rgb = bytes.sublist(i, i + expected);
  return _Ppm(width, height, rgb);
}
