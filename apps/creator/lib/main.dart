import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'content_panel.dart';
import 'preview_panel.dart';
import 'report_panel.dart';
import 'production_panel.dart';
import 'operations_panel.dart';
import 'session_store_stub.dart'
    if (dart.library.js_interop) 'session_store_web.dart';

const amber = Color(0xffa16a20);
ThemeData creatorTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  colorScheme: ColorScheme.fromSeed(
    seedColor: amber,
    brightness: Brightness.light,
  ),
  scaffoldBackgroundColor: const Color(0xfff4f5f7),
  fontFamily: 'PingFang SC',
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
  ),
  cardTheme: const CardThemeData(color: Colors.white, elevation: 0),
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  runApp(const CreatorApp());
}

GoRouter creatorRouter({
  http.Client? httpClient,
  SessionStore? sessionStore,
  String? initialLocation,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    ShellRoute(
      builder: (context, state, child) => Creator(
        key: const ValueKey('creator-shell'),
        httpClient: httpClient,
        sessionStore: sessionStore,
        route: state.uri,
      ),
      routes: [
        for (final path in [
          '/',
          '/dashboard',
          '/stories',
          '/editor',
          '/editor/:versionId',
          '/assets',
          '/reports',
          '/users',
        ])
          GoRoute(
            path: path,
            builder: (context, state) => const SizedBox.shrink(),
          ),
      ],
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('页面不存在'),
          TextButton(
            onPressed: () => context.go('/dashboard'),
            child: const Text('返回工作台'),
          ),
        ],
      ),
    ),
  ),
);

class CreatorApp extends StatefulWidget {
  const CreatorApp({super.key});
  @override
  State<CreatorApp> createState() => _CreatorAppState();
}

class _CreatorAppState extends State<CreatorApp> {
  late final router = creatorRouter();
  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    title: '入戏 · 制作台',
    theme: creatorTheme(),
    routerConfig: router,
  );
}

class Creator extends StatefulWidget {
  const Creator({super.key, this.httpClient, this.sessionStore, this.route});
  final http.Client? httpClient;
  final SessionStore? sessionStore;
  final Uri? route;
  @override
  State<Creator> createState() => _CreatorState();
}

class _CreatorState extends State<Creator> {
  final login = TextEditingController(),
      id = TextEditingController(text: '11111111-1111-4111-8111-333333333333'),
      editor = TextEditingController();
  late final store = widget.sessionStore ?? SessionStore();
  late final transport = widget.httpClient ?? http.Client();
  late final String device;
  final username = TextEditingController(),
      password = TextEditingController(),
      search = TextEditingController();
  String page = 'dashboard';
  bool useCode = false, restoring = true;
  Map<String, dynamic>? adminProfile;
  Future<dynamic>? overview, assetData, userData;
  int dashboardGeneration = 0;
  @override
  void initState() {
    super.initState();
    device = store.read('device') ?? const Uuid().v4();
    store.write('device', device);
    token = store.read('access') ?? '';
    refreshToken = store.read('refresh') ?? '';
    readRoute();
    restoreSession();
  }

  Future<void> restoreSession() async {
    try {
      if (token.isNotEmpty) {
        adminProfile = await api('GET', '/v1/admin/me');
        roles = adminProfile!['roles'];
        await loadWorkspace();
        await applyRoute();
      }
    } catch (_) {
      token = refreshToken = '';
      store.clear();
      status = '会话已失效，请重新登录。';
    } finally {
      if (mounted) setState(() => restoring = false);
    }
  }

  bool applyingRoute = false;
  void readRoute() {
    if (widget.route == null) return;
    page = widget.route!.pathSegments.firstOrNull ?? 'dashboard';
    workspace = widget.route!.queryParameters['workspace'] ?? 'content';
    if (!['content', 'preview', 'advanced'].contains(workspace)) {
      workspace = 'content';
    }
  }

