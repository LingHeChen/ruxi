import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ruxi_creator/main.dart';
import 'package:ruxi_creator/session_store_stub.dart';

class MemorySession extends SessionStore {
  final values = {'access': 'test-admin', 'refresh': 'test-refresh'};
  @override
  String? read(String key) => values[key];
  @override
  void write(String key, String value) {
    values[key] = value;
  }

  @override
  void clear() => values.clear();
}

MockClient fixture({bool reviewerOnly = false, List<String>? requests}) =>
    MockClient((request) async {
      final path = request.url.path;
      requests?.add(path);
      dynamic data;
      if (path == '/v1/admin/me') {
        data = {
          'display_name': '内容管理员',
          'roles': reviewerOnly
              ? ['reviewer']
              : ['editor', 'reviewer', 'publisher'],
        };
      } else if (path == '/v1/admin/stories') {
        data = {
          'items': [
            {
              'story_id': 'demo',
              'title': '末班车的第七位乘客',
              'summary': '原创悬疑故事',
              'seat_count': 3,
              'category': 'mystery',
              'difficulty': 'beginner',
              'current_version_id': 'version',
            },
          ],
        };
      } else if (path.endsWith('/versions')) {
        data = {'items': []};
      } else if (path == '/v1/admin/assets') {
        data = {
          'items': [
            {
              'filename': '片头.mp4',
              'status': 'ready',
              'mime_type': 'video/mp4',
              'duration_ms': 16000,
              'rights_source': '原创素材',
            },
          ],
        };
      } else if (path == '/v1/admin/operations') {
        data = {
          'outbox_pending': 0,
          'oldest_outbox_age_ms': 0,
          'runtime': {'memory_bytes': 10485760},
          'rooms': [
            {'lifecycle': 'finished', 'count': 3},
          ],
          'work': [],
          'outcomes': [],
        };
      } else if (path == '/v1/admin/users') {
        data = {
          'items': [
            {
              'display_name': '故事旅人',
              'username': 'traveler',
              'status': 'active',
              'room_count': 2,
            },
          ],
        };
      } else if (path == '/v1/admin/chat/reports') {
        data = {'items': []};
      } else if (path.endsWith('/metadata')) {
        data = {'updated': true};
      } else if (path.endsWith('/logout')) {
        data = {'revoked': true};
      } else {
        return http.Response(
          jsonEncode({
            'error': {'code': 'RESOURCE_NOT_FOUND'},
          }),
          404,
        );
      }
      return http.Response(
        jsonEncode({'data': data}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
void main() {
  testWidgets(
    'desktop admin navigation loads real sections and metadata controls',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Creator(
            httpClient: fixture(requests: requests),
            sessionStore: MemorySession(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('工作概览'), findsNWidgets(2));
      expect(find.text('1'), findsNWidgets(2));
      await tester.tap(find.text('刷新数据'));
      await tester.pumpAndSettle();
      expect(requests.where((p) => p == '/v1/admin/operations').length, 2);
      await tester.tap(find.text('剧目管理'));
      await tester.pumpAndSettle();
      expect(find.text('末班车的第七位乘客'), findsOneWidget);
      await tester.tap(find.text('展示设置'));
      await tester.pumpAndSettle();
      expect(find.text('故事分类'), findsOneWidget);
      expect(find.text('故事简介'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('素材库'));
      await tester.pumpAndSettle();
      expect(find.text('片头.mp4'), findsOneWidget);
      await tester.tap(find.text('用户目录'));
      await tester.pumpAndSettle();
      expect(find.text('traveler'), findsOneWidget);
      await tester.tap(find.text('举报审核'));
      await tester.pumpAndSettle();
      expect(find.text('暂无待处理举报'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'review-only admin avoids forbidden editor APIs and logout clears session',
    (tester) async {
      final store = MemorySession();
      await tester.pumpWidget(
        MaterialApp(
          home: Creator(
            httpClient: fixture(reviewerOnly: true),
            sessionStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('管理剧目'), findsNothing);
      expect(find.text('工作概览'), findsOneWidget);
      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();
      expect(find.text('登录创作与运营中心'), findsOneWidget);
      expect(store.values, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
