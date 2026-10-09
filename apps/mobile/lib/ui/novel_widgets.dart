import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/room_client.dart';

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
  late final _characters = widget.message.text.characters.toList();
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (m.illustration != null) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.asset(
                                    m.illustration!,
                                    height: narrow ? 160 : 230,
                                    fit: BoxFit.cover,
                                    alignment: m.illustration!.contains('/npc-')
                                        ? const Alignment(0, -.5)
                                        : Alignment.center,
                                    semanticLabel: '当前剧情插图',
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                                const SizedBox(height: 20),
                              ],
                              GestureDetector(
                                onTap: reveal,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: m.choices.isEmpty ? 120 : 96,
                                  ),
                                  child: Semantics(
                                    label: m.text,
                                    excludeSemantics: true,
                                    child: Text(
                                      _characters.take(_count).join(),
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
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: OutlinedButton(
                                      onPressed:
                                          _submitting ||
                                              widget.onChoice == null ||
                                              !(widget.choiceAvailable?.call(
                                                    choice,
                                                  ) ??
                                                  choice['allowed_now'] == true)
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
                                          : () => Navigator.pop(context, false),
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

class NovelMap extends StatelessWidget {
  const NovelMap({
    super.key,
    required this.locations,
    required this.links,
    required this.current,
    required this.onSelect,
  });
  final List<Json> locations, links;
  final String? current;
  final void Function(Json) onSelect;
  @override
  Widget build(BuildContext context) => NovelPanel(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Column(
        children: [
          const Text(
            '探索地图',
            style: TextStyle(fontSize: 11, color: novelGold, letterSpacing: 2),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                // Only authorized known locations/edges reach this map. Connections are never inferred.
                final width = box.maxWidth;
                final height = math.max(
                  box.maxHeight,
                  ((locations.length + 1) ~/ 2) * 72.0,
                );
                final positions = <String, Offset>{};
                for (var i = 0; i < locations.length; i++) {
                  positions[locations[i]['id']] = Offset(
                    width * (i.isEven ? .26 : .74),
                    30 + (i ~/ 2) * 72 + (i.isOdd ? 18 : 0),
                  );
                }
                return SingleChildScrollView(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: MapPaths(positions, links, current),
                          ),
                        ),
                        for (final l in locations)
                          Positioned(
                            left: positions[l['id']]!.dx - 30,
                            top: positions[l['id']]!.dy - 23,
                            width: 60,
                            child: Semantics(
                              button: true,
                              label:
                                  '${l['label']}${l['id'] == current ? '，当前位置' : '，查看地点'}',
                              child: Tooltip(
                                message: '${l['label']} · 点击查看',
                                child: InkWell(
                                  onTap: () => onSelect(l),
                                  borderRadius: BorderRadius.circular(10),
                                  child: Column(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: l['id'] == current
                                              ? const Color(0xffbba477)
                                              : const Color(0xff21333e),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: l['id'] == current
                                                ? const Color(0xfff7dda9)
                                                : const Color(0xff647984),
                                          ),
                                        ),
                                        child: Icon(
                                          l['id'] == current
                                              ? Icons.person_pin_circle_outlined
                                              : Icons.home_outlined,
                                          color: l['id'] == current
                                              ? const Color(0xff172632)
                                              : const Color(0xffabbec2),
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        l['label'],
                                        maxLines: 2,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: l['id'] == current
                                              ? novelGold
                                              : const Color(0xffb9c5c8),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class MapPaths extends CustomPainter {
  MapPaths(this.positions, this.links, this.current);
  final Map<String, Offset> positions;
  final List<Json> links;
  final String? current;
  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in links) {
      final a = positions[edge['from']], b = positions[edge['to']];
      if (a == null || b == null) continue;
      final delta = b - a;
      if (delta.distance < 1) continue;
      final direction = delta / delta.distance;
      final start = a + direction * 24, end = b - direction * 24;
      final paint = Paint()
        ..color = edge['allowed_now'] == true
            ? novelGold
            : const Color(0xff647580)
        ..strokeWidth = 1.3;
      final length = (end - start).distance;
      for (double i = 0; i < length; i += 8) {
        canvas.drawLine(
          start + direction * i,
          start + direction * math.min(i + 4, length),
          paint,
        );
      }
      final normal = Offset(-direction.dy, direction.dx);
      canvas.drawLine(end, end - direction * 5 + normal * 3, paint);
      canvas.drawLine(end, end - direction * 5 - normal * 3, paint);
    }
  }

  @override
  bool shouldRepaint(MapPaths oldDelegate) => true;
}
