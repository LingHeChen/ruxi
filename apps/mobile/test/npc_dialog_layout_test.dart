import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/ui/novel_widgets.dart';
import 'package:ruxi/ui/c2_stage.dart';
import 'package:ruxi/main.dart';

import 'tide_hotel_render_test.dart' show TideIdentity;

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'share dialog uses the player theme and fits $width at 200% text',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final identity = TideIdentity();
        final v = identity.fixture['blocks'];
        v['narrative_cues'] = [];
        v['own_results'] = [];
        v['members'] = [
          {'member_id': 'peer', 'display_name': '游客', 'role_id': 'archivist'},
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: playerTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: C2Stage(
              roomId: 'fixture',
              identity: identity,
              autoInitialize: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(C2Stage));
        final future = state.share({'id': 'receipt', 'label': '未退的房费'});
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(AlertDialog));
        expect(
          DialogTheme.of(context).backgroundColor,
          const Color(0xff15232c),
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await future;
        await tester.pumpWidget(const SizedBox());
        identity.dispose();
      },
    );
  }

  testWidgets(
    'passively received clues update the notebook without opening a modal',
    (tester) async {
      final identity = TideIdentity();
      final v = identity.fixture['blocks'];
      v['narrative_cues'] = [];
      v['knowledge'] = [];
      v['own_results'] = [];
      await tester.pumpWidget(
        MaterialApp(
          home: C2Stage(
            roomId: 'fixture',
            identity: identity,
            autoInitialize: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      v['knowledge'] = [
        {
          'id': 'shared',
          'label': '同伴分享的证词',
          'text': '一条被动获得的线索',
          'category': 'reported',
          'shareable': true,
        },
      ];
      final dynamic state = tester.state(find.byType(C2Stage));
      await state.client.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(NovelReader), findsNothing);
      expect(find.text('一条被动获得的线索'), findsNothing);
      expect(find.textContaining('1 条线索'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      identity.dispose();
    },
  );
  testWidgets('NPC questions stay inside the conversation', (tester) async {
    final identity = TideIdentity();
    final v = identity.fixture['blocks'];
    v['narrative_cues'] = [];
    v['own_results'] = [];
    v['npcs'] = [
      {'id': 'lin', 'label': '林素', 'description': '旅馆经营者'},
    ];
    v['actions'] = [
      {
        'id': 'ask_lin',
        'label': '为什么提到电工的父亲？',
        'target': 'lin',
        'cost': 1,
        'remaining_uses': 1,
        'allowed_now': true,
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: C2Stage(
          roomId: 'fixture',
          identity: identity,
          autoInitialize: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('与林素交谈'), findsOneWidget);
    expect(find.textContaining('为什么提到电工的父亲'), findsNothing);
    await tester.tap(find.text('与林素交谈'));
    await tester.pumpAndSettle();
    expect(find.textContaining('为什么提到电工的父亲'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    identity.dispose();
  });
  for (final width in [390.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'NPC description scroll keeps choices pinned at $width / $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 900),
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: NovelReader(
                  message: NovelMessage(
                    character: true,
                    title: '林素',
                    text: List.filled(60, '她望着窗外，低声讲述那一夜的经过。').join(),
                    choices: const [
                      {
                        'id': 'ask',
                        'label': '询问旧事',
                        'cost': 1,
                        'allowed_now': true,
                      },
                    ],
                  ),
                  onChoice: (_) async => null,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final later = find.text('稍后决定');
          final before = tester.getRect(later);
          await tester.drag(
            find.byKey(const ValueKey('npc-description-scroll')),
            const Offset(0, -500),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(later), before);
          expect(find.text('◇ 询问旧事 · 1 余力'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
