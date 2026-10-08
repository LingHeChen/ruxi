import 'package:flutter/material.dart';

import 'rule_editor.dart';
import 'narrative_panel.dart';

class ContentPanel extends StatelessWidget {
  const ContentPanel({
    super.key,
    required this.graph,
    required this.readOnly,
    required this.onTitle,
    required this.onGraph,
    required this.formKey,
  });
  final Map<String, dynamic> graph;
  final bool readOnly;
  final ValueChanged<String> onTitle;
  final ValueChanged<Map<String, dynamic>> onGraph;
  final GlobalKey<FormState> formKey;

  Widget section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 22)),
        const SizedBox(height: 16),
        child,
      ],
    ),
  );
  Widget table(List<String> headers, List<List<String>> rows) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: headers.map((h) => DataColumn(label: Text(h))).toList(),
          rows: rows
              .map(
                (r) => DataRow(
                  cells: r
                      .map(
                        (c) => DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 380),
                            child: Text(c),
                          ),
                        ),
                      )
                      .toList(),
                ),
              )
              .toList(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final timing = graph['timing'], decision = graph['decision'];
    final actions = graph['actions'], assets = graph['assets'];
    final readable =
        timing is Map &&
        decision is Map &&
        [
          'exploration_ms',
          'interlude_ms',
          'ending_ms',
        ].every((k) => timing[k] is num) &&
        decision['duration_ms'] is num &&
        decision['options'] is List &&
        (decision['options'] as List).every((v) => v is String) &&
        (graph['role_definitions'] == null ||
            graph['role_definitions'] is Map &&
                (graph['role_definitions'] as Map).values.every(
                  (v) =>
                      v is Map &&
                      v['title'] is String &&
                      v['description'] is String,
                )) &&
        (graph['clues'] == null ||
            graph['clues'] is Map &&
                (graph['clues'] as Map).values.every(
                  (v) =>
                      v is Map &&
                      v['title'] is String &&
                      v['text'] is String &&
                      v['shareable'] is bool,
                )) &&
        graph['roles'] is List &&
        (graph['roles'] as List).every((r) => r is String) &&
        graph['variables'] is Map &&
        (graph['variables'] as Map).values.every((v) => v is Map) &&
        (decision['endings'] == null || decision['endings'] is Map) &&
        actions is List &&
        actions.every(
          (a) =>
              a is Map &&
              a['requires'] is Map &&
              a['role'] is String &&
              (graph['roles'] as List).contains(a['role']) &&
              a['effects'] is List &&
              (a['effects'] as List).every((e) => e is Map),
        ) &&
        assets is List &&
        assets.every(
          (a) =>
              a is Map &&
              a['duration_ms'] is num &&
              a['media_id'] is String &&
              a['summary'] is String &&
              a['source'] is String,
        );
    if (!readable) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('此草稿的结构尚不完整，请在高级配置中修复，再执行自动验证。草稿可以保存，验证通过后才能审核发布。'),
        ),
      );
    }
    final clues = graph['clues'] is Map
        ? graph['clues'] as Map
        : {
            'C1': {'shareable': true},
            'C2': {'shareable': false},
            'C3': {'shareable': true},
          };
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          section(
            '剧目信息',
            TextFormField(
              initialValue: graph['title'],
              readOnly: readOnly,
              maxLength: 120,
              onChanged: onTitle,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? '请输入剧目名称' : null,
              decoration: const InputDecoration(
                labelText: '剧目名称',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          section(
            '剧目介绍',
            TextFormField(
              initialValue: graph['description'] ?? '',
              readOnly: readOnly,
              maxLength: 2000,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: '玩家可见介绍'),
              onChanged: (v) => onGraph({...graph, 'description': v}),
            ),
          ),
          if (!readOnly)
            section(
              '片段图文摘要',
              Column(
                children: [
                  for (var i = 0; i < assets.length; i++)
                    TextFormField(
                      initialValue: assets[i]['summary'],
                      maxLength: 2000,
                      minLines: 2,
                      maxLines: 5,
                      decoration: InputDecoration(
                        labelText: '${assets[i]['media_id']} · 授权摘要',
                      ),
                      onChanged: (v) {
                        final next = List<dynamic>.from(assets);
                        next[i] = {...assets[i], 'summary': v};
                        onGraph({...graph, 'assets': next});
                      },
                    ),
                ],
              ),
            ),
          if (!readOnly) NarrativePanel(graph: graph, onChanged: onGraph),
          section(
            '角色与行动',
            table(
              ['角色', '行动', '阶段', '得到的信息'],
              [
                for (final action in graph['actions'] as List)
                  [
                    '${action['role']}',
                    '${action['id']}',
                    '${action['phase']}',
                    (action['effects'] as List)
                        .map(
                          (e) =>
                              '${e['grant_clue'] ?? e['grant_item']} · ${e['visibility']}',
                        )
                        .join('、'),
                  ],
              ],
            ),
          ),
          section(
            '阶段与超时',
            table(
              ['阶段', '推进方式', '等待窗口'],
              [
                ['共同开场', '全员确认开场，再分别确认角色片段', '等待全员完成'],
                [
                  '探索',
                  '计时结束或全员结束探索，进入中场',
                  '${graph['timing']['exploration_ms'] ~/ 1000} 秒',
                ],
                [
                  '中场',
                  '全员确认后开始决策；超时挂起',
                  '${graph['timing']['interlude_ms'] ~/ 1000} 秒',
                ],
                [
                  '决策',
                  '截止后结算，最高票；平票按冻结顺序',
                  '${graph['decision']['duration_ms'] ~/ 1000} 秒',
                ],
                [
                  '结局',
                  '全员确认或等待窗口到期完成',
                  '${graph['timing']['ending_ms'] ~/ 1000} 秒',
                ],
              ],
            ),
          ),
          if (!readOnly)
            section(
              '调整计时',
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final field in [
                    ('探索', 'timing', 'exploration_ms'),
                    ('中场等待', 'timing', 'interlude_ms'),
                    ('决策', 'decision', 'duration_ms'),
                    ('结局等待', 'timing', 'ending_ms'),
                  ])
                    SizedBox(
                      width: 220,
                      child: TextFormField(
                        initialValue: '${graph[field.$2][field.$3] ~/ 1000}',
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '${field.$1}时长',
                          suffixText: '秒',
                        ),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          return n == null || n < 1 || n > 900
                              ? '请输入 1–900 秒'
                              : null;
                        },
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n >= 1 && n <= 900) {
                            final next = Map<String, dynamic>.from(graph);
                            next[field.$2] = {
                              ...graph[field.$2],
                              field.$3: n * 1000,
                            };
                            onGraph(next);
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
          if (!readOnly)
            section(
              '编辑行动规则',
              Column(
                children: [
                  for (var i = 0; i < (graph['actions'] as List).length; i++)
                    ActionEditor(
                      key: ValueKey(graph['actions'][i]['id']),
                      action: Map<String, dynamic>.from(graph['actions'][i]),
                      roles: List<String>.from(graph['roles']),
                      clues: graph['clues'] is Map
                          ? (graph['clues'] as Map).keys.cast<String>().toList()
                          : ['C1', 'C2', 'C3'],
                      variables: Map<String, dynamic>.from(graph['variables']),
                      onChanged: (action) {
                        final actions = List<dynamic>.from(graph['actions']);
                        actions[i] = action;
                        onGraph({...graph, 'actions': actions});
                      },
                    ),
                ],
              ),
            ),
          section(
            '线索与可见性',
            table(
              ['线索', '首次获得者', '公开方式', '使用权'],
              [
                for (final clue in clues.entries)
                  [
                    '${clue.key}',
                    actions
                        .where(
                          (a) => (a['effects'] as List).any(
                            (e) => e['grant_clue'] == clue.key,
                          ),
                        )
                        .map((a) => '${a['role']}')
                        .toSet()
                        .join('、'),
                    clue.value is Map && clue.value['shareable'] == true
                        ? '持有者主动公开，不可撤回'
                        : '私有记忆',
                    (actions).any(
                          (a) => (a['effects'] as List).any(
                            (e) => e['grant_item'] == clue.key,
                          ),
                        )
                        ? '道具使用权可交付；记忆保留'
                        : '线索记录',
                  ],
              ],
            ),
          ),
          section(
            '剧情关系',
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final stage in [
                  '共同开场',
                  '角色片段',
                  '协作探索',
                  '公共中场',
                  '共同抉择',
                  (decision['endings'] as Map? ?? {}).values.toSet().join(
                    ' / ',
                  ),
                ])
                  Chip(label: Text(stage)),
              ],
            ),
          ),
          section(
            '媒体与来源',
            table(
              ['片段', '时长', '授权范围', '来源'],
              [
                for (final asset in graph['assets'] as List)
                  [
                    '${asset['media_id']}',
                    '${asset['duration_ms'] ~/ 1000} 秒',
                    '${asset['media_id']}'.startsWith('role_')
                        ? '指定角色私有'
                        : '当前阶段公共',
                    '${asset['source']}',
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
