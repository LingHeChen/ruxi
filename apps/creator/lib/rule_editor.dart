import 'package:flutter/material.dart';

typedef Json = Map<String, dynamic>;

class ConditionEditor extends StatelessWidget {
  const ConditionEditor({
    super.key,
    required this.value,
    required this.clues,
    required this.variables,
    required this.onChanged,
    this.depth = 0,
  });
  final Json value;
  final List<String> clues;
  final Json variables;
  final ValueChanged<Json> onChanged;
  final int depth;
  static const ops = [
    'all',
    'any',
    'not',
    'public_clue',
    'owns_item',
    'knows_clue',
    'var',
  ];
  static const labels = {
    'all': '全部满足',
    'any': '任一满足',
    'not': '条件不成立',
    'public_clue': '线索已公开',
    'owns_item': '本人持有道具',
    'knows_clue': '本人已知线索',
    'var': '变量等于',
  };

  Json initial(String op) => switch (op) {
    'all' => {'all': []},
    'any' => {
      'any': [
        {'all': []},
      ],
    },
    'not' => {
      'not': {'all': []},
    },
    'var' => {
      'var': variables.keys.first,
      'eq': variables.values.first['initial'],
    },
    _ => {op: clues.first},
  };

  @override
  Widget build(BuildContext context) {
    final op = value.containsKey('var') ? 'var' : value.keys.first;
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue: op,
            key: ValueKey('operator-$op'),
            items: [
              for (final item in ops)
                if ((item != 'var' || variables.isNotEmpty) &&
                    (item == op ||
                        !(depth >= 6) ||
                        !['all', 'any', 'not'].contains(item)))
                  DropdownMenuItem(value: item, child: Text(labels[item]!)),
            ],
            onChanged: (v) {
              if (v != null) onChanged(initial(v));
            },
            decoration: const InputDecoration(labelText: '前置条件'),
          ),
          if (op == 'all' || op == 'any') ...[
            for (var i = 0; i < (value[op] as List).length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ConditionEditor(
                      value: Json.from(value[op][i]),
                      clues: clues,
                      variables: variables,
                      depth: depth + 1,
                      onChanged: (v) {
                        final children = List<dynamic>.from(value[op]);
                        children[i] = v;
                        onChanged({op: children});
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: '移除条件',
                    onPressed: () {
                      final children = List<dynamic>.from(value[op]);
                      children.removeAt(i);
                      onChanged({op: children});
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            if (depth < 6 && (value[op] as List).length < 10)
              TextButton.icon(
                onPressed: () => onChanged({
                  op: [
                    ...value[op],
                    {'public_clue': clues.first},
                  ],
                }),
                icon: const Icon(Icons.add),
                label: const Text('添加条件'),
              ),
            if (op == 'all' && (value[op] as List).isEmpty)
              const Text(
                '没有前置条件，该动作可直接执行。',
                style: TextStyle(color: Colors.white60),
              ),
          ] else if (op == 'not')
            ConditionEditor(
              value: Json.from(value['not']),
              clues: clues,
              variables: variables,
              depth: depth + 1,
              onChanged: (v) => onChanged({'not': v}),
            )
          else if (op == 'var') ...[
            DropdownButtonFormField<String>(
              initialValue: value['var'],
              key: ValueKey('variable-${value['var']}'),
              items: variables.keys
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  onChanged({'var': v, 'eq': variables[v]['initial']});
                }
              },
              decoration: const InputDecoration(labelText: '变量'),
            ),
            if (variables[value['var']]['type'] == 'bool')
              SwitchListTile(
                title: const Text('期望为真'),
                value: value['eq'] == true,
                onChanged: (v) => onChanged({'var': value['var'], 'eq': v}),
              )
            else
              TextFormField(
                initialValue: '${value['eq']}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '期望数值'),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null) onChanged({'var': value['var'], 'eq': n});
                },
              ),
          ] else
            DropdownButtonFormField<String>(
              initialValue: value[op],
              key: ValueKey('target-${value[op]}'),
              items: clues
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (c) {
                if (c != null) onChanged({op: c});
              },
              decoration: const InputDecoration(labelText: '线索或道具'),
            ),
        ],
      ),
    );
  }
}

class ActionEditor extends StatelessWidget {
  const ActionEditor({
    super.key,
    required this.action,
    required this.roles,
    required this.clues,
    required this.variables,
    required this.onChanged,
  });
  final Json action;
  final List<String> roles, clues;
  final Json variables;
  final ValueChanged<Json> onChanged;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text('${action['label'] ?? action['id']}'),
    subtitle: Text('${action['role']} · 探索阶段'),
    childrenPadding: const EdgeInsets.all(16),
    children: [
      TextFormField(
        initialValue: action['label'] ?? action['id'],
        maxLength: 120,
        decoration: const InputDecoration(labelText: '动作名称'),
        onChanged: (v) => onChanged({...action, 'label': v}),
      ),
      DropdownButtonFormField<String>(
        initialValue: action['role'],
        key: ValueKey('role-${action['role']}'),
        items: roles
            .map((r) => DropdownMenuItem(value: r, child: Text(r)))
            .toList(),
        decoration: const InputDecoration(labelText: '允许执行的角色'),
        onChanged: (r) {
          if (r != null) onChanged({...action, 'role': r});
        },
      ),
      ConditionEditor(
        value: Json.from(action['requires']),
        clues: clues,
        variables: variables,
        onChanged: (v) => onChanged({...action, 'requires': v}),
      ),
      const SizedBox(height: 16),
      const Align(
        alignment: Alignment.centerLeft,
        child: Text('动作效果 · 当前角色获得的信息'),
      ),
      for (var i = 0; i < (action['effects'] as List).length; i++)
        effectEditor(i),
    ],
  );

  Widget effectEditor(int i) {
    final effect = Json.from(action['effects'][i]);
    if (effect.containsKey('set_variable')) {
      return ListTile(
        title: Text('设置变量 ${effect['set_variable']} = ${effect['value']}'),
      );
    }
    final op = effect.containsKey('grant_item') ? 'grant_item' : 'grant_clue';
    void change(Json e) {
      final effects = List<dynamic>.from(action['effects']);
      effects[i] = e;
      onChanged({...action, 'effects': effects});
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: op,
            key: ValueKey('effect-$i-$op'),
            items: const [
              DropdownMenuItem(value: 'grant_clue', child: Text('获得线索')),
              DropdownMenuItem(value: 'grant_item', child: Text('获得唯一道具')),
            ],
            onChanged: (v) {
              if (v != null) {
                change({v: effect[op], 'visibility': effect['visibility']});
              }
            },
          ),
          DropdownButtonFormField<String>(
            initialValue: effect[op],
            key: ValueKey('effect-target-$i-${effect[op]}'),
            items: clues
                .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                .toList(),
            onChanged: (c) {
              if (c != null) {
                change({op: c, 'visibility': effect['visibility']});
              }
            },
          ),
          DropdownButtonFormField<String>(
            initialValue: effect['visibility'],
            key: ValueKey('visibility-$i-${effect['visibility']}'),
            items: const [
              DropdownMenuItem(value: 'actor', child: Text('仅执行者知道')),
              DropdownMenuItem(value: 'public', child: Text('直接公开给全员')),
            ],
            onChanged: (v) {
              if (v != null) change({...effect, 'visibility': v});
            },
          ),
        ],
      ),
    );
  }
}
