import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ruxi/data/c2_client.dart';
import 'package:ruxi/data/room_client.dart';
import 'package:ruxi/data/scene_communication.dart';
import 'package:ruxi/data/voice/rtc_contract.dart';
import 'package:ruxi/ui/scene_communication_panel.dart';

class FakeIdentity extends RoomClient {
  final sent = <Json>[];
  final voiceRequests = <Json>[];
  Completer<Json>? voiceGate;
  Json voice = {
    'voice_seq': 1,
    'voice_revision': 1,
    'status': 'off',
    'participation': 'off',
    'generation': null,
    'members': [],
  };
  @override
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    bool private = false,
    bool retried = false,
    Map<String, String> extraHeaders = const {},
  ]) async {
    if (path.endsWith('/chat')) {
      return {
        'messages': [],
        'scopes': ['global', 'scene', 'faction'],
      };
    }
    if (path.endsWith('/voice')) {
      final gate = voiceGate;
      voiceGate = null;
      return gate == null ? voice : await gate.future;
    }
    if (path.endsWith('/messages')) {
      sent.add(body!);
      return {'message_id': 'one'};
    }
    if (body?['action'] != null) voiceRequests.add(body!);
    if (body?['action'] == 'participation') {
      voice = {
        ...voice,
        'participation': body!['body']['enabled'] ? 'on' : 'off',
        'status': 'waiting',
      };
      return {'voice_revision': 1};
    }
    if (body?['action'] == 'client_state') return {'voice_revision': 1};
    if (body?['action'] == 'grant') {
      return {
        'lease_id': 'lease',
        'generation': 1,
        'token': 'ephemeral',
        'token_expires_at': DateTime.now()
            .add(const Duration(seconds: 120))
            .toIso8601String(),
      };
    }
    throw StateError('unexpected request');
  }
}

class FakeRtc implements VolcRtcClient {
  int joins = 0, leaves = 0;
  final microphones = <bool>[];
  RtcEvent? callback;
  Completer<void>? opening;
  @override
  bool get supported => true;
  @override
  Future<void> join(Json grant, RtcEvent event) async {
    joins++;
    callback = event;
  }

  @override
  Future<void> microphone(bool enabled) async {
    microphones.add(enabled);
    if (enabled && opening != null) await opening!.future;
  }

