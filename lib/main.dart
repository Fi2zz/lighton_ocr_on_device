import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'src/models/model_store.dart';
import 'src/ocr/ocr_service.dart';
import 'src/ocr/ocr_worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final root = await getApplicationSupportDirectory();
  final store = ModelStore(root: root);
  final service = OcrService(
    modelStore: store,
    workerFactory: IsolateOcrWorker.new,
  );
  await service.initialize();

  runApp(LightOnOcrApp(service: service, store: store));
}
