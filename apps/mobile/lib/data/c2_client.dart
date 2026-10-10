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
  int _ref = 1, _generation = 0;
  String _topic = '';
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat, _reconnect;
  final Map<String, Completer<Json>> _replies = {};
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
    _reconnect?.cancel();
    _heartbeat?.cancel();
    live = false;
    _failReplies();
    await _subscription?.cancel();
    await _socket?.sink.close();
    final joined = Completer<void>();
    try {
      final ticket = await request('POST', '/rooms/$roomId/socket-ticket', {
        'takeover': takeover,
      });
      if (closed || attempt != _generation) return;
      final uri = Uri.parse(identity.base).replace(
        scheme: identity.base.startsWith('https') ? 'wss' : 'ws',
        path: '/api/socket/websocket',
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
            if (frame[3] == 'phx_reply' && _replies.containsKey(frame[1])) {
              final reply = _replies.remove(frame[1])!;
              final response = Map<String, dynamic>.from(frame[4]['response']);
              if (frame[4]['status'] == 'ok') {
                reply.complete(response);
              } else {
                reply.completeError(
                  ApiError(response['code'] ?? 'COMMAND_REJECTED'),
                );
              }
              return;
            }
            if (frame[3] == 'phx_reply' &&
                frame[4]['status'] == 'ok' &&
                frame[4]['response']['snapshot'] != null) {
              snapshot = Map<String, dynamic>.from(
                frame[4]['response']['snapshot'],
              );
              reducer.snapshot(snapshot!);
              live = true;
              if (!joined.isCompleted) joined.complete();
              error = null;
              notifyListeners();
            } else if (frame[3] == 'phx_reply' &&
                frame[1] == '1' &&
                frame[4]['status'] == 'error') {
              final failure = ApiError(
                frame[4]['response']['code'] ?? 'RESYNC_REQUIRED',
              );
              if (!joined.isCompleted) joined.completeError(failure);
              error = RoomClient.explain(failure);
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
              communicationEvents.add({
                ...Map<String, dynamic>.from(frame[4]),
                'type': frame[3],
              });
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
      socket.sink.add(
        jsonEncode([
          '1',
          '1',
          _topic,
          'phx_join',
          {
            'protocol_version': snapshot?['protocol_version'] ?? 2,
            'control_epoch': ticket['control_epoch'],
          },
        ]),
      );
      _heartbeat = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _send('clock.ping', {'nonce': uuid.v4()}),
      );
      await joined.future.timeout(const Duration(seconds: 15));
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
  void _failReplies() {
    final replies = _replies.values.toList();
    _replies.clear();
    for (final reply in replies) {
      if (!reply.isCompleted) {
        reply.completeError(ApiError('SERVICE_UNAVAILABLE'));
      }
    }
  }

  Future<Json> _submitCommand(Json envelope) =>
      _channelRequest('room.command', envelope);

  Future<Json> interactionQuote(Json body) =>
      _channelRequest('interaction.quote', body);

  Future<Json> _channelRequest(String event, Json body) async {
    if (!live || _socket == null) {
      throw ApiError('SERVICE_UNAVAILABLE');
    }
    final reference = '${++_ref}';
    final reply = Completer<Json>();
    _replies[reference] = reply;
    try {
      _socket!.sink.add(jsonEncode(['1', reference, _topic, event, body]));
      return await reply.future.timeout(const Duration(seconds: 15));
    } finally {
      _replies.remove(reference);
    }
  }

  void _disconnected(int attempt) {
    if (closed || attempt != _generation) return;
    live = false;
    _failReplies();
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
    await retryCommand();
  }

  Future<void> recoverCommand() async {
    if (pending == null || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      var result = await request(
        'GET',
        '/rooms/$roomId/commands/${pending!['command_id']}',
      );
      if (result['status'] == 'pending') {
        // An absent receipt is not permission to create a new command. Replay
        // the same envelope so a late original response cannot duplicate work.
        result = await _submitCommand(pending!);
      }
      await _acceptCommandResult(result);
    } catch (e) {
      error = '操作结果仍待确认，请重试恢复。${RoomClient.explain(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _acceptCommandResult(Json result) async {
    if (result['status'] == 'pending') {
      error = '操作正在处理，请稍后恢复';
      return;
    }
    pending = null;
    if (result['status'] == 'rejected') {
      error = RoomClient.explain(
        ApiError(
          result['error']?['code'] ?? result['code'] ?? 'COMMAND_REJECTED',
        ),
      );
    }
    final receiptSeq = result['receipt_seq'];
    if (live && receiptSeq is int) {
      if (reducer.seq < receiptSeq) {
        final applied = Completer<void>();
        void onView() {
          if (!applied.isCompleted &&
              (closed || !live || reducer.seq >= receiptSeq)) {
            applied.complete();
          }
        }

        addListener(onView);
        try {
          await applied.future.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          await refresh();
        } finally {
          removeListener(onView);
        }
      }
    } else {
      await refresh();
    }
  }

  Future<void> retryCommand() async {
    if (pending == null || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await _submitCommand(pending!);
      await _acceptCommandResult(result);
    } on ApiError catch (e) {
      // Transient HTTP errors do not establish whether the command committed.
      if (![
        'SERVICE_UNAVAILABLE',
        'INTERNAL_ERROR',
        'RATE_LIMITED',
      ].contains(e.code)) {
        pending = null;
        await refresh();
      }
      error = RoomClient.explain(e);
    } catch (e) {
      error = '操作结果尚未确认，请点击恢复操作；不会重复消耗行动点';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(communicationEvents.close());
    closed = true;
    _failReplies();
    _generation++;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_socket?.sink.close());
    super.dispose();
  }
}
