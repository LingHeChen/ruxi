import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/data/room_client.dart';
import 'package:ruxi/ui/c2_stage.dart';

class StageIdentity extends RoomClient {
  @override
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    bool private = false,
    bool retried = false,
    Map<String, String> extraHeaders = const {},
  ]) async => {
    'protocol_version': 2,
    'stream_id': 'own',
    'view_seq': 1,
    'control_epoch': 1,
    'blocks': {
      'story_title': '雨夜最后一封信',
      'own_member_id': 'm1',
      'host_member_id': 'm1',
      'room': {'status': 'active', 'round': 1, 'step': 1},
      'self': {
        'role_id': 'guest',
        'ap_remaining': 3,
        'ap_reserved': 0,
        'location': 'office',
        'goals': ['找到停电的原因，帮助同伴安全离开。'],
      },
      'roles': [
        {'id': 'guest', 'label': '来客'},
      ],
      'members': [
        {
          'member_id': 'm1',
          'role_id': 'guest',
          'display_name': '林间',
          'ready': true,
          'online': true,
        },
      ],
      'map': {
        'locations': [
          {
            'id': 'office',
            'label': '值班室',
            'description': '雨水沿窗玻璃蜿蜒而下。桌上的旧信封没有邮票，收件人却写着你的名字。',
          },
          {'id': 'archive', 'label': '档案室', 'description': '二十年前的投递簿，就在最上层抽屉。'},
        ],
        'links': [
          {
            'id': 'dining_hall',
            'from': 'office',
            'to': 'archive',
            'cost': 1,
            'allowed_now': true,
          },
        ],
      },
      'actions': [
        {
          'id': 'inspect',
          'label': '拆开未寄出的信',
          'cost': 1,
          'allowed_now': true,
          'risk_text': '留意餐具上不寻常的细节。',
        },
        {
          'id': 'ask',
          'label': '翻看旧合照',
          'cost': 1,
          'allowed_now': true,
          'risk_text': '也许他知道发生了什么。',
        },
      ],
      'narrative_cues': [],
      'acknowledged_cues': [],
      'knowledge': [],
      'inventory': [],
    },
  };
}

void main() {
  final capture = Platform.environment['RUXI_CAPTURE_UI'] == '1';
  setUpAll(() async {
    if (capture) {
      for (final item in {
        'PingFang SC': '/System/Library/Fonts/STHeiti Medium.ttc',
        'Songti SC': '/System/Library/Fonts/Supplemental/Songti.ttc',
        'MaterialIcons': '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(item.key)..addFont(
              File(item.value)
                  .readAsBytes()
                  .then((b) => ByteData.sublistView(b)),
            ))
            .load();
      }
    }
  });
  for (final size in [const Size(1280, 1000), const Size(390, 844)]) {
    testWidgets('new stage keeps its hierarchy within viewport ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: playerTheme(),
          home: C2Stage(
            roomId: 'room',
            identity: StageIdentity(),
            autoInitialize: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/stories/last_letter/office.png'),
          tester.element(find.byType(C2Stage)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('雨夜最后一封信'), findsOneWidget);
      expect(find.text('创作项目'), findsNothing);
      expect(tester.takeException(), isNull);
      if (capture) {
        await expectLater(
          find.byType(C2Stage),
          matchesGoldenFile(
            '../../../.local/ui-review/player-stage-${size.width.toInt()}.png',
          ),
        );
      }
      if (capture) {
        await tester.tap(find.byIcon(Icons.map_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, '档案室'));
        await tester.pumpAndSettle();
        if (find.text('显示全文').evaluate().isNotEmpty) {
          await tester.tap(find.text('显示全文'));
          await tester.pump();
        }
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../../../.local/ui-review/player-dialog-${size.width.toInt()}.png',
          ),
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
