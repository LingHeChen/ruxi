import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';

import 'data/room_client.dart';
import 'ui/portal.dart';
import 'ui/c2_stage.dart';

const amber = Color(0xffd8b678);
const surface = Color(0xff1b2125);
const muted = Color(0xffb0b7bd);
ThemeData playerTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xff111918),
  colorScheme: ColorScheme.fromSeed(
    seedColor: amber,
    brightness: Brightness.dark,
    surface: const Color(0xff1a2522),
    primary: amber,
  ),
  fontFamily: 'PingFang SC',
  cardTheme: CardThemeData(
    color: const Color(0xff1b2823),
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Color(0xff35443d)),
    ),
  ),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  runApp(const RuxiApp());
}

GoRouter playerRouter({
  RoomClient? client,
  bool autoInitialize = true,
  String? initialLocation,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(path: '/worlds', redirect: (context, state) => '/discover'),
    GoRoute(
      path: '/world-rooms/:roomId',
      redirect: (context, state) => '/rooms/${state.pathParameters['roomId']}',
    ),
    GoRoute(
      path: '/rooms/:roomId',
      builder: (context, state) => C2Stage(
        key: ValueKey(state.pathParameters['roomId']),
        roomId: state.pathParameters['roomId'],
        identity: client,
        autoInitialize: autoInitialize,
      ),
    ),
    ShellRoute(
      builder: (context, state, child) => Home(
        key: const ValueKey('player-shell'),
        client: client,
        autoInitialize: autoInitialize,
        route: state.uri,
      ),
      routes: [
        for (final path in [
          '/',
          '/discover',
          '/rooms',
          '/me',
          '/stories/:storyId',
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
            onPressed: () => context.go('/'),
            child: const Text('返回首页'),
          ),
        ],
      ),
    ),
  ),
);

class RuxiApp extends StatefulWidget {
  const RuxiApp({super.key});
  @override
  State<RuxiApp> createState() => _RuxiAppState();
}

class _RuxiAppState extends State<RuxiApp> {
  late final router = playerRouter();
  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: '入戏 · 原创互动故事',
    debugShowCheckedModeBanner: false,
    theme: playerTheme(),
    routerConfig: router,
  );
}

class Home extends StatefulWidget {
  const Home({super.key, this.autoInitialize = true, this.client, this.route});
  final bool autoInitialize;
  final RoomClient? client;
  final Uri? route;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late final client = widget.client ?? RoomClient();
  int section = 0;
  bool initialized = false;
  static const paths = ['/', '/discover', '/rooms', '/me'];
  @override
  void initState() {
    super.initState();
    client.addListener(changed);
    unawaited(initialize());
  }

  Future<void> initialize() async {
    if (widget.autoInitialize) await client.initialize();
    client.roomId = null;
    initialized = true;
    syncRoute();
  }

  @override
  void didUpdateWidget(Home old) {
    super.didUpdateWidget(old);
    if (widget.route != old.route) syncRoute();
  }

  void syncRoute() {
    final index = paths.indexOf(widget.route?.path ?? '/');
    if (mounted) setState(() => section = index < 0 ? 1 : index);
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
    if (initialized && client.roomId != null && widget.route != null) {
      context.go('/rooms/${client.roomId}');
    }
  }

  void navigate(int index) {
    if (widget.route != null) {
      context.go(paths[index]);
    } else {
      setState(() => section = index);
    }
  }

  @override
  void dispose() {
    client.removeListener(changed);
    if (widget.client == null) client.dispose();
    super.dispose();
  }

  Future<void> recovery() async {
    final input = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复游客身份'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(labelText: '恢复码'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, input.text),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    input.dispose();
    if (code != null) await client.recover(code);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: wide ? 86 : 68,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '入戏',
              style: TextStyle(
                fontFamily: 'Songti SC',
                fontSize: 30,
                letterSpacing: 5,
              ),
            ),
            if (wide) ...[
              const SizedBox(width: 20),
              const Text(
                '让故事发生',
                style: TextStyle(fontSize: 12, color: muted, letterSpacing: 2),
              ),
            ],
          ],
        ),
        actions: [
          if (wide)
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton(
                  onPressed: () => navigate(i),
                  child: Text(
                    ['首页', '发现', '房间', '我的'][i],
                    style: TextStyle(color: section == i ? amber : muted),
                  ),
                ),
              ),
          if (!wide)
            IconButton(
              tooltip: '个人空间',
              onPressed: () => navigate(3),
              icon: const Icon(Icons.person_outline),
            ),
          const SizedBox(width: 20),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: section,
              onDestinationSelected: navigate,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  label: '首页',
                ),
                NavigationDestination(
                  icon: Icon(Icons.explore_outlined),
                  label: '发现',
                ),
                NavigationDestination(
                  icon: Icon(Icons.meeting_room_outlined),
                  label: '房间',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  label: '我的',
                ),
              ],
            ),
      body: SafeArea(
        child: Column(
          children: [
            if (client.status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  client.status,
                  style: const TextStyle(color: amber),
                ),
              ),
            Expanded(
              child: client.busy
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1280),
                          child: Padding(
                            padding: EdgeInsets.all(wide ? 32 : 20),
                            child: Portal(
                              client: client,
                              section: section,
                              onSection: navigate,
                              onRecovery: () => unawaited(recovery()),
                              storyId:
                                  widget.route?.pathSegments.firstOrNull ==
                                      'stories'
                                  ? widget.route!.pathSegments.last
                                  : null,
                              onStory: widget.route == null
                                  ? null
                                  : (id) => context.go('/stories/$id'),
                              query: widget.route?.path == '/discover'
                                  ? widget.route!.queryParameters
                                  : null,
                              onFilter: widget.route == null
                                  ? null
                                  : (query) => context.go(
                                      Uri(
                                        path: '/discover',
                                        queryParameters: query.isEmpty
                                            ? null
                                            : query,
                                      ).toString(),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
