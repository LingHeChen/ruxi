import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi_creator/preview_panel.dart';

void main() {
  testWidgets('preview actions retain actor role and private payload', (
    tester,
  ) async {
    final views = <String, dynamic>{};
    for (final role in ['investigator', 'passenger', 'conductor']) {
      views[role] = {
        'room': {
          'lifecycle': 'running',
          'phase_code': 'exploration',
          'exploration_step': 'active',
        },
        'self': {'membership_id': role},
        'members': [],
        'offers': [],
        'own_clues': role == 'investigator'
            ? [
                {
                  'clue_id': 'C1',
                  'title': '私有名单',
                  'text': 'canary-A',
                  'shared': false,
                },
              ]
            : [],
        'public_scene': {'shared_clues': []},
        'media': {'authorized': []},
        'available_actions': [],
        'visible_items': [],
        'own_vote': null,
        'hints': {'remaining': 2, 'entries': []},
      };
    }
    String? actor;
    String? command;
    Json? payload;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PreviewPanel(
              preview: {'views': views, 'history': [], 'steps': 0},
              busy: false,
              onStart: () {},
              onStep: (a, c, p, _) {
                actor = a;
                command = c;
                payload = p;
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('canary-A'), findsOneWidget);
    await tester.ensureVisible(find.text('公开这条线索'));
    await tester.tap(find.text('公开这条线索'));
    expect(actor, 'investigator');
    expect(command, 'share_clue');
    expect(payload, {'clue_id': 'C1'});
    expect(tester.takeException(), isNull);
  });
}
