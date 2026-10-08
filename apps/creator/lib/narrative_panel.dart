import 'package:flutter/material.dart';

class NarrativePanel extends StatelessWidget {
  const NarrativePanel({
    super.key,
    required this.graph,
    required this.onChanged,
  });
  final Map<String, dynamic> graph;
  final ValueChanged<Map<String, dynamic>> onChanged;
  static const defaultClues = {
    'C1': {
      'title': '车厢名单',
      'text': '名单上只有六个名字，却有第七处被擦去的签名。',
      'shareable': true,
    },
    'C2': {
      'title': '旧车票上的时间码',
      'text': '手机留言里的时间码是 23:17，与旧车票一致。',
      'shareable': false,
    },
    'C3': {
      'title': '异常装置记录',
      'text': '控制柜记录证实，未来留言由车上的异常装置发出。',
      'shareable': true,
    },
  };
  Widget field(
    String label,
    String value,
    ValueChanged<String> change, {
    int limit = 2000,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      initialValue: value,
      maxLength: limit,
      maxLines: limit > 500 ? 4 : 1,
      decoration: InputDecoration(labelText: label),
      onChanged: change,
    ),
  );
  @override
  Widget build(BuildContext context) {
    final roles = graph['roles'] as List;
    final definitions = Map<String, dynamic>.from(
      graph['role_definitions'] ?? {},
    );
    final clues = Map<String, dynamic>.from(graph['clues'] ?? defaultClues);
    final variables = Map<String, dynamic>.from(graph['variables']);
    return Column(
      children: [
        ExpansionTile(
          title: const Text('角色文字与私有信息'),
          children: [
            for (final code in roles)
              Builder(
                builder: (context) {
                  final value = Map<String, dynamic>.from(
                    definitions[code] ??
                        {
                          'title':
                              const {
                                'investigator': '调查员',
                                'passenger': '乘客',
                                'conductor': '乘务员',
                              }[code] ??
                              code,
                          'description':
                              const {
                                'investigator': '核对车厢记录，寻找异常。',
                                'passenger': '你收到了一段来自未来的留言。',
                                'conductor': '检查设备，确保末班车安全离站。',
                              }[code] ??
                              '按你的角色参与故事。',
                        },
                  );
                  void change(String key, String text) => onChanged({
                    ...graph,
                    'role_definitions': {
                      ...definitions,
                      code: {...value, key: text},
                    },
                  });
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        field(
                          '$code · 角色名称',
                          '${value['title']}',
                          (v) => change('title', v),
                          limit: 120,
                        ),
                        field(
                          '$code · 私有角色介绍',
                          '${value['description']}',
                          (v) => change('description', v),
                        ),
                        field(
                          '$code · 选角时公开介绍',
                          '${value['public_description'] ?? '选择这个角色，与队友一起参与故事。'}',
                          (v) => change('public_description', v),
                          limit: 500,
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        ExpansionTile(
          title: const Text('线索正文与共享规则'),
          children: [
            for (final entry in clues.entries)
              Builder(
                builder: (_) {
                  final value = Map<String, dynamic>.from(entry.value);
                  void change(String key, dynamic text) => onChanged({
                    ...graph,
                    'clues': {
                      ...clues,
                      entry.key: {...value, key: text},
                    },
                  });
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        field(
                          '${entry.key} · 线索名称',
                          '${value['title']}',
                          (v) => change('title', v),
                          limit: 120,
                        ),
                        field(
                          '${entry.key} · 私有正文',
                          '${value['text']}',
                          (v) => change('text', v),
                        ),
                        SwitchListTile(
                          title: const Text('持有者可以主动公开'),
                          value: value['shareable'] == true,
                          onChanged: (v) => change('shareable', v),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        ExpansionTile(
          title: const Text('变量初始值与范围'),
          children: [
            for (final entry in variables.entries)
              Builder(
                builder: (_) {
                  final value = Map<String, dynamic>.from(entry.value);
                  void change(String key, dynamic text) => onChanged({
                    ...graph,
                    'variables': {
                      ...variables,
                      entry.key: {...value, key: text},
                    },
                  });
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(entry.key),
                        if (value['type'] == 'bool')
                          SwitchListTile(
                            title: const Text('初始为真'),
                            value: value['initial'] == true,
                            onChanged: (v) => change('initial', v),
                          )
                        else
                          for (final key in ['initial', 'min', 'max'])
                            field(
                              {
                                'initial': '初始值',
                                'min': '最小值',
                                'max': '最大值',
                              }[key]!,
                              '${value[key]}',
                              (v) {
                                final n = int.tryParse(v);
                                if (n != null) change(key, n);
                              },
                              limit: 8,
                            ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        ExpansionTile(
          title: const Text('决策选项与准入条件'),
          children: [
            for (final option in graph['decision']['options'])
              Padding(
                padding: const EdgeInsets.all(16),
                child: field(
                  '$option · 玩家可见名称',
                  '${graph['option_labels']?[option] ?? option}',
                  (v) => onChanged({
                    ...graph,
                    'option_labels': {...?graph['option_labels'], option: v},
                  }),
                  limit: 120,
                ),
              ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('结局映射、平票优先级及复杂变量定义可在高级配置中调整。自动验证会检查全部结局可达性。'),
            ),
          ],
        ),
      ],
    );
  }
}
