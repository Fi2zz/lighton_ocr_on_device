import 'package:flutter/material.dart';

import 'src/models/model_file_picker.dart';
import 'src/models/model_store.dart';
import 'src/ocr/ocr_service.dart';
import 'src/ui/model_setup_page.dart';

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
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('LightOnOCR · 端侧')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.document_scanner, size: 56),
                const SizedBox(height: 12),
                const Text('先配置模型，再开始识别'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ModelSetupPage(
                          store: store,
                          picker: DeviceModelFilePicker(),
                          service: service,
                        ),
                      ),
                    );
                  },
                  child: const Text('模型配置'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
