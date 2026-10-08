import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi_creator/narrative_panel.dart';
import 'package:ruxi_creator/rule_editor.dart';

void main() {
  testWidgets('private role copy changes only the selected author field', (
    tester,
  ) async {
    Map<String, dynamic>? edited;
    final graph = <String, dynamic>{
      'roles': ['investigator'],
      'variables': <String, dynamic>{},
      'decision': {
        'options': ['leave'],
      },
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NarrativePanel(graph: graph, onChanged: (v) => edited = v),
          ),
        ),
      ),
    );
    await tester.tap(find.text('角色文字与私有信息'));
    await tester.pumpAndSettle();
    final target = find.widgetWithText(TextFormField, 'investigator · 私有角色介绍');
    await tester.enterText(target, '作者配置的私有文字');
    expect(
      edited!['role_definitions']['investigator']['description'],
      '作者配置的私有文字',
    );
    expect(edited!['roles'], graph['roles']);
    expect(edited!['decision'], graph['decision']);
  });
  testWidgets('malformed AST condition remains reviewable without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConditionEditor(
            value: const {},
            clues: const ['C1'],
            variables: const {},
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('条件结构不完整'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
