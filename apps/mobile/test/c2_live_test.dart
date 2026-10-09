import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/c2_client.dart';
import 'package:ruxi/data/room_client.dart';

void main() {
  test(
    'three real Flutter C2 clients connect, play and recover the saved ending',
    () async {
      final identities = <RoomClient>[];
      final clients = <C2Client>[];
      C2Client? restored;
      try {
        for (var i = 0; i < 3; i++) {
          final identity = RoomClient()..device = uuid.v4();
          identities.add(identity);
          final auth = await identity.request('POST', '/v1/auth/guest', {
            'device_id': identity.device,
            'command_id': uuid.v4(),
          });
          identity.token = auth['access_token'];
          clients.add(C2Client(identity));
        }
        final catalog = await clients[0].request('GET', '/stories');
        final fixture = (catalog['items'] as List).firstWhere(
          (s) =>
              (s['roles'] as List).map((r) => r['id']).join(',') ==
              'guest,doctor,reporter',
        );
        await identities[0].create(fixture['story_id']);
        expect(identities[0].roomId, isNotNull, reason: identities[0].status);
        final created = {
          'room_id': identities[0].roomId!,
          'invite_code': identities[0].invite!,
        };
        for (final c in clients.skip(1)) {
          await c.request('POST', '/rooms/join', {
            'invite_code': created['invite_code'],
          });
        }
        for (var i = 0; i < 3; i++) {
          final c = clients[i];
          await c.load(created['room_id']!);
          await c.command('role.select', {
            'role_id': ['guest', 'doctor', 'reporter'][i],
          });
          await c.command('member.ready', {'ready': true});
        }
        for (var n = 0; n < 100 && !clients.every((c) => c.live); n++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(clients.every((c) => c.live), isTrue);
        await clients[0].command('room.start');
        for (final c in clients) {
          await c.refresh();
          for (final cue in c.view!['narrative_cues']) {
            await c.command('media.complete', {
              'cue_id': cue['id'],
              'mode': 'summary',
            });
          }
        }
        var round = 0;
        for (final action in [
          'ask',
          'move:dining_hall',
          'unlock',
          'move:hall_kitchen',
          'switch_off',
        ]) {
          await clients[0].refresh();
          final current = clients[0].view!['room']['round'] as int;
          if (round != current) {
            round = current;
            for (final c in clients.skip(1)) {
              await c.refresh();
              await c.command('round.end');
            }
          }
          await clients[0].command('action.submit', {
            'action_id': action,
            'target_id': null,
          });
          expect(clients[0].error, isNull, reason: action);
        }
        expect(clients[0].view!['room']['ending']['id'], 'safe');
        restored = C2Client(identities[0]);
        await restored.load(created['room_id']!);
        expect(restored.view!['room']['ending']['id'], 'safe');
        expect(restored.reducer.seq, greaterThan(0));
      } finally {
        restored?.dispose();
        for (final c in clients) {
          c.dispose();
        }
        for (final identity in identities) {
          identity.dispose();
        }
      }
    },
    skip: !const bool.fromEnvironment('RUXI_LIVE_TEST')
        ? 'Requires local Core with published C2 restaurant fixture'
        : false,
  );
}
