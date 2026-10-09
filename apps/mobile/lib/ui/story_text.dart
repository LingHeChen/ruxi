import 'package:flutter/material.dart';

/// Small authored vocabulary: **important fact**, ==evidence==, and clock times.
/// Everything else is literal text; no HTML or remotely loaded content is parsed.
final _emphasis = RegExp(
  r'\*\*([^*\n]+)\*\*|==([^=\n]+)==|\b(?:[01]?\d|2[0-3]):[0-5]\d\b',
);

List<TextSpan> storySpans(String text, {int? visibleCharacters}) {
  final spans = <TextSpan>[];
  var remaining = visibleCharacters;
  void add(String value, Color? color) {
    final chars = value.characters;
    final shown = remaining == null
        ? value
        : chars.take(remaining!.clamp(0, chars.length)).join();
    if (shown.isNotEmpty) {
      spans.add(
        TextSpan(
          text: shown,
          style: color == null
              ? null
              : TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      );
    }
    if (remaining != null) {
      remaining = (remaining! - chars.length).clamp(0, 1 << 30);
    }
  }

  var cursor = 0;
  for (final match in _emphasis.allMatches(text)) {
    add(text.substring(cursor, match.start), null);
    add(
      match.group(1) ?? match.group(2) ?? match.group(0)!,
      match.group(2) != null
          ? const Color(0xffa8d7d0)
          : const Color(0xffefd09a),
    );
    cursor = match.end;
  }
  add(text.substring(cursor), null);
  return spans;
}

String storyPlainText(String text) =>
    storySpans(text).map((s) => s.text ?? '').join();

class StoryText extends StatelessWidget {
  const StoryText(this.text, {super.key, this.style, this.visibleCharacters});
  final String text;
  final TextStyle? style;
  final int? visibleCharacters;
  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(children: storySpans(text, visibleCharacters: visibleCharacters)),
    style: style,
  );
}
