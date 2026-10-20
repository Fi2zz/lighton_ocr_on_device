import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

abstract class ImageSourceService {
  Future<Uint8List?> pickFromGallery();
  Future<Uint8List?> takePhoto();
}

class DeviceImageSourceService implements ImageSourceService {
  final ImagePicker _picker = ImagePicker();

  @override
  Future<Uint8List?> pickFromGallery() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    return file?.readAsBytes();
  }

  @override
  Future<Uint8List?> takePhoto() async {
    final file = await _picker.pickImage(source: ImageSource.camera);
    return file?.readAsBytes();
  }
}
