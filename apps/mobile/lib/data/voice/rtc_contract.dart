import '../room_client.dart';

typedef RtcEvent = void Function(Json event);

abstract class VolcRtcClient {
  bool get supported;
  Future<void> join(Json grant, RtcEvent event);
  Future<void> microphone(bool enabled);
  Future<void> renew(String token);
  void volume(String uid, double volume);
  Future<void> leave();
}
