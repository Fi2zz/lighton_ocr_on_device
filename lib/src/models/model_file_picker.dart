import 'dart:io';

import 'package:file_picker/file_picker.dart';

abstract class ModelFilePicker {
  Future<File?> pickGgufFile();
}

class DeviceModelFilePicker implements ModelFilePicker {
  @override
  Future<File?> pickGgufFile() async {
    final result = await FilePicker.pickFile(type: FileType.any);
    final path = result?.path;
    return path == null ? null : File(path);
  }
}
