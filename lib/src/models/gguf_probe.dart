import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

enum GgufKind { main, mmproj, unknown }

class GgufProbe {
  static const int _maxProbeBytes = 4 * 1024 * 1024;

  static bool hasGgufMagic(Uint8List head) {
    return head.length >= 4 &&
        head[0] == 0x47 &&
        head[1] == 0x47 &&
        head[2] == 0x55 &&
        head[3] == 0x46;
  }

  static Future<GgufKind> detect(File file) async {
    if (!await file.exists()) {
      return GgufKind.unknown;
    }

    final length = await file.length();
    if (length < 4) {
      return GgufKind.unknown;
    }

    final RandomAccessFile raf = await file.open();
    try {
      final toRead = math.min(length, _maxProbeBytes);
      final bytes = await raf.read(toRead);
      if (!hasGgufMagic(bytes)) {
        return GgufKind.unknown;
      }

      final text = latin1.decode(bytes, allowInvalid: true);
      final isMmproj = text.contains('clip.') || text.contains('qwen3vl');
      if (isMmproj) {
        return GgufKind.mmproj;
      }
      final isMain =
          text.contains('qwen35') || text.contains('general.architecture');
      if (isMain) {
        return GgufKind.main;
      }
      return GgufKind.unknown;
    } finally {
      await raf.close();
    }
  }
}
