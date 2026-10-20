import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:share_plus/share_plus.dart';

import '../ocr/grounding.dart';
import '../ocr/ocr_types.dart';

class ResultPage extends StatelessWidget {
  final OcrResult result;
  final Uint8List? imageBytes;

  const ResultPage({
    super.key,
    required this.result,
    this.imageBytes,
  });

  String get _rendered => groundingToMarkdown(result.text);

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _rendered));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制 Markdown')),
    );
  }

  Future<void> _share() async {
    await SharePlus.instance.share(ShareParams(text: _rendered));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('识别结果'),
          actions: [
            IconButton(
              tooltip: '复制',
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: '分享',
              onPressed: _share,
              icon: const Icon(Icons.share),
            ),
          ],
        ),
        body: Column(
          children: [
            if (imageBytes != null)
              Container(
                width: double.infinity,
                height: 140,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Image.memory(imageBytes!, fit: BoxFit.contain),
              ),
            const TabBar(
              tabs: [
                Tab(text: '渲染'),
                Tab(text: '原文'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MarkdownBody(data: _rendered),
                        const SizedBox(height: 16),
                        _StatsTile(stats: result.stats),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(result.text),
                        const SizedBox(height: 16),
                        _StatsTile(stats: result.stats),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('换一张'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('重新识别'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsTile extends StatelessWidget {
  final OcrStats stats;

  const _StatsTile({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        title: const Text('耗时详情'),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          _row('加载', _formatMs(stats.loadMs)),
          _row('图像编码', _formatMs(stats.encodeMs)),
          _row('预填充', _formatMs(stats.prefillMs)),
          _row('生成', _formatMs(stats.decodeMs)),
          _row('总计', _formatMs(stats.totalMs)),
          _row('速度', '${stats.tokensPerSecond.toStringAsFixed(2)} tok/s'),
          _row('图片 token', '${stats.imageTokens}'),
          _row('峰值内存', _formatKb(stats.peakRssKb)),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(value),
    );
  }
}

String _formatMs(double ms) {
  if (ms >= 1000) {
    return '${(ms / 1000).toStringAsFixed(1)} s';
  }
  return '${ms.toStringAsFixed(0)} ms';
}

String _formatKb(int kb) {
  if (kb >= 1024 * 1024) {
    return '${(kb / (1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (kb >= 1024) {
    return '${(kb / 1024).toStringAsFixed(0)} MB';
  }
  return '$kb KB';
}
