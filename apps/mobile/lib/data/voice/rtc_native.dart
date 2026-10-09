import 'dart:async';
import 'dart:io';

import 'package:volc_engine_rtc/volc_engine_rtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../room_client.dart';
import 'rtc_contract.dart';

VolcRtcClient createRtcClient() => NativeRtc();

class NativeRtc implements VolcRtcClient {
  RTCEngine? _engine;
  RTCRoom? _room;
  final _streams = <String, String>{};
  int _generation = 0, _captureEpoch = 0;
  @override
  bool get supported => Platform.isAndroid || Platform.isIOS;
  @override
  Future<void> join(Json grant, RtcEvent event) async {
    await leave();
    final generation = ++_generation;
    final handler = IRTCRoomEventHandler();
    handler.onRoomStateChanged = (room, uid, state, extra) {
      if (generation != _generation) return;
      event({'type': state == 0 ? 'connected' : 'failed'});
    };
    handler.onTokenWillExpire = () => event({'type': 'renew'});
    handler.onUserPublishStreamAudio = (stream, info, published) {
      _streams[info.userId] = stream;
    };
    final engineHandler = IRTCEngineEventHandler();
    engineHandler.onConnectionStateChanged = (state, reason) {
      if (generation == _generation && (state == 1 || state == 4)) {
        event({'type': 'disconnected'});
      }
    };
    _engine = await RTCEngine.createRTCEngine(
      RTCVideoContext(appId: grant['app_id'], eventHandler: engineHandler),
    );
    if (generation != _generation) {
      _engine?.destroy();
      _engine = null;
      return;
    }
    _room = await _engine!.createRTCRoom(grant['rtc_room_id']);
    await _room!.setRTCRoomEventHandler(handler);
    await _room!.joinRoom(
      token: grant['token'],
      userInfo: UserInfo(userId: grant['rtc_uid'], extraInfo: ''),
      userVisibility: true,
      roomConfig: RoomConfig(
        isPublishAudio: false,
        isPublishVideo: false,
        isAutoSubscribeAudio: true,
        isAutoSubscribeVideo: false,
      ),
    );
  }

  @override
  Future<void> microphone(bool enabled) async {
    final intent = ++_captureEpoch;
    if (!enabled) {
      await _engine?.stopAudioCapture();
      await _room?.publishStreamAudio(false);
      return;
    }
    final generation = _generation;
    if (!await Permission.microphone.request().isGranted) {
      throw StateError('MIC_PERMISSION');
    }
    if (generation != _generation || intent != _captureEpoch) return;
    await _engine?.startAudioCapture();
    if (generation != _generation || intent != _captureEpoch) {
      await _engine?.stopAudioCapture();
      return;
    }
    await _room?.publishStreamAudio(true);
  }

  @override
  Future<void> renew(String token) async {
    await _room?.updateToken(token);
  }

  @override
  void volume(String uid, double volume) {
    final stream = _streams[uid];
    if (stream != null) {
      unawaited(
        _engine?.setRemoteAudioPlaybackVolume(
          streamId: stream,
          volume: (volume * 100).round(),
        ),
      );
    }
  }

  @override
  Future<void> leave() async {
    ++_generation;
    ++_captureEpoch;
    final engine = _engine, room = _room;
    _engine = null;
    _room = null;
    _streams.clear();
    await engine?.stopAudioCapture();
    await room?.leaveRoom();
    await room?.destroy();
    engine?.destroy();
  }
}
