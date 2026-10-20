import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lighton_ocr_on_device/src/image/image_preprocess.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';

Uint8List _png(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('landscape image keeps aspect ratio and max edge', () async {
    final result = await prepareImage(_png(4000, 2000), longestEdge: 2048);
    expect(result.width, 2048);
    expect(result.height, 1024);
    expect(result.rgb.length, 2048 * 1024 * 3);
  });

  test('portrait image keeps aspect ratio and max edge', () async {
    final result = await prepareImage(_png(2000, 4000), longestEdge: 2048);
    expect(result.width, 1024);
    expect(result.height, 2048);
    expect(result.rgb.length, 1024 * 2048 * 3);
  });

  test('small image is not upscaled', () async {
    final result = await prepareImage(_png(400, 200), longestEdge: 2048);
    expect(result.width, 400);
    expect(result.height, 200);
  });

  test('EXIF orientation is applied before resizing', () async {
    final result = await prepareImage(
      File('test/fixtures/exif_orientation_6.jpg').readAsBytesSync(),
      longestEdge: 2048,
    );
    expect(result.width, 400);
    expect(result.height, 200);
  });

  test('undecodable bytes throw E_ENCODE', () async {
    try {
      await prepareImage(Uint8List.fromList([1, 2, 3, 4, 5]));
      fail('expected OcrException');
    } on OcrException catch (error) {
      expect(error.code, 'E_ENCODE');
    }
  });
}
