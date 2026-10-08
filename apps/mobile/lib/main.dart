import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/room_client.dart';
import 'ui/media_sheet.dart';

const amber = Color(0xfff3ad47);
const surface = Color(0xff1b2125);
const muted = Color(0xffb0b7bd);
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RuxiApp());
}

class RuxiApp extends StatelessWidget {
  const RuxiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '入戏 · 末班车',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff101416),
      colorScheme: ColorScheme.fromSeed(
        seedColor: amber,
        brightness: Brightness.dark,
        surface: surface,
        primary: amber,
      ),
      fontFamily: 'PingFang SC',
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 38,
          fontWeight: FontWeight.w500,
          letterSpacing: -1.5,
        ),
        headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(fontSize: 16, height: 1.7),
        bodyMedium: TextStyle(fontSize: 14, height: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          foregroundColor: const Color(0xff101416),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    ),
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key, this.autoInitialize = true, this.client});
  final bool autoInitialize;
  final RoomClient? client;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late final client = widget.client ?? RoomClient();
  String? selectedStoryId;
  final code = TextEditingController(), chat = TextEditingController();
  int tab = 0;
  Timer? ticker;
  @override
  void initState() {
    super.initState();
    client.addListener(changed);
    if (widget.autoInitialize) client.initialize();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ticker?.cancel();
    client.removeListener(changed);
    client.dispose();
    code.dispose();
    chat.dispose();
    super.dispose();
  }

  Json get v => client.view!;
  Json get room => v['room'];
  String get self => client.memberId!;
  bool get active =>
      room['lifecycle'] == 'running' &&
      room['phase_code'] == 'exploration' &&
      room['exploration_step'] == 'active';
  bool get host => room['host_membership_id'] == self;
  String timeLeft() {
    final d = room['deadline_at'];
    var ms = room['remaining_ms'] ?? 0;
    if (d != null) {
      ms = DateTime.parse(d)
          .difference(DateTime.now().toUtc().add(client.clockOffset))
          .inMilliseconds;
    }
    final seconds = (ms / 1000).ceil().clamp(0, 99999);
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<bool> confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Widget pill(String text, {Color color = muted}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 12)),
  );
  Widget card(Widget child, {EdgeInsets padding = const EdgeInsets.all(20)}) =>
      Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xff343c42)),
        ),
        child: child,
      );
  Widget heading(String eyebrow, String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        eyebrow,
        style: const TextStyle(color: amber, fontSize: 12, letterSpacing: 3),
      ),
      const SizedBox(height: 12),
      Text(title, style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 12),
      Text(subtitle, style: const TextStyle(color: muted, height: 1.8)),
      const SizedBox(height: 28),
    ],
  );
  Widget action(
    String label,
    VoidCallback work, {
    bool enabled = true,
    bool primary = false,
    IconData? icon,
  }) => primary
      ? FilledButton(
          onPressed: client.canAct && enabled ? work : null,
          child: Text(label),
        )
      : OutlinedButton(
          onPressed: client.canAct && enabled ? work : null,
          child: icon == null
              ? Text(label)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    Text(label),
                  ],
                ),
        );
  @override
  Widget build(BuildContext context) {
    final inRoom = client.roomId != null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xff101416),
        toolbarHeight: 76,
        title: Row(
          children: [
            const Text(
              '入戏',
              style: TextStyle(
                fontSize: 24,
                letterSpacing: 6,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 18),
            pill('多人互动剧'),
          ],
        ),
        actions: [
          if (inRoom)
            TextButton(
              onPressed: () => client.backToCatalog(),
              child: const Text('回到剧目'),
            ),
          IconButton(
            tooltip: '身份与恢复码',
            onPressed: account,
            icon: const Icon(Icons.person_outline),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (client.status.isNotEmpty)
              Container(
                width: double.infinity,
                color: amber.withValues(alpha: .08),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        client.status,
                        style: const TextStyle(color: amber),
                        semanticsLabel: client.status,
                      ),
                    ),
                    if (client.pending.isNotEmpty)
                      TextButton(
                        onPressed: client.confirmPending,
                        child: const Text('确认结果'),
                      ),
                    if (client.connection == 'control_replaced')
                      TextButton(
                        onPressed: client.busy ? null : client.takeControl,
                        child: const Text('在此设备继续'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: !inRoom
                        ? discover()
                        : client.view == null
                        ? connecting()
                        : room['lifecycle'] == 'lobby'
                        ? lobby()
                        : play(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget discover() {
    final selected = client.stories.isEmpty
        ? null
        : client.stories.firstWhere(
            (story) => story['story_id'] == selectedStoryId,
            orElse: () => client.stories.first,
          );
    final isDemo =
        selected == null ||
        (selected['story_id'] == '11111111-1111-4111-8111-111111111111' &&
            selected['title'] == '末班车的第七位乘客');
    final seats = selected?['seat_count'] ?? 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(
          'PRIVATE SCREENING / 01',
          '每个人，都有一段秘密。',
          '和${{2: '一', 3: '两', 4: '三'}[seats] ?? seats - 1}位朋友一起进入故事。调查、交换线索，然后共同决定结局。',
        ),
        if (client.stories.length > 1) ...[
          DropdownButtonFormField<String>(
            initialValue: selected['story_id'],
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '选择剧目',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final story in client.stories)
                DropdownMenuItem(
                  value: story['story_id'],
                  child: Text(
                    story['title'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: client.busy
                ? null
                : (id) => setState(() => selectedStoryId = id),
          ),
          const SizedBox(height: 24),
        ],
        LayoutBuilder(
          builder: (c, b) {
            final wide = b.maxWidth > 760;
            final cover = scene(
              title: isDemo ? '末班车的\n第七位乘客' : selected['title'],
              caption: isDemo ? '原创悬疑 · 三人协作 · 10–15 分钟' : '$seats 人协作 · 私人房间',
              height: wide ? 460 : 360,
            );
            final detail = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                pill(isDemo ? '首部免费样片' : '互动故事', color: amber),
                const SizedBox(height: 24),
                Text(
                  isDemo ? '23:17，最后一班车。' : selected['title'],
                  style: const TextStyle(fontSize: 24),
                ),
                const SizedBox(height: 16),
                Text(
                  selected?['summary'] ?? '车厢里只有六个名字。\n一段来自未来的留言，\n却指向了第七位乘客。',
                  style: const TextStyle(
                    fontSize: 18,
                    height: 1.9,
                    color: muted,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  isDemo ? '三名角色 · 三条结局 · 私人房间' : '$seats 名角色 · 私人房间',
                  style: const TextStyle(color: muted),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: client.busy || client.stories.isEmpty
                        ? null
                        : () => client.create(selected['story_id']),
                    child: Text(client.busy ? '正在进入…' : '创建房间'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: code,
                  maxLength: 8,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: '八位邀请码',
                    hintText: '例如 7KQ8HM2N',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  onSubmitted: (_) => client.join(code.text),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: client.busy
                        ? null
                        : () => client.join(code.text),
                    child: const Text('加入朋友的房间'),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '原创互动故事 · 支持授权视频与图文摘要。',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            );
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 6, child: cover),
                      const SizedBox(width: 48),
                      Expanded(flex: 4, child: detail),
                    ],
                  )
                : Column(children: [cover, const SizedBox(height: 28), detail]);
          },
        ),
        const SizedBox(height: 36),
        if (client.rooms.isNotEmpty) ...[
          const Text('继续你的故事', style: TextStyle(fontSize: 20)),
          const SizedBox(height: 16),
          ...client.rooms.map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: card(
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(r['title']),
                  subtitle: Text(lifecycle(r['lifecycle'])),
                  trailing: const Icon(Icons.arrow_forward),
                  onTap: () => client.run(() => client.enter(r['room_id'])),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        const Text('不是旁观者。你的发现，会改变这一次的故事。', style: TextStyle(color: muted)),
      ],
    );
  }

  Widget connecting() => card(
    Column(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        Text(connectionName()),
        const SizedBox(height: 16),
        if (client.connection == 'control_replaced')
          FilledButton(
            onPressed: client.takeControl,
            child: const Text('确认由此设备接管'),
          ),
      ],
    ),
  );
  String connectionName() =>
      const {
        'live': '已连接',
        'connecting': '连接中',
        'joining': '加入房间',
        'syncing': '同步中',
        'reconnecting': '重新连接中',
        'control_replaced': '设备控制权已变化',
        'auth_expired': '需要恢复身份',
        'disconnected': '已断开',
      }[client.connection] ??
      client.connection;
  Widget lobby() {
    final room = v['room'];
    final members = v['members'] as List;
    final selected = v['self']['role_code'];
    final swap = v['collaboration']['role_swap'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('THE CAST / 房间大厅', '故事，在你们到齐后开始。', '选择自己的角色。全员在线并准备后，由房主开场。'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            pill(
              connectionName(),
              color: client.connection == 'live'
                  ? const Color(0xff87ba98)
                  : amber,
            ),
            pill('${members.length} / ${room['seat_count'] ?? 3} 位成员'),
            if (client.invite != null)
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: client.invite!));
                  message('邀请码已复制');
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text(
                  client.invite!,
                  style: const TextStyle(letterSpacing: 3),
                ),
              ),
          ],
        ),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (c, b) {
            final choices =
                (room['role_catalog'] as List?)?.map(
                  (r) => RoleChoice(
                    r['role_code'],
                    r['title'],
                    r['description'],
                    RoomRole.values
                            .where((known) => known.code == r['role_code'])
                            .firstOrNull
                            ?.icon ??
                        Icons.person_outline,
                  ),
                ) ??
                RoomRole.values.map(
                  (r) => RoleChoice(r.code, r.title, r.desc, r.icon),
                );
            final roles = choices.map((r) {
              final occupied = members
                  .where((m) => m['role_code'] == r.code)
                  .firstOrNull;
              final mine = selected == r.code;
              return Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: mine ? amber.withValues(alpha: .07) : surface,
                  border: Border.all(
                    color: mine ? amber : const Color(0xff343c42),
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(r.icon, color: mine ? amber : muted, size: 30),
                    const SizedBox(height: 32),
                    Text(r.title, style: const TextStyle(fontSize: 24)),
                    const SizedBox(height: 12),
                    Text(
                      r.desc,
                      style: const TextStyle(color: muted, height: 1.8),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      occupied == null
                          ? '尚未选择'
                          : mine
                          ? '你的角色'
                          : '${occupied['display_name']} · 已选择',
                      style: TextStyle(color: mine ? amber : muted),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: action(
                        mine
                            ? '已选择'
                            : occupied == null
                            ? '选择角色'
                            : '请求换角',
                        () => occupied == null
                            ? client.command('select_role', {
                                'role_code': r.code,
                              })
                            : client.command('request_role_swap', {
                                'to_member': occupied['membership_id'],
                              }),
                        enabled:
                            !mine && (occupied == null || selected != null),
                        primary: mine,
                      ),
                    ),
                  ],
                ),
              );
            }).toList();
            return b.maxWidth > 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < roles.length; i++) ...[
                        if (i > 0) const SizedBox(width: 16),
                        Expanded(child: roles[i]),
                      ],
                    ],
                  )
                : Column(
                    children: roles
                        .map(
                          (r) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: r,
                          ),
                        )
                        .toList(),
                  );
          },
        ),
        const SizedBox(height: 24),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('当前成员', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 12),
              ...members.map(
                (m) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    m['online'] ? Icons.circle : Icons.circle_outlined,
                    size: 12,
                    color: m['online'] ? const Color(0xff87ba98) : muted,
                  ),
                  title: Text(
                    '${m['display_name']}${m['membership_id'] == self ? ' · 你' : ''}${m['membership_id'] == room['host_membership_id'] ? ' · 房主' : ''}',
                  ),
                  trailing: Text(
                    m['ready'] ? '已准备' : '未准备',
                    style: TextStyle(color: m['ready'] ? amber : muted),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (swap != null && swap['status'] == 'pending') ...[
          const SizedBox(height: 16),
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('角色交换请求 · 30 秒内确认'),
                const Text('成功交换后，双方都需要重新准备。', style: TextStyle(color: muted)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  children: [
                    if (swap['to_member'] == self) ...[
                      action(
                        '接受交换',
                        () => client.command('accept_role_swap', {
                          'role_swap_id': swap['id'],
                        }),
                        primary: true,
                      ),
                      action(
                        '拒绝',
                        () => client.command('reject_role_swap', {
                          'role_swap_id': swap['id'],
                        }),
                      ),
                    ],
                    if (swap['from_member'] == self)
                      action(
                        '取消请求',
                        () => client.command('cancel_role_swap', {
                          'role_swap_id': swap['id'],
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            action(
              members.firstWhere((m) => m['membership_id'] == self)['ready']
                  ? '取消准备'
                  : '准备好了',
              () => client.command('ready', {
                'ready': !members.firstWhere(
                  (m) => m['membership_id'] == self,
                )['ready'],
              }),
              enabled: selected != null,
              primary: true,
            ),
            if (host)
              action(
                '开始故事',
                () => client.command('start'),
                enabled:
                    members.length == 3 &&
                    members.every((m) => m['ready'] && m['online']),
              ),
          ],
        ),
        const SizedBox(height: 18),
        const Text('房主拥有组局权限。每个人的角色秘密始终只属于自己。', style: TextStyle(color: muted)),
      ],
    );
  }

  Widget play() {
    final phase = room['phase_code'];
    final ended = phase == 'ending';
    final paused = ['paused', 'suspended'].contains(room['lifecycle']);
    final title = ended
        ? const {'E1': '真相', 'E2': '错过', 'E3': '余音'}[room['ending_code']]!
        : phase == 'decision'
        ? '车门，即将关闭。'
        : phase == 'briefing'
        ? '先了解你的角色。'
        : room['exploration_step'] == 'interlude'
        ? '最后一声警报。'
        : '六个名字。第七处痕迹。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${v['own_role']?['title'] ?? ''}视角',
                style: const TextStyle(color: amber, letterSpacing: 2),
              ),
            ),
            pill(connectionName()),
            const SizedBox(width: 8),
            pill(lifecycle(room['lifecycle']), color: amber),
          ],
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (c, b) {
            final stage = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                scene(
                  title: title,
                  caption: ended
                      ? '结局 ${room['ending_code']} · 属于你们的这一局'
                      : phase == 'decision'
                      ? '共同决策 · 剩余 ${timeLeft()}'
                      : active
                      ? '探索 · 剩余 ${timeLeft()}'
                      : '共同观看 · 原创动效样片',
                  height: b.maxWidth > 760 ? 430 : 300,
                ),
                const SizedBox(height: 16),
                card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v['public_scene']['description'],
                        style: const TextStyle(height: 1.8),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: (v['members'] as List)
                            .map(
                              (m) => pill(
                                '${m['display_name']} · ${m['online'] ? '在线' : '离线'}',
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
                if (paused) ...[
                  const SizedBox(height: 16),
                  card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          room['lifecycle'] == 'paused'
                              ? '故事已暂停'
                              : '故事已保存，等待原班组归来',
                          style: const TextStyle(fontSize: 20),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '剩余 ${timeLeft()}。所有成员在线并确认后继续。',
                          style: const TextStyle(color: muted),
                        ),
                        const SizedBox(height: 16),
                        action(
                          '确认继续',
                          () => client.command('resume', {
                            'timer_generation': room['timer_generation'],
                          }),
                          primary: true,
                        ),
                      ],
                    ),
                  ),
                ],
                ...mediaPanel(),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (active)
                      action(
                        '确认结束探索',
                        () => client.command('confirm_exploration_end'),
                      ),
                    if (host &&
                        (active || phase == 'decision') &&
                        !paused &&
                        !v['collaboration']['manual_pause_used'])
                      action('请求暂停', () => client.command('request_pause')),
                    if (!ended)
                      action('离开房间', () async {
                        if (await confirm('暂时离开？', '已开局的故事会挂起，只有原班组可以恢复。')) {
                          await client.command('leave_room');
                          await client.backToCatalog();
                        }
                      }),
                  ],
                ),
                if (v['collaboration']['pause_request'] != null) ...[
                  const SizedBox(height: 16),
                  card(
                    Column(
                      children: [
                        const Text('房主请求暂停，等待全员确认'),
                        const SizedBox(height: 12),
                        action(
                          '同意暂停',
                          () => client.command('confirm_pause', {
                            'pause_request_id':
                                v['collaboration']['pause_request']['id'],
                          }),
                          primary: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            );
            final panel = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (phase == 'decision') decision(),
                if (ended) ...[
                  card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('这一局的公开记录', style: TextStyle(fontSize: 20)),
                        const SizedBox(height: 16),
                        ...((v['public_scene']['timeline'] as List?) ?? []).map(
                          (e) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.history, size: 20),
                            title: Text(e['label']),
                            subtitle: Text(
                              DateTime.parse(e['occurred_at'])
                                  .toLocal()
                                  .toString()
                                  .substring(0, 19),
                            ),
                          ),
                        ),
                        ...(v['public_scene']['shared_clues'] as List).map(
                          (c) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(c['title']),
                            subtitle: Text(c['text']),
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          '复盘保留共享线索与自己的经历。他人未公开的秘密不会自动揭晓。',
                          style: TextStyle(color: muted),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: room['story_id'] == null
                              ? null
                              : () => client.create(room['story_id']),
                          child: const Text('再开一局'),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('场景')),
                      ButtonSegment(value: 1, label: Text('线索')),
                      ButtonSegment(value: 2, label: Text('讨论')),
                    ],
                    selected: {tab},
                    onSelectionChanged: (s) => setState(() => tab = s.first),
                  ),
                  const SizedBox(height: 18),
                  if (tab == 0) actionsPanel(),
                  if (tab == 1) cluesPanel(),
                  if (tab == 2) chatPanel(),
                ],
              ],
            );
            return b.maxWidth > 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 6, child: stage),
                      const SizedBox(width: 24),
                      Expanded(flex: 4, child: panel),
                    ],
                  )
                : Column(children: [stage, const SizedBox(height: 28), panel]);
          },
        ),
      ],
    );
  }

  List<Widget> mediaPanel() {
    final list = v['media']['authorized'] as List;
    return list.map((m) {
      final ack = (v['collaboration']['media_acks'] as List)
          .where((a) => a['media_id'] == m['media_id'])
          .firstOrNull;
      final done = ack != null && (ack['members'] as List).contains(self);
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m['kind'] == 'own_role'
                    ? '仅你可见 · 角色片段'
                    : '公共片段 · ${m['media_id'] == 'opening'
                          ? '开场'
                          : m['media_id'] == 'interlude'
                          ? '中场'
                          : '结局'}',
                style: const TextStyle(color: amber),
              ),
              const SizedBox(height: 12),
              const Text(
                '观看原创动效样片，也可阅读同视角授权摘要。',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  action(
                    '观看片段',
                    () => watchMedia(Map<String, dynamic>.from(m)),
                  ),
                  action('阅读摘要', () => readMedia(Map<String, dynamic>.from(m))),
                  action(
                    done ? '已确认' : '确认已了解',
                    () => client.command('media_complete', {
                      'media_id': m['media_id'],
                      'media_epoch': m['media_epoch'],
                      'mode': 'summary',
                    }),
                    enabled: !done && room['lifecycle'] == 'running',
                    primary: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  Future<void> watchMedia(Json media) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => AuthorizedMediaSheet(client: client, media: media),
    );
  }

  Future<void> readMedia(Json m) async {
    try {
      final a = await client.mediaAccess(m);
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('授权剧情摘要', style: TextStyle(fontSize: 24)),
              const SizedBox(height: 24),
              Text(
                a['summary'],
                style: const TextStyle(fontSize: 18, height: 1.9),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('返回故事'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      message(RoomClient.explain(e));
    }
  }

  Widget actionsPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('你可以做什么', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            Text(
              v['own_role']?['description'] ?? '',
              style: const TextStyle(color: muted),
            ),
            const SizedBox(height: 20),
            ...(v['available_actions'] as List).map(
              (a) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: action(
                    a['label'],
                    () => client.command('investigate', {
                      'action_id': a['action_id'],
                    }),
                    enabled: a['enabled'],
                    primary: true,
                  ),
                ),
              ),
            ),
            if ((v['available_actions'] as List).isEmpty)
              const Text('本阶段请观看片段或参与共同决策。', style: TextStyle(color: muted)),
            if (active || room['phase_code'] == 'decision') ...[
              const SizedBox(height: 12),
              action(
                '请求提示 · 剩余 ${v['hints']['remaining']}',
                () => client.command('request_hint', {'hint_level': 1}),
                enabled:
                    v['hints']['remaining'] > 0 &&
                    v['hints']['pending_job_id'] == null,
              ),
            ],
            if (v['hints']['pending_job_id'] != null)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('主持人正在整理你已知的信息…'),
              ),
            ...(v['hints']['entries'] as List).map(
              (h) => Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  h['text'],
                  style: const TextStyle(color: amber, height: 1.8),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      offersPanel(),
    ],
  );
  Widget cluesPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('我的线索', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 12),
      if ((v['own_clues'] as List).isEmpty)
        card(const Text('先调查你的场景。私人发现不会自动共享。', style: TextStyle(color: muted))),
      ...(v['own_clues'] as List).map(
        (c) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                pill(c['shared'] ? '全员可见' : '仅你可见', color: amber),
                const SizedBox(height: 12),
                Text(c['title'], style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 10),
                Text(
                  c['text'],
                  style: const TextStyle(color: muted, height: 1.8),
                ),
                if (!c['shared'] && c['clue_id'] != 'C2') ...[
                  const SizedBox(height: 16),
                  action('公开给所有成员', () async {
                    if (await confirm('公开这条线索？', '所有成员都能看到内容，公开后无法撤回。')) {
                      client.command('share_clue', {'clue_id': c['clue_id']});
                    }
                  }, enabled: active),
                ],
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
      const Text('共享线索', style: TextStyle(fontSize: 20)),
      const SizedBox(height: 12),
      if ((v['public_scene']['shared_clues'] as List).isEmpty)
        card(const Text('暂无共享线索', style: TextStyle(color: muted))),
      ...(v['public_scene']['shared_clues'] as List).map(
        (c) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c['title'], style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                Text(c['text'], style: const TextStyle(color: muted)),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      ...(v['visible_items'] as List)
          .where((i) => i['owner_membership_id'] == self)
          .map(
            (i) => card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('我的道具', style: TextStyle(color: amber)),
                  const SizedBox(height: 12),
                  Text(i['title'], style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  ...(v['members'] as List)
                      .where((m) => m['membership_id'] != self && m['online'])
                      .map(
                        (m) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: action('交给 ${m['display_name']}', () async {
                            if (await confirm(
                              '发起道具交付？',
                              '对方接受后才会转移所有权。30 秒未接受则失效。',
                            )) {
                              client.command('offer_item', {
                                'item_id': i['item_id'],
                                'to_member': m['membership_id'],
                              }, i['version']);
                            }
                          }, enabled: active),
                        ),
                      ),
                ],
              ),
            ),
          ),
      const SizedBox(height: 16),
      offersPanel(),
    ],
  );
  Widget offersPanel() => Column(
    children: (v['offers'] as List)
        .map(
          (o) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '道具交付 · ${const {'pending': '等待接受', 'accepted': '已接受', 'cancelled': '已取消', 'expired': '已过期', 'rejected': '已拒绝'}[o['status']]}',
                  ),
                  const SizedBox(height: 10),
                  if (o['status'] == 'pending')
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (o['to_member'] == self) ...[
                          action(
                            '接受',
                            () => client.command('accept_offer', {
                              'offer_id': o['offer_id'],
                            }),
                            enabled: active,
                            primary: true,
                          ),
                          action(
                            '拒绝',
                            () => client.command('reject_offer', {
                              'offer_id': o['offer_id'],
                            }),
                            enabled: active,
                          ),
                        ],
                        if (o['from_member'] == self)
                          action(
                            '取消交付',
                            () => client.command('cancel_offer', {
                              'offer_id': o['offer_id'],
                            }),
                            enabled: active,
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        )
        .toList(),
  );
  Widget decision() {
    final round = v['vote_round'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('在离开之前，你想怎么做？', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            const Text(
              '每人一票，截止前可修改。只显示你自己的选择。',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 20),
            ...(round['display_options'] as List).map((o) {
              final selected = v['own_vote']?['option_id'] == o['option_id'];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  width: double.infinity,
                  child: action(
                    '${selected ? '✓ ' : ''}${o['label']}${o['eligible'] ? '' : ' · ${o['reason_text']}'}',
                    () => client.command('vote', {
                      'round_id': round['round_id'],
                      'option_id': o['option_id'],
                    }),
                    enabled: o['eligible'] && room['lifecycle'] == 'running',
                    primary: selected,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget chatPanel() => card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('房间讨论', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 8),
        const Text(
          '消息会发给全员。请留意是否包含你的私人线索。',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          children: (v['members'] as List)
              .where((m) => client.blockedMembers.contains(m['membership_id']))
              .map(
                (m) => ActionChip(
                  label: Text('取消屏蔽 ${m['display_name']}'),
                  onPressed: () => client.toggleBlock(m['membership_id']),
                ),
              )
              .toList(),
        ),
        ...(v['chat'] as List)
            .where((m) => !client.blockedMembers.contains(m['sender_member']))
            .map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m['sender_member'] == self
                          ? '你'
                          : (v['members'] as List).firstWhere(
                              (a) => a['membership_id'] == m['sender_member'],
                            )['display_name'],
                      style: const TextStyle(color: amber, fontSize: 12),
                    ),
                    Text(m['text']),
                    if (m['sender_member'] != self)
                      PopupMenuButton<String>(
                        tooltip: '消息操作',
                        icon: const Icon(Icons.more_horiz, size: 20),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'block',
                            child: Text('屏蔽此成员的消息'),
                          ),
                          PopupMenuItem(value: 'report', child: Text('举报此消息')),
                        ],
                        onSelected: (value) async {
                          if (value == 'block') {
                            client.toggleBlock(m['sender_member']);
                          } else {
                            final reason = await showDialog<String>(
                              context: context,
                              builder: (c) => SimpleDialog(
                                title: const Text('举报将提交这条消息供审核'),
                                children: [
                                  for (final option in {
                                    'harassment': '辱骂或骚扰',
                                    'privacy': '泄露隐私',
                                    'spam': '垃圾信息',
                                    'other': '其他问题',
                                  }.entries)
                                    SimpleDialogOption(
                                      onPressed: () =>
                                          Navigator.pop(c, option.key),
                                      child: Text(option.value),
                                    ),
                                ],
                              ),
                            );
                            if (reason != null) {
                              await client.reportMessage(
                                m['message_id'],
                                reason,
                              );
                            }
                          }
                        },
                      ),
                  ],
                ),
              ),
            ),
        TextField(
          controller: chat,
          maxLength: 500,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '发送给全员',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        action('发送消息', () async {
          await client.command('chat_send', {'text': chat.text});
          if (client.pending.isEmpty && client.status == '已同步') chat.clear();
        }, primary: true),
      ],
    ),
  );
  Future<void> account() async {
    final restore = TextEditingController();
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('保存你的身份'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('保存恢复码，换机或凭证失效后可找回原来的角色与房间。恢复成功后会撤销旧设备会话，并轮换恢复码。'),
                const SizedBox(height: 16),
                SelectableText(
                  client.recoveryCode.isEmpty
                      ? '当前没有保存的恢复码'
                      : client.recoveryCode,
                  style: const TextStyle(fontSize: 13, color: amber),
                ),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: client.recoveryCode));
                    message('恢复码已复制，请安全保存');
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制恢复码'),
                ),
                const Divider(),
                TextField(
                  controller: restore,
                  decoration: const InputDecoration(
                    labelText: '使用已有恢复码',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    Navigator.pop(c);
                    await client.recover(restore.text);
                  },
                  child: const Text('恢复原身份'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '丢失恢复码且本地凭证失效后，无法仅凭设备找回身份。',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: client.busy
                ? null
                : () async {
                    Navigator.pop(c);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('注销当前身份？'),
                        content: const Text(
                          '恢复码和所有设备凭证将失效，聊天、提示及本机缓存会清除。进行中的房间将终止，原席位不能补人；已完成的共同结局保留去标识记录。此操作无法撤销。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('保留身份'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('确认注销'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) await client.eraseAccount();
                  },
            child: const Text('注销当前身份'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    restore.dispose();
  }

  Widget scene({
    required String title,
    required String caption,
    required double height,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        children: [
          const Positioned.fill(child: CustomPaint(painter: TrainPainter())),
          Positioned(
            top: 24,
            left: 24,
            child: Text(
              '末 班 车  /  2 3 : 1 7',
              style: TextStyle(
                color: Colors.white.withValues(alpha: .55),
                fontSize: 11,
                letterSpacing: 3,
              ),
            ),
          ),
          Positioned(
            left: 28,
            right: 24,
            bottom: 32,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Songti SC',
                    fontSize: height > 350 ? 40 : 30,
                    color: const Color(0xfff4f5f6),
                    height: 1.3,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  caption,
                  style: const TextStyle(
                    color: Color(0xffc4cccf),
                    fontSize: 12,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  String lifecycle(String s) =>
      const {
        'lobby': '等待开场',
        'running': '故事进行中',
        'paused': '已暂停',
        'suspended': '已保存',
        'finished': '已完成',
        'abandoned': '未完成',
      }[s] ??
      s;
}

enum RoomRole {
  investigator('investigator', '调查员', '记录里的异常，由你来追问。', Icons.fingerprint),
  passenger(
    'passenger',
    '乘客',
    '一段留言，与你的旅程有关。',
    Icons.confirmation_number_outlined,
  ),
  conductor('conductor', '乘务员', '车门关上前，查明设备的秘密。', Icons.train_outlined);

  const RoomRole(this.code, this.title, this.desc, this.icon);
  final String code, title, desc;
  final IconData icon;
}

class RoleChoice {
  const RoleChoice(this.code, this.title, this.desc, this.icon);
  final String code, title, desc;
  final IconData icon;
}

class TrainPainter extends CustomPainter {
  const TrainPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xff40595c), Color(0xff16272d), Color(0xff0d171e)],
        ).createShader(rect),
    );
    final van = Offset(size.width * .68, size.height * .37);
    final p = Paint()
      ..color = const Color(0xffb7c5bb).withValues(alpha: .18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 7; i++) {
      final x = size.width * (i / 6);
      canvas.drawLine(van, Offset(x, size.height), p);
    }
    for (var i = 0; i < 6; i++) {
      final t = i / 6;
      final y = van.dy + (size.height - van.dy) * t * t;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    for (var i = 0; i < 4; i++) {
      final factor = 1 - i * .19;
      final r = Rect.fromCenter(
        center: van,
        width: size.width * .72 * factor,
        height: size.height * .8 * factor,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(14)),
        Paint()
          ..color = const Color(0xffb9cdcb).withValues(alpha: .09)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    canvas.drawCircle(
      Offset(size.width * .77, size.height * .1),
      70,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                amber.withValues(alpha: .16),
                amber.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width * .77, size.height * .1),
                radius: 70,
              ),
            ),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xdd0b1116)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(TrainPainter oldDelegate) => false;
}
