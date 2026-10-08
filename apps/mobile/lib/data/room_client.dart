import 'dart:async';

import 'cache.dart';
import 'credentials.dart';
import 'cache_policy.dart';
import 'media_clock.dart';

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef Json = Map<String, dynamic>;
const uuid = Uuid();

class ApiError implements Exception {
  final String code;
  ApiError(this.code);
  @override
  String toString() => code;
}

class ViewReducer {
  Json? view;
  int seq = 0;
  String epoch = '';
  final Map<int, Json> buffer = {};
  static const types = {
    'member_changed',
    'role_selected',
    'ready_changed',
    'room_started',
    'phase_changed',
    'lifecycle_changed',
    'clue_discovered',
    'clue_shared',
    'transfer_offered',
    'transfer_resolved',
    'vote_recorded',
    'vote_settled',
    'hint_pending',
    'hint_ready',
    'hint_failed',
    'chat_added',
    'media_changed',
    'collaboration_changed',
  };
  void snapshot(Json data) {
    view = Map<String, dynamic>.from(data['snapshot']);
    seq = data['base_seq'];
    epoch = data['recovery_epoch'];
    buffer.clear();
  }

  bool event(Json e) {
    if (e['recovery_epoch'] != epoch) throw ApiError('RECOVERY_CHANGED');
    if (!types.contains(e['type'])) throw ApiError('UPGRADE_REQUIRED');
    final n = e['seq'] as int;
    if (n <= seq) return false;
    buffer[n] = e;
    if (buffer.length > 200 ||
        utf8.encode(jsonEncode(buffer.values.toList())).length > 1048576) {
      throw ApiError('RESYNC_REQUIRED');
    }
    var applied = false;
    while (buffer.containsKey(seq + 1)) {
      final next = buffer.remove(seq + 1)!;
      final replace = Map<String, dynamic>.from(next['payload']['replace']);
      const fields = {
        'room',
        'self',
        'members',
        'public_scene',
        'own_role',
        'own_clues',
        'visible_items',
        'offers',
        'available_actions',
        'own_vote',
        'vote_round',
        'hints',
        'chat',
        'media',
        'collaboration',
      };
      if (!replace.keys.every(fields.contains)) {
        throw ApiError('UPGRADE_REQUIRED');
      }
      view = {...view!, ...replace};
      seq++;
      applied = true;
    }
    return applied;
  }
}

