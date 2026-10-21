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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          ModelStatusCard(
            service: widget.service,
            onConfigure: _openSetup,
          ),
          const SizedBox(height: 16),
          _imageCard(context),
          const SizedBox(height: 16),
          _optionsCard(context),
          ListenableBuilder(
            listenable: widget.service,
            builder: (context, _) {
              final service = widget.service;
              final state = service.state;
              final running = state == OcrServiceState.running ||
                  state == OcrServiceState.cancelling;
              final loading = state == OcrServiceState.loading;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (loading || running) ...[
                    const SizedBox(height: 16),
                    _progressCard(context, service),
                  ],
                  if (service.error != null) ...[
                    const SizedBox(height: 16),
                    _errorCard(context, service.error!),
                  ],
                  const SizedBox(height: 16),
                  _primaryButton(context, state, running, loading),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            '模型在设备本地运行，图片不会上传。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
    final loading = service.state == OcrServiceState.loading;
    final elapsed = loading ? service.loadElapsed : service.runElapsed;
    final stage = service.activeStage ?? progress?.stage;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _stageLabel(stage),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  elapsed == null ? '' : _formatDuration(elapsed),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 12),
            if (loading)
              _timingRow(
                context,
                '模型加载',
                service.loadElapsed,
                active: true,
              )
            else ...[
              _timingRow(
                context,
                '图像预处理',
                service.stageTiming('preprocess'),
                active: service.activeStage == 'preprocess',
              ),
              _timingRow(
                context,
                '图像编码',
                service.stageTiming('encode'),
                active: service.activeStage == 'encode',
              ),
              _timingRow(
                context,
                '预填充',
                service.stageTiming('prefill'),
                active: service.activeStage == 'prefill',
              ),
              _timingRow(
                context,
                '生成文本',
                service.stageTiming('decode'),
                active: service.activeStage == 'decode',
              ),
              const Divider(height: 16),
              _timingRow(context, '总耗时', service.runElapsed),
            ],
            if (service.partialText.isNotEmpty) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text('识别结果', style: theme.textTheme.titleSmall),
                  ),
                  Text(
                    '已生成 ${service.partialText.length} 字符',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    _livePreview(service.partialText),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timingRow(
    BuildContext context,
    String label,
    Duration? duration, {
    bool active = false,
  }) {
    final theme = Theme.of(context);
    final color = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: active
                ? const CircularProgressIndicator(strokeWidth: 2)
                : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          Text(
            duration == null ? '—' : _formatDuration(duration),
            style: theme.textTheme.bodySmall?.copyWith(
              color: active ? color : theme.colorScheme.onSurface,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
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

String _stageLabel(String? stage) {
  return switch (stage) {
    'load' => '模型加载',
    'preprocess' => '图像预处理',
    'encode' => '图像编码',
    'prefill' => '预填充',
    'decode' => '生成文本',
    _ => '准备中',
  };
}

String _livePreview(String text) {
  const maxChars = 1500;
  if (text.length <= maxChars) {
    return text;
  }
  return '…（仅显示最近 $maxChars 字符）\n'
      '${text.substring(text.length - maxChars)}';
}

String _formatDuration(Duration duration) {
  if (duration.inMinutes >= 1) {
    final seconds = duration.inSeconds % 60;
    return '${duration.inMinutes}分${seconds.toString().padLeft(2, '0')}秒';
  }
  if (duration.inMilliseconds >= 1000) {
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s';
  }
  return '${duration.inMilliseconds} ms';
}
