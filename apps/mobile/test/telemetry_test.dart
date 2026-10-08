import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/telemetry.dart';

void main() {
  testWidgets(
    'twenty events flush immediately and sparse diagnostics flush at ten seconds',
    (tester) async {
      var delivered = 0;
      final queue = TelemetryQueue(
        read: () async => null,
        write: (_) async {},
        send: (events) async {
          delivered += events.length;
          return Delivery.accepted;
        },
      );
      await queue.start();
      for (var i = 0; i < 19; i++) {
        queue.record('screen_view', {'screen': 'play'});
      }
      await tester.pump();
      expect(delivered, 0);
      queue.record('screen_view', {'screen': 'play'});
      await tester.pump();
      expect(delivered, 20);
      queue.record('connection_state', {'state': 'offline'});
      await tester.pump(const Duration(seconds: 9));
      expect(delivered, 20);
      await tester.pump(const Duration(seconds: 1));
      expect(delivered, 21);
      await queue.shutdown();
    },
  );
  test(
    'bounded diagnostics reject text and cap queue before serializing batches',
    () async {
      final batches = <List<Diagnostic>>[];
      Diagnostic? stored;
      final queue = TelemetryQueue(
        autoFlush: false,
        read: () async => null,
        write: (value) async {
          stored = value;
        },
        send: (events) async {
          batches.add(events);
          return Delivery.accepted;
        },
      );
      await queue.start();
      queue.record('command_attempt', {'kind': 'chat_send', 'text': 'secret'});
      queue.record('game_finished', {'ending': 'E1'});
      expect(queue.pendingCount, 0);
      for (var i = 0; i < 300; i++) {
        queue.record('connection_state', {'state': 'offline'});
      }
      expect(queue.pendingCount, 200);
      expect(queue.encodedBytes, lessThanOrEqualTo(1048576));
      await queue.flush();
      expect(batches.single.length, 50);
      expect(
        utf8.encode(jsonEncode({'events': batches.single})).length,
        lessThanOrEqualTo(65536),
      );
      expect(queue.pendingCount, 150);
      await queue.shutdown();
      expect(stored?['events'], isNotEmpty);
    },
  );

  test(
    'failed delivery keeps IDs, backs off and accepts new events during flight',
    () async {
      var time = DateTime.utc(2026, 10, 8);
      final attempts = <List<Diagnostic>>[];
      final gate = Completer<Delivery>();
      final queue = TelemetryQueue(
        autoFlush: false,
        clock: () => time,
        read: () async => null,
        write: (_) async {},
        send: (events) async {
          attempts.add(events);
          return attempts.length == 1 ? await gate.future : Delivery.accepted;
        },
      );
      await queue.start();
      queue.record('screen_view', {'screen': 'play'});
      final first = queue.flush();
      queue.record('connection_state', {'state': 'offline'});
      gate.complete(Delivery.retry);
      await first;
      await queue.flush();
      expect(attempts.length, 1);
      expect(queue.pendingCount, 2);
      time = time.add(const Duration(seconds: 3));
      await queue.flush();
      expect(attempts.last.first['event_id'], attempts.first.first['event_id']);
      expect(queue.pendingCount, 1);
      await queue.flush();
      expect(queue.pendingCount, 0);
      await queue.shutdown();
    },
  );

  test('invalid batches are dropped and corrupt persisted properties are never sent', () async {
    final queue = TelemetryQueue(
      autoFlush: false,
      read: () async => {
        'events': [
          {
            'event_name': 'command_attempt',
            'properties': {'kind': 'vote', 'vote': 'private'},
          },
        ],
      },
      write: (_) async {},
      send: (_) async => Delivery.invalid,
    );
    await queue.start();
    expect(queue.pendingCount, 0);
    queue.record('screen_view', {'screen': 'entry'});
    await queue.flush();
    expect(queue.pendingCount, 0);
    await queue.shutdown();
  });
}