class RoomClient extends ChangeNotifier {
  final String base;
  RoomClient({
    this.base = const String.fromEnvironment(
      'API_BASE',
      defaultValue: 'http://localhost:4000',
    ),
  });
  final storage = Credentials();
  String device = '',
      token = '',
      refreshToken = '',
      recoveryCode = '',
      accountId = '';
  final cache = RoomCache();
  String? roomId, memberId, invite;
  int generation = 1;
  final reducer = ViewReducer();
  Json? get view => reducer.view;
  List<dynamic> stories = [], rooms = [];
  String connection = 'disconnected', status = '';
  bool busy = false,
      disposed = false,
      _manualClose = false,
      _repairing = false,
      _connecting = false;
  int _ref = 0, _retry = 0, _connectionGeneration = 0;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat, _reconnect;
  String _join = '', _topic = '', _syncId = '';
  final Map<String, Completer<Json>> _calls = {};
  final Map<String, Json> pending = {};
  final Map<String, int> _receipts = {};
  Json? _retryIntent;
  DateTime serverTime = DateTime.now();
  Duration clockOffset = Duration.zero;
  final mediaClock = MediaClock();
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    bool private = false,
  ]) async {
    final headers = {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (private) 'X-Device-ID': device,
      if (private) 'X-Control-Generation': '$generation',
    };
    final response =
        await (method == 'GET'
                ? http.get(Uri.parse('$base$path'), headers: headers)
                : method == 'PUT'
                ? http.put(
                    Uri.parse('$base$path'),
                    headers: headers,
                    body: jsonEncode(body),
                  )
                : http.post(
                    Uri.parse('$base$path'),
                    headers: headers,
                    body: jsonEncode(body ?? {}),
                  ))
            .timeout(const Duration(seconds: 10));
    final data = jsonDecode(response.body) as Json;
    if (response.statusCode >= 400) throw ApiError(data['error']['code']);
    if (data['meta']?['server_time'] != null) {
      serverTime = DateTime.parse(data['meta']['server_time']);
      // HTTP timestamps are useful before sync; they do not replace measured RTT samples.
      if (connection != 'live') {
        clockOffset = serverTime.difference(DateTime.now().toUtc());
      }
    }
    return data['data'];
  }

  Future<void> initialize() async {
    busy = true;
    notifyListeners();
    try {
      device = await storage.read(key: 'device') ?? uuid.v4();
      await storage.write(key: 'device', value: device);
      token = await storage.read(key: 'access') ?? '';
      refreshToken = await storage.read(key: 'refresh') ?? '';
      recoveryCode = await storage.read(key: 'recovery') ?? '';
      accountId = await storage.read(key: 'account') ?? '';
      await restoreCache();
      if (token.isEmpty) {
        await _saveAuth(
          await request('POST', '/v1/auth/guest', {
            'device_id': device,
            'command_id': uuid.v4(),
          }),
        );
      } else {
        try {
          await request('GET', '/v1/me');
        } catch (_) {
          await refresh();
        }
      }
      accountId = (await request('GET', '/v1/me'))['user_id'];
      await storage.write(key: 'account', value: accountId);
      await catalog();
      if (view == null) await restoreCache();
      if (roomId != null) {
        _manualClose = false;
        await connect();
      }
    } catch (e) {
      status = explain(e);
    } finally {
      busy = false;
    }
    notifyListeners();
  }

  Future<void> restoreCache() async {
    if (accountId.isEmpty) return;
    try {
      final raw = await cache.read(accountId);
      if (raw == null) return;
      final saved = retainedCache(raw, DateTime.now().toUtc());
      if (saved == null) {
        await cache.clear(accountId);
        return;
      }
      roomId = saved['room_id'];
      reducer.snapshot(saved);
      generation = view!['self']['control_generation'];
      memberId = view!['self']['membership_id'];
      for (final entry in (saved['pending'] as Map).entries) {
        pending[entry.key] = Map<String, dynamic>.from(entry.value);
      }
      notifyListeners();
    } catch (_) {
      // A corrupt local cache must not prevent fresh authentication and synchronization.
      await cache.clear(accountId);
      reducer.view = null;
      roomId = null;
      memberId = null;
      pending.clear();
    }
  }

  Future<void> _saveAuth(Json a) async {
    final nextAccount = a['user_id'] as String;
    if (accountId.isNotEmpty && accountId != nextAccount) {
      await cache.clear(accountId);
      pending.clear();
      reducer.view = null;
      roomId = null;
      memberId = null;
    }
    accountId = nextAccount;
    await storage.write(key: 'account', value: accountId);
    token = a['access_token'];
    refreshToken = a['refresh_token'];
    recoveryCode = a['recovery_code'] ?? recoveryCode;
    await storage.write(key: 'access', value: token);
    await storage.write(key: 'refresh', value: refreshToken);
    await storage.write(key: 'recovery', value: recoveryCode);
  }

  Future<void> refresh() async => _saveAuth(
    await request('POST', '/v1/auth/refresh', {
      'device_id': device,
      'refresh_token': refreshToken,
      'refresh_request_id': uuid.v4(),
    }),
  );

  Future<void> eraseAccount() => run(() async {
    await request('POST', '/v1/me/erase', {
      'command_id': uuid.v4(),
      'confirmation': 'ERASE_ACCOUNT',
    });
    close();
    if (accountId.isNotEmpty) await cache.clear(accountId);
    for (final key in ['access', 'refresh', 'recovery', 'account', 'device']) {
      await storage.delete(key: key);
    }
    token = refreshToken = recoveryCode = accountId = '';
    roomId = memberId = null;
    generation = 1;
    reducer.view = null;
    reducer.buffer.clear();
    pending.clear();
    _receipts.clear();
    _retryIntent = null;
    await initialize();
    status = token.isEmpty ? '原身份已注销，新身份暂时无法建立。' : '原身份已注销，已建立新的游客身份。';
  });
  Future<void> recover(String code) async {
    await run(() async {
      close();
      await _saveAuth(
        await request('POST', '/v1/auth/recover', {
          'device_id': device,
          'recovery_code': code.trim(),
          'recovery_request_id': uuid.v4(),
        }),
      );
      roomId = null;
      reducer.view = null;
      pending.clear();
      await cache.clear(accountId);
      await catalog();
    });
  }

  Future<void> catalog() async {
    stories = (await request('GET', '/v1/stories'))['items'];
    rooms = (await request('GET', '/v1/rooms'))['items'];
    notifyListeners();
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    busy = true;
    status = '';
    notifyListeners();
    try {
      await work();
    } catch (e) {
      status = explain(e);
    } finally {
      busy = false;
      if (!disposed) notifyListeners();
    }
  }

  Future<void> create(String story) async => run(() async {
    final r = await request('POST', '/v1/rooms', {
      'story_id': story,
      'command_id': uuid.v4(),
    });
    invite = r['invite_code'];
    await enter(r['room_id']);
  });
  Future<void> join(String code) async => run(() async {
    final r = await request('POST', '/v1/rooms/join', {
      'invite_code': code.trim().toUpperCase(),
      'command_id': uuid.v4(),
    });
    invite = code.trim().toUpperCase();
    await enter(r['room_id']);
  });
  Future<void> enter(String id, {bool takeover = false}) async {
    close();
    roomId = id;
    reducer.view = null;
    reducer.seq = 0;
    pending.clear();
    _receipts.clear();
    _retryIntent = null;
    _manualClose = false;
    await connect(takeover: takeover);
  }

  Future<void> connect({bool takeover = false}) async {
    if (_connecting || disposed || roomId == null) return;
    _connecting = true;
    final attempt = ++_connectionGeneration;
    connection = 'connecting';
    notifyListeners();
    try {
      final ticket = await request('POST', '/v1/rooms/$roomId/socket-ticket', {
        'device_id': device,
        'takeover': takeover,
        if (takeover) 'command_id': uuid.v4(),
      });
      if (attempt != _connectionGeneration || disposed) return;
      generation = ticket['control_generation'];
      memberId = ticket['membership_id'];
      final uri = Uri.parse(base).replace(
        scheme: base.startsWith('https') ? 'wss' : 'ws',
        path: '/socket/websocket',
        queryParameters: {'vsn': '2.0.0', 'ticket': ticket['socket_ticket']},
      );
      _socket = WebSocketChannel.connect(uri);
      await _socket!.ready;
      _topic = 'player_room:$roomId:$memberId';
      _join = '${++_ref}';
      connection = 'joining';
      _subscription = _socket!.stream.listen(
        (raw) => _message(raw, attempt),
        onDone: () => _lost(attempt),
        onError: (_) => _lost(attempt),
      );
      _send('phx_join', {
        'protocol_version': 1,
        'control_generation': generation,
        'recovery_epoch': reducer.epoch,
        'last_seq': reducer.seq,
        'has_snapshot': view != null,
      }, ref: _join);
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) async {
        try {
          await _call('heartbeat', {}, topic: 'phoenix');
          if (connection == 'live') await calibrateClock();
        } catch (_) {
          _lost(attempt);
        }
      });
    } catch (e) {
      status = explain(e);
      if (e is ApiError &&
          [
            'CONTROL_CONFIRMATION_REQUIRED',
            'CONTROL_REPLACED',
            'UNAUTHORIZED',
          ].contains(e.code)) {
        connection = e.code == 'UNAUTHORIZED'
            ? 'auth_expired'
            : 'control_replaced';
      } else {
        _schedule();
      }
    } finally {
      _connecting = false;
      if (!disposed) notifyListeners();
    }
  }

  void _send(String event, Json payload, {String? ref, String? topic}) =>
      _socket?.sink.add(
        jsonEncode([
          event == 'heartbeat' ? null : _join,
          ref ?? '${++_ref}',
          topic ?? _topic,
          event,
          payload,
        ]),
      );
  Future<Json> _call(String event, Json payload, {String? topic}) async {
    final ref = '${++_ref}';
    final completer = Completer<Json>();
    _calls[ref] = completer;
    _send(event, payload, ref: ref, topic: topic);
    try {
      return await completer.future.timeout(const Duration(seconds: 8));
    } finally {
      _calls.remove(ref);
    }
  }

  Future<void> calibrateClock() async {
    final sent = DateTime.now().toUtc();
    final clock = await _call('clock_ping', {
      'nonce': uuid.v4(),
      'client_sent_at': sent.toIso8601String(),
    });
    mediaClock.sample(
      sent,
      DateTime.now().toUtc(),
      DateTime.parse(clock['server_sent_at']),
    );
    clockOffset = mediaClock.offset;
  }

  void _message(dynamic raw, int attempt) async {
    if (attempt != _connectionGeneration || disposed) return;
    try {
      final f = jsonDecode(raw as String) as List;
      final event = f[3];
      final p = Map<String, dynamic>.from(f[4]);
      if (event == 'phx_reply') {
        final response = Map<String, dynamic>.from(p['response']);
        if (f[1] == _join) {
          if (p['status'] != 'ok') throw ApiError(response['error']['code']);
          connection = 'syncing';
          _syncId = response['sync_id'];
        }
        final c = _calls[f[1]];
        if (c != null && !c.isCompleted) c.complete(response);
      } else if (event == 'sync_snapshot') {
        if (reducer.epoch.isNotEmpty && reducer.epoch != p['recovery_epoch']) {
          pending.clear();
          _receipts.clear();
          _retryIntent = null;
        }
        reducer.snapshot(p);
        _syncId = p['sync_id'];
      } else if (event == 'view_event') {
        if (view == null) return;
        reducer.event(p);
        _resolveReceipts();
        if (reducer.buffer.isNotEmpty) await repair();
      } else if (event == 'sync_complete') {
        if (p['sync_id'] != _syncId) return;
        if (reducer.seq < p['through_seq']) await repair();
        if (reducer.seq >= p['through_seq']) {
          final ack = await _call('sync_ack', {
            'sync_id': _syncId,
            'last_seq': reducer.seq,
          });
          if (ack['error'] != null) throw ApiError(ack['error']['code']);
          connection = 'live';
          _retry = 0;
          await calibrateClock();
          await confirmPending();
        }
      } else if (event == 'watermark') {
        if (p['recovery_epoch'] != reducer.epoch) {
          throw ApiError('RECOVERY_CHANGED');
        }
        if (p['view_seq'] > reducer.seq) await repair();
      } else if (event == 'auth_expiring') {
        await refresh();
        _lost(attempt);
      } else if (event == 'resync_required') {
        throw ApiError(p['reason'] ?? 'RESYNC_REQUIRED');
      } else if (event == 'phx_close' || event == 'phx_error') {
        _lost(attempt);
      }
      await persist();
      if (!disposed) notifyListeners();
    } catch (e) {
      status = explain(e);
      if (e is ApiError && e.code == 'CONTROL_REPLACED') {
        connection = 'control_replaced';
        close(keepRoom: true);
      } else if (e is ApiError && e.code == 'UPGRADE_REQUIRED') {
        connection = 'upgrade_required';
        close(keepRoom: true);
      } else {
        reducer.view = null;
        _lost(attempt);
      }
      if (!disposed) notifyListeners();
    }
  }

  Future<void> repair() async {
    if (_repairing || roomId == null) return;
    _repairing = true;
    try {
      int? through;
      while (true) {
        final page = await request(
          'GET',
          '/v1/rooms/$roomId/events?after_seq=${reducer.seq}&recovery_epoch=${reducer.epoch}${through == null ? '' : '&through_seq=$through'}',
          null,
          true,
        );
        through = page['high_watermark'];
        for (final e in page['events']) {
          reducer.event(Map<String, dynamic>.from(e));
        }
        if (page['has_more'] != true) break;
      }
      _resolveReceipts();
    } on ApiError catch (e) {
      if (![
        'RESYNC_REQUIRED',
        'CURSOR_AHEAD',
        'RECOVERY_CHANGED',
      ].contains(e.code)) {
        rethrow;
      }
      final snapshot = Map<String, dynamic>.from(
        await request('GET', '/v1/rooms/$roomId/snapshot', null, true),
      );
      if (snapshot['recovery_epoch'] != reducer.epoch) {
        pending.clear();
        _receipts.clear();
        _retryIntent = null;
      }
      reducer.snapshot(snapshot);
      await persist();
    } finally {
      _repairing = false;
    }
  }

  Future<void> takeControl() async => run(() async {
    close(keepRoom: true);
    _manualClose = false;
    await connect(takeover: true);
  });

  bool get canAct => connection == 'live' && !busy && pending.isEmpty;
  Future<void> command(
    String type, [
    Json payload = const {},
    int? targetVersion,
  ]) async {
    if (!canAct) return;
    final intent = {
      'protocol_version': 1,
      'command_id': uuid.v4(),
      'recovery_epoch': reducer.epoch,
      'phase_id': view!['room']['phase_id'],
      'control_generation': generation,
      'type': type,
      'payload': payload,
      'target_version': ?targetVersion,
    };
    pending[intent['command_id'] as String] = intent;
    _retryIntent = intent;
    status = '提交中…';
    notifyListeners();
    try {
      await persist();
    } catch (_) {
      pending.remove(intent['command_id']);
      status = '无法保存操作，请检查设备存储';
      notifyListeners();
      return;
    }
    await _submit(intent);
  }

  Future<void> _submit(Json intent) async {
    try {
      final r = await _call('command', {
        ...intent,
        'control_generation': generation,
      });
      if (r['error'] != null) {
        pending.remove(intent['command_id']);
        _retryIntent = null;
        status = explain(ApiError(r['error']['code']));
      } else {
        _receipts[intent['command_id']] = r['receipt_seq'];
        status = '已提交，正在同步';
        _resolveReceipts();
      }
    } catch (_) {
      status = '正在确认结果，请勿重复操作';
    }
    await persist();
    if (!disposed) notifyListeners();
  }

  void _resolveReceipts() {
    final done = _receipts.entries
        .where((e) => e.value <= reducer.seq)
        .map((e) => e.key)
        .toList();
    for (final id in done) {
      pending.remove(id);
      _receipts.remove(id);
      if (_retryIntent?['command_id'] == id) _retryIntent = null;
    }
    if (done.isNotEmpty) status = '已同步';
  }

  Future<void> confirmPending() async {
    for (final intent in pending.values.toList()) {
      try {
        final r = await request(
          'GET',
          '/v1/rooms/$roomId/commands/${intent['command_id']}',
          null,
          true,
        );
        if (r['status'] == 'committed') {
          _receipts[intent['command_id']] = r['receipt_seq'];
          await repair();
          _resolveReceipts();
        } else {
          pending.remove(intent['command_id']);
          status = explain(ApiError(r['error']['code']));
        }
      } catch (e) {
        if (e is ApiError &&
            e.code == 'COMMAND_NOT_FOUND' &&
            intent['phase_id'] == view?['room']['phase_id'] &&
            intent['recovery_epoch'] == reducer.epoch) {
          await _submit(intent);
        } else {
          status = '旧操作结果未确认；请查看当前状态';
        }
      }
    }
    if (!disposed) notifyListeners();
  }

  Future<Json> mediaAccess(Json media) async => Map<String, dynamic>.from(
    await request('POST', '/v1/media/access', {
      'room_id': roomId,
      'asset_id': media['asset_id'],
      'device_id': device,
      'control_generation': generation,
    }),
  );
  void _lost(int attempt) {
    if (attempt != _connectionGeneration || _manualClose || disposed) return;
    _heartbeat?.cancel();
    _subscription?.cancel();
    _socket?.sink.close();
    _schedule();
  }

  void _schedule() {
    connection = 'reconnecting';
    _reconnect?.cancel();
    final seconds = min(30, pow(2, min(_retry++, 5)).toInt());
    _reconnect = Timer(
      Duration(
        milliseconds: seconds * 1000 + Random().nextInt(seconds * 300 + 1),
      ),
      () => connect(),
    );
    if (!disposed) notifyListeners();
  }

  void close({bool keepRoom = false}) {
    _manualClose = true;
    _connectionGeneration++;
    _reconnect?.cancel();
    _heartbeat?.cancel();
    _subscription?.cancel();
    _socket?.sink.close();
    for (final c in _calls.values) {
      if (!c.isCompleted) c.completeError(ApiError('DISCONNECTED'));
    }
    _calls.clear();
    if (!keepRoom) connection = 'disconnected';
  }

  Future<void> persist() async {
    if (accountId.isEmpty || roomId == null || view == null) return;
    await cache.write(accountId, {
      'room_id': roomId,
      'snapshot': view,
      'base_seq': reducer.seq,
      'recovery_epoch': reducer.epoch,
      'pending': pending,
    });
  }

  Future<void> backToCatalog() async {
    close();
    await cache.clear(accountId);
    roomId = null;
    reducer.view = null;
    pending.clear();
    await catalog();
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    close();
    super.dispose();
  }

  static String explain(Object e) {
    final code = e is ApiError ? e.code : '';
    return const {
          'ROLE_TAKEN': '角色已被队友选择',
          'ROOM_NOT_READY': '等待三位成员在线并准备',
          'NOT_ALLOWED': '当前条件不允许此操作',
          'PHASE_CHANGED': '阶段已变化，请查看最新状态',
          'TARGET_CHANGED': '目标状态已变化',
          'CONTROL_CONFIRMATION_REQUIRED': '此房间正在另一台设备使用，请确认接管',
          'CONTROL_REPLACED': '房间已由另一台设备接管',
          'UNAUTHORIZED': '凭证失效，请使用保存的恢复码找回身份',
          'AUTH_EXPIRED': '登录已过期，请恢复身份',
          'INVITE_UNAVAILABLE': '邀请码不可用、房间已满或已经开局',
          'CONTENT_BLOCKED': '剧目暂时不可用',
          'RECOVERY_CHANGED': '服务器已恢复备份，正在重新同步',
          'UPGRADE_REQUIRED': '协议已更新，请升级应用',
          'SERVICE_UNAVAILABLE': '服务暂时不可用，请稍后重试',
        }[code] ??
        '连接或操作失败，请重试${code.isEmpty ? '' : ' · $code'}';
  }
}
