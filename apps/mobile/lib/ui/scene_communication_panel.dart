import 'dart:async';

import 'package:flutter/material.dart';

import '../data/scene_communication.dart';
import 'novel_widgets.dart';

class SceneCommunicationPanel extends StatefulWidget {
  const SceneCommunicationPanel({super.key, required this.controller});
  final SceneCommunication controller;
  @override
  State<SceneCommunicationPanel> createState() => _PanelState();
}

class _PanelState extends State<SceneCommunicationPanel> {
  final text = TextEditingController(), scroll = ScrollController();
  String scope = 'global';
  bool voiceTab = false;
  SceneCommunication get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.unread = 0;
    c.addListener(changed);
    unawaited(c.refresh());
  }

  void changed() {
    if (mounted) {
      setState(() {});
      if (!voiceTab) c.unread = 0;
    }
  }

  @override
  void dispose() {
    c.removeListener(changed);
    if (c.pushToTalk) unawaited(c.microphone(false));
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final value = text.text;
    if (value.trim().isEmpty) return;
    try {
      await c.send(scope, value);
      if (mounted && text.text == value) text.clear();
    } catch (_) {}
  }

  Future<void> report(String kind, String target) async {
    var reason = 'harassment';
    final description = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('举报交流行为'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: reason,
                  items: const [
                    DropdownMenuItem(value: 'harassment', child: Text('骚扰或辱骂')),
                    DropdownMenuItem(value: 'noise', child: Text('噪声干扰')),
                    DropdownMenuItem(value: 'other', child: Text('其他')),
                  ],
                  onChanged: (v) => set(() => reason = v!),
                ),
                TextField(
                  controller: description,
                  maxLength: 1000,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '补充说明（可选）'),
                ),
                const Text('不会录音或提交音频。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('提交'),
            ),
          ],
        ),
      ),
    );
    final value = description.text;
    description.dispose();
    if (confirmed == true) {
      try {
        await c.report(kind, target, reason, value);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('举报已受理')));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('举报未提交，请重试')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 768;
    final choices = c.scopes;
    if (!choices.contains(scope)) scope = 'global';
    return Dialog(
      backgroundColor: const Color(0xff17252e),
      insetPadding: EdgeInsets.all(narrow ? 12 : 28),
      child: SizedBox(
        width: narrow ? double.infinity : 420,
        height: MediaQuery.sizeOf(context).height * .82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
              child: Row(
                children: [
                  const Icon(Icons.forum_outlined, color: novelGold),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '同伴交流',
                      style: TextStyle(fontSize: 20, color: novelGold),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭交流面板',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => setState(() => voiceTab = false),
                      child: Text(
                        '文本聊天',
                        style: TextStyle(
                          color: voiceTab ? Colors.white54 : novelGold,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => setState(() => voiceTab = true),
                      child: Text(
                        '场景语音',
                        style: TextStyle(
                          color: voiceTab ? novelGold : Colors.white54,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(c.error!, style: const TextStyle(color: novelGold)),
              ),
            Expanded(child: voiceTab ? voice() : chat()),
          ],
        ),
      ),
    );
  }

  Widget chat() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final channel in c.scopes)
              ChoiceChip(
                label: Text(
                  {
                    'global': '全局',
                    'scene': '当前场景',
                    'faction': '我的阵营',
                  }[channel]!,
                ),
                selected: scope == channel,
                onSelected: (_) => setState(() => scope = channel),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            scope == 'global'
                ? '房间内所有同伴可见'
                : scope == 'scene'
                ? '发送时同场景的同伴可见，离开后保留已收到消息'
                : '发送时同阵营的同伴可见',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ),
      ),
      Expanded(
        child: c.messages.where((m) => m['scope'] == scope).isEmpty
            ? const Center(
                child: Text(
                  '还没有消息，和同伴交流一下吧',
                  style: TextStyle(color: Colors.white54),
                ),
              )
            : ListView(
                controller: scroll,
                padding: const EdgeInsets.all(18),
                children: [
                  for (final m in c.messages.where((m) => m['scope'] == scope))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment:
                            m['sender_id'] == c.client.view?['own_member_id']
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          Text(
                            m['display_name'] ?? '同伴',
                            style: const TextStyle(
                              fontSize: 12,
                              color: novelGold,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color:
                                  m['sender_id'] ==
                                      c.client.view?['own_member_id']
                                  ? const Color(0xff354539)
                                  : const Color(0xff22323e),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: SelectableText(
                              m['body'],
                              style: const TextStyle(
                                color: Color(0xffeee9de),
                                height: 1.5,
                              ),
                            ),
                          ),
                          if (m['sender_id'] != c.client.view?['own_member_id'])
                            Align(
                              alignment: Alignment.centerRight,
                              child: IconButton(
                                tooltip: '举报这位同伴的文字交流',
                                icon: const Icon(Icons.flag_outlined, size: 16),
                                onPressed: () =>
                                    unawaited(report('chat', m['sender_id'])),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: text,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                decoration: const InputDecoration(
                  hintText: '输入消息…',
                  counterText: '',
                  filled: true,
                ),
                onSubmitted: (_) => unawaited(send()),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: c.sending ? null : () => unawaited(send()),
                child: Text(c.sending ? '发送中' : '发送'),
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget voice() {
    final state = c.voice;
    final reason = state?['reason'];
    final note = {
      'SINGLE_PLAYER': '单人游玩无需语音；邀请同伴后可使用。',
      'LOBBY': '开场后进入场景语音，现在只保存参与意愿。',
      'STORY_DISABLED': '这个剧目尚未开启场景语音。',
      'RTC_NOT_CONFIGURED': '语音服务尚未配置，文本聊天仍可使用。',
      'FENCE_NOT_VERIFIED': '语音隔离验证尚未完成，暂不开放连接。',
      'RESTRICTED': '你在这个房间的语音已被限制。',
      'SUSPENDED': '游戏已暂停，语音同步暂停。',
      'RETIRING': '正在切换语音连接，通常几秒内恢复收听；麦克风保持关闭。服务暂时不可用时，隔离确认可能需要更久。',
    }[reason];
    final on = state?['participation'] == 'on';
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        if (!c.rtc.supported) const Text('当前平台尚未提供语音 SDK，可继续使用文本聊天。'),
        Row(
          children: [
            Icon(
              c.connected ? Icons.headset : Icons.headset_off,
              color: novelGold,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                c.connected
                    ? (c.mic ? '麦克风已开启' : '已连接 · 仅收听')
                    : reason == 'RETIRING'
                    ? '等待连接恢复'
                    : c.joining
                    ? '正在连接'
                    : on
                    ? '等待同场景同伴'
                    : '尚未加入',
                style: const TextStyle(fontSize: 18, color: novelGold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          note ?? '只有当前场景中主动加入语音的同伴能互相听到。初次加入和切换场景均默认闭麦。',
          style: const TextStyle(color: Colors.white70, height: 1.6),
        ),
        const SizedBox(height: 18),
        for (final m in state?['members'] ?? [])
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              child: Text((m['display_name'] as String).characters.first),
            ),
            title: Text(
              m['display_name'],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              m['connection_state'] == 'connected' ? '已连接' : '等待连接',
            ),
            onLongPress: m['member_id'] == c.client.view?['own_member_id']
                ? null
                : () => unawaited(report('voice', m['member_id'])),
            trailing:
                m['rtc_uid'] == null ||
                    m['member_id'] == c.client.view?['own_member_id']
                ? null
                : IconButton(
                    tooltip: (c.peerVolumes[m['member_id']] ?? 1) == 0
                        ? '取消本地静音'
                        : '仅对我静音',
                    icon: Icon(
                      (c.peerVolumes[m['member_id']] ?? 1) == 0
                          ? Icons.volume_off
                          : Icons.volume_up,
                    ),
                    onPressed: () => c.peerVolume(
                      m['member_id'],
                      m['rtc_uid'],
                      (c.peerVolumes[m['member_id']] ?? 1) == 0 ? 1 : 0,
                    ),
                  ),
          ),
        const Divider(),
        if (c.connected)
          Listener(
            onPointerDown: c.pushToTalk
                ? (_) => unawaited(c.microphone(true))
                : null,
            onPointerUp: c.pushToTalk
                ? (_) => unawaited(c.microphone(false))
                : null,
            onPointerCancel: (_) => unawaited(c.microphone(false)),
            child: SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: c.pushToTalk
                    ? () {}
                    : () => unawaited(c.microphone(!c.mic)),
                icon: Icon(c.mic ? Icons.mic : Icons.mic_off),
                label: Text(
                  c.pushToTalk
                      ? '按住说话'
                      : c.mic
                      ? '关闭麦克风'
                      : '开启麦克风',
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        if (reason != 'SINGLE_PLAYER' && c.rtc.supported)
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: c.joining
                  ? null
                  : () =>
                        unawaited(c.participation(c.connected ? false : true)),
              child: Text(
                c.connected
                    ? '退出语音'
                    : on && reason != 'LOBBY'
                    ? '重新连接 · 默认仅收听'
                    : on && reason == 'LOBBY'
                    ? '已选择参与 · 开场后确认加入'
                    : '加入语音 · 默认仅收听',
              ),
            ),
          ),
        if (on && !c.connected)
          TextButton(
            onPressed: () => unawaited(c.participation(false)),
            child: const Text('取消语音参与'),
          ),
        const SizedBox(height: 18),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('按住说话'),
          subtitle: const Text('松手、失去焦点或切场景立即闭麦'),
          value: c.pushToTalk,
          onChanged: (value) => unawaited(c.preferences(ptt: value)),
        ),
        const Text(
          '同伴头像长按可举报；扬声器按钮仅在本地静音。',
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
        const SizedBox(height: 12),
        const Text('语音收听音量'),
        Slider(
          value: c.listeningVolume,
          onChanged: (value) => unawaited(c.preferences(volume: value)),
        ),
        const Text('场景媒体总音量'),
        Slider(
          value: c.audio.master,
          onChanged: (v) => setState(() => c.audio.configure(masterVolume: v)),
          onChangeEnd: (_) => unawaited(c.saveMixPreferences()),
        ),
        const Text('叙述音量'),
        Slider(
          value: c.audio.narration,
          onChanged: (v) =>
              setState(() => c.audio.configure(narrationVolume: v)),
          onChangeEnd: (_) => unawaited(c.saveMixPreferences()),
        ),
        const Text('背景音乐音量'),
        Slider(
          value: c.audio.bgm,
          onChanged: (v) => setState(() => c.audio.configure(bgmVolume: v)),
          onChangeEnd: (_) => unawaited(c.saveMixPreferences()),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('同伴讲话时降低背景音乐'),
          value: c.audio.duckWhileSpeaking,
          onChanged: (v) {
            setState(() => c.audio.configure(duck: v));
            unawaited(c.saveMixPreferences());
          },
        ),
        const Text(
          '关闭此面板不会退出语音；退出房间、切至后台或网络中断会停止音频。',
          style: TextStyle(fontSize: 12, color: Colors.white54, height: 1.6),
        ),
      ],
    );
  }
}
