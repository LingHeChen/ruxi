import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi_creator/main.dart';

import 'workspace_test.dart' show fixture, MemorySession;

void main() {
  final capture = Platform.environment['RUXI_CAPTURE_UI'] == '1';
  setUpAll(() async {
    if (capture) {
      final loader = FontLoader('PingFang SC')
        ..addFont(
          File('/System/Library/Fonts/STHeiti Medium.ttc')
              .readAsBytes()
              .then((b) => ByteData.sublistView(b)),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      await icons.load();
      final song = FontLoader('Songti SC')
        ..addFont(
          File('/System/Library/Fonts/Supplemental/Songti.ttc')
              .readAsBytes()
              .then((b) => ByteData.sublistView(b)),
        );
      await song.load();
    }
  });
  for (final size in [const Size(1440, 1100), const Size(390, 844)]) {
    testWidgets('admin shell and directories render at ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: creatorTheme(),
          home: Creator(httpClient: fixture(), sessionStore: MemorySession()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('工作概览'), findsWidgets);
      expect(tester.takeException(), isNull);
      if (capture) {
        await expectLater(
          find.byType(Creator),
          matchesGoldenFile(
            '../../../docs/screenshots/admin-dashboard-${size.width.toInt()}-widget.png',
          ),
        );
      }
      if (size.width < 1000) {
        await tester.tap(find.byTooltip('打开导航'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('剧目管理'));
      await tester.pumpAndSettle();
      expect(find.text('末班车的第七位乘客'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (capture) {
        await expectLater(
          find.byType(Creator),
          matchesGoldenFile(
            '../../../docs/screenshots/admin-stories-${size.width.toInt()}-widget.png',
          ),
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
