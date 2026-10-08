import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/room_client.dart';
import 'package:ruxi/main.dart';

class CatalogClient extends RoomClient {
  String? createdStory;
  @override
  Future<void> create(String story) async {
    createdStory = story;
  }
}

void main() {
  testWidgets(
    'published story selection changes the displayed story and room creation target',
    (tester) async {
      final client = CatalogClient()
        ..stories = [
          {
            'story_id': '11111111-1111-4111-8111-111111111111',
            'title': '末班车的第七位乘客',
            'summary': '三人故事',
            'seat_count': 3,
          },
          {
            'story_id': 'new-story',
            'title': '另一段原创故事',
            'summary': '四位朋友的协作故事。',
            'seat_count': 4,
          },
        ];
      await tester.pumpWidget(
        MaterialApp(home: Home(autoInitialize: false, client: client)),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另一段原创故事').last);
      await tester.pumpAndSettle();
      expect(find.text('四位朋友的协作故事。'), findsOneWidget);
      expect(find.text('4 名角色 · 私人房间'), findsOneWidget);
      await tester.ensureVisible(find.text('创建房间'));
      await tester.tap(find.text('创建房间'));
      await tester.pump();
      expect(client.createdStory, 'new-story');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
