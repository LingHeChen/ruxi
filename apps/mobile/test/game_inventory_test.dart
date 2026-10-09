import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/ui/game_inventory.dart';

void main() {
  final capture = Platform.environment['RUXI_CAPTURE_UI'] == '1';
  setUpAll(() async {
    if (!capture) return;
    for (final font in {
      'PingFang SC': '/System/Library/Fonts/STHeiti Medium.ttc',
      'Songti SC': '/System/Library/Fonts/Supplemental/Songti.ttc',
      'MaterialIcons': '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(font.value).readAsBytes().then((b) => ByteData.sublistView(b)),
          ))
          .load();
    }
  });
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'three panels isolate their content and reveal only selected detail at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: playerTheme(),
            debugShowCheckedModeBanner: false,
            home: const Scaffold(
              body: GameInventory(
                initialPanel: GamePanel.clues,
                clues: [
                  {
                    'id': 'postmark',
                    'label': '今夜的新邮戳',
                    'text': '旧信纸的日期与新邮戳并不相同。',
                    'shareable': false,
                  },
                ],
                inventory: [
                  {'id': 'key', 'label': '黄铜钥匙', 'description': '用于进入档案室。'},
                ],
                history: [
                  {
                    'label': '辨认新邮戳',
                    'action_id': 'inspect_postmark',
                    'round': 1,
                    'cost': 1,
                    'success': true,
                  },
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('今夜的新邮戳'), findsOneWidget);
        expect(find.text('旧信纸的日期与新邮戳并不相同。'), findsNothing);
        expect(find.text('黄铜钥匙'), findsNothing);
        expect(find.text('辨认新邮戳'), findsNothing);
        await tester.tap(find.text('今夜的新邮戳'));
        await tester.pump();
        expect(find.text('旧信纸的日期与新邮戳并不相同。'), findsOneWidget);
        if (capture) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../../../.local/ui-review/clue-panel-${width.toInt()}.png',
            ),
          );
        }
        await tester.tap(find.text('物品'));
        await tester.pump();
        expect(find.text('旧信纸的日期与新邮戳并不相同。'), findsNothing);
        expect(find.text('黄铜钥匙'), findsOneWidget);
        await tester.tap(find.text('黄铜钥匙'));
        await tester.pump();
        expect(find.text('用于进入档案室。'), findsOneWidget);
        if (capture) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../../../.local/ui-review/inventory-panel-${width.toInt()}.png',
            ),
          );
        }
        await tester.tap(find.text('历史'));
        await tester.pump();
        expect(find.text('黄铜钥匙'), findsNothing);
        expect(find.text('辨认新邮戳'), findsOneWidget);
        expect(find.text('第 1 回合 · 1 行动点 · 已完成'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../../../.local/ui-review/history-panel-${width.toInt()}.png',
            ),
          );
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
