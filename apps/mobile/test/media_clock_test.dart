import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/media_clock.dart';

void main() {
  test('public anchor clamps pre-start and end; drift uses the documented threshold', () {
    final start = DateTime.utc(2026, 10, 8);
    final anchor = <String, dynamic>{
      'start_at': start.toIso8601String(),
      'position_ms': 500,
      'rate': 1,
    };
    expect(
      publicMediaPosition(
        anchor,
        start.subtract(const Duration(seconds: 1)),
        5000,
      ),
      500,
    );
    expect(
      publicMediaPosition(anchor, start.add(const Duration(seconds: 2)), 5000),
      2500,
    );
    expect(
      publicMediaPosition(anchor, start.add(const Duration(seconds: 20)), 5000),
      5000,
    );
    for (final drift in [200, 700, 1000]) {
      expect(shouldSeekPublicMedia(2000 + drift, 2000), false);
    }
    expect(shouldSeekPublicMedia(3500, 2000), true);
    expect(shouldSeekPublicMedia(500, 2000), true);
  });

  test(
    'RTT midpoint accounts for latency and filters a slower jitter sample',
    () {
      final start = DateTime.utc(2026, 10, 8);
      final clock = MediaClock();
      for (var i = 0; i < 3; i++) {
        clock.sample(
          start,
          start.add(const Duration(milliseconds: 100)),
          start.add(const Duration(milliseconds: 2050)),
        );
      }
      expect(clock.offset.inMilliseconds, 2000);
      clock.sample(
        start,
        start.add(const Duration(seconds: 5)),
        start.add(const Duration(seconds: 10)),
      );
      expect(clock.offset.inMilliseconds, 2000);
      clock.sample(start, start.subtract(const Duration(seconds: 1)), start);
      expect(clock.offset.inMilliseconds, 2000);
    },
  );
}
