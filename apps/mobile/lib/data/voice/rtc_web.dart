import 'dart:convert';
import 'dart:js_interop';

import '../room_client.dart';
import 'rtc_contract.dart';

@JS('ruxiRTC')
external _Bridge get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<JSAny?> join(JSString raw, JSFunction callback);
  external JSPromise<JSAny?> mic(JSBoolean enabled);
  external JSPromise<JSAny?> renew(JSString token);
  external void volume(JSString uid, JSNumber value);
  external JSPromise<JSAny?> leave();
}

VolcRtcClient createRtcClient() => WebRtc();

class WebRtc implements VolcRtcClient {
  @override
  bool get supported => true;
  @override
  Future<void> join(Json grant, RtcEvent event) async {
    await _bridge
        .join(
          jsonEncode(grant).toJS,
          ((JSString raw) {
            event(jsonDecode(raw.toDart) as Json);
          }).toJS,
        )
        .toDart;
  }

  @override
  Future<void> microphone(bool enabled) async {
    await _bridge.mic(enabled.toJS).toDart;
  }

  @override
  Future<void> renew(String token) async {
    await _bridge.renew(token.toJS).toDart;
  }

  @override
  void volume(String uid, double volume) =>
      _bridge.volume(uid.toJS, volume.toJS);
  @override
  Future<void> leave() async {
    await _bridge.leave().toDart;
  }
}
