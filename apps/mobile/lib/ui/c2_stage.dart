import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/c2_client.dart';
import '../data/room_client.dart';
import 'novel_widgets.dart';

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
  bool loading = true, _seeded = false, _presenting = false;
  String? error, _ending;
  int? _round;
  final _results = <String>{}, _cues = <String>{}, _knowledge = <String>{};
  final _messages = <NovelMessage>[];
  final _log = <NovelMessage>[];
  List<dynamic> items(String key) => client.view?[key] as List? ?? [];
  @override
  void initState() {
    super.initState();
    client.addListener(changed);
    unawaited(initialize());
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
      }
    } catch (e) {
      error = RoomClient.explain(e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void changed() {
    if (!mounted) return;
    final v = client.view;
    if (v != null) observe(v);
    setState(() {});
  }

  void observe(Json v) {
    final room = v['room'];
    final round = room['round'] as int?;
    final results = items('own_results');
    final knowledge = items('knowledge');
    if (!_seeded) {
      _results.addAll(results.map((r) => '${r['intent_id']}'));
      _knowledge.addAll(knowledge.map((k) => '${k['id']}'));
      _seeded = true;
    }
    final freshCues = items('narrative_cues')
        .where(
          (c) =>
              !(v['acknowledged_cues'] as List? ?? []).contains(c['id']) &&
              !_cues.contains(c['id']),
        )
        .toList();
    final freshResults = results
        .where((r) => !_results.contains('${r['intent_id']}'))
        .toList();
    final freshKnowledge = knowledge
        .where((k) => !_knowledge.contains('${k['id']}'))
        .toList();
    _knowledge.addAll(knowledge.map((k) => '${k['id']}'));
    _cues.addAll(freshCues.map((c) => '${c['id']}'));
    for (final result in freshResults) {
      _results.add('${result['intent_id']}');
      final invalid = result['status'] == 'invalidated';
      final success = result['success'] != false && !invalid;
      final location = (v['map']?['locations'] as List? ?? [])
          .where((l) => l['id'] == v['self']?['location'])
          .firstOrNull;
      final moved = '${result['action_id']}'.startsWith('move:');
      final details = [
        if (invalid) '行动条件发生了变化，这次行动未执行，预留的行动点已退回。',
        if (!invalid && !success) '这次尝试没有成功。你可以整理思路，再寻找其他办法。',
        if (success && moved)
          '你来到${location?['label'] ?? '新的地点'}。\n${location?['description'] ?? ''}',
        if (success && !moved && freshCues.isEmpty && freshKnowledge.isEmpty)
          '你的行动已经完成。环顾四周，看看接下来还能做些什么。',
        if (success)
          ...freshCues.map((c) => '${c['summary'] ?? c['text'] ?? ''}'),
        if (success) ...freshKnowledge.map((k) => '${k['text']}'),
      ].join('\n\n');
      enqueue(
        NovelMessage(
          title: moved
              ? '场景抵达'
              : success
              ? '行动回响'
              : '行动结果',
          text: details,
          subtitle: '${result['label'] ?? '你的选择'} · ${result['cost'] ?? 0} 行动点',
          clue: freshKnowledge.isNotEmpty,
          acknowledge: freshCues.map((c) => '${c['id']}').toList(),
        ),
      );
    }
    if (freshResults.isEmpty) {
      if (freshKnowledge.isNotEmpty) {
        enqueue(
          NovelMessage(
            title: '一条新的线索',
            text: freshKnowledge.map((k) => '${k['text']}').join('\n\n'),
            clue: true,
          ),
        );
      }
      for (final cue in freshCues) {
        enqueue(
          NovelMessage(
            title: '故事 · 旁白',
            text: '${cue['summary'] ?? cue['text'] ?? ''}',
            acknowledge: ['${cue['id']}'],
          ),
        );
      }
    }
    if (_round != null &&
        round != null &&
        round > _round! &&
        room['ending'] == null) {
      enqueue(
        NovelMessage(
          title: '第 $round 回合',
          text: '时间向前，故事继续。\n行动点已恢复，重新决定你的下一步。',
          round: round,
        ),
      );
    }
    _round = round;
    final ending = room['ending'];
    if (ending != null && _ending != ending['id']) {
      _ending = ending['id'];
      enqueue(
        NovelMessage(
          title: '故事的最后一页',
          text: '${ending['summary']}',
          subtitle: '你的选择，写下了这个结局。',
          ending: true,
        ),
      );
    }
  }

  void enqueue(NovelMessage message) {
    _messages.add(message);
    _log.add(message);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(present()));
  }

  Future<void> present() async {
    if (_presenting || !mounted) return;
    _presenting = true;
    while (_messages.isNotEmpty && mounted) {
      if (!mounted) break;
      final message = _messages.removeAt(0);
      await showNovelMessage(context, message);
      if (!mounted) break;
      for (final cue in message.acknowledge) {
        await client.command('media.complete', {
          'cue_id': cue,
          'mode': 'summary',
        });
        if (client.error != null || client.pending != null) {
          _cues.remove(cue);
          break;
        }
      }
    }
    _presenting = false;
    if (mounted) setState(() {});
  }

  Future<void> send(
    String type, [
    Json body = const {},
    String? feedback,
  ]) async {
    if (client.busy || client.pending != null) return;
    await client.command(type, body);
    if (!mounted) return;
    if (client.error != null) {
      enqueue(NovelMessage(title: '这一步尚未完成', text: client.error!));
    } else if (type == 'action.submit' && client.view?['own_intent'] != null) {
      enqueue(
        const NovelMessage(
          title: '行动已提交',
          text: '你已作出选择，行动点暂时预留。等其他参与者决定后，故事会给出结果。',
        ),
      );
    } else if (feedback != null) {
      enqueue(NovelMessage(title: '你的选择', text: feedback));
    }
  }

  Future<bool?> ask(NovelMessage message) async {
    if (_presenting || !mounted) return null;
    _presenting = true;
    try {
      return await showNovelMessage(context, message);
    } finally {
      _presenting = false;
      if (mounted) unawaited(present());
    }
  }

  Future<void> choose(Json action) async {
    if (!['deliver', 'keep'].contains(action['id'])) {
      await send('action.submit', {
        'action_id': action['id'],
        'target_id': null,
      });
      return;
    }
    final confirmed = await ask(
      NovelMessage(
        title: action['label'],
        text: '${action['risk_text'] ?? '仔细观察，或许能找到新的线索。'}',
        subtitle: '消耗 ${action['cost']} 行动点',
        confirm: true,
      ),
    );
    if (confirmed == true && mounted) {
      await send('action.submit', {
        'action_id': action['id'],
        'target_id': null,
      });
    }
  }

  Future<void> move(Json location, Json? link) async {
    final current = client.view?['self']?['location'] == location['id'];
    final confirmed = await ask(
      NovelMessage(
        title: location['label'],
        text: location['description'] ?? '安静地观察这个地点。',
        subtitle: current
            ? '你正在这里'
            : link == null
            ? '这里没有直接相连的通路'
            : '移动消耗 ${link['cost']} 行动点',
        confirm:
            !current &&
            link?['allowed_now'] == true &&
            !blocked &&
            client.view?['room']['status'] == 'active' &&
            (link?['cost'] ?? 0) <=
                ((client.view?['self']['ap_remaining'] ?? 0) -
                    (client.view?['self']['ap_reserved'] ?? 0)),
      ),
    );
    if (confirmed == true && link != null && mounted) {
      await send('action.submit', {
        'action_id': 'move:${link['id']}',
        'target_id': null,
      });
    }
  }

  bool get blocked =>
      client.busy ||
      client.pending != null ||
      client.view?['own_intent'] != null ||
      items('narrative_cues').any(
        (c) =>
            c['blocking'] == true &&
            !(client.view?['acknowledged_cues'] as List? ?? []).contains(
              c['id'],
            ),
      );
  Future<void> share(Json clue) async {
    final selected = <String>{};
    final members = items('members')
        .where((m) => m['member_id'] != client.view?['own_member_id'])
        .toList();
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('分享这条线索'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('选中的同伴会永久获得这条线索。'),
                for (final m in members)
                  CheckboxListTile(
                    title: Text(m['display_name']),
                    value: selected.contains(m['member_id']),
                    onChanged: (v) => set(
                      () => v == true
                          ? selected.add(m['member_id'])
                          : selected.remove(m['member_id']),
                    ),
                  ),
              ],
            ),
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
              child: const Text('分享'),
            ),
          ],
        ),
      ),
    );
    if (yes == true && mounted) {
      await send('knowledge.share', {
        'clue_id': clue['id'],
        'audience_member_ids': selected.toList(),
      }, '这条线索已经分享给选中的同伴。');
    }
  }

  Future<void> journal() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xff152127),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 650),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '旅途手记',
                        style: TextStyle(fontSize: 24, fontFamily: 'Songti SC'),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      tooltip: '关闭手记',
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      for (final k in items('knowledge'))
                        ListTile(
                          leading: const Icon(
                            Icons.mail_outline,
                            color: novelGold,
                          ),
                          trailing:
                              k['shareable'] == true &&
                                  items('roles').length > 1
                              ? IconButton(
                                  tooltip: '分享线索',
                                  icon: const Icon(Icons.ios_share, size: 18),
                                  onPressed: client.busy
                                      ? null
                                      : () {
                                          Navigator.pop(context);
                                          unawaited(
                                            share(Map<String, dynamic>.from(k)),
                                          );
                                        },
                                )
                              : null,
                          title: Text(
                            k['text'],
                            style: const TextStyle(height: 1.8),
                          ),
                        ),
                      if (items('knowledge').isEmpty)
                        const Text('还没有线索。尝试与场景中的事物互动。'),
                      const Divider(height: 40),
                      const Text('随身物品', style: TextStyle(color: novelGold)),
                      for (final i in items('inventory'))
                        ListTile(title: Text(i['label'])),
                      const Divider(height: 32),
                      const Text('本次阅读记录', style: TextStyle(color: novelGold)),
                      for (final m in _log.reversed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            '${m.title}\n${m.text}',
                            style: const TextStyle(height: 1.8),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    client.removeListener(changed);
    client.dispose();
    if (widget.identity == null) identity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = client.view;
    if (loading || v == null) {
      return Scaffold(
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(error!),
                    TextButton(
                      onPressed: initialize,
                      child: const Text('重新连接'),
                    ),
                  ],
                ),
        ),
      );
    }
    final room = v['room'];
    final self = v['self'];
    final locations = (v['map']?['locations'] as List? ?? []).cast<Json>();
    final links = (v['map']?['links'] as List? ?? []).cast<Json>();
    final location = locations
        .where((l) => l['id'] == self?['location'])
        .firstOrNull;
    final member = items('members')
        .where((m) => m['member_id'] == v['own_member_id'])
        .firstOrNull;
    final solo = items('roles').length == 1;
    final lobby = room['status'] == 'lobby';
    final active = room['status'] == 'active';
    final ended = room['ending'] != null;
    final background = v['story_title'] == '雨夜最后一封信'
        ? 'assets/stories/last_letter/${self?['location'] == 'archive' ? 'archive' : 'office'}.png'
        : null;
    return Scaffold(
      backgroundColor: const Color(0xff0b151d),
      body: LayoutBuilder(
        builder: (context, size) {
          final narrow = size.maxWidth < 700;
          return Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 700),
                child: background == null
                    ? Container(
                        key: const ValueKey('fallback'),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xff33505c), Color(0xff0d1922)],
                          ),
                        ),
                      )
                    : Image.asset(
                        background,
                        key: ValueKey(background),
                        fit: BoxFit.cover,
                        alignment: Alignment(narrow ? .45 : 0, 0),
                        width: size.maxWidth,
                        height: size.maxHeight,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: Color(0xff1a2a32)),
                      ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, .32, .68, 1],
                    colors: [
                      Color(0xaa07131c),
                      Colors.transparent,
                      Color(0x5507131c),
                      Color(0xff07131c),
                    ],
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: narrow ? 12 : 28,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => context.go('/discover'),
                            tooltip: '返回剧目',
                            icon: const Icon(Icons.arrow_back),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              v['story_title'] ?? '故事现场',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Songti SC',
                                fontSize: narrow ? 19 : 25,
                                color: const Color(0xfff4ecd9),
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: journal,
                            tooltip: '旅途手记',
                            icon: Badge(
                              label: Text('${items('knowledge').length}'),
                              isLabelVisible: items('knowledge').isNotEmpty,
                              child: const Icon(Icons.menu_book_outlined),
                            ),
                          ),
                          IconButton(
                            onPressed: client.busy
                                ? null
                                : () => unawaited(client.refresh()),
                            tooltip: client.live ? '连接正常 · 刷新' : '正在连接 · 刷新',
                            icon: Icon(
                              client.live ? Icons.wifi : Icons.sync,
                              size: 20,
                              color: client.live
                                  ? const Color(0xffb8cfbf)
                                  : novelGold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned(
                            left: narrow ? 22 : 64,
                            top: 12,
                            right: narrow ? 170 : 350,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  lobby
                                      ? '故事即将开始'
                                      : '第 ${room['round'] ?? 1} 回合',
                                  style: const TextStyle(
                                    color: novelGold,
                                    letterSpacing: 2,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  lobby
                                      ? (v['story_title'] == '雨夜最后一封信'
                                            ? '最后一次值夜'
                                            : '选择你的角色')
                                      : location?['label'] ?? '故事现场',
                                  style: TextStyle(
                                    fontSize: narrow ? 26 : 44,
                                    fontFamily: 'Songti SC',
                                    color: const Color(0xfff6efd9),
                                  ),
                                ),
                                if (!lobby)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: Wrap(
                                      spacing: 4,
                                      children: [
                                        for (
                                          var i = 0;
                                          i < (self?['ap_remaining'] ?? 0);
                                          i++
                                        )
                                          Icon(
                                            Icons.diamond_outlined,
                                            size: narrow ? 15 : 19,
                                            color:
                                                i < (self?['ap_reserved'] ?? 0)
                                                ? Colors.white38
                                                : novelGold,
                                          ),
                                        Text(
                                          '  ${self?['ap_remaining'] ?? 0} 行动点',
                                          style: const TextStyle(
                                            color: Color(0xffe5dcc5),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (!lobby && locations.isNotEmpty)
                            Positioned(
                              top: 4,
                              right: narrow ? 12 : 40,
                              child: SizedBox(
                                width: narrow ? 146 : 250,
                                height: narrow ? 155 : 210,
                                child: NovelMap(
                                  locations: locations,
                                  links: links,
                                  current: self?['location'],
                                  onSelect: (l) => unawaited(
                                    move(
                                      l,
                                      links
                                          .where(
                                            (e) =>
                                                e['from'] ==
                                                    self?['location'] &&
                                                e['to'] == l['id'],
                                          )
                                          .firstOrNull,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        narrow ? 12 : 48,
                        0,
                        narrow ? 12 : 48,
                        narrow ? 12 : 30,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: 1100,
                          maxHeight: size.maxHeight * (narrow ? .57 : .5),
                        ),
                        child: NovelPanel(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: EdgeInsets.all(narrow ? 20 : 28),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.auto_awesome_outlined,
                                        size: 16,
                                        color: novelGold,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          lobby
                                              ? '选择你的视角'
                                              : ended
                                              ? '终章'
                                              : '接下来，你会怎么做？',
                                          style: const TextStyle(
                                            color: novelGold,
                                            fontSize: 13,
                                            letterSpacing: 2,
                                          ),
                                        ),
                                      ),
                                      if (client.busy)
                                        const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    lobby
                                        ? solo
                                              ? '一盏灯，一封信，一个等待揭开的雨夜。\n准备好之后，独自走进这个故事。'
                                              : '选择你的角色。每个人的视角，都可能改变故事的方向。'
                                        : ended
                                        ? room['ending']['summary']
                                        : location?['description'] ??
                                              '留意周围的细节，选择你的下一步。',
                                    style: TextStyle(
                                      fontSize: narrow ? 15 : 18,
                                      height: 1.9,
                                      color: const Color(0xffebe6d8),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  if (lobby) ...[
                                    if (!solo && v['invite_code'] != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 16,
                                        ),
                                        child: SelectableText(
                                          '邀请同伴 · ${v['invite_code']}',
                                          style: const TextStyle(
                                            color: novelGold,
                                          ),
                                        ),
                                      ),
                                    if (!solo)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: Text(
                                          items('members')
                                              .map(
                                                (m) =>
                                                    '${m['display_name']} · ${m['ready'] == true ? '已准备' : '未准备'}',
                                              )
                                              .join(' / '),
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        for (final r in items('roles'))
                                          ChoiceChip(
                                            label: Text(r['label']),
                                            selected:
                                                member?['role_id'] == r['id'],
                                            onSelected: client.busy
                                                ? null
                                                : (_) => unawaited(
                                                    send(
                                                      'role.select',
                                                      {'role_id': r['id']},
                                                      '你将以${r['label']}的身份进入故事。',
                                                    ),
                                                  ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    FilledButton(
                                      onPressed:
                                          client.busy ||
                                              member?['role_id'] == null
                                          ? null
                                          : () => unawaited(() async {
                                              await send('member.ready', {
                                                'ready': true,
                                              });
                                              if (solo &&
                                                  client.error == null &&
                                                  mounted) {
                                                await send('room.start');
                                              }
                                            }()),
                                      child: Text(
                                        solo
                                            ? '走进故事 →'
                                            : member?['ready'] == true
                                            ? '已准备，等待同伴'
                                            : '我准备好了',
                                      ),
                                    ),
                                    if (!solo &&
                                        v['host_member_id'] ==
                                            v['own_member_id'])
                                      TextButton(
                                        onPressed:
                                            client.busy ||
                                                !items('members').every(
                                                  (m) => m['ready'] == true,
                                                )
                                            ? null
                                            : () =>
                                                  unawaited(send('room.start')),
                                        child: const Text('全员就绪，开始故事'),
                                      ),
                                  ],
                                  if (active) ...[
                                    if (blocked && !client.busy)
                                      Text(
                                        client.view?['own_intent'] != null
                                            ? '行动已提交，等待其他参与者。'
                                            : '读完当前叙事后，继续探索。',
                                        style: const TextStyle(
                                          color: novelGold,
                                        ),
                                      ),
                                    Wrap(
                                      spacing: 12,
                                      runSpacing: 10,
                                      children: [
                                        for (final a in items('actions'))
                                          NovelChoice(
                                            label: a['label'],
                                            cost: a['cost'],
                                            enabled:
                                                !blocked &&
                                                a['allowed_now'] == true,
                                            onTap: () => unawaited(
                                              choose(
                                                Map<String, dynamic>.from(a),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 14),
                                    Wrap(
                                      alignment: WrapAlignment.spaceBetween,
                                      spacing: 16,
                                      runSpacing: 8,
                                      children: [
                                        TextButton.icon(
                                          onPressed:
                                              client.busy ||
                                                  client.pending != null ||
                                                  items('narrative_cues').any(
                                                    (c) =>
                                                        c['blocking'] == true &&
                                                        !(v['acknowledged_cues']
                                                                    as List? ??
                                                                [])
                                                            .contains(c['id']),
                                                  )
                                              ? null
                                              : () => unawaited(() async {
                                                  final yes = await ask(
                                                    NovelMessage(
                                                      title: '让时间继续',
                                                      text: '结束本回合会放弃剩余行动点。所有参与者结束后，进入下一回合并恢复行动点。',
                                                      subtitle:
                                                          '当前剩余 ${self?['ap_remaining'] ?? 0} 行动点',
                                                      confirm: true,
                                                    ),
                                                  );
                                                  if (yes == true) {
                                                    await send('round.end');
                                                  }
                                                }()),
                                          icon: const Icon(
                                            Icons.nights_stay_outlined,
                                            size: 16,
                                          ),
                                          label: const Text('结束本回合'),
                                        ),
                                        if (v['own_intent'] != null)
                                          TextButton(
                                            onPressed: client.busy
                                                ? null
                                                : () => unawaited(
                                                    send('action.cancel', {
                                                      'intent_id':
                                                          v['own_intent']['id'],
                                                    }, '已取消等待中的行动。'),
                                                  ),
                                            child: const Text('取消待执行行动'),
                                          ),
                                        if (items('knowledge').isNotEmpty)
                                          TextButton.icon(
                                            onPressed: journal,
                                            icon: const Icon(
                                              Icons.mail_outline,
                                              size: 16,
                                            ),
                                            label: Text(
                                              '${items('knowledge').length} 条线索 · 查看手记',
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                  if (v['vote'] != null) ...[
                                    Text(v['vote']['label']),
                                    for (final option in v['vote']['options'])
                                      NovelChoice(
                                        label: option['label'],
                                        enabled: !client.busy,
                                        onTap: () => unawaited(
                                          send('vote.cast', {
                                            'option_id': option['id'],
                                          }, '你的投票已记录。'),
                                        ),
                                      ),
                                  ],
                                  if (room['status'] == 'suspended')
                                    FilledButton(
                                      onPressed: client.busy
                                          ? null
                                          : () => unawaited(
                                              send(
                                                'room.resume',
                                                {},
                                                '你已确认继续，等待所有参与者回来。',
                                              ),
                                            ),
                                      child: const Text('故事已暂停 · 确认继续'),
                                    ),
                                  if (ended)
                                    FilledButton(
                                      onPressed: () => context.go('/discover'),
                                      child: const Text('带着故事离开 →'),
                                    ),
                                  if (client.pending != null)
                                    OutlinedButton(
                                      onPressed: client.busy
                                          ? null
                                          : () => unawaited(
                                              client.recoverCommand(),
                                            ),
                                      child: const Text('查询未确认的操作'),
                                    ),
                                  if (client.error != null)
                                    Text(
                                      client.error!,
                                      style: const TextStyle(
                                        color: Color(0xffe3ad98),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
