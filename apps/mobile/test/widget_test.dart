import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/data/room_client.dart';

void main() {
  testWidgets('phone layout at large font stays within viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Home(autoInitialize: false),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('把今晚，交给一个好故事。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'view stream deduplicates and drains out-of-order atomic replacements',
    () {
      final r = ViewReducer()
        ..snapshot({
          'snapshot': {
            'room': {'phase_code': 'exploration'},
            'own_clues': [],
          },
          'base_seq': 10,
          'recovery_epoch': 'A',
        });
      Map<String, dynamic> event(int seq, Map<String, dynamic> replace) => {
        'seq': seq,
        'recovery_epoch': 'A',
        'type': 'clue_discovered',
        'payload': {'replace': replace},
      };
      expect(
        r.event(
          event(12, {
            'own_clues': [
              {'clue_id': 'C1'},
            ],
          }),
        ),
        false,
      );
      expect(r.seq, 10);
      expect(
        r.event(
          event(11, {
            'room': {'phase_code': 'decision'},
          }),
        ),
        true,
      );
      expect(r.seq, 12);
      expect(r.view!['own_clues'].length, 1);
      expect(r.event(event(12, {'own_clues': []})), false);
      expect(r.view!['own_clues'].length, 1);
    },
  );
  test('recovery epoch and unknown event cannot silently advance sequence', () {
    final r = ViewReducer()
      ..snapshot({
        'snapshot': {'room': {}},
        'base_seq': 0,
        'recovery_epoch': 'A',
      });
    expect(
      () => r.event({
        'seq': 1,
        'recovery_epoch': 'B',
        'type': 'clue_discovered',
        'payload': {'replace': {}},
      }),
      throwsA(isA<ApiError>()),
    );
    expect(
      () => r.event({
        'seq': 1,
        'recovery_epoch': 'A',
        'type': 'future_event',
        'payload': {'replace': {}},
      }),
      throwsA(isA<ApiError>()),
    );
    expect(r.seq, 0);
  });
}
