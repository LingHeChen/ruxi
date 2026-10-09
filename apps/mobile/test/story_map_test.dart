import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/data/room_client.dart';
import 'package:ruxi/ui/story_map.dart';

void main() {
  setUpAll(() async {
    if (Platform.environment['RUXI_CAPTURE_UI'] != '1') return;
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
  });
  final story = jsonDecode(
    File('../../content/c3/tide_hotel/story.json').readAsStringSync(),
  );
  final locations = (story['locations'] as List).cast<Json>();
  final links = <Json>[
    for (final p in story['c3']['passages']) ...[
      {
        'from': p['a'],
        'to': p['b'],
        'cost': 1,
        'allowed_now': p['barrier_id'] == null,
      },
      {'from': p['b'], 'to': p['a'], 'cost': 1, 'allowed_now': true},
    ],
  ];
  test('eight-scene map gives each branch space and excludes unprojected locations', () {
    final layout = StoryMapLayout(locations, links);
    expect(layout.positions.length, 8);
    expect(layout.treeEdges.length, 7);
    final points = layout.positions.values.toList();
    for (var i = 0; i < points.length; i++) {
      for (var j = i + 1; j < points.length; j++) {
        expect((points[i] - points[j]).distance, greaterThanOrEqualTo(120));
      }
    }
    final restricted = StoryMapLayout(locations.take(2).toList(), links);
    expect(restricted.positions.keys, unorderedEquals(['lobby', 'lounge']));
  });
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'expanded map at $width guards movement and returns one adjacent destination',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Json? picked;
        await tester.pumpWidget(
          MaterialApp(
            theme: playerTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    picked = await showDialog<Json>(
                      context: context,
                      builder: (_) => StoryMapDialog(
                        locations: locations,
                        links: links,
                        current: 'lobby',
                        canMove: true,
                        ap: 3,
                      ),
                    );
                  },
                  child: const Text('打开地图'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开地图'));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        if (width == 390) {
          expect(
            tester
                .widget<InteractiveViewer>(find.byType(InteractiveViewer))
                .transformationController!
                .value
                .getMaxScaleOnAxis(),
            closeTo(.9, .01),
          );
          await tester.tap(find.byTooltip('放大地图'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<InteractiveViewer>(find.byType(InteractiveViewer))
                .transformationController!
                .value
                .getMaxScaleOnAxis(),
            closeTo(1.17, .01),
          );
          await tester.tap(find.byTooltip('缩小地图'));
          await tester.pumpAndSettle();
          if (Platform.environment['RUXI_CAPTURE_UI'] == '1') {
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                '../../../.local/tide_hotel/map-current-390.png',
              ),
            );
          }
        }
        await tester.tap(find.byTooltip('显示完整地图'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('阁楼资料室').first);
        await tester.pumpAndSettle();
        expect(find.text('没有直接通路，请先移动到相邻地点'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, '移动到阁楼资料室'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('海景餐厅').first);
        await tester.pumpAndSettle();
        expect(find.text('移动消耗 1 行动点'), findsOneWidget);
        if (Platform.environment['RUXI_CAPTURE_UI'] == '1') {
          await tester.runAsync(
            () => precacheImage(
              const AssetImage('assets/stories/tide_hotel/lounge-v2.png'),
              tester.element(find.byType(StoryMapDialog)),
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../../../.local/tide_hotel/map-${width.toInt()}.png',
            ),
          );
        }
        await tester.tap(find.text('移动到海景餐厅'));
        await tester.pumpAndSettle();
        expect(picked?['id'], 'lounge');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
