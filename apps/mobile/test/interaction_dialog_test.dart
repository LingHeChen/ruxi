import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/ui/interaction_dialog.dart';

void main() {
  testWidgets('normalized text reaches server and submit errors unlock retry', (
    tester,
  ) async {
    String? answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: playerTheme(),
        home: Scaffold(
          body: InteractionDialog(
            interaction: {'label': '口令', 'kind': 'password'},
            quote: () async => {
              'quote_id': 'q',
              'cost': 1,
              'attempts_remaining': 3,
              'risk_text': '错误输入计次。',
              'input_spec': {
                'format': 'text',
                'normalization': 'nfkc_trim_casefold',
                'min_length': 3,
                'max_length': 3,
              },
            },
            submit: (q, text) async {
              answer = text;
              throw Exception('network');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Ａß  ');
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(answer, '  Ａß  ');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认提交'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets(
      'password at $width validates format and preserves leading zero',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? answer;
        await tester.pumpWidget(
          MaterialApp(
            theme: playerTheme(),
            home: Scaffold(
              body: InteractionDialog(
                interaction: {'label': '保险柜', 'kind': 'password'},
                quote: () async => {
                  'quote_id': 'q',
                  'cost': 1,
                  'attempts_remaining': 3,
                  'risk_text': '错误输入也计入次数。',
                  'input_spec': {
                    'format': 'pin',
                    'normalization': 'exact',
                    'min_length': 4,
                    'max_length': 4,
                  },
                },
                submit: (q, text) async {
                  answer = text;
                  return '等待原命令确认';
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '427');
        await tester.tap(find.text('确认提交'));
        await tester.pump();
        expect(answer, isNull);
        await tester.enterText(find.byType(TextField), '0427');
        await tester.tap(find.text('确认提交'));
        await tester.pumpAndSettle();
        expect(answer, '0427');
        expect(find.text('等待原命令确认'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
