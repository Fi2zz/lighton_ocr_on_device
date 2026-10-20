import 'package:flutter/material.dart';

import '../../ocr/ocr_service.dart';

class ModelStatusCard extends StatelessWidget {
  final OcrService service;
  final VoidCallback onConfigure;

  const ModelStatusCard({
    super.key,
    required this.service,
    required this.onConfigure,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final info = service.modelInfo;
        final state = service.state;

        final (label, color) = switch (state) {
          OcrServiceState.unconfigured => ('未配置', Colors.orange),
          OcrServiceState.loading => ('加载中', Colors.blue),
          OcrServiceState.ready => ('已就绪', Colors.green),
          OcrServiceState.running => ('识别中', Colors.blue),
          OcrServiceState.cancelling => ('取消中', Colors.orange),
          OcrServiceState.failed => ('异常', Colors.red),
        };

        final subtitle = info == null
            ? '请导入主模型与 mmproj'
            : '${_formatBytes(info.totalBytes)} · $label';

        return Card(
          child: ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('LightOnOCR-3-0.8B'),
            subtitle: Text(subtitle),
            trailing: TextButton(
              onPressed: onConfigure,
              child: Text(info == null ? '配置模型' : '设置'),
            ),
          ),
        );
      },
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
