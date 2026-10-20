import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lighton_ocr_on_device/src/ocr/ocr_types.dart';
import 'package:lighton_ocr_on_device/src/ui/result_page.dart';

void main() {
  const result = OcrResult(
    text: '![title](10,20,30,40) # 标题\n\n![text](0,0,10,10) 正文',
    stats: OcrStats(
      promptTokens: 100,
      outputTokens: 50,
      imageTokens: 300,
      loadMs: 100,
      encodeMs: 200,
      prefillMs: 300,
      decodeMs: 1000,
      peakRssKb: 1024,
    ),
  );

  testWidgets('renders markdown without grounding markers', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ResultPage(result: result)),
    );

    expect(find.text('标题'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
    expect(find.textContaining('![title]'), findsNothing);
    expect(find.text('渲染'), findsOneWidget);
    expect(find.text('原文'), findsOneWidget);
  });

  testWidgets('raw tab keeps grounding markers', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ResultPage(result: result)),
    );

    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();

    expect(find.textContaining('![title](10,20,30,40)'), findsOneWidget);
  });

  testWidgets('copy and share actions exist', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      const MaterialApp(home: ResultPage(result: result)),
    );

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();

    expect(calls.any((call) => call.method == 'Clipboard.setData'), isTrue);
    expect(find.byIcon(Icons.share), findsOneWidget);
    expect(find.text('重新识别'), findsOneWidget);
    expect(find.text('换一张'), findsOneWidget);
  });

  testWidgets('stats can be expanded', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ResultPage(result: result)),
    );

    expect(find.text('耗时详情'), findsOneWidget);
    await tester.tap(find.text('耗时详情'));
    await tester.pumpAndSettle();

    expect(find.textContaining('编码'), findsOneWidget);
  });
}
