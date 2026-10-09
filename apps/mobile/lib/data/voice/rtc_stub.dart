import '../room_client.dart';
import 'rtc_contract.dart';

VolcRtcClient createRtcClient() => UnsupportedRtc();

class UnsupportedRtc implements VolcRtcClient {
  @override
  bool get supported => false;
  @override
  Future<void> join(Json grant, RtcEvent event) async =>
      throw UnsupportedError('RTC');
  @override
  Future<void> microphone(bool enabled) async {}
  @override
  Future<void> renew(String token) async {}
  @override
  void volume(String uid, double volume) {}
  @override
  Future<void> leave() async {}
}
