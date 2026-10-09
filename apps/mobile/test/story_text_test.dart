import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:ruxi/ui/story_text.dart';

void main() {
  test(
    'authored emphasis and time anchors preserve words and style during typing',
    () {
      const text = '问**江临**：==原始护理页==记着22:10。';
      final plain = storyPlainText(text);
      expect(plain, '问江临：原始护理页记着22:10。');
      for (var i = 0; i <= plain.characters.length; i++) {
        expect(
          storySpans(text, visibleCharacters: i).map((s) => s.text).join(),
          plain.characters.take(i).join(),
        );
      }
      final spans = storySpans(text);
      expect(spans.firstWhere((s) => s.text == '江临').style?.color, isNotNull);
      expect(
        spans.firstWhere((s) => s.text == '原始护理页').style?.color,
        isNot(spans.firstWhere((s) => s.text == '江临').style?.color),
      );
      expect(
        spans.firstWhere((s) => s.text == '22:10').style?.color,
        isNotNull,
      );
    },
  );
  test('literal content and grapheme clusters are not interpreted as HTML or split', () {
    const text = '<b>没有标记</b> 👨‍👩‍👧‍👦 **证据**';
    final plain = storyPlainText(text);
    expect(plain, '<b>没有标记</b> 👨‍👩‍👧‍👦 证据');
    for (var i = 0; i <= plain.characters.length; i++) {
      expect(
        storySpans(text, visibleCharacters: i).map((s) => s.text).join(),
        plain.characters.take(i).join(),
      );
    }
    expect(storyPlainText('**未闭合 ==文本'), '**未闭合 ==文本');
  });
}
