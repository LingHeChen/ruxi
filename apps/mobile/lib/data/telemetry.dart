import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

enum Delivery { accepted, invalid, retry }

typedef Diagnostic = Map<String, dynamic>;

/// Optional bounded diagnostics. No gameplay result, text, state or credentials.
class TelemetryQueue {
  TelemetryQueue({
    required this.send,
    required this.read,
    required this.write,
    this.autoFlush = true,
    DateTime Function()? clock,
  }) : now = clock ?? DateTime.now;
  final Future<Delivery> Function(List<Diagnostic>) send;
  final Future<Diagnostic?> Function() read;
  final Future<void> Function(Diagnostic) write;
  final bool autoFlush;
  final DateTime Function() now;
  final _events = <Diagnostic>[];
  final session = const Uuid().v4();
  Timer? _timer;
  bool _closed = false;
  int _failures = 0;
  DateTime? _retryAt;
  Future<void> _tail = Future.value();
  Future<void>? _flight;
  String _batchId = const Uuid().v4();
  String get batchId => _batchId;
  List<Diagnostic>? _retryBatch;
  int get pendingCount => _events.length;
  int get encodedBytes => utf8.encode(jsonEncode({'events': _events})).length;
  static const allowed = {
    'connection_state': {
      'state': ['online', 'offline', 'reconnecting'],
    },
    'screen_view': {
      'screen': ['entry', 'discover', 'lobby', 'play', 'ending', 'account'],
    },
    'media_summary': {
      'reason': ['timeout', 'buffering', 'user'],
    },
    'command_attempt': {
      'kind': [
        'select_role',
        'ready',
        'start',
        'media_complete',
        'investigate',
        'share_clue',
        'offer_item',
        'accept_offer',
        'reject_offer',
        'cancel_offer',
        'vote',
        'request_hint',
        'chat_send',
        'request_pause',
        'confirm_pause',
        'cancel_pause',
        'resume',
        'leave_room',
      ],
    },
  };

  bool _safe(String name, Diagnostic properties) {
    final fields = allowed[name];
    return fields != null &&
        properties.length == 1 &&
        fields.keys.every((key) => fields[key]!.contains(properties[key]));
  }

  Future<void> start() async {
    try {
      final saved = await read();
      if (_closed) return;
      for (final raw in (saved?['events'] as List? ?? []).take(200)) {
        if (raw is! Map) continue;
        final e = Map<String, dynamic>.from(raw);
        final date = DateTime.tryParse(e['occurred_at'] as String? ?? '');
        if (e.length == 7 &&
            e['event_name'] is String &&
            e['properties'] is Map &&
            _safe(
              e['event_name'],
              Map<String, dynamic>.from(e['properties']),
            ) &&
            e['event_id'] is String &&
            e['session_id'] is String &&
            RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(e['event_id']) &&
            RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(e['session_id']) &&
            e['schema_version'] == 1 &&
            e['app_version'] == '0.1.0' &&
            date != null &&
            now().difference(date).inDays < 7 &&
            date.isBefore(now().add(const Duration(minutes: 5)))) {
          _events.add(e);
        }
      }
      _bound();
    } catch (_) {
      /* A corrupt diagnostics cache cannot stop authentication. */
    }
    if (_closed) return;
    if (autoFlush) {
      _timer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(flush()),
      );
    }
    _persist();
  }

  void record(String name, Diagnostic properties) {
    if (_closed || !_safe(name, properties)) return;
    _events.add({
      'event_id': const Uuid().v4(),
      'event_name': name,
      'schema_version': 1,
      'occurred_at': now().toUtc().toIso8601String(),
      'app_version': '0.1.0',
      'session_id': session,
      'properties': Map<String, dynamic>.from(properties),
    });
    _bound();
    _persist();
    if (autoFlush && _events.length >= 20) unawaited(flush());
  }

  void _bound() {
    while (_events.length > 200 || encodedBytes > 1048576) {
      final diagnostic = _events.indexWhere(
        (e) => e['event_name'] == 'connection_state',
      );
      _events.removeAt(diagnostic >= 0 ? diagnostic : 0);
    }
  }

  void _persist() {
    // Coalesce writes: rapid diagnostics do not create an unbounded task queue.
    if (_saving || _closed) {
      _dirty = true;
      return;
    }
    _saving = true;
    _tail = _save();
  }

  bool _saving = false, _dirty = false;
  Future<void> _save() async {
    do {
      _dirty = false;
      final value = jsonDecode(jsonEncode({'events': _events})) as Diagnostic;
      try {
        await write(value);
      } catch (_) {
        /* Disk limits never block play. */
      }
    } while (_dirty && !_closed);
    _saving = false;
  }

  Future<void> flush() {
    if (_closed ||
        _flight != null ||
        _events.isEmpty ||
        (_retryAt != null && now().isBefore(_retryAt!))) {
      return _flight ?? Future.value();
    }
    _flight = _deliver();
    return _flight!;
  }

  Future<void> _deliver() async {
    final batch = <Diagnostic>[];
    for (final event in _retryBatch ?? _events.take(50)) {
      if (utf8
              .encode(
                jsonEncode({
                  'events': [...batch, event],
                }),
              )
              .length >
          65536) {
        break;
      }
      batch.add(event);
    }
    _retryBatch = batch;
    try {
      final result = await send(batch).timeout(const Duration(seconds: 12));
      if (_closed) return;
      if (result == Delivery.retry) {
        _failures = (_failures + 1).clamp(1, 6);
        _retryAt = now().add(Duration(seconds: 1 << _failures));
      } else {
        final ids = batch.map((e) => e['event_id']).toSet();
        _events.removeWhere((e) => ids.contains(e['event_id']));
        _failures = 0;
        _retryAt = null;
        _retryBatch = null;
        _batchId = const Uuid().v4();
        _persist();
      }
    } catch (_) {
      _failures = (_failures + 1).clamp(1, 6);
      _retryAt = now().add(Duration(seconds: 1 << _failures));
    } finally {
      _flight = null;
      if (autoFlush && !_closed && _events.length >= 20 && _retryAt == null) {
        unawaited(flush());
      }
    }
  }

  Future<void> shutdown() async {
    _closed = true;
    _timer?.cancel();
    await _tail;
    await _flight;
    _events.clear();
  }
}
