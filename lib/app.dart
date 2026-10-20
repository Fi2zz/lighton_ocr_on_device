import 'package:flutter/material.dart';

import 'src/image/image_source.dart';
import 'src/models/model_store.dart';
import 'src/ocr/ocr_service.dart';
import 'src/ui/home_page.dart';

class LightOnOcrApp extends StatelessWidget {
  final OcrService service;
  final ModelStore store;

  const LightOnOcrApp({
    super.key,
    required this.service,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LightOnOCR',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F6F6B),
        ),
      ),
      home: HomePage(
        service: service,
        store: store,
        imageSource: DeviceImageSourceService(),
      ),
    );
  }
}
