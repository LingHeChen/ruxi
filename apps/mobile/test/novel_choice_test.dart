import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/ui/novel_widgets.dart';

void main() {
  final capture = Platform.environment['RUXI_CAPTURE_UI'] == '1';
  setUpAll(() async {
    if (capture) {
      for (final entry in {
        'PingFang SC': '/System/Library/Fonts/STHeiti Medium.ttc',
        'Songti SC': '/System/Library/Fonts/Supplemental/Songti.ttc',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              Future.value(
                ByteData.sublistView(File(entry.value).readAsBytesSync()),
              ),
            ))
            .load();
      }
    }
  });
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'illustrated choices at $width preserve errors and prevent duplicate submission',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pending = Completer<String?>();
        var submissions = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: playerTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showNovelMessage(
                    context,
                    const NovelMessage(
                      title: '行动回响',
                      text: '雨水将漫过桌面。你只能先保护一件东西。',
                      illustration: 'assets/stories/last_letter/rescue.png',
                      choices: [
                        {
                          'id': 'ledger',
                          'label': '先抢救投递簿',
                          'cost': 2,
                          'risk_text': '录音带会被水浸坏。',
                          'allowed_now': true,
                        },
                        {
                          'id': 'tape',
                          'label': '先抢救录音带',
                          'cost': 2,
                          'risk_text': '投递簿会被水浸坏。',
                          'allowed_now': false,
                        },
                      ],
                    ),
                    onChoice: (_) {
                      submissions++;
                      return pending.future;
                    },
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);
        if (capture) {
          await tester.runAsync(
            () => precacheImage(
              const AssetImage('assets/stories/last_letter/rescue.png'),
              tester.element(find.byType(NovelReader)),
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../../../.local/ui-review/illustrated-choice-${width.toInt()}.png',
            ),
          );
        }
        expect(find.text('此刻，你会怎么做？'), findsOneWidget);
        final tape = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, '◇ 先抢救录音带 · 2 余力'),
        );
        expect(tape.onPressed, isNull);
        final ledger = find.text('◇ 先抢救投递簿 · 2 余力');
        await tester.ensureVisible(ledger);
        await tester.tap(ledger);
        await tester.pump();
        await tester.tap(ledger);
        expect(submissions, 1);
        pending.complete('当前余力已经变化。');
        await tester.pumpAndSettle();
        expect(find.text('当前余力已经变化。'), findsOneWidget);
        expect(find.text('确认选择 →'), findsNothing);
        await tester.tap(find.text('稍后决定'));
        await tester.pumpAndSettle();
        expect(find.byType(NovelReader), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
