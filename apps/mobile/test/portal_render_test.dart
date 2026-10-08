import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';

import 'catalog_test.dart' show CatalogClient;

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
  for (final size in [const Size(1280, 1000), const Size(390, 844)]) {
    testWidgets('portal renders home and personal navigation at ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: playerTheme(),
          home: Home(autoInitialize: false, client: CatalogClient()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('首页'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (capture) {
        await expectLater(
          find.byType(Home),
          matchesGoldenFile(
            '../../../docs/screenshots/player-home-${size.width.toInt()}-widget.png',
          ),
        );
      }
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.text('登录账号'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (capture) {
        await expectLater(
          find.byType(Home),
          matchesGoldenFile(
            '../../../docs/screenshots/player-personal-${size.width.toInt()}-widget.png',
          ),
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
