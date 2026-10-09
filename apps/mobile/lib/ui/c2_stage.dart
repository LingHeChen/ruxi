import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/c2_client.dart';
import '../data/room_client.dart';
import 'novel_widgets.dart';
import 'game_inventory.dart';
import 'interaction_dialog.dart';

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

  String? illustrationFor(Json v, String? media, [String? action]) {
    final cue = items('narrative_cues')
        .where((c) => c['media_id'] == media && c['image_uri'] != null)
        .firstOrNull;
    if (media != null && cue != null) return cue['image_uri'];
    final result = items('own_results')
        .where((r) => r['action_id'] == action && r['image_uri'] != null)
        .lastOrNull;
    if (result != null) return result['image_uri'];
    if (action?.startsWith('move:') == true) {
      final scene = (v['map']?['locations'] as List? ?? [])
          .where((l) => l['id'] == v['self']?['location'])
          .firstOrNull;
      if (scene?['image_uri'] != null) return scene['image_uri'];
    }
    if (v['story_title'] != '雨夜最后一封信') return null;
    if (media == 'opening' || action == 'read_letter') {
      return 'assets/stories/last_letter/arrival.png';
    }
    if (action == 'inspect_damage' || media == 'echo_inspect_damage') {
      return 'assets/stories/last_letter/rescue.png';
    }
    return null;
  }

  List<Json> narrativeChoices(Json v, List<dynamic> clues, String? action) {
    if (v['room']['status'] == 'active' && v['story_title'] == '潮汐旅馆：第九声钟响') {
      final result = items('own_results')
          .where((r) => r['action_id'] == action)
          .lastOrNull;
      final target = result?['target'];
      return items('actions')
          .where(
            (a) =>
                a['allowed_now'] == true &&
                (a['remaining_uses'] ?? 0) > 0 &&
                (action == 'reconstruct'
                    ? {
                        'publish_truth',
                        'seal_handover',
                        'accuse_murder',
                      }.contains(a['id'])
                    : target != null && a['target'] == target),
          )
          .take(3)
          .map((a) => Map<String, dynamic>.from(a))
          .toList();
    }
    if (v['story_title'] != '雨夜最后一封信' || v['room']['status'] != 'active') {
      return [];
    }
    final gained = clues.map((c) => c['id']).toSet();
    final group = gained.contains('damage') || action == 'inspect_damage'
        ? {'rescue_ledger', 'rescue_tape', 'listen_rain'}
        : gained.contains('last_note') || gained.contains('doubt')
        ? {'deduce_rescue', 'deduce_abandon'}
        : action?.startsWith('move:') == true &&
              v['self']['location'] == 'office' &&
              items('knowledge').any((k) => k['id'] == 'truth')
        ? {'deliver', 'keep'}
        : <String>{};
    return items('actions')
        .where((a) => group.contains(a['id']) && (a['remaining_uses'] ?? 1) > 0)
        .map((a) => Map<String, dynamic>.from(a))
        .toList();
  }

  void observe(Json v) {
    final room = v['room'];
    final round = room['round'] as int?;
    final results = items('own_results');
    final knowledge = items('knowledge');
    if (!_seeded) {
      _results.addAll(results.map((r) => '${r['intent_id']}'));
      _results.addAll(
        items('interaction_results')
            .map((r) => 'interaction:${r['resolution_id']}'),
      );
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
    for (final outcome in items('interaction_results')) {
      if (_results.add('interaction:${outcome["resolution_id"]}')) {
        final check = outcome["kind"] == "check";
        enqueue(
          NovelMessage(
            title: check
                ? '骰子判定 · ${outcome["success"] == true ? "成功" : "失败"}'
                : '密码${outcome["success"] == true ? "正确" : "错误"}',
            clue: freshKnowledge.isNotEmpty,
            acknowledge: freshCues.map((c) => '${c['id']}').toList(),
            text: [
              '${check ? "点数 ${outcome["roll"]} / 目标 ${outcome["target"]}\n\n" : ""}本次尝试已结算，消耗 ${outcome["cost"]} 余力。剩余 ${outcome["attempts_remaining"]} 次尝试。',
              ...freshCues.map((c) => '${c['summary'] ?? c['text'] ?? ''}'),
              ...freshKnowledge.map((k) => '${k['text']}'),
            ].join('\n\n'),
            illustration:
                freshCues
                    .where((c) => c['image_uri'] != null)
                    .firstOrNull?['image_uri'] ??
                outcome['image_uri'],
          ),
        );
      }
    }
    for (final result in freshResults) {
      if ('${result["action_id"]}'.startsWith('interaction:') &&
          result['status'] == 'resolved') {
        _results.add('${result["intent_id"]}');
        continue;
      }
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
          illustration: illustrationFor(v, null, result['action_id']),
          choices: success
              ? narrativeChoices(v, freshKnowledge, result['action_id'])
              : const [],
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
            illustration: illustrationFor(v, cue['media_id']),
            choices: cue['media_id'] == 'echo_inspect_damage'
                ? narrativeChoices(v, const [], 'inspect_damage')
                : const [],
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
          title: v['story_title'] == '雨夜最后一封信'
              ? (round == 2
                    ? '雨势渐急'
                    : round == 3
                    ? '灯光熄灭'
                    : '天将破晓')
              : '第 $round 回合',
          text: v['story_title'] == '雨夜最后一封信'
              ? '这个雨夜向前走了一段。\n留意场景的变化，再作出你的选择。'
              : '时间向前，故事继续。\n行动点已恢复，重新决定你的下一步。',
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
          illustration: ending['kind'] == 'image' ? ending['uri'] : null,
        ),
      );
    }
  }

  void enqueue(NovelMessage message) {
    _messages.add(message);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(present()));
  }

  Future<void> present() async {
    if (_presenting || !mounted) return;
    _presenting = true;
    while (_messages.isNotEmpty && mounted) {
      if (!mounted) break;
      final message = _messages.removeAt(0);
      await showNovelMessage(
        context,
        message,
        onChoice: (action) => submitNarrativeChoice(message, action),
        choiceAvailable: choiceAvailable,
      );
      if (!mounted) break;
      for (final cue in message.acknowledge) {
        if ((client.view?['acknowledged_cues'] as List? ?? []).contains(cue)) {
          continue;
        }
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

  bool choiceAvailable(Json choice) {
    if (client.busy ||
        client.pending != null ||
        client.view?['own_intent'] != null ||
        client.view?['room']['status'] != 'active') {
      return false;
    }
    final current = items('actions')
        .where((a) => a['id'] == choice['id'])
        .firstOrNull;
    return current != null && current['allowed_now'] == true;
  }

  Future<String?> submitNarrativeChoice(
    NovelMessage message,
    Json action,
  ) async {
    if (client.busy || client.pending != null) return '上一项操作尚未确认，请先返回场景查询操作结果。';
    for (final cue in message.acknowledge) {
      if ((client.view?['acknowledged_cues'] as List? ?? []).contains(cue)) {
        continue;
      }
      await client.command('media.complete', {
        'cue_id': cue,
        'mode': 'summary',
      });
      if (!mounted) return '故事已经离开当前页面。';
      if (client.error != null || client.pending != null) {
        return client.error ?? '阅读确认尚未完成，请稍后重试。';
      }
    }
    await client.refresh();
    if (!mounted) return '故事已经离开当前页面。';
    if (!choiceAvailable(action)) return '当前条件或余力已经变化。你可以稍后决定，回到场景查看新的选项。';
    await client.command('action.submit', {
      'action_id': action['id'],
      'target_id': null,
    });
    return client.error ??
        (client.pending != null ? '这次选择尚未确认，请返回场景查询操作结果。' : null);
  }

  bool _showAllActions = false;
  Future<void> interact(Json interaction) async {
    if (_presenting || client.busy || client.pending != null) return;
    _presenting = true;
    try {
      await showInteraction(
        context,
        interaction,
        () async => Map<String, dynamic>.from(
          await client.request(
            'POST',
            '/rooms/${client.roomId}/interaction-quotes',
            {
              'interaction_id': interaction['id'],
              'step_id': client.view?['room']['step_id'],
            },
          ),
        ),
        (q, answer) async {
          await client.command('interaction.submit', {
            'quote_id': q['quote_id'],
            'kind': interaction['kind'],
            'input': answer == null ? <String, dynamic>{} : {'answer': answer},
          });
          return client.error ??
              (client.pending != null ? '提交结果待确认，请返回场景查询原操作。' : null);
        },
      );
    } finally {
      _presenting = false;
      if (mounted) unawaited(present());
    }
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
    if (![
      'deliver',
      'keep',
      'rescue_ledger',
      'rescue_tape',
      'leave_early',
      'publish_truth',
      'seal_handover',
      'accuse_murder',
    ].contains(action['id'])) {
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
        illustration: location['image_uri'],
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

  Future<void> openPanel(GamePanel panel) async {
    if (_presenting || !mounted) return;
    _presenting = true;
    try {
      final clue = await showDialog<Json>(
        context: context,
        builder: (dialogContext) => GameInventory(
          initialPanel: panel,
          clues: items('knowledge').cast<Json>(),
          inventory: items('inventory').cast<Json>(),
          history:
              (client.view?['action_history'] as List? ?? items('own_results'))
                  .cast<Json>(),
          onShare: !client.busy && items('roles').length > 1
              ? (clue) => Navigator.pop(dialogContext, clue)
              : null,
        ),
      );
      if (clue != null && mounted) await share(clue);
    } finally {
      _presenting = false;
      if (mounted) unawaited(present());
    }
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
    final cinematic = solo && v['story_title'] == '雨夜最后一封信';
    final clues = items('knowledge').map((k) => k['id']).toSet();
    final chapter = clues.contains('truth')
        ? '第三幕 · 迟到的告别'
        : self?['location'] == 'archive' || clues.contains('damage')
        ? '第二幕 · 雨水中的选择'
        : '第一幕 · 雨夜来信';
    var sceneText = location?['description'] ?? '留意周围的细节，选择你的下一步。';
    if (cinematic && self?['location'] == 'archive') {
      if (clues.contains('truth')) {
        sceneText = '你已经把那夜的证据与今夜的邮戳联系起来。回到值班室，决定怎样完成这次迟到的告别。';
      } else if (clues.contains('last_note')) {
        sceneText = clues.contains('postmark')
            ? '抢救的证据与铁盒中的便条已经摆在面前。母亲为什么没回来？又是谁送来了这封信？'
            : '便条提到一个活下来的人。回值班室看看信封的新邮戳，也许能找到连接过去与今夜的名字。';
      } else if (clues.contains('record') || clues.contains('voice')) {
        sceneText = '你抢救下来的证据已经放入背包。雨水漫过桌面，蓝色铁盒的盖子仍然紧闭着。';
      }
    } else if (cinematic) {
      if (clues.contains('truth')) {
        sceneText = '天色正在发白。你可以带着旧信去找到长河，也可以写下自己的回信。手里的证据与记忆，会陪你完成最后的选择。';
      } else if (clues.contains('address')) {
        sceneText = '黄铜钥匙已经放入背包。信封的新邮戳和桌上的旧合照，也许藏着值得带进档案室的线索。';
      }
    }
    final visibleActions = items('actions')
        .where((a) => (a['remaining_uses'] ?? 1) > 0)
        .toList();
    final lobby = room['status'] == 'lobby';
    final active = room['status'] == 'active';
    final ended = room['ending'] != null;
    final background =
        location?['image_uri'] ??
        (v['story_title'] == '雨夜最后一封信'
            ? 'assets/stories/last_letter/${self?['location'] == 'archive' ? 'archive' : 'office'}.png'
            : null);
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
                    : AnimatedOpacity(
                        opacity: cinematic
                            ? ((room['round'] ?? 1) >= 3 ? .65 : 1)
                            : 1,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 900),
                        child: Image.asset(
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
                            tooltip: '我的目标',
                            icon: const Icon(Icons.flag_outlined),
                            onPressed: () => unawaited(
                              showNovelMessage(
                                context,
                                NovelMessage(
                                  title: '我的身份与目标',
                                  text:
                                      '${self?['faction'] == null ? "" : "所属阵营：${self?['faction']}\n\n"}${(self?['goals'] as List? ?? []).join("\n\n")}\n\n${(self?['objectives'] as List? ?? []).map((o) => "${o['label']} · ${o['result'] == 'achieved'
                                          ? '已达成'
                                          : o['result'] == 'failed'
                                          ? '未达成'
                                          : '进行中'}").join("\n")}',
                                ),
                              ),
                            ),
                          ),
                          for (final panel in GamePanel.values)
                            IconButton(
                              onPressed: () => unawaited(openPanel(panel)),
                              tooltip: panel.title,
                              icon: Badge(
                                label: Text(
                                  '${panel == GamePanel.clues
                                      ? items('knowledge').length
                                      : panel == GamePanel.inventory
                                      ? items('inventory').length
                                      : (v['action_history'] as List? ?? items('own_results')).length}',
                                ),
                                isLabelVisible: panel == GamePanel.clues
                                    ? items('knowledge').isNotEmpty
                                    : panel == GamePanel.inventory
                                    ? items('inventory').isNotEmpty
                                    : false,
                                child: Icon(panel.icon, size: narrow ? 20 : 22),
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
                                      : cinematic
                                      ? chapter
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
                                          '  ${self?['ap_remaining'] ?? 0} ${cinematic ? '余力' : '行动点'}',
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
                                              ? '以你的角色视角探索场景、询问人物、查证线索。\n准备好之后，独自走进这个故事。'
                                              : '选择你的角色。每个人的视角，都可能改变故事的方向。'
                                        : ended
                                        ? room['ending']['summary']
                                        : sceneText,
                                    style: TextStyle(
                                      fontSize: narrow ? 15 : 18,
                                      height: 1.9,
                                      color: const Color(0xffebe6d8),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  if (active && items('npcs').isNotEmpty)
                                    Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        for (final npc in items('npcs'))
                                          ActionChip(
                                            avatar: npc['image_uri'] == null
                                                ? const Icon(
                                                    Icons.person_outline,
                                                  )
                                                : ClipOval(
                                                    child: Image.asset(
                                                      npc['image_uri'],
                                                      width: 30,
                                                      height: 30,
                                                      fit: BoxFit.cover,
                                                    ),
                                                  ),
                                            label: Text('与${npc['label']}交谈'),
                                            onPressed: () => enqueue(
                                              NovelMessage(
                                                title: npc['label'],
                                                text: npc['description'] ?? '',
                                                illustration: npc['image_uri'],
                                                choices: visibleActions
                                                    .where(
                                                      (a) =>
                                                          a['target'] ==
                                                              npc['id'] &&
                                                          a['allowed_now'] ==
                                                              true,
                                                    )
                                                    .map(
                                                      (a) =>
                                                          Map<
                                                            String,
                                                            dynamic
                                                          >.from(a),
                                                    )
                                                    .toList(),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
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
                                        for (final i
                                            in (_showAllActions
                                                ? items('interactions')
                                                : items('interactions')
                                                      .take(3)))
                                          NovelChoice(
                                            label: i['label'],
                                            cost: i['cost'],
                                            enabled: !blocked,
                                            onTap: () => unawaited(interact(i)),
                                          ),
                                        for (final a
                                            in (_showAllActions
                                                ? visibleActions
                                                : visibleActions.take(
                                                    (3 -
                                                            items(
                                                              'interactions',
                                                            ).length)
                                                        .clamp(0, 3),
                                                  )))
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
                                    if (visibleActions.length +
                                            items('interactions').length >
                                        3)
                                      TextButton(
                                        onPressed: () => setState(
                                          () => _showAllActions =
                                              !_showAllActions,
                                        ),
                                        child: Text(
                                          _showAllActions ? '收起其他行动' : '查看其他行动',
                                        ),
                                      ),
                                    const SizedBox(height: 14),
                                    Wrap(
                                      alignment: WrapAlignment.spaceBetween,
                                      spacing: 16,
                                      runSpacing: 8,
                                      children: [
                                        if (!cinematic)
                                          TextButton.icon(
                                            onPressed:
                                                client.busy ||
                                                    client.pending != null ||
                                                    items('narrative_cues').any(
                                                      (c) =>
                                                          c['blocking'] ==
                                                              true &&
                                                          !(v['acknowledged_cues']
                                                                      as List? ??
                                                                  [])
                                                              .contains(
                                                                c['id'],
                                                              ),
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
                                            onPressed: () => unawaited(
                                              openPanel(GamePanel.clues),
                                            ),
                                            icon: const Icon(
                                              Icons.mail_outline,
                                              size: 16,
                                            ),
                                            label: Text(
                                              '${items('knowledge').length} 条线索 · 打开线索册',
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
