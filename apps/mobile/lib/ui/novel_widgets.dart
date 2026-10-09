import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/room_client.dart';
import 'story_text.dart';

const novelGold = Color(0xffdcc18d);

class NovelMessage {
  const NovelMessage({
    required this.title,
    required this.text,
    this.subtitle,
    this.acknowledge = const [],
    this.round,
    this.clue = false,
    this.confirm = false,
    this.ending = false,
    this.illustration,
    this.choices = const [],
  });
  final String title, text;
  final String? subtitle;
  final String? illustration;
  final List<Json> choices;
  final List<String> acknowledge;
  final int? round;
  final bool clue, confirm, ending;
}

Future<bool?> showNovelMessage(
  BuildContext context,
  NovelMessage message, {
  Future<String?> Function(Json)? onChoice,
  bool Function(Json)? choiceAvailable,
}) => showGeneralDialog<bool>(
  context: context,
  barrierDismissible: false,
  barrierLabel: '故事对话',
  barrierColor: const Color(0xb3071018),
  transitionDuration: MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 420),
  transitionBuilder: (context, animation, secondary, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, .035),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
  pageBuilder: (context, _, _) => message.round != null
      ? RoundTransition(message: message)
      : NovelReader(
          message: message,
          onChoice: onChoice,
          choiceAvailable: choiceAvailable,
        ),
);

class NovelPanel extends StatelessWidget {
  const NovelPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xf0152129),
      border: Border.all(color: const Color(0xff69726c), width: .6),
      borderRadius: BorderRadius.circular(6),
      boxShadow: const [
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 40,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: child,
  );
}

class NarrativeIllustration extends StatelessWidget {
  const NarrativeIllustration({
    super.key,
    required this.uri,
    required this.child,
  });
  final String? uri;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (uri == null) return child;
    final portrait = uri!.contains('/npc-');
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.asset(
        uri!,
        width: portrait ? (narrow ? 180 : 240) : double.infinity,
        height: portrait ? (narrow ? 270 : 360) : (narrow ? 180 : 260),
        fit: portrait ? BoxFit.contain : BoxFit.cover,
        semanticLabel: portrait ? '人物肖像，完整展示' : '当前剧情插图',
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
    if (portrait && !narrow) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          image,
          const SizedBox(width: 28),
          Expanded(child: child),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (portrait) Center(child: image) else image,
        const SizedBox(height: 22),
        child,
      ],
    );
  }
}

class NovelReader extends StatefulWidget {
  const NovelReader({
    super.key,
    required this.message,
    this.onChoice,
    this.choiceAvailable,
  });
  final NovelMessage message;
  final Future<String?> Function(Json)? onChoice;
  final bool Function(Json)? choiceAvailable;
  @override
  State<NovelReader> createState() => _NovelReaderState();
}

