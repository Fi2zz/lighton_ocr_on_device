import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../ocr/ocr_types.dart';

class PreparedImage {
  final Uint8List rgb;
  final int width;
  final int height;

  const PreparedImage({
    required this.rgb,
    required this.width,
    required this.height,
  });
}

Future<PreparedImage> prepareImage(
  Uint8List encoded, {
  int longestEdge = 2048,
}) async {
  if (longestEdge <= 0) {
    throw const OcrException(OcrErrorCode.encode, 'invalid longest edge');
  }

  final decoded = img.decodeImage(encoded);
  if (decoded == null) {
    throw const OcrException(OcrErrorCode.encode, 'failed to decode image');
  }

  final oriented = img.bakeOrientation(decoded);
  final target = _fit(oriented.width, oriented.height, longestEdge);
  final resized = target.width == oriented.width && target.height == oriented.height
      ? oriented
      : img.copyResize(
          oriented,
          width: target.width,
          height: target.height,
          interpolation: img.Interpolation.average,
        );

  final rgb = resized.getBytes(order: img.ChannelOrder.rgb);
  return PreparedImage(rgb: rgb, width: resized.width, height: resized.height);
}

({int width, int height}) _fit(int width, int height, int longestEdge) {
  final maxEdge = math.max(width, height);
  if (maxEdge <= longestEdge) {
    return (width: width, height: height);
  }
  final scale = longestEdge / maxEdge;
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}
