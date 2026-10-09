import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/room_client.dart';

const _gold = Color(0xffd8b678);
const _ink = Color(0xff1a2823);
const _muted = Color(0xffb0b7bd);
const categories = {
  'mystery': '悬疑推理',
  'emotion': '情感沉浸',
  'scifi': '科幻想象',
  'adventure': '冒险探索',
};
const difficulties = {
  'beginner': '新手友好',
  'intermediate': '进阶挑战',
  'advanced': '深度推理',
};

class Portal extends StatefulWidget {
  const Portal({
    super.key,
    required this.client,
    required this.section,
    required this.onSection,
    required this.onRecovery,
    this.storyId,
    this.onStory,
    this.query,
    this.onFilter,
  });
  final RoomClient client;
  final int section;
  final ValueChanged<int> onSection;
  final VoidCallback onRecovery;
  final String? storyId;
  final ValueChanged<String>? onStory;
  final Map<String, String>? query;
  final ValueChanged<Map<String, String>>? onFilter;
  @override
  State<Portal> createState() => _PortalState();
}

class _PortalState extends State<Portal> {
  RoomClient get client => widget.client;
  final search = TextEditingController();
  String category = '', seats = '', sort = 'latest';
  List<dynamic>? results;
  String? next;
  int total = 0, requestGeneration = 0;
  bool searching = false;
  String? error;
  @override
  void initState() {
    super.initState();
    restoreFilters();
  }

