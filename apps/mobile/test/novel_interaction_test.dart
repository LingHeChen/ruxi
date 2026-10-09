import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/data/room_client.dart';
import 'package:ruxi/ui/c2_stage.dart';
import 'package:ruxi/ui/novel_widgets.dart';

import 'stage_render_test.dart' show StageIdentity;

class InteractiveIdentity extends StageIdentity {
  bool acted = false;
  int round = 1;
  @override
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    bool private = false,
    bool retried = false,
    Map<String, String> extraHeaders = const {},
  ]) async {
    if (method == 'POST') {
      if (body?['type'] == 'action.submit') acted = true;
      if (body?['type'] == 'round.end') round = 2;
      return {'status': 'accepted'};
    }
    final snapshot = await super.request(
      method,
      path,
      body,
      private,
      retried,
      extraHeaders,
    );
    final v = snapshot['blocks'];
    v['room']['round'] = round;
    v['own_results'] = acted
        ? [
            {
              'intent_id': 'first',
              'action_id': 'inspect',
              'label': '拆开未寄出的信',
              'status': 'resolved',
              'success': true,
              'cost': 1,
            },
          ]
        : [];
    v['knowledge'] = acted
        ? [
            {'id': 'address', 'text': '母亲在信里写道：先去找蓝色铁盒。', 'shareable': false},
          ]
        : [];
    return snapshot;
  }
}

void main() {
  testWidgets(
    'action presents acquired clue once and next round fades then closes',
    (tester) async {
      final identity = InteractiveIdentity();
      await tester.pumpWidget(
        MaterialApp(
          theme: playerTheme(),
          home: C2Stage(
            roomId: 'room',
            identity: identity,
            autoInitialize: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('◇  拆开未寄出的信  · 1 点'));
      await tester.pumpAndSettle();
      expect(find.text('行动回响'), findsOneWidget);
      if (find.text('显示全文').evaluate().isNotEmpty) {
        await tester.tap(find.text('显示全文'));
      }
      await tester.pump();
      expect(find.text('母亲在信里写道：先去找蓝色铁盒。'), findsOneWidget);
      expect(find.text('✧ 新线索已记入旅途手记'), findsOneWidget);
      await tester.tap(find.text('继续 →'));
      await tester.pumpAndSettle();
      expect(find.text('行动回响'), findsNothing);
      await tester.tap(find.byTooltip('正在连接 · 刷新'));
      await tester.pumpAndSettle();
      expect(find.text('行动回响'), findsNothing);
      await tester.tap(find.text('结束本回合'));
      await tester.pumpAndSettle();
      if (find.text('显示全文').evaluate().isNotEmpty) {
        await tester.tap(find.text('显示全文'));
      }
      await tester.pump();
      await tester.tap(find.text('确认选择 →'));
      await tester.pumpAndSettle();
      expect(find.byType(RoundTransition), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(RoundTransition), findsNothing);
      expect(find.text('第 2 回合'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      identity.dispose();
    },
  );
  testWidgets(
    'known map node explains movement and respects current position',
    (tester) async {
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
      await tester.tap(find.text('档案室'));
      await tester.pumpAndSettle();
      expect(find.text('移动消耗 1 行动点'), findsOneWidget);
      if (find.text('显示全文').evaluate().isNotEmpty) {
        await tester.tap(find.text('显示全文'));
      }
      await tester.pump();
      expect(find.text('二十年前的投递簿，就在最上层抽屉。'), findsOneWidget);
      await tester.tap(find.text('再想一想'));
      await tester.pumpAndSettle();
      expect(find.text('移动消耗 1 行动点'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