class _NovelReaderState extends State<NovelReader> {
  Timer? _typing;
  int _count = 0;
  bool _submitting = false;
  String? _error;
  late final _characters = storyPlainText(widget.message.text).characters
      .toList();
  bool get complete => _count >= _characters.length;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_typing != null || complete) return;
    if (MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.of(context).accessibleNavigation) {
      _count = _characters.length;
      return;
    }
    _typing = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _count = math.min(_count + 2, _characters.length));
      if (complete) timer.cancel();
    });
  }

  void reveal() {
    _typing?.cancel();
    setState(() => _count = _characters.length);
  }

  @override
  void dispose() {
    _typing?.cancel();
    super.dispose();
  }

  Future<void> select(Json choice) async {
    if (_submitting || widget.onChoice == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onChoice!(choice);
    } catch (_) {
      error = '这次选择尚未确认，请稍后查询操作结果。';
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _error = error;
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: m.illustration == null ? 720 : 880,
              maxHeight: MediaQuery.sizeOf(context).height * .9,
            ),
            child: Material(
              color: Colors.transparent,
              child: NovelPanel(
                child: Padding(
                  padding: EdgeInsets.all(narrow ? 22 : 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            m.clue
                                ? Icons.mark_email_read_outlined
                                : m.ending
                                ? Icons.wb_twilight
                                : Icons.auto_awesome,
                            color: novelGold,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              m.title,
                              style: const TextStyle(
                                fontFamily: 'Songti SC',
                                fontSize: 24,
                                color: novelGold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (m.subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            m.subtitle!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xffb4bcb8),
                              height: 1.7,
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      Flexible(
                        child: SingleChildScrollView(
                          child: NarrativeIllustration(
                            uri: m.illustration,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  onTap: reveal,
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight: m.choices.isEmpty ? 120 : 96,
                                    ),
                                    child: Semantics(
                                      label: storyPlainText(m.text),
                                      excludeSemantics: true,
                                      child: StoryText(
                                        m.text,
                                        visibleCharacters: _count,
                                        style: TextStyle(
                                          fontSize: narrow ? 16 : 18,
                                          height: 1.9,
                                          color: const Color(0xffeee7d8),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (m.clue)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 16),
                                    child: Text(
                                      '✧ 新线索已记入线索册',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: novelGold,
                                      ),
                                    ),
                                  ),
                                if (_error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: Text(
                                      _error!,
                                      style: const TextStyle(
                                        color: Color(0xffedb4a0),
                                        height: 1.7,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 24),
                                if (complete && m.choices.isNotEmpty) ...[
                                  const Text(
                                    '此刻，你会怎么做？',
                                    style: TextStyle(
                                      color: novelGold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  for (final choice in m.choices)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: OutlinedButton(
                                        onPressed:
                                            _submitting ||
                                                widget.onChoice == null ||
                                                !(widget.choiceAvailable?.call(
                                                      choice,
                                                    ) ??
                                                    choice['allowed_now'] ==
                                                        true)
                                            ? null
                                            : () => unawaited(select(choice)),
                                        style: OutlinedButton.styleFrom(
                                          alignment: Alignment.centerLeft,
                                          padding: const EdgeInsets.all(16),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text(
                                              '◇ ${choice['label']} · ${choice['cost']} 余力',
                                              style: const TextStyle(
                                                fontSize: 15,
                                                color: novelGold,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              choice['risk_text'] ?? '',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                height: 1.6,
                                                color: Color(0xffb6c0bd),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (_submitting)
                                    const Padding(
                                      padding: EdgeInsets.only(bottom: 12),
                                      child: LinearProgressIndicator(
                                        minHeight: 2,
                                      ),
                                    ),
                                ],
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    if (m.confirm)
                                      TextButton(
                                        onPressed: _submitting
                                            ? null
                                            : () =>
                                                  Navigator.pop(context, false),
                                        child: const Text('再想一想'),
                                      ),
                                    FilledButton(
                                      onPressed: _submitting
                                          ? null
                                          : () {
                                              if (!complete) {
                                                reveal();
                                              } else {
                                                Navigator.pop(context, true);
                                              }
                                            },
                                      child: Text(
                                        !complete
                                            ? '显示全文'
                                            : m.choices.isNotEmpty
                                            ? '稍后决定'
                                            : m.confirm
                                            ? '确认选择 →'
                                            : '继续 →',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RoundTransition extends StatefulWidget {
  const RoundTransition({super.key, required this.message});
  final NovelMessage message;
  @override
  State<RoundTransition> createState() => _RoundTransitionState();
}

class _RoundTransitionState extends State<RoundTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  Timer? _stay;
  bool _closing = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_stay != null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 1;
    } else {
      _animation.forward();
    }
    _stay = Timer(const Duration(milliseconds: 3000), () => unawaited(close()));
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _stay?.cancel();
    if (!MediaQuery.disableAnimationsOf(context)) await _animation.reverse();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _stay?.cancel();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xdd08131c),
    child: InkWell(
      onTap: () => unawaited(close()),
      child: Center(
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _animation, curve: Curves.easeInOut),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.nights_stay_outlined,
                  size: 38,
                  color: novelGold,
                ),
                const SizedBox(height: 28),
                Text(
                  widget.message.title,
                  style: const TextStyle(
                    fontFamily: 'Songti SC',
                    fontSize: 44,
                    letterSpacing: 5,
                    color: Color(0xfff4e6c7),
                  ),
                ),
                const SizedBox(height: 20),
                const SizedBox(width: 100, child: Divider(color: novelGold)),
                const SizedBox(height: 20),
                Text(
                  widget.message.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    height: 2,
                    fontSize: 16,
                    color: Color(0xffc7cfce),
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  '点击继续 · 即将自动进入',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class NovelChoice extends StatelessWidget {
  const NovelChoice({
    super.key,
    required this.label,
    this.cost,
    required this.enabled,
    required this.onTap,
  });
  final String label;
  final int? cost;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: enabled ? onTap : null,
    style: OutlinedButton.styleFrom(
      foregroundColor: const Color(0xffefe5cd),
      backgroundColor: enabled ? const Color(0x99263a43) : Colors.transparent,
      disabledForegroundColor: const Color(0xff8a999c),
      side: BorderSide(
        color: enabled ? const Color(0xffa1987c) : const Color(0xff45575c),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    child: Text(
      '◇  $label${cost == null ? '' : '  · $cost 点'}',
      style: const TextStyle(fontSize: 14),
    ),
  );
}
