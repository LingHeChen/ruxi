import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:ruxi_creator/main.dart';
import 'package:ruxi_creator/content_panel.dart';

void main() {
  testWidgets('creator supports account and controlled code login', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Creator()));
    await tester.pumpAndSettle();
    expect(find.text('登录创作与运营中心'), findsOneWidget);
    expect(find.text('管理员账号'), findsOneWidget);
    await tester.tap(find.text('使用一次性登录码'));
    await tester.pumpAndSettle();
    expect(find.text('一次性登录码'), findsOneWidget);
  });
  testWidgets(
    'incomplete draft stays editable without crashing structured view',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentPanel(
              graph: {'story_id': 'test', 'title': '未完成草稿'},
              readOnly: false,
              onTitle: (_) {},
              onGraph: (_) {},
              formKey: GlobalKey<FormState>(),
            ),
          ),
        ),
      );
      expect(find.textContaining('此草稿的结构尚不完整'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
