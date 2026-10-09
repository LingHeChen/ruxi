import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/c2_client.dart';
import 'package:ruxi/data/room_client.dart';

void main() {
  test(
    'C2 view watermarks ignore duplicates and reject gaps or other streams',
    () {
      final r = C2ViewReducer();
      r.snapshot({
        'protocol_version': 2,
        'stream_id': 'own',
        'view_seq': 4,
        'blocks': {'knowledge': []},
      });
      expect(
        r.event({
          'stream_id': 'own',
          'base_view_seq': 4,
          'view_seq': 5,
          'blocks': {
            'knowledge': ['private'],
          },
        }),
        isTrue,
      );
      expect(
        r.event({
          'stream_id': 'own',
          'base_view_seq': 4,
          'view_seq': 5,
          'blocks': {},
        }),
        isFalse,
      );
      expect(
        () => r.event({
          'stream_id': 'other',
          'base_view_seq': 5,
          'view_seq': 6,
          'blocks': {},
        }),
        throwsA(isA<ApiError>()),
      );
      expect(
        () => r.event({
          'stream_id': 'own',
          'base_view_seq': 6,
          'view_seq': 7,
          'blocks': {},
        }),
        throwsA(isA<ApiError>()),
      );
      expect(r.blocks!['knowledge'], ['private']);
      expect(r.seq, 5);
    },
  );
  test('C2 snapshots replace the authorized view and reject C1 shapes', () {
    final r = C2ViewReducer();
    expect(() => r.snapshot({'protocol_version': 1}), throwsA(isA<ApiError>()));
    r.snapshot({
      'protocol_version': 2,
      'stream_id': 'a',
      'view_seq': 9,
      'blocks': {
        'knowledge': ['a'],
      },
    });
    r.snapshot({
      'protocol_version': 2,
      'stream_id': 'b',
      'view_seq': 0,
      'blocks': {'knowledge': []},
    });
    expect(r.stream, 'b');
    expect(r.seq, 0);
    expect(r.blocks!['knowledge'], isEmpty);
  });
}
