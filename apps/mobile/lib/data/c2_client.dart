import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'room_client.dart';

class C2ViewReducer {
  Json? blocks;
  String stream = '';
  int seq = 0;
  void snapshot(Json value) {
    if (![2, 3].contains(value['protocol_version'])) {
      throw ApiError('UPGRADE_REQUIRED');
    }
    blocks = Map<String, dynamic>.from(value['blocks']);
    stream = value['stream_id'];
    seq = value['view_seq'];
  }

  bool event(Json value) {
    if (value['stream_id'] != stream) throw ApiError('RESYNC_REQUIRED');
    final next = value['view_seq'] as int;
    if (next <= seq) return false;
    if (value['base_view_seq'] != seq || next != seq + 1) {
      throw ApiError('RESYNC_REQUIRED');
    }
    blocks = Map<String, dynamic>.from(value['blocks']);
    seq = next;
    return true;
  }
}

class C2Client extends ChangeNotifier {
  final communicationEvents = StreamController<Json>.broadcast();
  C2Client(this.identity);
  final RoomClient identity;
  final reducer = C2ViewReducer();
  Json? snapshot, pending;
  Json? get view => reducer.blocks;
  String? roomId, error;
  bool busy = false, live = false, closed = false;
  int _ref = 0, _generation = 0;
  String _topic = '';
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat, _reconnect;
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    int? revision,
  ]) => identity.request(method, '/api/v2$path', body, false, false, {
    if (method != 'GET') 'Idempotency-Key': uuid.v4(),
    if (revision != null) 'If-Match': '$revision',
  });
  Future<void> initialize() async {
    await identity.initialize();
    await identity.ensureGuest();
  }

  Future<void> load(String id) async {
    roomId = id;
    await refresh();
    await connect();
  }

  Future<void> refresh() async {
    if (closed || roomId == null) return;
    final current = Map<String, dynamic>.from(
      await request('GET', '/rooms/$roomId/snapshot'),
    );
    if (closed) return;
    snapshot = current;
    reducer.snapshot(current);
    error = null;
    notifyListeners();
  }

  Future<void> connect({bool takeover = false}) async {
    final attempt = ++_generation;
    _heartbeat?.cancel();
    await _subscription?.cancel();
    await _socket?.sink.close();
    try {
      final ticket = await request('POST', '/rooms/$roomId/socket-ticket', {
        'takeover': takeover,
      });
      if (closed || attempt != _generation) return;
      final uri = Uri.parse(identity.base).replace(
        scheme: identity.base.startsWith('https') ? 'wss' : 'ws',
        path: '/socket/websocket',
        queryParameters: {'vsn': '2.0.0', 'ticket': ticket['socket_ticket']},
      );
      final socket = WebSocketChannel.connect(uri);
      _socket = socket;
      await socket.ready.timeout(const Duration(seconds: 10));
      if (closed || attempt != _generation) {
        await socket.sink.close();
        return;
      }
      _topic = 'room:$roomId:member:${ticket['member_id']}';
      _subscription = socket.stream.listen(
        (raw) {
          try {
            final frame = jsonDecode(raw) as List;
            if (frame[2] != _topic) return;
            if (frame[3] == 'phx_reply' &&
                frame[4]['status'] == 'ok' &&
                frame[4]['response']['snapshot'] != null) {
              snapshot = Map<String, dynamic>.from(
                frame[4]['response']['snapshot'],
              );
              reducer.snapshot(snapshot!);
              live = true;
              error = null;
              notifyListeners();
            } else if (frame[3] == 'phx_reply' &&
                frame[4]['status'] == 'error') {
              error = RoomClient.explain(
                ApiError(frame[4]['response']['code'] ?? 'RESYNC_REQUIRED'),
              );
              live = false;
              notifyListeners();
            } else if (frame[3] == 'room.view') {
              if (reducer.event(Map<String, dynamic>.from(frame[4]))) {
                notifyListeners();
              }
              _send('view.ack', {
                'stream_id': reducer.stream,
                'view_seq': reducer.seq,
              });
            } else if (frame[3] == 'voice.state' ||
                frame[3] == 'chat.changed') {
              communicationEvents.add(Map<String, dynamic>.from(frame[4]));
            } else if (frame[3] == 'phx_error' || frame[3] == 'phx_close') {
              _disconnected(attempt);
            }
          } catch (_) {
            unawaited(refresh().catchError((_) {}));
          }
        },
        onError: (_) => _disconnected(attempt),
        onDone: () => _disconnected(attempt),
      );
      _send('phx_join', {
        'protocol_version': snapshot?['protocol_version'] ?? 2,
        'control_epoch': ticket['control_epoch'],
      });
      _heartbeat = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _send('clock.ping', {'nonce': uuid.v4()}),
      );
    } catch (e) {
      error = RoomClient.explain(e);
      live = false;
      notifyListeners();
      if (e is! ApiError ||
          ![
            'TAKEOVER_REQUIRED',
            'STALE_CONTROL',
            'UNAUTHORIZED',
          ].contains(e.code)) {
        _disconnected(attempt);
      }
    }
  }

  void _send(String event, Json body) =>
      _socket?.sink.add(jsonEncode(['1', '${++_ref}', _topic, event, body]));
  void _disconnected(int attempt) {
    if (closed || attempt != _generation) return;
    live = false;
    _heartbeat?.cancel();
    notifyListeners();
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 3), () => unawaited(connect()));
  }

  Future<void> command(String type, [Json body = const {}]) async {
    if (busy || pending != null || snapshot == null) return;
    final envelope = <String, dynamic>{
      'protocol_version': snapshot?['protocol_version'] ?? 2,
      'command_id': uuid.v4(),
      'control_epoch': snapshot!['control_epoch'],
      'step_id': view?['room']['step_id'],
      'type': type,
      'body': body,
    };
    pending = envelope;
    error = null;
    busy = true;
    notifyListeners();
    try {
      final result = await request('POST', '/rooms/$roomId/commands', envelope);
      pending = null;
      if (result['status'] == 'rejected') {
        throw ApiError(
          result['error']?['code'] ?? result['code'] ?? 'COMMAND_REJECTED',
        );
      }
      await refresh();
    } on ApiError catch (e) {
      pending = null;
      error = RoomClient.explain(e);
    } catch (e) {
      error = '发送结果尚未确认，请先检查操作结果';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> recoverCommand() async {
    if (pending == null || busy) return;
    busy = true;
    notifyListeners();
    try {
      final result = await request(
        'GET',
        '/rooms/$roomId/commands/${pending!['command_id']}',
      );
      if (result['status'] != 'pending') {
        pending = null;
        await refresh();
      } else {
        error = '服务器尚未记录此操作，可以用原编号重新发送';
      }
    } catch (e) {
      error = RoomClient.explain(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> retryCommand() async {
    if (pending == null || busy) return;
    busy = true;
    notifyListeners();
    try {
      final result = await request('POST', '/rooms/$roomId/commands', pending);
      pending = null;
      if (result['status'] == 'rejected') {
        throw ApiError(
          result['error']?['code'] ?? result['code'] ?? 'COMMAND_REJECTED',
        );
      }
      await refresh();
    } catch (e) {
      error = RoomClient.explain(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(communicationEvents.close());
    closed = true;
    _generation++;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_socket?.sink.close());
    super.dispose();
  }
}
