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
      'story_title': '停电之前',
      'own_member_id': 'm1',
      'host_member_id': 'm1',
      'room': {'status': 'active', 'round': 1, 'step': 1},
      'self': {
        'role_id': 'guest',
        'ap_remaining': 3,
        'ap_reserved': 0,
        'location': 'dining',
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
          {'id': 'dining', 'label': '餐厅'},
          {'id': 'hall', 'label': '走廊'},
        ],
        'links': [
          {
            'id': 'dining_hall',
            'from': 'dining',
            'to': 'hall',
            'cost': 1,
            'allowed_now': true,
          },
        ],
      },
      'actions': [
        {
          'id': 'inspect',
          'label': '检查餐具',
          'cost': 1,
          'allowed_now': true,
          'risk_text': '留意餐具上不寻常的细节。',
        },
        {
          'id': 'ask',
          'label': '询问服务员',
          'cost': 1,
          'allowed_now': true,
          'risk_text': '也许他知道发生了什么。',
        },
      ],
      'narrative_cues': [
        {
          'id': 'opening',
          'summary': '窗外的雨越来越大，餐厅的灯闪了一下。每个人都抬起了头，等着谁先打破沉默。',
          'blocking': true,
        },
      ],
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
      expect(find.text('停电之前'), findsOneWidget);
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
      await tester.pumpWidget(const SizedBox());
    });
  }
}
