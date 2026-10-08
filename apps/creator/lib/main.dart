import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'content_panel.dart';
import 'preview_panel.dart';
import 'report_panel.dart';

const amber = Color(0xfff3ad47);
void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '入戏 · 制作台',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: amber,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff101416),
    ),
    home: const Creator(),
  ),
);

class Creator extends StatefulWidget {
  const Creator({super.key});
  @override
  State<Creator> createState() => _CreatorState();
}

class _CreatorState extends State<Creator> {
  final login = TextEditingController(),
      id = TextEditingController(text: '11111111-1111-4111-8111-333333333333'),
      editor = TextEditingController();
  final device = const Uuid().v4();
  String token = '', refreshToken = '', status = '', hash = '';
  List<dynamic> roles = [];
  List<dynamic> versions = [];
  List<dynamic> stories = [];
  String storyId = '11111111-1111-4111-8111-111111111111';
  int revision = 0;
  bool busy = false;
  Map<String, dynamic>? version;
  Map<String, dynamic>? preview;
  String workspace = 'content';
  final contentForm = GlobalKey<FormState>();
  String? approved;
  static const base = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:4000',
  );
  Future<dynamic> api(
    String method,
    String path, [
    Map<String, dynamic>? body,
    bool retried = false,
  ]) async {
    final headers = {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final url = Uri.parse('$base$path');
    final r =
        await (method == 'GET'
                ? http.get(url, headers: headers)
                : method == 'PUT'
                ? http.put(url, headers: headers, body: jsonEncode(body))
                : http.post(url, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 10));
    final d = jsonDecode(r.body);
    if (r.statusCode == 401 &&
        !retried &&
        refreshToken.isNotEmpty &&
        !path.startsWith('/v1/admin/auth/')) {
      final refreshed = await api('POST', '/v1/admin/auth/refresh', {
        'refresh_token': refreshToken,
        'device_id': device,
        'refresh_request_id': const Uuid().v4(),
      });
      token = refreshed['access_token'];
      refreshToken = refreshed['refresh_token'];
      return api(method, path, body, true);
    }
    if (r.statusCode >= 400) throw Exception(d['error']['code']);
    return d['data'];
  }

  Future<void> run(Future<void> Function() f) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '处理中…';
    });
    try {
      await f();
    } catch (e) {
      status = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() async {
    version = await api('GET', '/v1/admin/versions/${id.text}');
    revision = version!['revision'];
    hash = version!['hash'];
    editor.text = const JsonEncoder.withIndent('  ').convert(version!['graph']);
    storyId = version!['graph']['story_id'];
    stories = (await api('GET', '/v1/admin/stories'))['items'];
    approved = null;
    preview = null;
    versions = (await api(
      'GET',
      '/v1/admin/stories/$storyId/versions',
    ))['items'];
    status = '已读取版本 · $revision';
  }

  Future<void> startPreview() async {
    preview = await api(
      'POST',
      '/v1/admin/versions/${id.text}/preview',
      post(),
    );
    status = '多角色试玩已开始。';
  }

  Future<void> createStory() async {
    var draftTitle = '';
    final form = GlobalKey<FormState>();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('创建剧目'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('从三人协作模板开始，所有内容先保存为草稿，审核发布后玩家才能看到。'),
              const SizedBox(height: 16),
              TextFormField(
                onChanged: (v) => draftTitle = v,
                autofocus: true,
                maxLength: 120,
                decoration: const InputDecoration(labelText: '剧目名称'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入剧目名称' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, draftTitle.trim());
              }
            },
            child: const Text('创建草稿'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final story = await api('POST', '/v1/admin/stories', {
      'title': name,
      'summary': '',
      'seat_count': 3,
      'command_id': const Uuid().v4(),
    });
    storyId = story['story_id'];
    final draft = await api('POST', '/v1/admin/stories/$storyId/versions', {
      'command_id': const Uuid().v4(),
    });
    id.text = draft['version_id'];
    await load();
    final graph = {...version!['graph'] as Map<String, dynamic>, 'title': name};
    await api('PUT', '/v1/admin/versions/${id.text}', {
      'revision': revision,
      'graph': graph,
    });
    await load();
    status = '已创建剧目草稿，尚未发布。';
  }

  void previewStep(
    String role,
    String type,
    Map<String, dynamic> payload,
    Map<String, dynamic> extra,
  ) => run(() async {
    preview = await api('POST', '/v1/admin/previews/step', {
      'preview_token': preview!['preview_token'],
      'actor_role': role,
      'type': type,
      'payload': payload,
      'command_id': const Uuid().v4(),
      ...extra,
    });
    status = '操作完成，各角色视角已更新。';
  });

  Map<String, dynamic> post() => {
    'revision': revision,
    'command_id': const Uuid().v4(),
  };
  Widget button(
    String text,
    Future<void> Function() f, {
    bool enabled = true,
  }) => FilledButton(
    onPressed: busy || !enabled ? null : () => run(f),
    child: Text(text),
  );
  @override
  void dispose() {
    login.dispose();
    id.dispose();
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('入戏  /  制作台', style: TextStyle(letterSpacing: 3)),
      actions: [
        if (token.isNotEmpty && roles.contains('reviewer'))
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('聊天举报审核'),
                content: ReportPanel(
                  load: () => api('GET', '/v1/admin/chat/reports'),
                  review: (id, outcome) => api(
                    'POST',
                    '/v1/admin/chat/reports/$id',
                    {'command_id': const Uuid().v4(), 'status': outcome},
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            child: const Text('举报审核'),
          ),
        if (token.isNotEmpty)
          TextButton(
            onPressed: () => run(() async {
              await api('POST', '/v1/admin/auth/logout', {});
              token = '';
              refreshToken = '';
              version = null;
              editor.clear();
              status = '已退出';
            }),
            child: const Text('退出'),
          ),
      ],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('让每个角色，都有自己的故事。', style: TextStyle(fontSize: 32)),
              const SizedBox(height: 12),
              const Text(
                '草稿 → 自动验证 → 三角色试玩 → 审核 → 冻结发布',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 24),
              if (token.isEmpty) ...[
                const Text('使用部署 CLI 签发的五分钟一次性登录码。'),
                const SizedBox(height: 16),
                TextField(
                  controller: login,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '后台登录码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                button('登录制作台', () async {
                  final a = await api('POST', '/v1/admin/auth/exchange', {
                    'login_code': login.text.trim(),
                    'device_id': device,
                    'login_request_id': const Uuid().v4(),
                  });
                  token = a['access_token'];
                  refreshToken = a['refresh_token'];
                  roles = a['roles'];
                  login.clear();
                  await load();
                }),
              ] else ...[
                Text(
                  '当前权限：${roles.join(' / ')}',
                  style: const TextStyle(color: amber),
                ),
                const SizedBox(height: 20),
                if (stories.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey('story-$storyId'),
                    initialValue: stories.any((s) => s['story_id'] == storyId)
                        ? storyId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '剧目',
                      border: OutlineInputBorder(),
                    ),
                    items: stories
                        .map(
                          (s) => DropdownMenuItem<String>(
                            value: s['story_id'],
                            child: Text('${s['title']} · ${s['seat_count']} 人'),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (value) => run(() async {
                            if (value == null || value == storyId) return;
                            storyId = value;
                            versions = (await api(
                              'GET',
                              '/v1/admin/stories/$storyId/versions',
                            ))['items'];
                            version = null;
                            preview = null;
                            editor.clear();
                            if (versions.isNotEmpty) {
                              id.text = versions.first['version_id'];
                              await load();
                            } else {
                              id.clear();
                              status = '此剧目尚未创建内容版本。';
                            }
                          }),
                  ),
                const SizedBox(height: 16),
                if (versions.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue:
                        versions.any((v) => v['version_id'] == id.text)
                        ? id.text
                        : null,
                    key: ValueKey(id.text),
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '内容版本',
                      border: OutlineInputBorder(),
                    ),
                    items: versions
                        .map(
                          (v) => DropdownMenuItem<String>(
                            value: v['version_id'],
                            child: Text(
                              '${v['status'] == 'published'
                                  ? '已发布'
                                  : v['status'] == 'approved'
                                  ? '已审核'
                                  : '草稿'} · 修订 ${v['revision']} · ${v['version_id'].toString().substring(0, 8)}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (v) {
                            if (v != null) {
                              run(() async {
                                id.text = v;
                                await load();
                              });
                            }
                          },
                  ),
                ExpansionTile(
                  title: const Text('按版本编号查找'),
                  children: [
                    TextField(
                      controller: id,
                      decoration: const InputDecoration(labelText: '版本编号'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    button(
                      '创建剧目',
                      createStory,
                      enabled: roles.contains('editor'),
                    ),
                    button('读取版本', load),
                    if (versions.isEmpty)
                      button('从模板创建首个版本', () async {
                        final draft = await api(
                          'POST',
                          '/v1/admin/stories/$storyId/versions',
                          {'command_id': const Uuid().v4()},
                        );
                        id.text = draft['version_id'];
                        await load();
                      }),
                    button('基于当前版本创建草稿', () async {
                      final r = await api(
                        'POST',
                        '/v1/admin/stories/$storyId/versions',
                        {
                          'base_version_id': id.text,
                          'command_id': const Uuid().v4(),
                        },
                      );
                      id.text = r['version_id'];
                      await load();
                    }, enabled: version != null),
                  ],
                ),
                if (version != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    '版本 ${version!['status']} · Revision $revision',
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    hash,
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                  const SizedBox(height: 20),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'content',
                        label: Text('内容配置'),
                        icon: Icon(Icons.view_list_outlined),
                      ),
                      ButtonSegment(
                        value: 'preview',
                        label: Text('多角色试玩'),
                        icon: Icon(Icons.groups_outlined),
                      ),
                      ButtonSegment(
                        value: 'advanced',
                        label: Text('高级配置'),
                        icon: Icon(Icons.code),
                      ),
                    ],
                    selected: {workspace},
                    onSelectionChanged: (s) =>
                        setState(() => workspace = s.first),
                  ),
                  const SizedBox(height: 24),
                  if (workspace == 'content')
                    ContentPanel(
                      key: ValueKey('${id.text}:$revision'),
                      graph: Map<String, dynamic>.from(version!['graph']),
                      formKey: contentForm,
                      readOnly:
                          version!['status'] == 'published' ||
                          !roles.contains('editor'),
                      onTitle: (title) {
                        version!['graph']['title'] = title;
                        editor.text = const JsonEncoder.withIndent('  ')
                            .convert(version!['graph']);
                      },
                      onGraph: (graph) => setState(() {
                        version!['graph'] = graph;
                        editor.text = const JsonEncoder.withIndent('  ')
                            .convert(graph);
                      }),
                    ),
                  if (workspace == 'preview')
                    PreviewPanel(
                      preview: preview,
                      busy: busy,
                      onStart: () => run(startPreview),
                      onStep: previewStep,
                    ),
                  if (workspace == 'advanced')
                    TextField(
                      controller: editor,
                      minLines: 16,
                      maxLines: 28,
                      readOnly: version!['status'] == 'published',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        labelText: '内容 schema v2 · 规则配置',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      button(
                        '保存草稿',
                        () async {
                          if (contentForm.currentState?.validate() == false) {
                            throw Exception('请修正标记的配置后保存。');
                          }
                          await api('PUT', '/v1/admin/versions/${id.text}', {
                            'revision': revision,
                            'graph': jsonDecode(editor.text),
                          });
                          await load();
                        },
                        enabled:
                            version!['status'] != 'published' &&
                            roles.contains('editor'),
                      ),
                      button('运行自动验证', () async {
                        final j = await api(
                          'POST',
                          '/v1/admin/versions/${id.text}/validate',
                          post(),
                        );
                        final report = await api(
                          'GET',
                          '/v1/admin/jobs/${j['job_id']}',
                        );
                        status = const JsonEncoder.withIndent('  ')
                            .convert(report);
                      }, enabled: roles.contains('editor')),
                      button('审核当前 Hash', () async {
                        final r = await api(
                          'POST',
                          '/v1/admin/versions/${id.text}/approve',
                          {...post(), 'content_hash': hash},
                        );
                        approved = r['approved_hash'];
                        status = '审核完成；发布前仍会校验素材就绪和冻结 Hash';
                      }, enabled: roles.contains('reviewer')),
                      button(
                        '发布冻结版本',
                        () async {
                          await api(
                            'POST',
                            '/v1/admin/versions/${id.text}/publish',
                            {...post(), 'approved_hash': approved},
                          );
                          await load();
                        },
                        enabled:
                            roles.contains('publisher') && approved != null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                ],
              ],
              const SizedBox(height: 24),
              SelectableText(
                status,
                style: const TextStyle(color: amber, height: 1.7),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
