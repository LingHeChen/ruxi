import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/data/room_client.dart';
import 'package:ruxi/ui/c2_stage.dart';
import 'package:ruxi/ui/novel_widgets.dart';

class TideIdentity extends RoomClient {
  final Json fixture = jsonDecode(
    File('test/fixtures/tide_hotel_view.json').readAsStringSync(),
  );
  @override
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    bool private = false,
    bool retried = false,
    Map<String, String> extraHeaders = const {},
  ]) async => fixture;
}

void main() {
  setUpAll(() async {
    if (Platform.environment['RUXI_CAPTURE_UI'] == '1') {
      for (final entry in {
        'PingFang SC': '/System/Library/Fonts/STHeiti Medium.ttc',
        'Songti SC': '/System/Library/Fonts/Supplemental/Songti.ttc',
        'MaterialIcons': '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              File(entry.value)
                  .readAsBytes()
                  .then((b) => ByteData.sublistView(b)),
            ))
            .load();
      }
    }
  });
  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets('illustrated NPC stage and conversation fit $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: playerTheme(),
          home: C2Stage(
            roomId: 'fixture',
            identity: TideIdentity(),
            autoInitialize: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final uri in ['lobby-v2.png', 'npc-lin.png']) {
          await precacheImage(
            AssetImage('assets/stories/tide_hotel/$uri'),
            tester.element(find.byType(C2Stage)),
          );
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('与林素交谈'), findsOneWidget);
      expect(
        find.image(const AssetImage('assets/stories/tide_hotel/lobby-v2.png')),
        findsOneWidget,
      );
      final chipBottom = tester
          .getRect(find.widgetWithText(ActionChip, '与林素交谈'))
          .bottom;
      final actionTop = tester.getRect(find.byType(NovelChoice).first).top;
      expect(actionTop - chipBottom, greaterThanOrEqualTo(18));
      await tester.tap(find.text('与林素交谈'));
      await tester.pumpAndSettle();
      if (find.text('显示全文').evaluate().isNotEmpty) {
        await tester.tap(find.text('显示全文'));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('问林素：最后见到江临是什么时候？'), findsWidgets);
      final portrait = tester.widget<Image>(
        find.descendant(
          of: find.byType(NovelReader),
          matching: find.image(
            const AssetImage('assets/stories/tide_hotel/npc-lin.png'),
          ),
        ),
      );
      expect(portrait.fit, BoxFit.contain);
      expect(tester.takeException(), isNull);
      if (Platform.environment['RUXI_CAPTURE_UI'] == '1') {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../../../.local/tide_hotel/npc-${width.toInt()}.png',
          ),
        );
      }
    });
  }
}
