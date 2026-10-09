import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/c2_client.dart';
import '../data/room_client.dart';

class C2Stage extends StatefulWidget {
  const C2Stage({super.key, this.roomId});
  final String? roomId;
  @override
  State<C2Stage> createState() => _C2StageState();
}

class _C2StageState extends State<C2Stage> {
  final identity = RoomClient();
  late final client = C2Client(identity);
  final invite = TextEditingController();
  List<dynamic> stories = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    client.addListener(changed);
    unawaited(initialize());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> initialize() async {
    try {
      await client.initialize();
      if (widget.roomId != null) {
        await client.load(widget.roomId!);
      } else {
        stories = (await client.request('GET', '/stories'))['items'];
      }
    } catch (e) {
      error = RoomClient.explain(e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> enter({String? release}) async {
    try {
      final data = await client.request(
        'POST',
        release == null ? '/rooms/join' : '/rooms',
        release == null
            ? {'invite_code': invite.text.trim()}
            : {'release_id': release},
      );
      if (mounted) context.go('/world-rooms/${data['room_id']}');
    } catch (e) {
      if (mounted) setState(() => error = RoomClient.explain(e));
    }
  }

  @override
  void dispose() {
    client.removeListener(changed);
    client.dispose();
    identity.dispose();
    invite.dispose();
    super.dispose();
  }

  List<dynamic> list(String key) => client.view?[key] as List? ?? [];
  Widget panel(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );
  Future<void> share(Json clue) async {
    final selected = <String>{};
    final members = list('members')
        .where((m) => m['member_id'] != client.view?['own_member_id'])
        .toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('分享知识'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('分享后，对方会永久获得这条知识。'),
              for (final member in members)
                CheckboxListTile(
                  title: Text(member['display_name']),
                  value: selected.contains(member['member_id']),
                  onChanged: (v) => set(
                    () => v == true
                        ? selected.add(member['member_id'])
                        : selected.remove(member['member_id']),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('确认分享'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await client.command('knowledge.share', {
        'clue_id': clue['id'],
        'audience_member_ids': selected.toList(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = client.view;
    final room = v?['room'] as Json?;
    final disabled = client.busy || client.pending != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('入戏 · 探索故事'),
        leading: IconButton(
          tooltip: '回到首页',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        actions: [
          if (widget.roomId != null)
            IconButton(
              tooltip: '刷新房间',
              onPressed: () => unawaited(client.refresh()),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (error != null || client.error != null)
                      panel('操作提示', [Text(error ?? client.error!)]),
                    if (client.pending != null)
                      panel('确认上次操作', [
                        const Text('发送后尚未确认结果，请先查询，再决定是否重新发送。'),
                        Wrap(
                          spacing: 12,
                          children: [
                            OutlinedButton(
                              onPressed: disabled && client.busy
                                  ? null
                                  : () => unawaited(client.recoverCommand()),
                              child: const Text('检查结果'),
                            ),
                            OutlinedButton(
                              onPressed: client.busy
                                  ? null
                                  : () => unawaited(client.retryCommand()),
                              child: const Text('用原编号重试'),
                            ),
                          ],
                        ),
                      ]),
                    if (widget.roomId == null) ...[
                      panel('与朋友一起进入故事', [
                        TextField(
                          controller: invite,
                          decoration: const InputDecoration(labelText: '邀请码'),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => unawaited(enter()),
                          child: const Text('加入房间'),
                        ),
                      ]),
                      for (final s in stories)
                        panel(s['title'], [
                          Text(s['summary'] ?? ''),
                          Text(
                            '${s['seat_count']} 位角色 · ${s['estimated_minutes']} 分钟',
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: () =>
                                unawaited(enter(release: s['release_id'])),
                            child: const Text('邀请朋友开始故事'),
                          ),
                        ]),
                      if (stories.isEmpty) const Text('暂时没有已发布的探索故事。'),
                    ],
                    if (v != null) ...[
                      Row(
                        children: [
                          Icon(
                            client.live
                                ? Icons.cloud_done_outlined
                                : Icons.cloud_off_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(client.live ? '实时连接' : '正在恢复连接'),
                          const Spacer(),
                          if (room?['round'] != null)
                            Text(
                              '第 ${room!['round']} 回合 · 第 ${room['step']} 步',
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (room?['status'] == 'lobby') ...[
                        panel('等候开场', [
                          if (v['invite_code'] != null)
                            SelectableText('邀请码 ${v['invite_code']}'),
                          for (final r in list('roles'))
                            ListTile(
                              leading: Icon(
                                list('members')
                                            .where(
                                              (m) =>
                                                  m['member_id'] ==
                                                  v['own_member_id'],
                                            )
                                            .firstOrNull?['role_id'] ==
                                        r['id']
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                              ),
                              title: Text(r['label']),
                              onTap: disabled
                                  ? null
                                  : () => unawaited(
                                      client.command('role.select', {
                                        'role_id': r['id'],
                                      }),
                                    ),
                            ),
                          FilledButton(
                            onPressed: disabled
                                ? null
                                : () => unawaited(
                                    client.command('member.ready', {
                                      'ready': true,
                                    }),
                                  ),
                            child: const Text('准备好了'),
                          ),
                          if (v['host_member_id'] == v['own_member_id'])
                            TextButton(
                              onPressed: disabled
                                  ? null
                                  : () =>
                                        unawaited(client.command('room.start')),
                              child: const Text('全员准备后开场'),
                            ),
                        ]),
                      ] else ...[
                        if (room?['status'] == 'suspended')
                          panel('故事已暂停', [
                            const Text('所有参与者确认后继续。'),
                            FilledButton(
                              onPressed: disabled
                                  ? null
                                  : () => unawaited(
                                      client.command('room.resume'),
                                    ),
                              child: const Text('确认继续'),
                            ),
                          ]),
                        if (room?['ending'] != null)
                          panel('故事结局', [Text(room!['ending']['summary'])]),
                        if (v['self'] != null)
                          panel('当前处境', [
                            Text(
                              '剩余行动点 ${v['self']['ap_remaining']} · 已预留 ${v['self']['ap_reserved']}',
                            ),
                            for (final goal in v['self']['goals'] ?? [])
                              Text('$goal'),
                          ]),
                        for (final cue in list('narrative_cues').where(
                          (c) => !(v['acknowledged_cues'] as List? ?? [])
                              .contains(c['id']),
                        ))
                          panel('阅读故事', [
                            Text(cue['summary'] ?? ''),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: disabled
                                  ? null
                                  : () => unawaited(
                                      client.command('media.complete', {
                                        'cue_id': cue['id'],
                                        'mode': 'summary',
                                      }),
                                    ),
                              child: const Text('读完，继续'),
                            ),
                          ]),
                        if (room?['status'] == 'active')
                          panel('选择行动', [
                            for (final a in list('actions'))
                              ListTile(
                                title: Text(a['label']),
                                subtitle: Text(
                                  '${a['cost']} 行动点 · ${a['risk_text'] ?? ''}',
                                ),
                                trailing: FilledButton(
                                  onPressed:
                                      disabled || a['allowed_now'] != true
                                      ? null
                                      : () => unawaited(
                                          client.command('action.submit', {
                                            'action_id': a['id'],
                                            'target_id': null,
                                          }),
                                        ),
                                  child: const Text('执行'),
                                ),
                              ),
                            if (v['own_intent_id'] != null)
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => unawaited(
                                        client.command('action.cancel', {
                                          'intent_id': v['own_intent_id'],
                                        }),
                                      ),
                                child: const Text('取消本步行动'),
                              ),
                            OutlinedButton(
                              onPressed: disabled
                                  ? null
                                  : () =>
                                        unawaited(client.command('round.end')),
                              child: const Text('结束本回合'),
                            ),
                          ]),
                        if (v['map'] != null)
                          panel('已知地点', [
                            for (final l in v['map']['locations'])
                              ListTile(
                                leading: Icon(
                                  l['id'] == v['self']['location']
                                      ? Icons.my_location
                                      : Icons.place_outlined,
                                ),
                                title: Text(l['label']),
                                subtitle: Text(l['description'] ?? ''),
                              ),
                            for (final link
                                in (v['map']['links'] as List).where(
                                  (l) => l['from'] == v['self']['location'],
                                ))
                              OutlinedButton(
                                onPressed:
                                    disabled ||
                                        link['allowed_now'] != true ||
                                        room?['status'] != 'active'
                                    ? null
                                    : () => unawaited(
                                        client.command('action.submit', {
                                          'action_id': 'move:${link['id']}',
                                          'target_id': null,
                                        }),
                                      ),
                                child: Text(
                                  '前往 ${((v['map']['locations'] as List).firstWhere((l) => l['id'] == link['to']))['label']} · ${link['cost']} 点',
                                ),
                              ),
                          ]),
                        panel('我的知识', [
                          for (final k in list('knowledge'))
                            ListTile(
                              title: Text(k['text']),
                              trailing: k['shareable'] == true
                                  ? TextButton(
                                      onPressed: disabled
                                          ? null
                                          : () => unawaited(
                                              share(
                                                Map<String, dynamic>.from(k),
                                              ),
                                            ),
                                      child: const Text('分享'),
                                    )
                                  : null,
                            ),
                          if (list('knowledge').isEmpty)
                            const Text('尚未发现新的知识。'),
                        ]),
                        panel('我的物品', [
                          for (final item in list('inventory'))
                            ListTile(
                              title: Text(item['label']),
                              subtitle: Text(
                                item['reserved'] == true ? '正在等待交接' : '由你持有',
                              ),
                            ),
                          if (list('inventory').isEmpty) const Text('暂无物品。'),
                        ]),
                        if (v['vote'] != null)
                          panel('共同决定', [
                            for (final option in v['vote']['options'])
                              ListTile(
                                leading: Icon(
                                  v['vote']['own_ballot'] == option['id']
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                ),
                                title: Text(option['label']),
                                onTap: disabled
                                    ? null
                                    : () => unawaited(
                                        client.command('vote.cast', {
                                          'vote_id': v['vote']['id'],
                                          'option_id': option['id'],
                                        }),
                                      ),
                              ),
                          ]),
                      ],
                      panel('参与者', [
                        for (final member in list('members'))
                          ListTile(
                            leading: Icon(
                              member['online'] == true
                                  ? Icons.person
                                  : Icons.person_outline,
                            ),
                            title: Text(member['display_name']),
                            subtitle: Text(
                              '${member['role_id'] ?? '未选角色'} · ${member['ready'] == true ? '已准备' : '未准备'}',
                            ),
                          ),
                      ]),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
