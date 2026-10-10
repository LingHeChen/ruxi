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

class TideLobbyIdentity extends TideIdentity {
  TideLobbyIdentity() {
    final v = fixture['blocks'] as Json;
    v['room'] = {'status': 'lobby', 'phase': 'lobby'};
    v['narrative_cues'] = [];
    v['knowledge'] = [];
    v['own_results'] = [];
    v['roles'] = [
      {
        'id': 'reporter',
        'label': '徐闻 · 声音记者',
        'description': '江临要求你从进门起就开着录音。',
      },
      {
        'id': 'archivist',
        'label': '沈砚 · 地方档案研究员',
        'description': '你整理的旧名录可能存在缺口。',
      },
      {'id': 'volunteer', 'label': '许澄 · 救援志愿者', 'description': '你熟悉避风站与后山路线。'},
      {
        'id': 'photographer',
        'label': '陆遥 · 纪实摄影师',
        'description': '你带来一张未发表的旧照片。',
      },
    ];
    v['members'] = [
      {
        'member_id': 'fixture',
        'display_name': '自己',
        'role_id': 'reporter',
        'ready': false,
      },
      {
        'member_id': 'other',
        'display_name': '同伴',
        'role_id': 'archivist',
        'ready': false,
      },
    ];
    v['min_players'] = 1;
  }
}

class TideOpeningIdentity extends TideIdentity {
  TideOpeningIdentity(String role) {
    final story = jsonDecode(
      File('../../content/c3/tide_hotel/story.json').readAsStringSync(),
    ) as Json;
    final media = (story['media'] as List).firstWhere(
      (m) => m['id'] == 'role_opening_$role',
    );
    final v = fixture['blocks'] as Json;
    v['acknowledged_cues'] = [];
    v['narrative_cues'] = [
      {
        'id': 'private-opening',
        'media_id': media['id'],
        'text': media['summary'],
        'kind': 'image',
        'image_uri': media['uri'],
      },
    ];
  }
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
    testWidgets('role descriptions and occupied seats fit $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: playerTheme(),
          home: C2Stage(
            roomId: 'fixture',
            identity: TideLobbyIdentity(),
            autoInitialize: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final occupied = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '沈砚 · 地方档案研究员 · 同伴已选'),
      );
      expect(occupied.onSelected, isNull);
      final own = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '徐闻 · 声音记者'),
      );
      expect(own.selected, isTrue);
      expect(own.onSelected, isNotNull);
      expect(find.text('你整理的旧名录可能存在缺口。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

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

  for (final role in ['reporter', 'archivist', 'volunteer', 'photographer']) {
    testWidgets('$role reads their own character before the common opening', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: playerTheme(),
          home: C2Stage(
            roomId: 'fixture',
            identity: TideOpeningIdentity(role),
            autoInitialize: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final message = tester
          .widget<NovelReader>(find.byType(NovelReader))
          .message;
      expect(message.title, '你的角色 · 私人经历');
      final names = {
        'reporter': '徐闻',
        'archivist': '沈砚',
        'volunteer': '许澄',
        'photographer': '陆遥',
      };
      expect(message.text, startsWith('你叫${names[role]}'));
      expect(message.text, isNot(contains('可由1～4人自由选择任意角色')));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