  @override
  void didUpdateWidget(Portal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(oldWidget.query, widget.query)) restoreFilters();
  }

  void restoreFilters() {
    final q = widget.query;
    if (q == null) return;
    search.text = (q['q'] ?? '').characters.take(80).toString();
    category = categories.containsKey(q['category']) ? q['category']! : '';
    seats = ['1', '2', '3', '4'].contains(q['seats']) ? q['seats']! : '';
    sort = q['sort'] == 'title' ? 'title' : 'latest';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) filter(updateUrl: false);
    });
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> filter({bool more = false, bool updateUrl = true}) async {
    if (!more && updateUrl) {
      widget.onFilter?.call({
        if (search.text.trim().isNotEmpty) 'q': search.text.trim(),
        if (category.isNotEmpty) 'category': category,
        if (seats.isNotEmpty) 'seats': seats,
        if (sort != 'latest') 'sort': sort,
      });
    }
    final generation = ++requestGeneration;
    setState(() {
      searching = true;
      error = null;
    });
    try {
      final query = Uri(
        queryParameters: {
          'q': search.text.trim(),
          'category': category,
          'seats': seats,
          'sort': sort,
          if (more && (next ?? client.storiesNext) != null)
            'offset': (next ?? client.storiesNext)!,
        },
      ).query;
      final data = await client.request('GET', '/api/v2/stories?$query');
      if (!mounted || generation != requestGeneration) return;
      setState(() {
        results = [if (more) ...(results ?? client.stories), ...data['items']];
        next = data['next_cursor'];
        total = data['total'];
      });
    } catch (e) {
      if (mounted && generation == requestGeneration) {
        setState(() => error = RoomClient.explain(e));
      }
    } finally {
      if (mounted && generation == requestGeneration) {
        setState(() => searching = false);
      }
    }
  }

  Widget panel(Widget child, {EdgeInsets? padding}) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: _ink,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xff343c42)),
    ),
    child: child,
  );
  Widget title(String eyebrow, String text, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: const TextStyle(color: _gold, letterSpacing: 3, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Text(
          text,
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        Text(subtitle, style: const TextStyle(color: _muted, height: 1.7)),
      ],
    ),
  );
  Widget empty(String text, IconData icon, {Widget? action}) => panel(
    Column(
      children: [
        Icon(icon, color: _muted, size: 40),
        const SizedBox(height: 16),
        Text(text, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 16), action],
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => widget.storyId != null
      ? storyPage()
      : switch (widget.section) {
          1 => catalog(),
          2 => roomList(),
          3 => personal(),
          _ => home(),
        };
  Widget home() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title(
        'RUXI / INTERACTIVE STORIES',
        '把今晚，交给一个好故事。',
        '发现原创互动故事。和朋友分饰角色，让每一次选择都成为你们的结局。',
      ),
      if (client.stories.isNotEmpty)
        featured(Map<String, dynamic>.from(client.stories.first))
      else
        empty(
          client.busy ? '正在加载故事…' : '暂时没有已发布故事，稍后再来看看。',
          Icons.auto_stories_outlined,
          action: TextButton(
            onPressed: () => client.run(client.catalog),
            child: const Text('刷新目录'),
          ),
        ),
      const SizedBox(height: 20),
      TextField(
        controller: search,
        maxLength: 80,
        onSubmitted: (_) {
          widget.onSection(1);
          filter();
        },
        decoration: InputDecoration(
          hintText: '搜索下一部想玩的故事',
          prefixIcon: const Icon(Icons.search),
          counterText: '',
          filled: true,
          fillColor: _ink,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          suffixIcon: IconButton(
            tooltip: '搜索故事',
            onPressed: () {
              widget.onSection(1);
              filter();
            },
            icon: const Icon(Icons.arrow_forward),
          ),
        ),
      ),
      const SizedBox(height: 28),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final entry in categories.entries)
            ActionChip(
              avatar: Icon(categoryIcon(entry.key), size: 18),
              label: Text(entry.value),
              onPressed: () {
                category = entry.key;
                widget.onSection(1);
                filter();
              },
            ),
        ],
      ),
      const SizedBox(height: 32),
      Row(
        children: [
          const Expanded(
            child: Text(
              '现在入戏',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () => widget.onSection(1),
            child: const Text('浏览全部 →'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      grid(client.stories),
      const SizedBox(height: 28),
      panel(
        LayoutBuilder(
          builder: (context, b) => Wrap(
            spacing: 36,
            runSpacing: 16,
            children: [
              const SizedBox(
                width: 420,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('朋友已经开场？', style: TextStyle(fontSize: 22)),
                    SizedBox(height: 8),
                    Text(
                      '输入邀请码加入私人房间，选好角色再一起出发。',
                      style: TextStyle(color: _muted),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: joinDialog,
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('使用邀请码'),
              ),
              TextButton(onPressed: guide, child: const Text('第一次玩？查看入戏指南')),
            ],
          ),
        ),
      ),
      if (client.rooms.any((r) => r['can_resume'] == true)) ...[
        const SizedBox(height: 28),
        Row(
          children: [
            const Expanded(child: Text('未完待续', style: TextStyle(fontSize: 22))),
            TextButton(
              onPressed: () => widget.onSection(2),
              child: const Text('我的房间 →'),
            ),
          ],
        ),
        ...client.rooms
            .where((r) => r['can_resume'] == true)
            .take(2)
            .map(roomTile),
      ],
    ],
  );
  Widget featured(Json story) => ClipRRect(
    borderRadius: BorderRadius.circular(22),
    child: Container(
      padding: const EdgeInsets.all(32),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xff304347), Color(0xff172329)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '编辑精选 / ORIGINAL',
                    style: TextStyle(color: _gold, letterSpacing: 2),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    story['title'],
                    style: const TextStyle(
                      fontSize: 34,
                      fontFamily: 'Songti SC',
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    story['summary'].toString(),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xffc8d4d3),
                      height: 1.8,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '${story['seat_count']} 人协作  /  ${story['estimated_minutes'] ?? 15} 分钟  /  ${categories[story['category']] ?? '悬疑推理'}',
                    style: const TextStyle(color: _muted),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => details(story),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('了解这个故事'),
                  ),
                ],
              ),
            ),
            if (box.maxWidth > 650) ...[
              const SizedBox(width: 36),
              SizedBox(
                width: 240,
                height: 250,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.rotate(
                      angle: -.12,
                      child: Container(
                        width: 168,
                        height: 228,
                        decoration: BoxDecoration(
                          color: const Color(0xff152328),
                          border: Border.all(
                            color: _gold.withValues(alpha: .4),
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                    const Text(
                      '入\n戏',
                      style: TextStyle(
                        fontFamily: 'Songti SC',
                        fontSize: 60,
                        height: 1.3,
                        color: Color(0xffc2cabb),
                      ),
                    ),
                    const Positioned(
                      bottom: 12,
                      child: Text(
                        '每个选择，都会留下回响。',
                        style: TextStyle(
                          color: _gold,
                          letterSpacing: 2,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  IconData categoryIcon(String? key) => switch (key) {
    'emotion' => Icons.favorite_outline,
    'scifi' => Icons.public,
    'adventure' => Icons.explore_outlined,
    _ => Icons.fingerprint,
  };
  Widget grid(List<dynamic> items) {
    if (items.isEmpty) {
      return empty('没有找到符合条件的故事。试试其他关键词或分类。', Icons.search_off);
    }
    return LayoutBuilder(
      builder: (context, b) {
        final columns = b.maxWidth > 960
            ? 3
            : b.maxWidth > 580
            ? 2
            : 1;
        final width = (b.maxWidth - (columns - 1) * 18) / columns;
        return Wrap(
          spacing: 18,
          runSpacing: 18,
          children: [
            for (final raw in items)
              SizedBox(
                width: width,
                child: storyCard(Map<String, dynamic>.from(raw)),
              ),
          ],
        );
      },
    );
  }

  Widget storyCard(Json story) => Material(
    color: _ink,
    borderRadius: BorderRadius.circular(18),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => details(story),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 148,
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  switch (story['category']) {
                    'emotion' => const Color(0xff573d43),
                    'scifi' => const Color(0xff244953),
                    'adventure' => const Color(0xff3d4a32),
                    _ => const Color(0xff344342),
                  },
                  const Color(0xff16221e),
                ],
              ),
            ),
            child: Row(
              children: [
                Icon(
                  categoryIcon(story['category']),
                  size: 44,
                  color: _gold.withValues(alpha: .55),
                ),
                const Spacer(),
                Text(
                  '${story['seat_count']}\n人协作',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 18, color: Colors.white70),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${categories[story['category']] ?? '悬疑推理'} · ${difficulties[story['difficulty']] ?? '新手友好'}',
                  style: const TextStyle(color: _gold, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Text(
                  story['title'],
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  story['summary'].toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, height: 1.7),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text(
                      '${story['estimated_minutes'] ?? 15} 分钟',
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                    Spacer(),
                    Text('查看故事 →', style: TextStyle(color: _gold)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget catalog() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title('DISCOVER / 故事目录', '寻找你的下一场故事', '按题材和参与人数筛选，找到适合今晚的那一部。'),
      TextField(
        controller: search,
        maxLength: 80,
        onSubmitted: (_) => filter(),
        decoration: InputDecoration(
          hintText: '搜索故事名称或简介',
          prefixIcon: const Icon(Icons.search),
          counterText: '',
          filled: true,
          fillColor: _ink,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          suffixIcon: IconButton(
            tooltip: '搜索',
            onPressed: () => filter(),
            icon: const Icon(Icons.arrow_forward),
          ),
        ),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          ChoiceChip(
            label: const Text('全部题材'),
            selected: category.isEmpty,
            onSelected: (_) {
              category = '';
              filter();
            },
          ),
          for (final e in categories.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: category == e.key,
              onSelected: (_) {
                category = e.key;
                filter();
              },
            ),
        ],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final n in ['', '1', '2', '3', '4'])
            FilterChip(
              label: Text(n.isEmpty ? '不限人数' : '$n 人故事'),
              selected: seats == n,
              onSelected: (_) {
                seats = n;
                filter();
              },
            ),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<String>(
              initialValue: sort,
              decoration: const InputDecoration(labelText: '排序'),
              items: const [
                DropdownMenuItem(value: 'latest', child: Text('最新发布')),
                DropdownMenuItem(value: 'title', child: Text('按名称')),
              ],
              onChanged: (v) {
                sort = v!;
                filter();
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      if (searching) const LinearProgressIndicator(),
      if (error != null)
        panel(
          Column(
            children: [
              Text(error!),
              TextButton(onPressed: () => filter(), child: const Text('重新加载')),
            ],
          ),
        ),
      Text(
        '共 ${results == null ? (client.storiesTotal == 0 ? client.stories.length : client.storiesTotal) : total} 个故事',
        style: const TextStyle(color: _muted),
      ),
      const SizedBox(height: 16),
      grid(results ?? client.stories),
      if ((next ?? (results == null ? client.storiesNext : null)) != null)
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: OutlinedButton(
            onPressed: searching ? null : () => filter(more: true),
            child: const Text('加载更多'),
          ),
        ),
    ],
  );
  String lifecycle(String? state) =>
      const {
        'lobby': '等待开场',
        'running': '进行中',
        'paused': '已暂停',
        'suspended': '等待重新连接',
        'finished': '已完成',
        'abandoned': '已结束',
      }[state] ??
      '已结束';
  Widget roomTile(dynamic room) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: panel(
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          room['can_resume'] == true
              ? Icons.play_circle_outline
              : Icons.history,
          color: _gold,
        ),
        title: Text(room['title']),
        subtitle: Text(
          '${lifecycle(room['lifecycle'])} · ${room['updated_at'].toString().split('T').first}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: client.busy
            ? null
            : () => client.run(() => client.openGame(room['room_id'])),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    ),
  );
  Widget roomList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      title('TOGETHER / 我的房间', '把故事继续下去', '进行中的房间与已完成的故事，都保存在这里。'),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            onPressed: joinDialog,
            icon: const Icon(Icons.group_add_outlined),
            label: const Text('邀请码加入'),
          ),
          OutlinedButton(
            onPressed: () => widget.onSection(1),
            child: const Text('发现新故事'),
          ),
          if (client.signedIn)
            TextButton.icon(
              onPressed: client.busy ? null : () => client.run(client.catalog),
              icon: const Icon(Icons.refresh),
              label: const Text('刷新房间'),
            ),
        ],
      ),
      const SizedBox(height: 24),
      if (!client.signedIn)
        empty(
          '登录后查看自己的房间，或使用邀请码体验故事。',
          Icons.person_outline,
          action: FilledButton(
            onPressed: () => auth(),
            child: const Text('登录 / 注册'),
          ),
        )
      else if (client.rooms.isEmpty)
        empty(
          '还没有参与过故事，先去发现一部喜欢的作品吧。',
          Icons.meeting_room_outlined,
          action: TextButton(
            onPressed: () => widget.onSection(1),
            child: const Text('浏览故事'),
          ),
        )
      else
        ...client.rooms.map(roomTile),
    ],
  );
  Widget personal() {
    final profile = client.profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title('YOUR SPACE / 个人空间', '故事里的你，故事外的自己。', '管理个人资料、收藏和账号安全。'),
        if (!client.signedIn) ...[
          panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.account_circle_outlined,
                  size: 44,
                  color: _gold,
                ),
                const SizedBox(height: 20),
                const Text('登录，让故事跟着你。', style: TextStyle(fontSize: 24)),
                const SizedBox(height: 12),
                const Text(
                  '收藏喜欢的剧目，保存参与记录，换设备继续入戏。',
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      onPressed: () => auth(),
                      child: const Text('登录账号'),
                    ),
                    OutlinedButton(
                      onPressed: () => auth(register: true),
                      child: const Text('注册新账号'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextButton(onPressed: recoveryDialog, child: const Text('使用恢复码找回账号')),
        ] else ...[
          panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: _gold.withValues(alpha: .15),
                      child: const Icon(
                        Icons.person_outline,
                        color: _gold,
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile?['display_name'] ?? '游客',
                            style: const TextStyle(fontSize: 24),
                          ),
                          Text(
                            client.registered
                                ? '@${profile?['username']}'
                                : '游客身份 · 注册后保留现有记录',
                            style: const TextStyle(color: _muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if ((profile?['bio'] ?? '').toString().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(profile!['bio']),
                  ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 28,
                  runSpacing: 16,
                  children: [
                    stat('${client.rooms.length}', '参与故事'),
                    stat(
                      '${client.rooms.where((r) => r['lifecycle'] == 'finished').length}',
                      '完成故事',
                    ),
                    stat('${client.favorites.length}', '我的收藏'),
                  ],
                ),
                const Divider(height: 36),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: editProfile,
                      child: const Text('编辑资料'),
                    ),
                    if (!client.registered)
                      FilledButton(
                        onPressed: () => auth(register: true),
                        child: const Text('升级为正式账号'),
                      ),
                    if (client.registered)
                      OutlinedButton(
                        onPressed: passwordDialog,
                        child: const Text('修改密码'),
                      ),
                    TextButton(
                      onPressed: widget.onRecovery,
                      child: const Text('恢复与注销'),
                    ),
                    TextButton(
                      onPressed: client.busy ? null : client.logout,
                      child: const Text('退出登录'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (client.recoveryCode.isNotEmpty) ...[
            const SizedBox(height: 20),
            panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('请保存你的账号恢复码', style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 10),
                  const Text(
                    '忘记密码时用它找回账号。恢复后会轮换，退出登录会清除本机副本。请保存在自己的安全位置。',
                    style: TextStyle(color: _muted, height: 1.7),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    client.recoveryCode,
                    style: const TextStyle(color: _gold, fontSize: 13),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: client.recoveryCode),
                      );
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('恢复码已复制')));
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制恢复码'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 28),
          const Text('我的收藏', style: TextStyle(fontSize: 22)),
          const SizedBox(height: 16),
          if (client.favorites.isEmpty)
            empty('在故事详情中点击收藏，喜欢的故事就会出现在这里。', Icons.bookmark_outline)
          else
            grid(client.favorites),
        ],
        const SizedBox(height: 24),
        panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('入戏指南', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 8),
              const Text('了解角色选择、协作调查与结局决策。', style: TextStyle(color: _muted)),
              TextButton(onPressed: guide, child: const Text('查看玩法说明 →')),
            ],
          ),
        ),
      ],
    );
  }

  Widget stat(String value, String label) => SizedBox(
    width: 120,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: const TextStyle(fontSize: 28, color: _gold)),
        Text(label, style: const TextStyle(color: _muted)),
      ],
    ),
  );
  Future<Json>? detailFuture;
  String? loadedStory;
  Widget storyPage() {
    if (loadedStory != widget.storyId) {
      loadedStory = widget.storyId;
      detailFuture = client
          .request('GET', '/api/v2/stories/${widget.storyId}')
          .then((v) => Map<String, dynamic>.from(v));
    }
    return FutureBuilder<Json>(
      future: detailFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return empty(
            RoomClient.explain(snapshot.error!),
            Icons.error_outline,
            action: TextButton(
              onPressed: () => setState(() {
                loadedStory = null;
              }),
              child: const Text('重试'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton(
              onPressed: () => widget.onSection(1),
              child: const Text('返回剧目列表'),
            ),
            detailContent(snapshot.data!, context),
          ],
        );
      },
    );
  }

  Widget detailContent(Json story, BuildContext c, {VoidCallback? refresh}) {
    final saved = client.favorites.any(
      (f) => f['story_id'] == story['story_id'],
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${categories[story['category']] ?? '悬疑推理'} / ${difficulties[story['difficulty']] ?? '新手友好'}',
                style: const TextStyle(color: _gold),
              ),
              const SizedBox(height: 16),
              Text(
                story['title'],
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${story['seat_count']} 名角色 · 私人房间 · ${story['estimated_minutes'] ?? 15} 分钟',
                style: const TextStyle(color: _muted),
              ),
              const Divider(height: 40),
              const Text('故事简介', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 12),
              Text(
                story['summary'].toString(),
                style: const TextStyle(height: 1.9),
              ),
              const SizedBox(height: 24),
              const Text('如何开始', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 10),
              Text(
                '创建私人房间，把邀请码发给 ${story['seat_count'] - 1} 位朋友。大家选好角色并准备后，由房主开始故事。可先以游客体验，也可以登录保存记录。',
                style: const TextStyle(color: _muted, height: 1.8),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: client.busy
                        ? null
                        : () {
                            if (widget.onStory == null) Navigator.pop(c);
                            client.create(story['story_id']);
                          },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('创建房间'),
                  ),
                  OutlinedButton.icon(
                    onPressed: client.busy
                        ? null
                        : () async {
                            if (!client.signedIn) {
                              if (widget.onStory == null) Navigator.pop(c);
                              await auth();
                              return;
                            }
                            await client.favorite(story['story_id'], !saved);
                            if (c.mounted) {
                              if (refresh != null) {
                                refresh();
                              } else {
                                setState(() {});
                              }
                            }
                          },
                    icon: Icon(saved ? Icons.bookmark : Icons.bookmark_outline),
                    label: Text(saved ? '取消收藏' : '收藏故事'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> details(Json story) async {
    if (widget.onStory != null) {
      widget.onStory!(story['story_id']);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, refresh) =>
            detailContent(story, c, refresh: () => refresh(() {})),
      ),
    );
  }

  Future<void> joinDialog() async {
    final code = TextEditingController();
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('加入朋友的房间'),
        content: Form(
          key: form,
          child: TextFormField(
            controller: code,
            autofocus: true,
            maxLength: 8,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: '八位邀请码',
              hintText: '例如 7KQ8HM2N',
            ),
            validator: (v) =>
                RegExp(r'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$')
                    .hasMatch((v ?? '').trim().toUpperCase())
                ? null
                : '请输入完整的八位邀请码',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, code.text);
            },
            child: const Text('加入房间'),
          ),
        ],
      ),
    );
    code.dispose();
    if (result != null) await client.join(result);
  }

  Future<void> auth({bool register = false}) async {
    final username = TextEditingController(),
        password = TextEditingController(),
        name = TextEditingController();
    final form = GlobalKey<FormState>();
    bool submitting = false, visible = false;
    String? failure;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, state) => AlertDialog(
          title: Text(register ? '注册入戏账号' : '欢迎回到入戏'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      register && client.signedIn
                          ? '注册后保留当前游客的房间与收藏。'
                          : '使用账号密码，保存你的故事旅程。',
                      style: const TextStyle(color: _muted),
                    ),
                    const SizedBox(height: 20),
                    if (register) ...[
                      TextFormField(
                        controller: name,
                        maxLength: 24,
                        decoration: const InputDecoration(labelText: '昵称'),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? '请输入昵称' : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: username,
                      maxLength: 64,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: '账号',
                        helperText: '3–64 位英文、数字或 _ . @ -',
                      ),
                      validator: (v) =>
                          RegExp(r'^[a-z0-9][a-z0-9_.@-]{2,63}$')
                              .hasMatch((v ?? '').trim().toLowerCase())
                          ? null
                          : '账号格式不正确',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: password,
                      obscureText: !visible,
                      maxLength: 128,
                      autofillHints: [
                        register
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      decoration: InputDecoration(
                        labelText: '密码',
                        helperText: '10–128 字节',
                        suffixIcon: IconButton(
                          tooltip: visible ? '隐藏密码' : '显示密码',
                          onPressed: () => state(() => visible = !visible),
                          icon: Icon(
                            visible ? Icons.visibility_off : Icons.visibility,
                          ),
                        ),
                      ),
                      validator: (v) =>
                          (v ?? '').length < 10 ? '密码至少 10 个字符' : null,
                    ),
                    if (failure != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          failure!,
                          style: const TextStyle(color: _gold),
                        ),
                      ),
                    TextButton(
                      onPressed: submitting
                          ? null
                          : () {
                              Navigator.pop(c);
                              recoveryDialog();
                            },
                      child: const Text('忘记密码 / 找回身份'),
                    ),
                    TextButton(
                      onPressed: submitting
                          ? null
                          : () => state(() {
                              register = !register;
                              failure = null;
                            }),
                      child: Text(register ? '已有账号？去登录' : '还没有账号？去注册'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      state(() {
                        submitting = true;
                        failure = null;
                      });
                      await client.authenticateAccount(
                        username.text,
                        password.text,
                        displayName: register ? name.text.trim() : null,
                      );
                      if (!c.mounted) return;
                      if (client.status == '欢迎回来。' ||
                          client.status == '注册成功，欢迎入戏。') {
                        Navigator.pop(c);
                        widget.onSection(3);
                      } else {
                        state(() {
                          submitting = false;
                          failure = client.status;
                        });
                      }
                    },
              child: Text(
                submitting
                    ? '正在验证…'
                    : register
                    ? '创建账号'
                    : '登录',
              ),
            ),
          ],
        ),
      ),
    );
    username.dispose();
    password.dispose();
    name.dispose();
  }

  Future<void> recoveryDialog() async {
    final code = TextEditingController(), password = TextEditingController();
    final form = GlobalKey<FormState>();
    bool reset = true, working = false;
    String? failure;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, state) => AlertDialog(
          title: const Text('找回账号与身份'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '使用注册时保存的恢复码找回账号。成功后会撤销旧设备会话并生成新的恢复码。',
                      style: TextStyle(color: _muted, height: 1.7),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('重置正式账号密码'),
                      subtitle: const Text('游客找回身份时关闭此选项'),
                      value: reset,
                      onChanged: working ? null : (v) => state(() => reset = v),
                    ),
                    TextFormField(
                      controller: code,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '恢复码'),
                      validator: (v) =>
                          (v ?? '').trim().length < 20 ? '请输入完整恢复码' : null,
                    ),
                    if (reset)
                      TextFormField(
                        controller: password,
                        obscureText: true,
                        maxLength: 128,
                        decoration: const InputDecoration(labelText: '新密码'),
                        validator: (v) =>
                            (v ?? '').length < 10 ? '新密码至少 10 个字符' : null,
                      ),
                    if (failure != null)
                      Text(failure!, style: const TextStyle(color: _gold)),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      state(() {
                        working = true;
                        failure = null;
                      });
                      if (reset) {
                        await client.resetPassword(code.text, password.text);
                      } else {
                        await client.recover(code.text);
                      }
                      if (!c.mounted) return;
                      if (client.signedIn &&
                          (reset
                              ? client.status.startsWith('密码已重置')
                              : client.status.isEmpty)) {
                        Navigator.pop(c);
                        widget.onSection(3);
                      } else {
                        state(() {
                          working = false;
                          failure = client.status;
                        });
                      }
                    },
              child: Text(working ? '正在恢复…' : '找回账号'),
            ),
          ],
        ),
      ),
    );
    code.dispose();
    password.dispose();
  }

  Future<void> editProfile() async {
    final name = TextEditingController(text: client.profile?['display_name']),
        bio = TextEditingController(text: client.profile?['bio']);
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('编辑个人资料'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  maxLength: 24,
                  decoration: const InputDecoration(labelText: '昵称'),
                  validator: (v) => (v ?? '').trim().isEmpty ? '请输入昵称' : null,
                ),
                TextFormField(
                  controller: bio,
                  maxLength: 160,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '个人简介'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true) await client.saveProfile(name.text, bio.text);
    name.dispose();
    bio.dispose();
  }

  Future<void> passwordDialog() async {
    final old = TextEditingController(), next = TextEditingController();
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('修改密码'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('修改后所有设备会退出，需要重新登录。'),
                TextFormField(
                  controller: old,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前密码'),
                  validator: (v) => (v ?? '').length < 10 ? '请输入当前密码' : null,
                ),
                TextFormField(
                  controller: next,
                  obscureText: true,
                  maxLength: 128,
                  decoration: const InputDecoration(labelText: '新密码'),
                  validator: (v) =>
                      (v ?? '').length < 10 ? '新密码至少 10 个字符' : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, true);
            },
            child: const Text('确认修改'),
          ),
        ],
      ),
    );
    if (ok == true) await client.changePassword(old.text, next.text);
    old.dispose();
    next.dispose();
  }

  void guide() => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('第一次入戏'),
      content: const SingleChildScrollView(
        child: Text(
          '1. 发现故事\n根据人数和题材选一部作品，创建私人房间或用邀请码加入。\n\n2. 选好角色\n每个人拥有不同的信息。全员准备后，房主开始故事。\n\n3. 一起调查\n发现线索、分享信息、交换道具；遇到困难可以请求受限提示。\n\n4. 决定结局\n在时间内表达选择，共同见证结果。离开后可以在「我的房间」继续。',
          style: TextStyle(height: 1.8),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('准备好了'),
        ),
      ],
    ),
  );
}
