import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../image/image_source.dart';
import '../models/model_file_picker.dart';
import '../models/model_store.dart';
import '../ocr/error_messages.dart';
import '../ocr/ocr_service.dart';
import '../ocr/ocr_types.dart';
import 'model_setup_page.dart';
import 'result_page.dart';
import 'widgets/model_status_card.dart';

class HomePage extends StatefulWidget {
  final OcrService service;
  final ModelStore store;
  final ImageSourceService imageSource;

  const HomePage({
    super.key,
    required this.service,
    required this.store,
    required this.imageSource,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Uint8List? _imageBytes;

  Future<void> _pick(Future<Uint8List?> Function() picker) async {
    final bytes = await picker();
    if (bytes == null || !mounted) {
      return;
    }
    setState(() => _imageBytes = bytes);
  }

  Future<void> _openSetup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ModelSetupPage(
          store: widget.store,
          picker: DeviceModelFilePicker(),
          service: widget.service,
        ),
      ),
    );
    await widget.service.initialize();
  }

  Future<void> _run() async {
    if (_imageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择一张图片')),
      );
      return;
    }
    if (!widget.service.isModelConfigured) {
      await _openSetup();
      return;
    }

    unawaited(WakelockPlus.enable().catchError((_) {}));

    await widget.service.recognize(encodedImage: _imageBytes!);
    unawaited(WakelockPlus.disable().catchError((_) {}));

    if (!mounted) {
      return;
    }
    if (widget.service.state != OcrServiceState.ready) {
      return;
    }
    final result = widget.service.result;
    if (result == null) {
      return;
    }

    final again = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ResultPage(result: result, imageBytes: _imageBytes),
      ),
    );
    if (!mounted) {
      return;
    }
    if (again == false) {
      setState(() => _imageBytes = null);
    } else if (again == true) {
      await _run();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LightOnOCR · 端侧'),
        actions: [
          IconButton(
            tooltip: '模型配置',
            onPressed: _openSetup,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.service,
        builder: (context, _) {
          final service = widget.service;
          final state = service.state;
          final running = state == OcrServiceState.running ||
              state == OcrServiceState.cancelling;
          final loading = state == OcrServiceState.loading;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              ModelStatusCard(
                service: service,
                onConfigure: _openSetup,
              ),
              const SizedBox(height: 16),
              _imageCard(context),
              const SizedBox(height: 16),
              _optionsCard(context),
              const SizedBox(height: 16),
              if (loading || running) ...[
                _progressCard(context, service),
                const SizedBox(height: 16),
              ],
              if (service.error != null) ...[
                _errorCard(context, service.error!),
                const SizedBox(height: 16),
              ],
              _primaryButton(context, state, running, loading),
              const SizedBox(height: 24),
              Text(
                '模型在设备本地运行，图片不会上传。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _imageCard(BuildContext context) {
    if (_imageBytes == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(
                Icons.document_scanner_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              const Text('选择要识别的图片'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _pick(widget.imageSource.takePhoto),
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('拍照'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () =>
                        _pick(widget.imageSource.pickFromGallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('相册'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Image.memory(_imageBytes!, fit: BoxFit.contain),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _pick(widget.imageSource.pickFromGallery),
                child: const Text('重新选择'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _optionsCard(BuildContext context) {
    final config = widget.service.config;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: config.longestEdge,
                decoration: const InputDecoration(labelText: '长边'),
                items: const [
                  DropdownMenuItem(value: 1024, child: Text('1024')),
                  DropdownMenuItem(value: 1280, child: Text('1280')),
                  DropdownMenuItem(value: 1536, child: Text('1536')),
                  DropdownMenuItem(value: 2048, child: Text('2048')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    unawaited(widget.service.updateConfig(
                      config.copyWith(longestEdge: value),
                    ));
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: config.maxTokens,
                decoration: const InputDecoration(labelText: '最大输出'),
                items: const [
                  DropdownMenuItem(value: 2048, child: Text('2048')),
                  DropdownMenuItem(value: 4096, child: Text('4096')),
                  DropdownMenuItem(value: 8192, child: Text('8192')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    unawaited(widget.service.updateConfig(
                      config.copyWith(maxTokens: value),
                    ));
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard(BuildContext context, OcrService service) {
    final progress = service.progress;
    final fraction = progress?.fraction;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(progress?.stage ?? '准备中'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: fraction),
            if (service.partialText.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('已生成 ${service.partialText.length} 字符'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _errorCard(BuildContext context, OcrException error) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ocrErrorMessage(error),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
            if (error.message.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('查看详情'),
                children: [
                  SelectableText('${error.code}: ${error.message}'),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _primaryButton(
    BuildContext context,
    OcrServiceState state,
    bool running,
    bool loading,
  ) {
    if (state == OcrServiceState.unconfigured) {
      return FilledButton(
        onPressed: _openSetup,
        child: const Text('配置模型'),
      );
    }
    if (running) {
      return FilledButton.tonal(
        onPressed: () => widget.service.cancel(),
        child: Text(
          state == OcrServiceState.cancelling ? '取消中…' : '取消',
        ),
      );
    }
    return FilledButton(
      onPressed: loading || _imageBytes == null ? null : _run,
      child: Text(loading ? '模型加载中…' : '开始识别'),
    );
  }
}