  @override
  void didUpdateWidget(Creator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route != widget.route) {
      readRoute();
      if (!restoring && token.isNotEmpty) run(applyRoute);
    }
  }

  Future<void> applyRoute() async {
    if (widget.route == null) return;
    applyingRoute = true;
    try {
      readRoute();
      final parts = widget.route!.pathSegments;
      if (parts.length == 2 &&
          parts.first == 'editor' &&
          roles.contains('editor') &&
          (version == null || version!['version_id'] != parts[1])) {
        id.text = parts[1];
        version = preview = null;
        await load();
        versions = (await api(
          'GET',
          '/v1/admin/stories/$storyId/versions',
        ))['items'];
      }
    } finally {
      applyingRoute = false;
    }
  }

  void navigatePage(String value) {
    setState(() => page = value);
    syncRoute();
  }

  void syncRoute() {
    if (widget.route == null || applyingRoute || restoring || !mounted) return;
    final target = page == 'editor' && id.text.isNotEmpty
        ? Uri(
            path: '/editor/${id.text}',
            queryParameters: workspace == 'content'
                ? null
                : {'workspace': workspace},
          ).toString()
        : '/$page';
    if (widget.route.toString() != target) context.go(target);
  }

  Future<void> loadWorkspace() async {
    dashboardGeneration++;
    if (roles.contains('editor')) {
      stories = (await api('GET', '/v1/admin/stories'))['items'];
      if (stories.isNotEmpty) {
        storyId = stories.first['story_id'];
        versions = (await api(
          'GET',
          '/v1/admin/stories/$storyId/versions',
        ))['items'];
        if (versions.isNotEmpty) {
          id.text = versions.first['version_id'];
          await load();
        }
      }
      assetData = null;
    }
    if (roles.contains('reviewer')) {
      overview = null;
      userData = null;
    }
  }

  void saveSession() {
    store.write('access', token);
    store.write('refresh', refreshToken);
  }

  Future<void> signOut() async {
    try {
      await api('POST', '/v1/admin/auth/logout', {});
    } finally {
      clearLocalSession();
    }
  }

  void clearLocalSession() {
    store.clear();
    token = refreshToken = '';
    version = preview = adminProfile = null;
    editor.clear();
    stories = [];
    versions = [];
    roles = [];
    overview = assetData = userData = null;
    page = 'dashboard';
    status = '';
  }

  Future<void> signIn() async {
    final auth = await api(
      'POST',
      useCode ? '/v1/admin/auth/exchange' : '/v1/admin/auth/login',
      {
        if (useCode)
          'login_code': login.text.trim()
        else ...{
          'username': username.text.trim(),
          'password': password.text,
        },
        'device_id': device,
        'login_request_id': const Uuid().v4(),
      },
    );
    token = auth['access_token'];
    refreshToken = auth['refresh_token'];
    roles = auth['roles'];
    saveSession();
    password.clear();
    login.clear();
    adminProfile = await api('GET', '/v1/admin/me');
    await loadWorkspace();
    await applyRoute();
    status = '';
  }

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
                ? transport.get(url, headers: headers)
                : method == 'PUT'
                ? transport.put(url, headers: headers, body: jsonEncode(body))
                : transport.post(url, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 10));
    final d = jsonDecode(r.body);
    if (r.statusCode == 401 &&
        !retried &&
        refreshToken.isNotEmpty &&
        !path.startsWith('/v1/admin/auth/')) {
      await refreshSession();
      return api(method, path, body, true);
    }
    if (r.statusCode >= 400) {
      const messages = {
        'REVISION_CONFLICT': '草稿已发生变化，请重新读取版本后再操作。',
        'AUTH_EXPIRED': '登录已过期，请重新领取登录码。',
        'UNAUTHORIZED': '登录凭证无效或已过期。',
        'NOT_ALLOWED': '当前账号无权执行此操作，或版本已冻结。',
        'CONTENT_INVALID': '内容未通过验证，请检查规则和素材。',
        'ASSET_MISMATCH': '文件内容与上传信息不符，请重新上传。',
        'RIGHTS_REQUIRED': '请填写素材版权与来源说明。',
        'INVALID_CAPTIONS': '字幕格式或时间范围不正确，请检查 WebVTT。',
        'INVALID_ARGUMENT': '输入信息不完整或格式不正确。',
        'RATE_LIMITED': '操作过于频繁，请稍后再试。',
      };
      throw Exception(messages[d['error']['code']] ?? '操作失败，请刷新后重试。');
    }
    return d['data'];
  }

  Future<void>? refreshingAuth;
  Future<void> refreshSession() => refreshingAuth ??= performRefresh()
      .whenComplete(() => refreshingAuth = null);
  Future<void> performRefresh() async {
    final refreshed = await api('POST', '/v1/admin/auth/refresh', {
      'refresh_token': refreshToken,
      'device_id': device,
      'refresh_request_id': const Uuid().v4(),
    });
    token = refreshed['access_token'];
    refreshToken = refreshed['refresh_token'];
    saveSession();
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
      if (mounted) {
        setState(() => busy = false);
        syncRoute();
      }
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
    await run(() async {
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
      final graph = {
        ...version!['graph'] as Map<String, dynamic>,
        'title': name,
      };
      await api('PUT', '/v1/admin/versions/${id.text}', {
        'revision': revision,
        'graph': graph,
      });
      await load();
      status = '已创建剧目草稿，尚未发布。';
      page = 'editor';
    });
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
    if (widget.httpClient == null) transport.close();
    username.dispose();
    password.dispose();
    search.dispose();
    login.dispose();
    id.dispose();
    editor.dispose();
    super.dispose();
  }

  static const navigation = {
    'dashboard': ('工作概览', Icons.dashboard_outlined),
    'stories': ('剧目管理', Icons.auto_stories_outlined),
    'editor': ('内容工作室', Icons.edit_note),
    'assets': ('素材库', Icons.perm_media_outlined),
    'reports': ('举报审核', Icons.fact_check_outlined),
    'users': ('用户目录', Icons.people_outline),
  };
  bool visiblePage(String key) =>
      key == 'dashboard' ||
      (key == 'users'
          ? roles.contains('reviewer') || roles.contains('publisher')
          : ['stories', 'editor', 'assets'].contains(key)
          ? roles.contains('editor')
          : roles.contains('reviewer'));
  Widget sidebar({bool drawer = false}) => Container(
    width: 228,
    color: const Color(0xff17252b),
    padding: const EdgeInsets.fromLTRB(18, 28, 18, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 12),
          child: Text(
            '入戏',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w600,
              letterSpacing: 8,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 0, 32),
          child: Text(
            '创作与运营中心',
            style: TextStyle(
              color: Color(0xff9fbbb8),
              fontSize: 12,
              letterSpacing: 2,
            ),
          ),
        ),
        for (final e in navigation.entries)
          if (visiblePage(e.key))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: page == e.key
                    ? const Color(0xff324943)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  leading: Icon(
                    e.value.$2,
                    color: page == e.key
                        ? const Color(0xfff3ad47)
                        : const Color(0xffa5b4b8),
                    size: 20,
                  ),
                  title: Text(
                    e.value.$1,
                    style: TextStyle(
                      color: page == e.key
                          ? Colors.white
                          : const Color(0xffb9c5c9),
                      fontSize: 14,
                    ),
                  ),
                  onTap: () {
                    navigatePage(e.key);
                    if (drawer) Navigator.pop(context);
                  },
                ),
              ),
            ),
        const Spacer(),
        const Divider(color: Color(0xff34454a)),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '原创故事，从这里开始。',
            style: TextStyle(color: Color(0xffa5b4b8), fontSize: 12),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (restoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (token.isEmpty) return loginPage();
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return Scaffold(
      drawer: wide ? null : Drawer(child: sidebar(drawer: true)),
      body: Row(
        children: [
          if (wide) sidebar(),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 76,
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      bottom: BorderSide(color: Color(0xffe5e7eb)),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (!wide)
                        Builder(
                          builder: (c) => IconButton(
                            tooltip: '打开导航',
                            onPressed: () => Scaffold.of(c).openDrawer(),
                            icon: const Icon(Icons.menu),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          '工作台  /  ${navigation[page]?.$1 ?? '工作概览'}',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Color(0xff475569),
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.account_circle_outlined,
                        color: Color(0xff64748b),
                      ),
                      const SizedBox(width: 10),
                      Text(adminProfile?['display_name'] ?? '内容管理员'),
                      const SizedBox(width: 16),
                      TextButton(
                        onPressed: busy ? null : () => run(signOut),
                        child: const Text('退出'),
                      ),
                    ],
                  ),
                ),
                if (busy) const LinearProgressIndicator(minHeight: 2),
                if (status.isNotEmpty && page != 'editor')
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 10,
                    ),
                    color: const Color(0xfffff6e6),
                    child: Text(status, style: const TextStyle(color: amber)),
                  ),
                Expanded(
                  child: page == 'editor'
                      ? editorWorkspace()
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(28),
                          child: KeyedSubtree(
                            key: ValueKey(page),
                            child: switch (page) {
                              'stories' => storyDirectory(),
                              'assets' => assetsPage(),
                              'reports' => reportsPage(),
                              'users' => usersPage(),
                              _ => dashboard(),
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget loginPage() => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: LayoutBuilder(
                builder: (c, b) => Row(
                  children: [
                    if (b.maxWidth > 650)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 48),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '入戏',
                                style: TextStyle(
                                  fontSize: 40,
                                  letterSpacing: 10,
                                  fontFamily: 'Songti SC',
                                ),
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                '让好故事，\n拥有值得信赖的后台。',
                                style: TextStyle(fontSize: 28, height: 1.6),
                              ),
                              const SizedBox(height: 24),
                              const Text(
                                '内容创作 · 素材制作 · 审核发布 · 运营管理',
                                style: TextStyle(color: Color(0xff64748b)),
                              ),
                              const SizedBox(height: 48),
                              Container(height: 4, width: 80, color: amber),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '登录创作与运营中心',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '仅限已获授权的制作与运营账号。',
                            style: TextStyle(color: Color(0xff64748b)),
                          ),
                          const SizedBox(height: 28),
                          if (useCode)
                            TextField(
                              controller: login,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: '一次性登录码',
                              ),
                            )
                          else ...[
                            TextField(
                              controller: username,
                              autofillHints: const [AutofillHints.username],
                              decoration: const InputDecoration(
                                labelText: '管理员账号',
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: password,
                              obscureText: true,
                              autofillHints: const [AutofillHints.password],
                              onSubmitted: (_) => run(signIn),
                              decoration: const InputDecoration(
                                labelText: '密码',
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: busy ? null : () => run(signIn),
                              child: Text(busy ? '正在验证…' : '登录后台'),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() => useCode = !useCode),
                            child: Text(useCode ? '使用账号密码登录' : '使用一次性登录码'),
                          ),
                          if (status.isNotEmpty)
                            Text(status, style: const TextStyle(color: amber)),
                          const SizedBox(height: 20),
                          const Text(
                            '普通玩家注册不会获得后台权限。管理员须先为账号分配制作、审核或发布角色。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xff64748b),
                              height: 1.7,
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
        ),
      ),
    ),
  );
  Widget pageHeading(
    String title,
    String description, {
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 24,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(description, style: const TextStyle(color: Color(0xff64748b))),
          ],
        ),
        ?action,
      ],
    ),
  );
  Widget box(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xffe5e7eb)),
    ),
    child: child,
  );
  Widget metric(String label, String value, IconData icon) => SizedBox(
    width: 220,
    child: box(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Color(0xff64748b)),
                ),
              ),
              Icon(icon, color: amber, size: 20),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
  Widget dashboard() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      pageHeading(
        '工作概览',
        '内容、制作与运营进展，一处掌握。',
        action: OutlinedButton.icon(
          onPressed: busy ? null : () => run(loadWorkspace),
          icon: const Icon(Icons.refresh),
          label: const Text('刷新数据'),
        ),
      ),
      if (roles.contains('editor'))
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            metric('全部剧目', '${stories.length}', Icons.auto_stories_outlined),
            metric(
              '已发布剧目',
              '${stories.where((s) => s['current_version_id'] != null).length}',
              Icons.task_alt,
            ),
            metric('当前剧目版本', '${versions.length}', Icons.layers_outlined),
          ],
        ),
      const SizedBox(height: 24),
      box(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '工作入口',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (roles.contains('editor')) ...[
                  FilledButton.icon(
                    onPressed: () => navigatePage('stories'),
                    icon: const Icon(Icons.auto_stories_outlined),
                    label: const Text('管理剧目'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => navigatePage('assets'),
                    icon: const Icon(Icons.perm_media_outlined),
                    label: const Text('查看素材'),
                  ),
                ],
                if (roles.contains('reviewer'))
                  OutlinedButton.icon(
                    onPressed: () => navigatePage('reports'),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('处理举报'),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('制作流程', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            const Text(
              '创建草稿 → 配置内容与素材 → 自动验证 → 多角色试玩 → 审核确认 → 冻结发布',
              style: TextStyle(color: Color(0xff64748b), height: 1.8),
            ),
          ],
        ),
      ),
      if (roles.contains('reviewer')) ...[
        const SizedBox(height: 24),
        box(
          OperationsPanel(
            key: ValueKey(dashboardGeneration),
            load: () => overview ??= api('GET', '/v1/admin/operations'),
          ),
        ),
      ],
      const SizedBox(height: 24),
      box(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('当前权限', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final role in roles)
                  Chip(
                    label: Text(
                      {
                            'editor': '内容制作',
                            'reviewer': '内容审核',
                            'publisher': '发布管理',
                          }[role] ??
                          role,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
  Future<void> openStory(dynamic story) async {
    storyId = story['story_id'];
    versions = (await api(
      'GET',
      '/v1/admin/stories/$storyId/versions',
    ))['items'];
    version = preview = null;
    editor.clear();
    if (versions.isNotEmpty) {
      id.text = versions.first['version_id'];
      await load();
    } else {
      id.clear();
    }
    page = 'editor';
    status = '';
  }

  Widget storyDirectory() {
    final rows = stories
        .where(
          (s) => s['title'].toString().toLowerCase().contains(
            search.text.trim().toLowerCase(),
          ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        pageHeading(
          '剧目管理',
          '管理展示信息，进入工作室编辑与发布。',
          action: FilledButton.icon(
            onPressed: busy ? null : createStory,
            icon: const Icon(Icons.add),
            label: const Text('新建剧目'),
          ),
        ),
        box(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '搜索剧目名称',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 20),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Text('没有匹配的剧目。'),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('剧目名称')),
                      DataColumn(label: Text('题材 / 难度')),
                      DataColumn(label: Text('人数')),
                      DataColumn(label: Text('发布状态')),
                      DataColumn(label: Text('操作')),
                    ],
                    rows: rows
                        .map(
                          (s) => DataRow(
                            cells: [
                              DataCell(
                                SizedBox(
                                  width: 250,
                                  child: Text(
                                    s['title'],
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              DataCell(
                                Text(
                                  '${categoryLabels[s['category']] ?? '悬疑推理'} / ${difficultyLabels[s['difficulty']] ?? '新手友好'}',
                                ),
                              ),
                              DataCell(Text('${s['seat_count']} 人')),
                              DataCell(
                                Chip(
                                  label: Text(
                                    s['current_version_id'] == null
                                        ? '未发布'
                                        : '已发布',
                                  ),
                                ),
                              ),
                              DataCell(
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => run(() => openStory(s)),
                                      child: const Text('编辑内容'),
                                    ),
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => metadata(s),
                                      child: const Text('展示设置'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                        .toList(),
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                '共 ${rows.length} 个剧目',
                style: const TextStyle(color: Color(0xff64748b)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const categoryLabels = {
    'mystery': '悬疑推理',
    'emotion': '情感沉浸',
    'scifi': '科幻想象',
    'adventure': '冒险探索',
  };
  static const difficultyLabels = {
    'beginner': '新手友好',
    'intermediate': '进阶挑战',
    'advanced': '深度推理',
  };
  Future<void> metadata(dynamic story) async {
    var category = story['category'] as String? ?? 'mystery',
        difficulty = story['difficulty'] as String? ?? 'beginner';
    final summary = TextEditingController(text: story['summary']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${story['title']} · 展示设置'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: '故事分类'),
                items: categoryLabels.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: (v) => category = v!,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: difficulty,
                decoration: const InputDecoration(labelText: '难度'),
                items: difficultyLabels.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: (v) => difficulty = v!,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: summary,
                maxLength: 1000,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '故事简介'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('保存展示信息'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await run(() async {
        await api('PUT', '/v1/admin/stories/${story['story_id']}/metadata', {
          'category': category,
          'difficulty': difficulty,
          'summary': summary.text.trim(),
          'command_id': const Uuid().v4(),
        });
        stories = (await api('GET', '/v1/admin/stories'))['items'];
        status = '展示信息已保存。';
      });
    }
    summary.dispose();
  }

  Widget assetsPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      pageHeading(
        '素材库',
        '已上传文件与处理状态。进入内容工作室上传、配置字幕或使用素材。',
        action: OutlinedButton.icon(
          onPressed: () =>
              setState(() => assetData = api('GET', '/v1/admin/assets')),
          icon: const Icon(Icons.refresh),
          label: const Text('刷新'),
        ),
      ),
      box(
        FutureBuilder<dynamic>(
          future: assetData ??= api('GET', '/v1/admin/assets'),
          builder: (c, s) {
            if (s.hasError) return Text('读取失败：${s.error}');
            if (!s.hasData) return const LinearProgressIndicator();
            final items = s.data['items'] as List;
            if (items.isEmpty) return const Text('暂无素材。请在内容工作室的素材制作区域上传文件。');
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('文件名')),
                  DataColumn(label: Text('状态')),
                  DataColumn(label: Text('格式')),
                  DataColumn(label: Text('时长')),
                  DataColumn(label: Text('来源说明')),
                ],
                rows: items
                    .map(
                      (a) => DataRow(
                        cells: [
                          DataCell(
                            SizedBox(
                              width: 260,
                              child: Text(
                                a['filename'] ?? '素材',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            Chip(
                              label: Text(
                                {
                                      'ready': '已就绪',
                                      'processing': '处理中',
                                      'uploading': '待上传',
                                      'failed': '处理失败',
                                    }[a['status']] ??
                                    a['status'],
                              ),
                            ),
                          ),
                          DataCell(Text(a['mime_type'] ?? '—')),
                          DataCell(
                            Text(
                              a['duration_ms'] == null
                                  ? '—'
                                  : '${(a['duration_ms'] / 1000).round()} 秒',
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 220,
                              child: Text(
                                a['rights_source'] ?? '尚未填写',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: () => navigatePage('editor'),
        child: const Text('进入内容工作室'),
      ),
    ],
  );
  Widget reportsPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      pageHeading('举报审核', '查看待处理举报，按规则保留、移除或驳回。'),
      box(
        ReportPanel(
          load: () => api('GET', '/v1/admin/chat/reports'),
          review: (id, outcome) => api('POST', '/v1/admin/chat/reports/$id', {
            'command_id': const Uuid().v4(),
            'status': outcome == 'remove' ? 'resolved' : outcome,
            'remove_message': outcome == 'remove',
          }),
        ),
      ),
    ],
  );
  Future<void> editRoles(dynamic user) async {
    final selected = Set<String>.from(user['roles'] as List? ?? []);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, state) => AlertDialog(
          title: Text('${user['display_name']} · 后台权限'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('授予的角色决定账号可访问的后台功能。保存后该用户已有后台会话将退出，玩家账号不受影响。'),
                for (final entry in {
                  'editor': '内容制作',
                  'reviewer': '内容审核',
                  'publisher': '发布与权限管理',
                }.entries)
                  CheckboxListTile(
                    title: Text(entry.value),
                    value: selected.contains(entry.key),
                    onChanged: (v) => state(() {
                      if (v == true) {
                        selected.add(entry.key);
                      } else {
                        selected.remove(entry.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('保存权限'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await run(() async {
        await api('POST', '/v1/admin/users/${user['user_id']}/roles', {
          'roles': selected.toList(),
          'command_id': const Uuid().v4(),
        });
        if (user['user_id'] == adminProfile?['user_id']) {
          clearLocalSession();
          status = '权限已更新，请重新登录。';
        } else {
          userData = api('GET', '/v1/admin/users');
          status = '后台权限已更新。';
        }
      });
    }
  }

  Widget usersPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      pageHeading(
        '用户目录',
        '最近注册账号及游客概览，最多显示 100 条；不展示密码或凭证。',
        action: OutlinedButton.icon(
          onPressed: () =>
              setState(() => userData = api('GET', '/v1/admin/users')),
          icon: const Icon(Icons.refresh),
          label: const Text('刷新'),
        ),
      ),
      box(
        FutureBuilder<dynamic>(
          future: userData ??= api('GET', '/v1/admin/users'),
          builder: (c, s) {
            if (s.hasError) return Text('读取失败：${s.error}');
            if (!s.hasData) return const LinearProgressIndicator();
            final items = s.data['items'] as List;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  const DataColumn(label: Text('昵称')),
                  const DataColumn(label: Text('账号')),
                  const DataColumn(label: Text('身份')),
                  const DataColumn(label: Text('状态')),
                  const DataColumn(label: Text('参与房间')),
                  const DataColumn(label: Text('后台权限')),
                  if (roles.contains('publisher'))
                    const DataColumn(label: Text('操作')),
                ],
                rows: items
                    .map(
                      (u) => DataRow(
                        cells: [
                          DataCell(Text(u['display_name'])),
                          DataCell(Text(u['username'] ?? '—')),
                          DataCell(Text(u['username'] == null ? '游客' : '正式账号')),
                          DataCell(
                            Text(u['status'] == 'active' ? '正常' : '已注销'),
                          ),
                          DataCell(Text('${u['room_count']}')),
                          DataCell(
                            Text(
                              (u['roles'] as List? ?? [])
                                  .map(
                                    (r) =>
                                        {
                                          'editor': '制作',
                                          'reviewer': '审核',
                                          'publisher': '发布',
                                        }[r] ??
                                        r,
                                  )
                                  .join(' / '),
                            ),
                          ),
                          if (roles.contains('publisher'))
                            DataCell(
                              TextButton(
                                onPressed:
                                    busy ||
                                        u['username'] == null ||
                                        u['status'] != 'active'
                                    ? null
                                    : () => editRoles(u),
                                child: const Text('分配权限'),
                              ),
                            ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget editorWorkspace() => Scaffold(
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
                style: TextStyle(color: Color(0xff64748b)),
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
                    FilledButton(
                      onPressed: busy || !roles.contains('editor')
                          ? null
                          : createStory,
                      child: const Text('创建剧目'),
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
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff64748b),
                    ),
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
                    onSelectionChanged: (s) {
                      setState(() => workspace = s.first);
                      syncRoute();
                    },
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
                  if (workspace == 'content' &&
                      roles.contains('editor') &&
                      version!['status'] != 'published')
                    ProductionPanel(
                      key: ValueKey('production:${id.text}:$revision'),
                      api: (method, path, [body]) => api(method, path, body),
                      versionId: id.text,
                      revision: revision,
                      graph: Map<String, dynamic>.from(version!['graph']),
                      onGraph: (graph) => setState(() {
                        version!['graph'] = graph;
                        editor.text = const JsonEncoder.withIndent('  ')
                            .convert(graph);
                      }),
                      onReload: () async {
                        await load();
                        if (mounted) setState(() {});
                      },
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
