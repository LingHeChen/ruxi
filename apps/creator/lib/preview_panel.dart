import 'package:flutter/material.dart';

typedef Json = Map<String, dynamic>;
const _labels = {'investigator': '调查员', 'passenger': '乘客', 'conductor': '乘务员'};

class PreviewPanel extends StatelessWidget {
  const PreviewPanel({
    super.key,
    required this.preview,
    required this.busy,
    required this.onStart,
    required this.onStep,
  });
  final Json? preview;
  final bool busy;
  final VoidCallback onStart;
  final void Function(String role, String type, Json payload, Json extra)
  onStep;

  Widget action(
    String label,
    String role,
    String type,
    Json payload, {
    Json extra = const {},
    bool enabled = true,
  }) => OutlinedButton(
    onPressed: busy || !enabled
        ? null
        : () => onStep(role, type, payload, extra),
    child: Text(label),
  );

  @override
  Widget build(BuildContext context) {
    final views = preview?['views'] as Map?;
    final history = preview?['history'] as List? ?? [];
    final roleCodes = views?.keys.cast<String>().toList() ?? [];
    final timeActor = roleCodes.isEmpty ? 'investigator' : roleCodes.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('多角色试玩', style: TextStyle(fontSize: 24)),
            ),
            FilledButton(
              onPressed: busy ? null : onStart,
              child: Text(preview == null ? '开始试玩' : '重新开始'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '同时查看每个角色实际能收到的信息。操作共享同一场预览，时间推进仅影响这场试玩。',
          style: TextStyle(color: Colors.white60, height: 1.6),
        ),
        if (views == null) ...[
          const SizedBox(height: 24),
          const Text('先保存并验证草稿，再开始三角色试玩。'),
        ] else ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Chip(label: Text('第 ${preview!['steps']} 步')),
              action('推进 30 秒', timeActor, 'advance_time', {'delta_ms': 30000}),
              action('推进 45 秒', timeActor, 'advance_time', {'delta_ms': 45000}),
              action('推进 3 分钟', timeActor, 'advance_time', {
                'delta_ms': 180000,
              }),
            ],
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final count = constraints.maxWidth >= 1000
                  ? 3
                  : constraints.maxWidth >= 650
                  ? 2
                  : 1;
              final width = (constraints.maxWidth - (count - 1) * 16) / count;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final role in roleCodes)
                    SizedBox(
                      width: width,
                      child: roleCard(role, Json.from(views[role])),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          const Text('操作与可见性记录', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 12),
          if (history.isEmpty) const Text('尚未执行操作。'),
          for (final entry in history.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry['step']}. ${_labels[entry['actor_role']] ?? entry['actor_role']} · ${entry['type']}',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    roleCodes
                        .map((r) {
                          final fields = entry['changed_fields'][r] as List;
                          return '${_labels[r] ?? r}：${fields.isEmpty ? '无可见变化' : fields.join('、')}';
                        })
                        .join('  /  '),
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget roleCard(String role, Json view) {
    final room = view['room'] as Map;
    final id = view['self']['membership_id'];
    final members = view['members'] as List;
    final running = room['lifecycle'] == 'running';
    final exploring =
        running &&
        room['phase_code'] == 'exploration' &&
        room['exploration_step'] == 'active';
    final offered = view['offers'] as List;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _labels[role] ?? view['own_role']?['title'] ?? role,
              style: const TextStyle(fontSize: 22, color: Color(0xfff3ad47)),
            ),
            const SizedBox(height: 8),
            Text('${room['phase_code']} · ${room['lifecycle']}'),
            if (room['ending_code'] != null) Text('结局 ${room['ending_code']}'),
            const Divider(height: 32),
            const Text('仅自己知道', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final clue in view['own_clues'] as List)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${clue['title']} ${clue['shared'] == true ? '· 已公开' : '· 私有'}',
                    ),
                    Text(
                      '${clue['text']}',
                      style: const TextStyle(
                        color: Colors.white60,
                        height: 1.6,
                      ),
                    ),
                    if (exploring &&
                        clue['shared'] != true &&
                        clue['clue_id'] != 'C2')
                      action('公开这条线索', role, 'share_clue', {
                        'clue_id': clue['clue_id'],
                      }),
                  ],
                ),
              ),
            if ((view['own_clues'] as List).isEmpty)
              const Text('还没有发现线索。', style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 16),
            const Text('公共线索'),
            for (final clue
                in view['public_scene']['shared_clues'] as List? ?? [])
              Text(
                '${clue['title']} · ${clue['text']}',
                style: const TextStyle(height: 1.6),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final media in view['media']['authorized'] as List)
                  action('确认 ${media['media_id']}', role, 'media_complete', {
                    'media_id': media['media_id'],
                    'media_epoch': media['media_epoch'],
                    'mode': 'summary',
                  }, enabled: running),
                for (final a in view['available_actions'] as List)
                  action('${a['label']}', role, 'investigate', {
                    'action_id': a['action_id'],
                  }, enabled: a['enabled'] == true),
                if (exploring) ...[
                  action('结束探索', role, 'confirm_exploration_end', {}),
                  action('请求提示', role, 'request_hint', {
                    'hint_level': 1,
                  }, enabled: view['hints']['remaining'] > 0),
                  for (final item in view['visible_items'] as List)
                    if (item['owner_membership_id'] == id)
                      for (final other in members)
                        if (other['membership_id'] != id)
                          action(
                            '交付给 ${_labels[other['role_code']] ?? other['role_code']}',
                            role,
                            'offer_item',
                            {
                              'item_id': item['item_id'],
                              'to_member': other['membership_id'],
                            },
                            extra: {'target_version': item['version']},
                          ),
                  for (final offer in offered)
                    if (offer['status'] == 'pending' &&
                        offer['to_member'] == id) ...[
                      action('接受交付', role, 'accept_offer', {
                        'offer_id': offer['offer_id'],
                      }),
                      action('拒绝交付', role, 'reject_offer', {
                        'offer_id': offer['offer_id'],
                      }),
                    ],
                ],
                if (running && room['phase_code'] == 'decision')
                  for (final option
                      in view['vote_round']['display_options'] as List)
                    action('${option['label']}', role, 'vote', {
                      'round_id': view['vote_round']['round_id'],
                      'option_id': option['option_id'],
                    }, enabled: option['eligible'] == true),
              ],
            ),
            if (view['own_vote'] != null)
              Text('我的选择：${view['own_vote']['option_id']}'),
            for (final hint in view['hints']['entries'] as List)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('提示：${hint['text']}'),
              ),
          ],
        ),
      ),
    );
  }
}
