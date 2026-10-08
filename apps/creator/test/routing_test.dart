import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi_creator/main.dart';

import 'workspace_test.dart' show fixture, MemorySession;

void main() {
  testWidgets('direct admin URL restores page and sidebar changes URL', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = creatorRouter(
      httpClient: fixture(),
      sessionStore: MemorySession(),
      initialLocation: '/assets',
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('片头.mp4'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/assets');
    await tester.tap(find.text('用户目录'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/users');
    expect(find.text('traveler'), findsOneWidget);
    router.go('/stories');
    await tester.pumpAndSettle();
    expect(find.text('末班车的第七位乘客'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    final restored = creatorRouter(
      httpClient: fixture(),
      sessionStore: MemorySession(),
      initialLocation: '/users',
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: restored));
    await tester.pumpAndSettle();
    expect(find.text('traveler'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    restored.dispose();
  });
  testWidgets(
    'editor deep link loads specified version and workspace after reconstruction',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final graph = jsonDecode(
        File('../../content/demo/story.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      graph['title'] = '路由指定剧本';
      final fallback = fixture();
      final requests = <String>[];
      final transport = MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/v1/admin/versions/deep-version') {
          return http.Response(
            jsonEncode({
              'data': {
                'version_id': 'deep-version',
                'revision': 7,
                'hash': 'test-hash',
                'status': 'draft',
                'graph': graph,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final forwarded = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await fallback.send(forwarded));
      });
      final router = creatorRouter(
        httpClient: transport,
        sessionStore: MemorySession(),
        initialLocation: '/editor/deep-version?workspace=advanced',
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(requests, contains('/v1/admin/versions/deep-version'));
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/editor/deep-version?workspace=advanced',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              (widget.controller?.text.contains('路由指定剧本') ?? false),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      transport.close();
      fallback.close();
    },
  );
}
