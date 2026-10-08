import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/room_client.dart';

void main() {
  test(
    'real Flutter client reaches live after creating a room',
    () async {
      final client = RoomClient()..device = uuid.v4();
      try {
        final auth = await client.request('POST', '/v1/auth/guest', {
          'device_id': client.device,
          'command_id': uuid.v4(),
        });
        client.token = auth['access_token'];
        final stories = await client.request('GET', '/v1/stories');
        final created = await client.request('POST', '/v1/rooms', {
          'story_id': stories['items'][0]['story_id'],
          'command_id': uuid.v4(),
        });
        await client.enter(created['room_id']);
        for (var i = 0; i < 100 && client.connection != 'live'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(client.connection, 'live', reason: client.status);
        await client.calibrateClock();
        await client.command('start');
        expect(
          client.pending,
          isEmpty,
          reason: 'Rejected commands must keep their authoritative rejection',
        );
        expect(client.connection, 'live');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(client.connection, 'live');
        expect(client.view?['room']['room_id'], created['room_id']);
        await client.enter(created['room_id']);
        for (var i = 0; i < 100 && client.connection != 'live'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(client.connection, 'live', reason: client.status);
      } finally {
        client.dispose();
        if (client.token.isNotEmpty) {
          await client.request('POST', '/v1/me/erase', {
            'command_id': uuid.v4(),
            'confirmation': 'ERASE_ACCOUNT',
          });
        }
      }
    },
    skip: !const bool.fromEnvironment('RUXI_LIVE_TEST')
        ? 'Requires local Core; run with --dart-define=RUXI_LIVE_TEST=true'
        : false,
  );
}
