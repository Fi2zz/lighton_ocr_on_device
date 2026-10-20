import 'dart:io';

import 'package:flutter/material.dart';

import '../models/model_file_picker.dart';
import '../models/model_store.dart';
import '../ocr/ocr_service.dart';
import '../ocr/ocr_types.dart';

class ModelSetupPage extends StatefulWidget {
  final ModelStore store;
  final ModelFilePicker picker;
  final OcrService service;

  const ModelSetupPage({
    super.key,
    required this.store,
    required this.picker,
    required this.service,
  });

  @override
  State<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends State<ModelSetupPage> {
  bool _mainExists = false;
  bool _mmprojExists = false;
  int _mainBytes = 0;
  int _mmprojBytes = 0;
  double? _mainProgress;
  double? _mmprojProgress;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final main = widget.store.mainFile;
    final mmproj = widget.store.mmprojFile;
    final mainExists = await main.exists();
    final mmprojExists = await mmproj.exists();
    final mainBytes = mainExists ? await _length(main) : 0;
    final mmprojBytes = mmprojExists ? await _length(mmproj) : 0;
    if (!mounted) {
      return;
    }
    setState(() {
      _mainExists = mainExists;
      _mmprojExists = mmprojExists;
      _mainBytes = mainBytes;
      _mmprojBytes = mmprojBytes;
    });
  }

  Future<int> _length(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }

  Future<void> _importMain() async {
    final file = await widget.picker.pickGgufFile();
    if (file == null) {
      return;
    }
    await _import(
      file: file,
      main: true,
      onProgress: (value) {
        if (mounted) {
          setState(() => _mainProgress = value);
        }
      },
    );
  }

  Future<void> _importMmproj() async {
    final file = await widget.picker.pickGgufFile();
    if (file == null) {
      return;
    }
    await _import(
      file: file,
      main: false,
      onProgress: (value) {
        if (mounted) {
          setState(() => _mmprojProgress = value);
        }
      },
    );
  }

  Future<void> _import({
    required File file,
    required bool main,
    required void Function(double) onProgress,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
      if (main) {
        _mainProgress = 0;
      } else {
        _mmprojProgress = 0;
      }
    });

    try {
      if (main) {
        await widget.store.importMain(file, onProgress: onProgress);
      } else {
        await widget.store.importMmproj(file, onProgress: onProgress);
      }
      await widget.service.initialize();
    } on OcrException catch (error) {
      if (mounted) {
        setState(() => _error = _messageFor(error));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _mainProgress = null;
          _mmprojProgress = null;
        });
      }
      await _refresh();
    }
  }

  Future<void> _loadModel() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.service.loadModel();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    final error = widget.service.error;
    if (error != null) {
      setState(() => _error = _messageFor(error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('模型已加载')),
      );
    }
  }

  Future<void> _release() async {
    setState(() => _busy = true);
    await widget.service.reset();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已释放模型内存')),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型？'),
        content: const Text('主模型与 mmproj 将从应用私有目录删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _busy = true);
    await widget.store.deleteAll();
    await widget.service.initialize();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    await _refresh();
  }

  String _messageFor(OcrException error) {
    return switch (error.code) {
      OcrErrorCode.ggufInvalid => '文件不是有效的 GGUF，或类型选错',
      OcrErrorCode.modelMissing => '请先导入主模型和 mmproj',
      OcrErrorCode.load => '模型加载失败：${error.message}',
      OcrErrorCode.oom => '内存不足，请降低图片长边或换更小的量化',
      _ => '${error.code}：${error.message}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final canLoad = _mainExists && _mmprojExists && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('模型配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '导入 GGUF 模型',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            '主模型与 mmproj 需成对导入。文件只保存在应用私有目录，不会上传。',
          ),
          const SizedBox(height: 16),
          _slot(
            title: '主模型',
            filename: ModelStore.mainFileName,
            exists: _mainExists,
            bytes: _mainBytes,
            progress: _mainProgress,
            onImport: _busy ? null : _importMain,
          ),
          const SizedBox(height: 12),
          _slot(
            title: 'mmproj',
            filename: ModelStore.mmprojFileName,
            exists: _mmprojExists,
            bytes: _mmprojBytes,
            progress: _mmprojProgress,
            onImport: _busy ? null : _importMmproj,
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: canLoad ? _loadModel : null,
            child: const Text('加载模型'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _release,
            child: const Text('释放内存'),
          ),
          TextButton(
            onPressed: _busy ? null : _delete,
            child: const Text('删除模型'),
          ),
          const SizedBox(height: 24),
          const Text(
            '转换脚本：tool/model/convert.sh、quantize.sh',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _slot({
    required String title,
    required String filename,
    required bool exists,
    required int bytes,
    required double? progress,
    required VoidCallback? onImport,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: onImport,
                  child: const Text('导入'),
                ),
              ],
            ),
            Text(
              filename,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              exists ? '已导入 · ${_formatBytes(bytes)}' : '未导入',
              style: TextStyle(
                color: exists
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress),
            ],
          ],
        ),
      ),
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
