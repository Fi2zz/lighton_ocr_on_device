import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/ocr/ocr_ffi.dart';
import 'src/ocr/ocr_types.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: FfiSmokePage()));
}

class FfiSmokePage extends StatefulWidget {
  const FfiSmokePage({super.key});

  @override
  State<FfiSmokePage> createState() => _FfiSmokePageState();
}

class _FfiSmokePageState extends State<FfiSmokePage> {
  final StringBuffer _log = StringBuffer();
  String _text = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _add(String line) {
    // Visible in `adb logcat` / `flutter run` while diagnosing device-only FFI.
    // ignore: avoid_print
    print('FFI_SMOKE $line');
    if (!mounted) {
      return;
    }
    setState(() => _log.writeln(line));
  }

  Future<void> _run() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'models'));
      final model = File(p.join(dir.path, 'lightonocr3-0.8b.gguf'));
      final mmproj = File(p.join(dir.path, 'mmproj-lightonocr3-0.8b.gguf'));
      final raw = File(p.join(dir.path, 'report-1-1280.rgb'));
      final size = File(p.join(dir.path, 'report-1-1280.size'));

      _add('model=${await model.exists()} ${await model.length()}');
      _add('mmproj=${await mmproj.exists()} ${await mmproj.length()}');

      final dimensions = (await size.readAsString()).trim().split(RegExp(r'\s+'));
      final width = int.parse(dimensions[0]);
      final height = int.parse(dimensions[1]);
      final rgb = await raw.readAsBytes();

      _add('running in background isolate...');
      final result = await Isolate.run(
        () => _ocrInIsolate(
          modelPath: model.path,
          mmprojPath: mmproj.path,
          rgb: rgb,
          width: width,
          height: height,
        ),
      );
      _text = result.text;
      _add('TEXT ${_text.length}: ${_text.length > 1500 ? _text.substring(0, 1500) : _text}');
      _add(
        'stats=${result.stats.promptTokens}/${result.stats.outputTokens}/${result.stats.imageTokens} '
        'encode=${result.stats.encodeMs.toStringAsFixed(0)}ms '
        'decode=${result.stats.decodeMs.toStringAsFixed(0)}ms '
        'rss=${result.stats.peakRssKb}KB',
      );
      if (mounted) {
        setState(() {});
      }
    } on OcrException catch (error) {
      _add('${error.code}: ${error.message}');
    } catch (error) {
      _add('error: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FFI smoke')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            _log.toString(),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const Divider(),
          Text(_text),
        ],
      ),
    );
  }
}

class _SmokeResult {
  const _SmokeResult(this.text, this.stats);
  final String text;
  final OcrStats stats;
}

_SmokeResult _ocrInIsolate({
  required String modelPath,
  required String mmprojPath,
  required Uint8List rgb,
  required int width,
  required int height,
}) {
  final ffi = OcrFfi.open();
  Pointer<OcrEngine>? engine;
  try {
    engine = ffi.create(
      modelPath: modelPath,
      mmprojPath: mmprojPath,
      config: const OcrConfig(nThreads: 8),
    );
    final text = StringBuffer();
    final stats = ffi.run(
      engine: engine,
      rgb: rgb,
      width: width,
      height: height,
      mode: OcrMode.grounding,
      maxTokens: 2048,
      onToken: text.write,
    );
    return _SmokeResult(text.toString(), stats);
  } finally {
    if (engine != null) {
      ffi.destroy(engine);
    }
  }
}
