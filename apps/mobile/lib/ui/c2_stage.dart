import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/c2_client.dart';
import '../data/room_client.dart';

class C2Stage extends StatefulWidget {
  const C2Stage({
    super.key,
    this.roomId,
    this.identity,
    this.autoInitialize = true,
  });
  final String? roomId;
  final RoomClient? identity;
  final bool autoInitialize;
  @override
  State<C2Stage> createState() => _C2StageState();
}

class _C2StageState extends State<C2Stage> {
  late final identity = widget.identity ?? RoomClient();
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
      if (widget.autoInitialize) await client.initialize();
      if (widget.roomId != null) {
        if (widget.autoInitialize) {
          await client.load(widget.roomId!);
        } else {
          client.roomId = widget.roomId;
          await client.refresh();
        }
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
      if (mounted) context.go('/rooms/${data['room_id']}');
    } catch (e) {
      if (mounted) setState(() => error = RoomClient.explain(e));
    }
  }

  @override
  void dispose() {
    client.removeListener(changed);
    client.dispose();
    if (widget.identity == null) identity.dispose();
    invite.dispose();
    super.dispose();
  }

  List<dynamic> list(String key) => client.view?[key] as List? ?? [];
  Widget panel(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 20),
    child: Padding(
      padding: const EdgeInsets.all(26),
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

  Widget chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xffd8ab65).withValues(alpha: .09),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: const Color(0xffd8ab65).withValues(alpha: .22)),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: Color(0xffdeb97d)),
    ),
  );
  Widget teamPanel(Json v) => panel('同场的人', [
    for (final member in list('members'))
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(
          backgroundColor: const Color(0xff314b3e),
          child: Text((member['display_name'] as String).characters.first),
        ),
        title: Text(member['display_name']),
        subtitle: Text(
          member['role_id'] == null
              ? '等待选角'
              : (list('roles')
                        .where((r) => r['id'] == member['role_id'])
                        .firstOrNull?['label'] ??
                    member['role_id']),
        ),
        trailing: Icon(
          member['online'] == true ? Icons.circle : Icons.circle_outlined,
          size: 8,
          color: member['online'] == true
              ? const Color(0xff83ad8b)
              : Colors.grey,
        ),
      ),
  ]);
  Widget knowledgePanel() => panel('我的线索', [
    for (final k in list('knowledge'))
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k['text'], style: const TextStyle(height: 1.8)),
            if (k['shareable'] == true)
              TextButton.icon(
                onPressed: client.busy
                    ? null
                    : () => unawaited(share(Map<String, dynamic>.from(k))),
                icon: const Icon(Icons.ios_share, size: 16),
                label: const Text('分享给同伴'),
              ),
          ],
        ),
      ),
    if (list('knowledge').isEmpty)
      const Text(
        '留意周围的细节。新的线索会出现在这里。',
        style: TextStyle(color: Colors.white54, height: 1.8),
      ),
  ]);
  Widget mapPanel(Json v, bool disabled) => panel('探索地图', [
    for (final l in v['map']['locations'])
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          l['id'] == v['self']['location']
              ? Icons.my_location
              : Icons.place_outlined,
          color: l['id'] == v['self']['location']
              ? const Color(0xffdeb97d)
              : Colors.white38,
        ),
        title: Text(l['label']),
        subtitle: l['id'] == v['self']['location'] ? const Text('你在这里') : null,
      ),
    for (final link in (v['map']['links'] as List).where(
      (l) => l['from'] == v['self']['location'],
    ))
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton(
          onPressed:
              disabled ||
                  link['allowed_now'] != true ||
                  v['room']['status'] != 'active'
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
      ),
  ]);
  @override
  Widget build(BuildContext context) {
    final v = client.view;
    final room = v?['room'] as Json?;
    final disabled = client.busy || client.pending != null;
    final active = room?['status'] == 'active';
    final lobby = room?['status'] == 'lobby';
    final self = v?['self'];
    final cues = list('narrative_cues')
        .where(
          (c) => !(v?['acknowledged_cues'] as List? ?? []).contains(c['id']),
        )
        .toList();
    final title = v?['story_title'] ?? '故事现场';
    final ownMember = list('members')
        .where((m) => m['member_id'] == v?['own_member_id'])
        .firstOrNull;
    final ownRole = list('roles')
        .where((r) => r['id'] == ownMember?['role_id'])
        .firstOrNull;
    final main = <Widget>[
      if (lobby)
        panel('选择你的角色', [
          const Text(
            '每个人都有自己的视角。选好角色，故事就从你们之间开始。',
            style: TextStyle(color: Colors.white54, height: 1.8),
          ),
          const SizedBox(height: 20),
          for (final r in list('roles'))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: ownMember?['role_id'] == r['id']
                    ? const Color(0xff344b3c)
                    : const Color(0xff222e29),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: disabled
                      ? null
                      : () => unawaited(
                          client.command('role.select', {'role_id': r['id']}),
                        ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.person_outline,
                          color: Color(0xffb6c5b7),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            r['label'],
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                        if (ownMember?['role_id'] == r['id'])
                          const Icon(
                            Icons.check_circle,
                            color: Color(0xffcfb378),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: disabled || ownMember?['role_id'] == null
                ? null
                : () => unawaited(
                    client.command('member.ready', {'ready': true}),
                  ),
            child: Text(ownMember?['ready'] == true ? '已准备，等待同伴' : '我准备好了'),
          ),
          if (v?['host_member_id'] == v?['own_member_id'])
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton(
                onPressed:
                    disabled ||
                        !list('members').every((m) => m['ready'] == true)
                    ? null
                    : () => unawaited(client.command('room.start')),
                child: const Text('全员就绪，开始故事'),
              ),
            ),
        ]),
      if (room?['status'] == 'suspended')
        panel('故事暂停在这里', [
          const Text(
            '等同伴回来。所有参与者确认后，将从原处继续。',
            style: TextStyle(height: 1.8, color: Colors.white60),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: disabled
                ? null
                : () => unawaited(client.command('room.resume')),
            child: const Text('我已回来，确认继续'),
          ),
        ]),
      if (room?['ending'] != null)
        panel('故事的最后一页', [
          const Icon(
            Icons.auto_stories_outlined,
            size: 40,
            color: Color(0xffd4b782),
          ),
          const SizedBox(height: 20),
          Text(
            room!['ending']['summary'],
            style: const TextStyle(fontSize: 18, height: 2),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => context.go('/discover'),
            child: const Text('发现下一部剧目'),
          ),
        ]),
      for (final cue in cues)
        panel('此刻的故事', [
          Text(
            cue['summary'] ?? '',
            style: const TextStyle(
              fontSize: 17,
              height: 2,
              color: Color(0xffe3e1d5),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: disabled
                ? null
                : () => unawaited(
                    client.command('media.complete', {
                      'cue_id': cue['id'],
                      'mode': 'summary',
                    }),
                  ),
            child: const Text('读完，继续故事'),
          ),
        ]),
      if (active)
        panel('接下来，你会怎么做？', [
          for (final a in list('actions'))
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xff24332b),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xff38493d)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          a['label'],
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      chip('${a['cost']} 行动点'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    a['risk_text'] ?? '',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed:
                          disabled ||
                              a['allowed_now'] != true ||
                              cues.any((c) => c['blocking'] == true)
                          ? null
                          : () => unawaited(
                              client.command('action.submit', {
                                'action_id': a['id'],
                                'target_id': null,
                              }),
                            ),
                      child: const Text('选择这个行动 →'),
                    ),
                  ),
                ],
              ),
            ),
          if (list('actions').isEmpty)
            const Text(
              '这里暂时没有可执行的行动。可以看看地图，前往别的地点。',
              style: TextStyle(height: 1.8, color: Colors.white54),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              if (v?['own_intent_id'] != null)
                OutlinedButton(
                  onPressed: disabled
                      ? null
                      : () => unawaited(
                          client.command('action.cancel', {
                            'intent_id': v!['own_intent_id'],
                          }),
                        ),
                  child: const Text('取消本步行动'),
                ),
              TextButton(
                onPressed: disabled
                    ? null
                    : () => unawaited(client.command('round.end')),
                child: const Text('结束本回合'),
              ),
            ],
          ),
        ]),
      if (v?['vote'] != null)
        panel('共同作出决定', [
          for (final option in v!['vote']['options'])
            ListTile(
              title: Text(option['label']),
              leading: Icon(
                v['vote']['own_ballot'] == option['id']
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
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
    ];
    final aside = <Widget>[
      if (lobby && v?['invite_code'] != null)
        panel('邀请同伴入戏', [
          const Text(
            '把邀请码发给朋友，一起走进这部故事。',
            style: TextStyle(color: Colors.white54, height: 1.8),
          ),
          const SizedBox(height: 20),
          SelectableText(
            v!['invite_code'],
            style: const TextStyle(
              fontSize: 26,
              letterSpacing: 5,
              color: Color(0xffdeb97d),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${list('members').length} / ${v['seat_count']} 人已加入',
            style: const TextStyle(color: Colors.white54),
          ),
        ]),
      if (self != null)
        panel('你的角色', [
          Text(
            ownRole?['label'] ?? self['role_id'],
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              chip('剩余 ${self['ap_remaining']} 点'),
              chip('预留 ${self['ap_reserved']} 点'),
            ],
          ),
          for (final goal in self['goals'] ?? [])
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                '$goal',
                style: const TextStyle(height: 1.7, color: Colors.white60),
              ),
            ),
        ]),
      if (v?['map'] != null) mapPanel(v!, disabled),
      if (!lobby) knowledgePanel(),
      if (!lobby)
        panel('随身物品', [
          for (final item in list('inventory'))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(item['label']),
              subtitle: Text(item['reserved'] == true ? '等待交接' : '由你持有'),
            ),
          if (list('inventory').isEmpty)
            const Text('暂时没有随身物品。', style: TextStyle(color: Colors.white54)),
        ]),
      if (v != null) teamPanel(v),
    ];
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        title: const Text(
          '入戏',
          style: TextStyle(
            fontFamily: 'Songti SC',
            letterSpacing: 5,
            fontSize: 28,
          ),
        ),
        leading: IconButton(
          tooltip: '返回剧目',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/discover'),
        ),
        actions: [
          IconButton(
            tooltip: '刷新房间',
            onPressed: () => unawaited(client.refresh()),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: Padding(
                      padding: EdgeInsets.all(box.maxWidth < 700 ? 16 : 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            children: [
                              chip(
                                lobby
                                    ? '开场之前'
                                    : room?['ending'] != null
                                    ? '故事落幕'
                                    : '故事进行中',
                              ),
                              chip(client.live ? '实时连接' : '正在恢复连接'),
                              if (room?['round'] != null)
                                chip(
                                  '第 ${room!['round']} 回合 · 第 ${room['step']} 步',
                                ),
                            ],
                          ),
                          const SizedBox(height: 22),
                          Text(
                            title,
                            style: const TextStyle(
                              fontFamily: 'Songti SC',
                              fontSize: 34,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '你的选择，正在改变故事的方向。',
                            style: TextStyle(
                              color: Colors.white54,
                              height: 1.8,
                            ),
                          ),
                          const SizedBox(height: 28),
                          if (error != null || client.error != null)
                            panel('操作提示', [Text(error ?? client.error!)]),
                          if (client.pending != null)
                            panel('上次行动尚待确认', [
                              const Text('先检查结果，避免重复执行。'),
                              Wrap(
                                spacing: 12,
                                children: [
                                  TextButton(
                                    onPressed: client.busy
                                        ? null
                                        : () => unawaited(
                                            client.recoverCommand(),
                                          ),
                                    child: const Text('检查操作结果'),
                                  ),
                                  TextButton(
                                    onPressed: client.busy
                                        ? null
                                        : () =>
                                              unawaited(client.retryCommand()),
                                    child: const Text('用原编号重新发送'),
                                  ),
                                ],
                              ),
                            ]),
                          if (box.maxWidth >= 960)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: Column(children: main)),
                                const SizedBox(width: 24),
                                SizedBox(
                                  width: 330,
                                  child: Column(children: aside),
                                ),
                              ],
                            )
                          else ...[
                            ...main,
                            ...aside,
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
