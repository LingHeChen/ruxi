import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../data/room_client.dart';
import '../data/media_clock.dart';

/// One active decoder. Closing or backgrounding never advances the room.
class AuthorizedMediaSheet extends StatefulWidget {
  const AuthorizedMediaSheet({
    super.key,
    required this.client,
    required this.media,
  });
  final RoomClient client;
  final Json media;
  @override
  State<AuthorizedMediaSheet> createState() => _AuthorizedMediaSheetState();
}

class _AuthorizedMediaSheetState extends State<AuthorizedMediaSheet>
    with WidgetsBindingObserver {
  VideoPlayerController? player;
  Json? authorization;
  String? error;
  bool loading = true, summary = false;
  int generation = 0;
  Timer? repaint;
  DateTime? bufferingSince;
  bool foreground = true, localPaused = false, correcting = false;
  int ticks = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.client.addListener(roomChanged);
    load();
    repaint = Timer.periodic(const Duration(milliseconds: 500), (_) {
      monitorPlayback();
      if (mounted) setState(() {});
    });
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      loading = true;
      error = null;
      summary = false;
      bufferingSince = null;
      localPaused = false;
    });
    final old = player;
    player = null;
    await old?.dispose();
    try {
      final a = await widget.client.mediaAccess(widget.media);
      if (!mounted || current != generation) return;
      authorization = a;
      if (a['url'] == null) {
        summary = true;
        setState(() => loading = false);
        return;
      }
      final p = VideoPlayerController.networkUrl(Uri.parse(a['url']));
      player = p;
      await p.initialize().timeout(const Duration(seconds: 30));
      if (!mounted || current != generation) {
        await p.dispose();
        return;
      }
      p.addListener(videoChanged);
      final anchor = widget.client.view?['media']['public_anchor'];
      if (anchor != null && anchor['media_id'] == widget.media['media_id']) {
        final now = DateTime.now().toUtc().add(widget.client.clockOffset);
        final delta = now
            .difference(DateTime.parse(anchor['start_at']))
            .inMilliseconds;
        final expected = publicMediaPosition(
          anchor,
          now,
          p.value.duration.inMilliseconds,
        );
        await p.seekTo(
          Duration(
            milliseconds: expected.clamp(0, p.value.duration.inMilliseconds),
          ),
        );
        if (delta < 0) {
          await Future<void>.delayed(Duration(milliseconds: -delta));
        }
      }
      if (!mounted || current != generation) return;
      if (![
            'paused',
            'suspended',
          ].contains(widget.client.view?['room']['lifecycle']) &&
          foreground) {
        await p.play();
      }
      setState(() => loading = false);
    } catch (e) {
      if (mounted && current == generation) {
        setState(() {
          loading = false;
          summary = true;
          error = '片段暂时无法播放。可重试授权，或阅读同视角摘要。';
        });
      }
    }
  }

  void roomChanged() {
    if (!mounted) return;
    final view = widget.client.view;
    if (view == null) return;
    if (['paused', 'suspended'].contains(view['room']['lifecycle'])) {
      player?.pause();
    }
    final list = view['media']['authorized'] as List;
    if (!list.any((a) => a['media_id'] == widget.media['media_id'])) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
    setState(() {});
  }

  void videoChanged() {
    if (player?.value.hasError == true && error == null && mounted) {
      setState(() => error = '播放中断，请重新授权播放或阅读摘要。');
    }
  }

  void monitorPlayback() {
    final p = player;
    if (p == null || loading || summary || !foreground || localPaused) {
      bufferingSince = null;
      return;
    }
    if (p.value.isBuffering) {
      bufferingSince ??= DateTime.now();
      if (DateTime.now().difference(bufferingSince!) >=
          const Duration(seconds: 30)) {
        p.pause();
        summary = true;
        error = '缓冲超过 30 秒，可阅读当前已授权的摘要并确认。';
      }
      return;
    }
    bufferingSince = null;
    if (++ticks % 4 != 0 ||
        correcting ||
        !p.value.isPlaying ||
        widget.client.view?['room']['lifecycle'] != 'running') {
      return;
    }
    final anchor = widget.client.view?['media']['public_anchor'];
    if (anchor == null || anchor['media_id'] != widget.media['media_id']) {
      return;
    }
    final expected = publicMediaPosition(
      anchor,
      DateTime.now().toUtc().add(widget.client.clockOffset),
      p.value.duration.inMilliseconds,
    );
    if (shouldSeekPublicMedia(p.value.position.inMilliseconds, expected)) {
      correcting = true;
      p
          .seekTo(Duration(milliseconds: expected))
          .catchError((Object _) {
            // Decoder failures retain the authorized summary fallback.
          })
          .whenComplete(() => correcting = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) player?.pause();
  }

  @override
  void dispose() {
    generation++;
    repaint?.cancel();
    widget.client.removeListener(roomChanged);
    WidgetsBinding.instance.removeObserver(this);
    player?.removeListener(videoChanged);
    player?.dispose();
    super.dispose();
  }

  Future<void> confirm() async {
    await widget.client.command('media_complete', {
      'media_id': widget.media['media_id'],
      'media_epoch': widget.media['media_epoch'],
      'mode': summary || error != null ? 'summary' : 'video',
    });
    if (mounted && widget.client.pending.isEmpty) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = player;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.media['kind'] == 'own_role'
                        ? '仅你可见 · 角色片段'
                        : '公共剧情片段',
                    style: const TextStyle(fontSize: 22),
                  ),
                ),
                IconButton(
                  tooltip: '关闭片段',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '原创动效开发样片 · 最终影视素材待制作',
              style: TextStyle(color: Color(0xffb0b7bd), fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (loading)
              const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (summary || p == null || error != null) ...[
              if (error != null) ...[
                Text(error!),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: load, child: const Text('重新授权播放')),
              ],
              if (authorization?['summary'] != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    authorization!['summary'],
                    style: const TextStyle(fontSize: 18, height: 1.9),
                  ),
                ),
            ] else ...[
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .52,
                  ),
                  child: AspectRatio(
                    aspectRatio: p.value.aspectRatio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: VideoPlayer(p),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              VideoProgressIndicator(
                p,
                allowScrubbing: widget.media['kind'] == 'own_role',
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      localPaused = p.value.isPlaying;
                      p.value.isPlaying ? p.pause() : p.play();
                      setState(() {});
                    },
                    icon: Icon(
                      p.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    label: Text(p.value.isPlaying ? '暂停本机' : '继续播放'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      p.pause();
                      setState(() => summary = true);
                    },
                    child: const Text('阅读授权摘要'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    !loading &&
                        authorization != null &&
                        widget.client.canAct &&
                        widget.client.view?['room']['lifecycle'] == 'running'
                    ? confirm
                    : null,
                child: const Text('确认已了解'),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '本地播放暂停不会暂停整间房。剧情由所有成员确认后推进。',
              style: TextStyle(fontSize: 12, color: Color(0xffb0b7bd)),
            ),
          ],
        ),
      ),
    );
  }
}
