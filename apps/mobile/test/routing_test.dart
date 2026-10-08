import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/main.dart';
import 'package:ruxi/data/room_client.dart';

import 'catalog_test.dart' show CatalogClient;

class RouteClient extends CatalogClient {
  String? entered;
  @override
  Future<void> enter(String id, {bool takeover = false}) async {
    entered = roomId = id;
    connection = 'live';
    notifyListeners();
  }

  @override
  Future<void> backToCatalog() async {
    roomId = null;
    notifyListeners();
  }

  @override
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    bool private = false,
    bool retried = false,
  ]) async {
    if (path.startsWith('/v1/stories/')) return stories.last;
    return super.request(method, path, body, private, retried);
  }
}

void main() {
  testWidgets('URL restores personal space and navigation updates route', (
    tester,
  ) async {
    final router = playerRouter(
      client: RouteClient(),
      autoInitialize: false,
      initialLocation: '/me',
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('登录账号'), findsOneWidget);
    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/discover');
    expect(find.text('寻找你的下一场故事'), findsOneWidget);
    router.go('/me');
    await tester.pumpAndSettle();
    expect(find.text('登录账号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
  testWidgets(
    'direct room URL reenters original room without creating another',
    (tester) async {
      final client = RouteClient()..token = 'test';
      final router = playerRouter(
        client: client,
        autoInitialize: false,
        initialLocation: '/rooms/room-id',
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.entered, 'room-id');
      expect(router.routeInformationProvider.value.uri.path, '/rooms/room-id');
      router.go('/discover');
      await tester.pumpAndSettle();
      expect(client.roomId, isNull);
      expect(find.text('寻找你的下一场故事'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    },
  );
  testWidgets(
    'direct story URL loads detail and filter URL restores category',
    (tester) async {
      final client = RouteClient();
      final router = playerRouter(
        client: client,
        autoInitialize: false,
        initialLocation: '/stories/new-story',
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(find.text('4 名角色 · 私人房间 · 10–15 分钟'), findsOneWidget);
      await tester.tap(find.text('返回剧目列表'));
      await tester.pumpAndSettle();
      router.go('/discover?category=scifi&q=星空&seats=4');
      await tester.pumpAndSettle();
      expect(client.lastSearch, contains('category=scifi'));
      expect(client.lastSearch, contains('seats=4'));
      expect(find.text('星空'), findsOneWidget);
      expect(find.text('另一段原创故事'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      // Reconstructing the app at the same URL models reload without old widget state.
      final restored = playerRouter(
        client: RouteClient(),
        autoInitialize: false,
        initialLocation: '/discover?category=scifi&q=星空&seats=4',
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: restored));
      await tester.pumpAndSettle();
      expect(find.text('星空'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      restored.dispose();
    },
  );
}
