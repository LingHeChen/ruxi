import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi_creator/report_panel.dart';

void main() {
  testWidgets(
    'reviewer can disposition a reported message without exposing room secrets',
    (tester) async {
      final decisions = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportPanel(
              load: () async => {
                'items': [
                  {
                    'report_id': 'report-1',
                    'reason': 'spam',
                    'message_text': '主动提交审核的消息',
                  },
                ],
              },
              review: (id, outcome) async {
                decisions.add('$id:$outcome');
                return {};
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('主动提交审核的消息'), findsOneWidget);
      await tester.tap(find.text('标记已处理'));
      await tester.pumpAndSettle();
      expect(decisions, ['report-1:resolved']);
      expect(find.text('暂无待处理举报'), findsOneWidget);
    },
  );
}
