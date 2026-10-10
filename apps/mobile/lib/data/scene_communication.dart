import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'c2_client.dart';
import 'audio_session_coordinator.dart';
import 'room_client.dart';
import 'voice/rtc_client.dart';

class SceneCommunication extends ChangeNotifier with WidgetsBindingObserver {
  SceneCommunication(this.client, {VolcRtcClient? rtc})
    : rtc = rtc ?? createRtcClient() {
    WidgetsBinding.instance.addObserver(this);
    client.addListener(worldChanged);
    subscription = client.communicationEvents.stream.listen((event) {
      if (event['type'] == 'voice.state' && event['state'] is Map) {
        unawaited(applyVoice(Map<String, dynamic>.from(event['state'])));
      } else {
        unawaited(refresh(chat: true, voiceState: false));
      }
    });
    timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (foreground && !_refreshing) unawaited(refresh());
    });
    unawaited(loadPreferences());
  }
  final C2Client client;
  final VolcRtcClient rtc;
  Timer? timer, heartbeat;
  StreamSubscription<Json>? subscription;
  Json? voice, grant;
  List<Json> messages = [];
  List<String> scopes = ['global'];
  String? error;
  bool sending = false,
      joining = false,
      mic = false,
      connected = false,
      foreground = true,
      _disposed = false,
      _refreshing = false,
      _refreshChatAgain = false,
      _refreshVoiceAgain = false;
  int localGeneration = 0, unread = 0;
  int _micAttempt = 0;
  bool sceneConsent = false;
  double listeningVolume = 1;
  final audio = AudioSessionCoordinator.instance;
  bool pushToTalk = false;
  final Map<String, double> peerVolumes = {};
  String? _worldKey;
  int get epoch => client.snapshot?['control_epoch'] ?? 1;
  String? get room => client.roomId;
  Future<dynamic> api(String method, String path, [Json? body]) =>
      client.identity.request(method, '/api/v2/rooms/$room$path', body);
  Future<void> loadPreferences() async {
    try {
      final p = await SharedPreferences.getInstance();
      listeningVolume = p.getDouble('scene_voice_volume') ?? 1;
      pushToTalk = p.getBool('scene_voice_ptt') ?? false;
      audio.configure(
        masterVolume: p.getDouble('scene_audio_master') ?? 1,
        narrationVolume: p.getDouble('scene_audio_narration') ?? 1,
        bgmVolume: p.getDouble('scene_audio_bgm') ?? 0.7,
        duck: p.getBool('scene_audio_duck') ?? true,
      );
      changed();
    } catch (_) {}
  }

  Future<void> preferences({double? volume, bool? ptt}) async {
    listeningVolume = volume ?? listeningVolume;
    pushToTalk = ptt ?? pushToTalk;
    if (ptt != null) await microphone(false);
    for (final m in voice?['members'] ?? []) {
      if (m['rtc_uid'] != null) {
        rtc.volume(
          m['rtc_uid'],
          listeningVolume * (peerVolumes[m['member_id']] ?? 1),
        );
      }
    }
    changed();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('scene_voice_volume', listeningVolume);
      await p.setBool('scene_voice_ptt', pushToTalk);
    } catch (_) {
      error = '音频偏好未保存，请稍后重试';
      changed();
    }
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  void worldChanged() {
    final key =
        '${client.view?['self']?['location']}:${client.view?['room']?['status']}:$epoch:${client.live}';
    if (key != _worldKey) {
      if (_worldKey != null) unawaited(stop());
      _worldKey = key;
      unawaited(refresh());
    }
  }

  Future<void> refresh({bool chat = true, bool voiceState = true}) async {
    if (_disposed || room == null) return;
    if (_refreshing) {
      _refreshChatAgain |= chat;
      _refreshVoiceAgain |= voiceState;
      return;
    }
    _refreshing = true;
    try {
      if (chat) {
        final history = await api('GET', '/chat');
        if (_disposed) return;
        final next = (history['messages'] as List).cast<Json>();
        final old = messages.map((m) => m['id']).toSet();
        unread += next
            .where(
              (m) =>
                  !old.contains(m['id']) &&
                  m['sender_id'] != client.view?['own_member_id'],
            )
            .length;
        messages = next;
        scopes = (history['scopes'] as List).cast<String>();
      }
      if (voiceState) await applyVoice(await api('GET', '/voice'));
      changed();
    } catch (_) {
      if (grant != null) await stop();
    } finally {
      _refreshing = false;
      if ((_refreshChatAgain || _refreshVoiceAgain) && !_disposed) {
        final chatAgain = _refreshChatAgain;
        final voiceAgain = _refreshVoiceAgain;
        _refreshChatAgain = _refreshVoiceAgain = false;
        unawaited(refresh(chat: chatAgain, voiceState: voiceAgain));
      }
    }
  }

  Future<void> applyVoice(Json nextVoice) async {
    if (_disposed) return;
    if (voice != null && nextVoice['voice_seq'] < voice!['voice_seq']) return;
    voice = nextVoice;
    // The authenticated server retains the room participation choice across
    // reloads; no token or story state is restored from browser storage.
    if (voice!['participation'] == 'on' && voice!['reason'] != 'LOBBY') {
      sceneConsent = true;
    }
    if (grant != null &&
        (voice!['generation'] != grant!['generation'] ||
            !['connecting', 'connected'].contains(voice!['status']))) {
      await stop();
    }
    if (voice!['participation'] == 'on' &&
        ['connecting', 'connected'].contains(voice!['status']) &&
        grant == null &&
        !joining &&
        foreground &&
        sceneConsent &&
        client.live) {
      unawaited(join());
    }
    changed();
  }

  Future<void> send(String scope, String text) async {
    if (sending || room == null) return;
    final body = {
      'request_id': const Uuid().v4(),
      'control_epoch': epoch,
      'scope': scope,
      'text': text.trim(),
    };
    sending = true;
    error = null;
    changed();
    try {
      await retry(() => api('POST', '/chat/messages', body));
      await refresh();
    } catch (e) {
      error = '消息未发送，内容已保留，请重试';
      rethrow;
    } finally {
      sending = false;
      changed();
    }
  }

  Future<dynamic> retry(Future<dynamic> Function() request) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await request();
      } catch (e) {
        final retryable =
            e is TimeoutException ||
            (e is ApiError &&
                [
                  'RATE_LIMITED',
                  'VOICE_UNAVAILABLE',
                  'OWNER_UNAVAILABLE',
                ].contains(e.code));
        if (!retryable || attempt >= 3) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: (1000 << attempt) + Random().nextInt(250)),
        );
      }
    }
  }

  Future<Json> request(String action, Json body) async {
    final p = {
      'voice_protocol_version': 1,
      'request_id': const Uuid().v4(),
      'control_epoch': epoch,
      'expected_revision': voice?['voice_revision'] ?? 0,
      'action': action,
      'body': body,
    };
    Json result;
    try {
      result = await retry(() => api('POST', '/voice/requests', p)) as Json;
    } on ApiError catch (e) {
      if (e.code != 'STALE_REVISION') rethrow;
      final fresh = await api('GET', '/voice') as Json;
      if (body['lease_id'] != null && fresh['lease_id'] != body['lease_id']) {
        rethrow;
      }
      voice = fresh;
      // A stale request stays immutable; a freshly authorized retry gets a new ID.
      result = await api('POST', '/voice/requests', {
        ...p,
        'request_id': const Uuid().v4(),
        'expected_revision': fresh['voice_revision'],
      }) as Json;
    }
    if (voice != null) {
      voice = {
        ...voice!,
        'voice_revision': result['voice_revision'] ?? voice!['voice_revision'],
      };
    }
    return result;
  }

  Future<void> saveMixPreferences() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('scene_audio_master', audio.master);
      await p.setDouble('scene_audio_narration', audio.narration);
      await p.setDouble('scene_audio_bgm', audio.bgm);
      await p.setBool('scene_audio_duck', audio.duckWhileSpeaking);
    } catch (_) {
      error = '音频偏好未保存，请稍后重试';
      changed();
    }
  }

  Future<void> report(
    String kind,
    String target,
    String reason,
    String description,
  ) async {
    final body = {
      'request_id': const Uuid().v4(),
      'target_member_id': target,
      'reason_code': reason,
      'description': description,
    };
    await retry(() => api('POST', '/$kind/reports', body));
  }

  Future<void> participation(bool enabled) async {
    if (enabled && voice?['reason'] != 'LOBBY') {
      sceneConsent = true;
    }
    if (!enabled) {
      sceneConsent = false;
      await stop();
    }
    error = null;
    try {
      await request('participation', {'enabled': enabled});
      await refresh();
    } catch (e) {
      error = '语音状态已变化，请重试';
      await refresh();
      changed();
    }
  }

  Future<void> join() async {
    if (joining || !rtc.supported) return;
    joining = true;
    final generation = ++localGeneration;
    changed();
    try {
      final next = await request('grant', {});
      if (_disposed ||
          generation != localGeneration ||
          !foreground ||
          !client.live) {
        return;
      }
      grant = next;
      mic = false;
      await rtc.join(next, (event) {
        if (generation == localGeneration && !_disposed) {
          unawaited(onRtc(event));
        }
      });
      heartbeat = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(keepAlive()),
      );
    } catch (e) {
      await stop();
      error = '语音连接未完成，可继续使用文本聊天';
    } finally {
      joining = false;
      changed();
    }
  }

  Future<void> onRtc(Json event) async {
    switch (event['type']) {
      case 'levels':
        audio.speaking(
          (event['speakers'] as List? ?? []).any((s) => (s['volume'] ?? 0) > 8),
        );
        break;
      case 'connected':
        connected = true;
        mic = false;
        final g = grant;
        if (g != null) {
          await request('client_state', {
            'lease_id': g['lease_id'],
            'status': 'connected',
          });
        }
        break;
      case 'renew':
        await keepAlive(renew: true);
        break;
      case 'muted':
        mic = false;
        break;
      case 'microphone_error':
        mic = false;
        error = '无法使用麦克风，请检查权限；仍可收听和发送文字';
        break;
      case 'focus_lost':
      case 'device_changed':
        await microphone(false);
        error = '麦克风已关闭，需要时请重新开麦';
        break;
      case 'background':
      case 'disconnected':
      case 'failed':
        await stop();
        break;
    }
    changed();
  }

  Future<void> keepAlive({bool renew = false}) async {
    final g = grant;
    if (g == null) return;
    try {
      final remaining = DateTime.parse(g['token_expires_at'])
          .difference(DateTime.now())
          .inSeconds;
      final next = await request(
        renew || remaining < 45 ? 'renew' : 'heartbeat',
        {'lease_id': g['lease_id']},
      );
      if (grant != g) return;
      if (next['token'] != null) {
        grant = next;
        await rtc.renew(next['token']);
      }
    } catch (_) {
      await stop();
    }
  }

  Future<void> microphone(bool enabled) async {
    final attempt = ++_micAttempt;
    if (!enabled) {
      mic = false;
      changed();
    }
    if (enabled && (!connected || !foreground || !client.live)) return;
    try {
      await rtc.microphone(enabled);
      if (attempt != _micAttempt) {
        await rtc.microphone(false);
        return;
      }
      mic = enabled;
    } catch (_) {
      mic = false;
      error = '无法使用麦克风，请检查权限；仍可收听和发送文字';
    }
    changed();
  }

  void peerVolume(String member, String uid, double volume) {
    peerVolumes[member] = volume;
    rtc.volume(uid, volume * listeningVolume);
    changed();
  }

  Future<void> stop() async {
    ++localGeneration;
    ++_micAttempt;
    heartbeat?.cancel();
    heartbeat = null;
    mic = false;
    connected = false;
    audio.speaking(false);
    final old = grant;
    grant = null;
    await rtc.leave();
    if (old != null && !_disposed) {
      try {
        await request('client_state', {
          'lease_id': old['lease_id'],
          'status': 'left',
        });
      } catch (_) {}
    }
    changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive) {
      // Permission dialogs and window blur are not a room exit. Keep the
      // authorized listening session and its lease, but stop microphone capture.
      unawaited(microphone(false));
    } else if (!foreground) {
      unawaited(stop());
    } else {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    timer?.cancel();
    heartbeat?.cancel();
    unawaited(subscription?.cancel());
    client.removeListener(worldChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(rtc.leave());
    audio.resetVoice();
    super.dispose();
  }
}
