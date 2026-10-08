import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/room_client.dart';
import 'package:ruxi/main.dart';

class CatalogClient extends RoomClient {
  String? createdStory;
  String? lastSearch;
  CatalogClient() {
    stories = [
      {
        'story_id': '11111111-1111-4111-8111-111111111111',
        'title': '末班车的第七位乘客',
        'summary': '三人故事',
        'seat_count': 3,
        'category': 'mystery',
        'difficulty': 'beginner',
      },
      {
        'story_id': 'new-story',
        'title': '另一段原创故事',
        'summary': '四位朋友的协作故事。',
        'seat_count': 4,
        'category': 'scifi',
        'difficulty': 'intermediate',
      },
    ];
  }
  @override
  Future<void> create(String story) async {
    createdStory = story;
  }

  @override
  Future<dynamic> request(
    String method,
    String path, [
    Json? body,
    bool private = false,
    bool retried = false,
  ]) async {
    lastSearch = path;
    final q = Uri.parse(path).queryParameters;
    final filtered = stories
        .where(
          (s) =>
              (q['category']?.isEmpty ?? true) ||
              s['category'] == q['category'],
        )
        .toList();
    return {'items': filtered, 'total': filtered.length, 'next_cursor': null};
  }
}

void main() {
  testWidgets(
    'home discovers stories before creating; detail creates selected story',
    (tester) async {
      final client = CatalogClient();
      await tester.pumpWidget(
        MaterialApp(home: Home(autoInitialize: false, client: client)),
      );
      expect(find.text('把今晚，交给一个好故事。'), findsOneWidget);
      expect(find.text('创建房间'), findsNothing);
      await tester.ensureVisible(find.text('另一段原创故事'));
      await tester.tap(find.text('另一段原创故事'));
      await tester.pumpAndSettle();
      expect(find.text('4 名角色 · 私人房间 · 10–15 分钟'), findsOneWidget);
      await tester.tap(find.text('创建房间'));
      await tester.pumpAndSettle();
      expect(client.createdStory, 'new-story');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('category routes to searchable catalog with real API filter', (
    tester,
  ) async {
    final client = CatalogClient();
    await tester.pumpWidget(
      MaterialApp(home: Home(autoInitialize: false, client: client)),
    );
    await tester.ensureVisible(find.text('科幻想象'));
    await tester.tap(find.text('科幻想象'));
    await tester.pumpAndSettle();
    expect(client.lastSearch, contains('category=scifi'));
    expect(find.text('寻找你的下一场故事'), findsOneWidget);
    expect(find.text('另一段原创故事'), findsOneWidget);
    expect(find.text('末班车的第七位乘客'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('personal space provides login, registration and validation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Home(autoInitialize: false, client: CatalogClient())),
    );
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('登录账号'), findsOneWidget);
    await tester.tap(find.text('注册新账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建账号'));
    await tester.pumpAndSettle();
    expect(find.text('请输入昵称'), findsOneWidget);
    expect(find.text('账号格式不正确'), findsOneWidget);
    expect(find.text('密码至少 10 个字符'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('personal space shows own favorites and participation records', (
    tester,
  ) async {
    final client = CatalogClient()
      ..token = 'test-session'
      ..profile = {
        'display_name': '故事旅人',
        'username': 'traveler',
        'is_guest': false,
        'bio': '喜欢悬疑',
      };
    client.favorites = [client.stories.last];
    client.rooms = [
      {
        'room_id': 'fixture',
        'title': '末班车的第七位乘客',
        'lifecycle': 'finished',
        'updated_at': '2026-10-08T00:00:00Z',
        'can_resume': false,
      },
    ];
    await tester.pumpWidget(
      MaterialApp(home: Home(autoInitialize: false, client: client)),
    );
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('故事旅人'), findsOneWidget);
    expect(find.text('我的收藏'), findsNWidgets(2));
    expect(find.text('修改密码'), findsOneWidget);
    expect(find.text('另一段原创故事'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
