import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/c2_client.dart';
import 'package:ruxi/data/room_client.dart';

Json view(int seq) => {
  'protocol_version': 2,
  'stream_id': 'stream',
  'view_seq': seq,
  'control_epoch': 1,
  'blocks': {
    'room': {'step_id': null},
    'value': seq,
  },
};

class TestClient extends C2Client {
  TestClient(super.identity);
  int snapshots = 0;
  final httpPosts = <String>[];
  @override
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    int? revision,
  ]) async {
    if (path.endsWith('/socket-ticket')) {
      return {
        'socket_ticket': 'test',
        'member_id': 'member',
        'control_epoch': 1,
      };
    }
    if (method == 'GET' && path.endsWith('/snapshot')) {
      snapshots++;
      return view(0);
    }
    if (method == 'GET' && path.contains('/commands/')) {
      return {'status': 'pending'};
    }
    if (method == 'POST') httpPosts.add(path);
    throw StateError('Unexpected HTTP $method $path');
  }
}

void main() {
  for (final viewFirst in [true, false]) {
    test(
      'commands use WS and apply view without HTTP refresh (viewFirst=$viewFirst)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final received = <Json>[];
        var dropped = false;
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.listen((raw) async {
            final f = jsonDecode(raw as String) as List;
            void reply(String status, Json body) => socket.add(
              jsonEncode([
                f[0],
                f[1],
                f[2],
                'phx_reply',
                {'status': status, 'response': body},
              ]),
            );
            if (f[3] == 'phx_join') {
              reply('ok', {'snapshot': view(0)});
            } else if (f[3] == 'interaction.quote') {
              reply('ok', {'quote_id': 'quoted'});
            } else if (f[3] == 'room.command') {
              received.add(Map<String, dynamic>.from(f[4]));
              if (f[4]['type'] == 'drop' && !dropped) {
                dropped = true;
                await socket.close();
                return;
              }
              if (f[4]['type'] == 'reject') {
                reply('error', {'code': 'NOT_ALLOWED'});
                return;
              }
              void pushView() => socket.add(
                jsonEncode([
                  null,
                  null,
                  f[2],
                  'room.view',
                  {
                    'stream_id': 'stream',
                    'base_view_seq': 0,
                    'view_seq': 1,
                    'blocks': {
                      'room': {'step_id': null},
                      'value': 1,
                    },
                  },
                ]),
              );
              if (viewFirst) pushView();
              reply('ok', {'status': 'committed', 'receipt_seq': 1});
              if (!viewFirst) {
                await Future<void>.delayed(const Duration(milliseconds: 20));
                pushView();
              }
            }
          });
        });
        final identity = RoomClient(base: 'http://127.0.0.1:${server.port}');
        final client = TestClient(identity);
        try {
          await client.load('room');
          expect(client.live, isTrue);
          await client.command('action.submit', {'action_id': 'inspect'});
          expect(received.single['type'], 'action.submit');
          expect(received.single['body'], {'action_id': 'inspect'});
          expect(client.pending, isNull);
          expect(client.error, isNull);
          expect(client.view!['value'], 1);
          expect(client.snapshots, 1);
          expect(client.httpPosts, isEmpty);
          await client.command('reject');
          expect(
            client.live,
            isTrue,
            reason: 'Business rejection must not disconnect the channel',
          );
          expect(client.pending, isNull);
          expect(client.error, isNotNull);
          await client.command('drop');
          expect(client.live, isFalse);
          final uncertainId = client.pending!['command_id'];
          await client.connect();
          expect(client.live, isTrue);
          await client.recoverCommand();
          expect(client.pending, isNull);
          expect(client.error, isNull);
          expect(received.last['command_id'], uncertainId);
          expect(client.httpPosts, isEmpty);
        } finally {
          client.dispose();
          identity.dispose();
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
        }
      },
    );
  }
}
