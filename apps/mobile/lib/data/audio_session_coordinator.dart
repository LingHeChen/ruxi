import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// One local mixer for authorized scene media and RTC playback. It never seeks,
/// acknowledges cues, or changes the world clock when a person starts talking.
class AudioSessionCoordinator extends ChangeNotifier {
  static final instance = AudioSessionCoordinator();
  double master = 1, narration = 1, bgm = 0.7, _duck = 1;
  bool duckWhileSpeaking = true;
  Timer? _restore, _fade;
  final Map<Object, ({String kind, void Function(double) setVolume})> _players =
      {};
  void attach(Object key, String kind, void Function(double) volume) {
    _players[key] = (kind: kind, setVolume: volume);
    apply();
  }

  void detach(Object key) {
    _players.remove(key);
  }

  void configure({
    double? masterVolume,
    double? narrationVolume,
    double? bgmVolume,
    bool? duck,
  }) {
    master = masterVolume ?? master;
    narration = narrationVolume ?? narration;
    bgm = bgmVolume ?? bgm;
    duckWhileSpeaking = duck ?? duckWhileSpeaking;
    if (!duckWhileSpeaking) {
      _restore?.cancel();
      fade(1, 280);
    }
    apply();
  }

  void speaking(bool speaking) {
    _restore?.cancel();
    if (speaking && duckWhileSpeaking) {
      fade(pow(10, -8 / 20).toDouble(), 120);
    } else {
      _restore = Timer(const Duration(milliseconds: 800), () => fade(1, 280));
    }
  }

  void fade(double target, int milliseconds) {
    _fade?.cancel();
    final start = _duck;
    var elapsed = 0;
    _fade = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      elapsed += 20;
      _duck = start + (target - start) * (elapsed / milliseconds).clamp(0, 1);
      apply();
      if (elapsed >= milliseconds) timer.cancel();
    });
  }

  void resetVoice() {
    _restore?.cancel();
    _fade?.cancel();
    _duck = 1;
    apply();
  }

  void apply() {
    for (final p in _players.values) {
      p.setVolume(
        (master * (p.kind == 'bgm' ? bgm * _duck : narration)).clamp(0, 1),
      );
    }
    notifyListeners();
  }
}
