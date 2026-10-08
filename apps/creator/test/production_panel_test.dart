import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi_creator/production_panel.dart';

void main() {
  testWidgets(
    'processing assets update automatically and stop polling once ready',
    (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProductionPanel(
                versionId: 'version',
                revision: 1,
                graph: const {'assets': []},
                onGraph: (_) {},
                onReload: () async {},
                api: (method, path, [body]) async {
                  reads++;
                  return {
                    'items': [
                      {
                        'filename': '原创视频.mp4',
                        'status': reads == 1 ? 'processing' : 'ready',
                      },
                    ],
                  };
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('正在转码'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('可以使用'), findsOneWidget);
      expect(reads, 2);
      await tester.pump(const Duration(seconds: 15));
      expect(reads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
