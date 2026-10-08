/// Clock estimates keep low-latency samples and smooth network jitter.
class MediaClock {
  final List<({int rtt, int offset})> _samples = [];
  Duration offset = Duration.zero;

  void sample(DateTime sent, DateTime received, DateTime server) {
    final rtt = received.difference(sent).inMicroseconds;
    if (rtt < 0 || rtt > 10000000) return;
    final value = server.difference(sent).inMicroseconds - rtt ~/ 2;
    _samples.add((rtt: rtt, offset: value));
    if (_samples.length > 12) _samples.removeAt(0);
    final best = [..._samples]..sort((a, b) => a.rtt.compareTo(b.rtt));
    final selected = best.take(3).toList();
    final estimate =
        selected.fold<int>(0, (sum, s) => sum + s.offset) ~/ selected.length;
    offset = Duration(
      microseconds: _samples.length == 1
          ? estimate
          : (offset.inMicroseconds * 3 + estimate) ~/ 4,
    );
  }
}

int publicMediaPosition(
  Map<String, dynamic> anchor,
  DateTime serverNow,
  int durationMs,
) {
  final elapsed = serverNow
      .difference(DateTime.parse(anchor['start_at']))
      .inMilliseconds;
  final position =
      (anchor['position_ms'] as num).toInt() +
      (elapsed.clamp(0, 86400000) * (anchor['rate'] as num)).toInt();
  return position.clamp(0, durationMs);
}

/// Medium drift waits for a boundary; playback speed support is not assumed.
bool shouldSeekPublicMedia(int actualMs, int expectedMs) =>
    (actualMs - expectedMs).abs() > 1000;