  @override
  Future<void> renew(String token) async {}
  @override
  void volume(String uid, double value) {}
  @override
  Future<void> leave() async {
    leaves++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  (SceneCommunication, C2Client, FakeIdentity, FakeRtc) fixture() {
    final id = FakeIdentity(),
        rtc = FakeRtc(),
        client = C2Client(FakeIdentity());
    // Use one identity for requests; no auth/RTC persistence in this controller.
    final c2 = C2Client(id)
      ..roomId = 'room'
      ..live = true;
    client.dispose();
    c2.snapshot = {'control_epoch': 1};
    c2.reducer.blocks = {
      'room': {'status': 'active'},
      'self': {'location': 'lobby'},
      'own_member_id': 'self',
    };
    return (SceneCommunication(c2, rtc: rtc), c2, id, rtc);
  }

  testWidgets(
    'voice update during an in-flight refresh is applied immediately',
    (tester) async {
      final (c, client, id, _) = fixture();
      final gate = Completer<Json>();
      id.voiceGate = gate;
      final first = c.refresh();
      await tester.pump();
      id.voice = {...id.voice, 'voice_seq': 2};
      await c.refresh();
      gate.complete({...id.voice, 'voice_seq': 1});
      await first;
      await tester.pump();
      expect(c.voice?['voice_seq'], 2);
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'text scopes remain separate and sending does not create a game intent',
    (tester) async {
      final (c, client, id, _) = fixture();
      await c.refresh();
      await c.send('scene', 'hello');
      expect(id.sent.single['scope'], 'scene');
      expect(client.pending, isNull);
      expect(client.busy, isFalse);
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'RTC only reports connected after the real SDK callback; joining never opens mic',
    (tester) async {
      final (c, client, id, rtc) = fixture();
      await c.refresh();
      await c.participation(true);
      await c.join();
      expect(c.connected, isFalse);
      expect(rtc.microphones, isEmpty);
      rtc.callback!({'type': 'connected'});
      await tester.pump();
      expect(c.connected, isTrue);
      expect(c.mic, isFalse);
      final callback = rtc.callback!;
      await c.stop();
      callback({'type': 'connected'});
      await tester.pump();
      expect(c.connected, isFalse);
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'release while permission is pending cannot reopen the microphone',
    (tester) async {
      final (c, client, id, rtc) = fixture();
      c.connected = true;
      rtc.opening = Completer<void>();
      final opening = c.microphone(true);
      await tester.pump();
      await c.microphone(false);
      rtc.opening!.complete();
      await opening;
      expect(c.mic, isFalse);
      expect(rtc.microphones.last, isFalse);
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    },
  );
  testWidgets('permission dialog only mutes; actual background leaves voice', (
    tester,
  ) async {
    final (c, client, id, rtc) = fixture();
    await c.refresh();
    await c.participation(true);
    await c.join();
    rtc.callback!({'type': 'connected'});
    await tester.pump();
    id.voice = {...id.voice, 'status': 'connected', 'generation': 1};
    rtc.callback!({'type': 'microphone_error'});
    await tester.pump();
    expect(c.grant, isNotNull);
    expect(rtc.leaves, 0);
    c.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await tester.pump();
    expect(c.grant, isNotNull);
    expect(c.connected, isTrue);
    expect(rtc.leaves, 0);
    expect(rtc.microphones.last, isFalse);
    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    c.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump();
    expect(c.grant, isNull);
    expect(c.connected, isFalse);
    expect(rtc.leaves, 1);
    c.dispose();
    client.dispose();
    id.dispose();
    await tester.pump();
  });
  testWidgets(
    'reload restores the server participation choice after retirement',
    (tester) async {
      final (c, client, id, rtc) = fixture();
      id.voice = {
        ...id.voice,
        'participation': 'on',
        'status': 'switching',
        'reason': 'RETIRING',
      };
      await c.refresh();
      expect(c.sceneConsent, isTrue);
      expect(rtc.joins, 0);
      id.voice = {
        ...id.voice,
        'voice_seq': 2,
        'status': 'connecting',
        'reason': null,
        'generation': 1,
      };
      await c.refresh();
      await tester.pump();
      expect(rtc.joins, 1);
      rtc.callback!({'type': 'connected'});
      await tester.pump();
      expect(c.connected, isTrue);
      expect(c.mic, isFalse);
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'returning from background automatically restores listening only',
    (tester) async {
      final (c, client, id, rtc) = fixture();
      id.voice = {
        ...id.voice,
        'participation': 'on',
        'status': 'connecting',
        'generation': 1,
      };
      await c.refresh();
      await tester.pump();
      rtc.callback!({'type': 'connected'});
      await tester.pump();
      c.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(c.grant, isNull);
      // The server may still report the earlier connected lease while recovering.
      id.voice = {...id.voice, 'voice_seq': 2, 'status': 'connected'};
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(rtc.joins, 2);
      rtc.callback!({'type': 'connected'});
      await tester.pump();
      expect(c.connected, isTrue);
      expect(c.mic, isFalse);
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    },
  );
  testWidgets('lobby preference does not initiate a voice connection', (
    tester,
  ) async {
    final (c, client, id, rtc) = fixture();
    id.voice = {
      ...id.voice,
      'participation': 'on',
      'status': 'waiting',
      'reason': 'LOBBY',
    };
    await c.refresh();
    await tester.pump();
    expect(c.sceneConsent, isFalse);
    expect(rtc.joins, 0);
    c.dispose();
    client.dispose();
    id.dispose();
    await tester.pump();
  });
  testWidgets(
    'reconnect button keeps participation; cancellation is a separate action',
    (tester) async {
      final (c, client, id, _) = fixture();
      id.voice = {
        ...id.voice,
        'participation': 'on',
        'status': 'switching',
        'reason': 'RETIRING',
      };
      await c.refresh();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: SceneCommunicationPanel(controller: c)),
        ),
      );
      await tester.tap(find.text('场景语音'));
      await tester.pump();
      await tester.tap(find.text('重新连接 · 默认仅收听'));
      await tester.pump();
      expect(id.voiceRequests.last['action'], 'participation');
      expect(id.voiceRequests.last['body']['enabled'], isTrue);
      await tester.tap(find.text('取消语音参与'));
      await tester.pump();
      expect(id.voiceRequests.last['body']['enabled'], isFalse);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    },
  );
  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets('communication panel remains usable at $width and 200% text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final (c, client, id, _) = fixture();
      await c.refresh();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(body: SceneCommunicationPanel(controller: c)),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('文本聊天'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('场景语音'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      client.dispose();
      id.dispose();
      await tester.pump();
    });
  }
}
