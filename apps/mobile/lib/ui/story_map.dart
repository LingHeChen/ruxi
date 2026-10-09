import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/room_client.dart';
import 'novel_widgets.dart';
import 'story_text.dart';

String _pair(String a, String b) => a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

/// A tidy spanning forest, derived only from the authorized projection.
class StoryMapLayout {
  StoryMapLayout(List<Json> locations, List<Json> links) {
    final ids = locations.map((l) => l['id'] as String).toList();
    final neighbors = {for (final id in ids) id: <String>[]};
    for (final e in links) {
      final a = e['from'], b = e['to'];
      if (!neighbors.containsKey(a) || !neighbors.containsKey(b)) continue;
      if (!neighbors[a]!.contains(b)) neighbors[a]!.add(b);
      if (!neighbors[b]!.contains(a)) neighbors[b]!.add(a);
    }
    final visited = <String>{};
    final children = <String, List<String>>{};
    var leaf = 0, deepest = 0;
    void visit(String id, int depth) {
      visited.add(id);
      children[id] = [];
      // Reserve all immediate neighbors before recursion, so cross-links cannot
      // turn a sibling into a descendant and stretch the main branches.
      for (final n in neighbors[id]!) {
        if (visited.add(n)) {
          children[id]!.add(n);
          treeEdges.add(_pair(id, n));
        }
      }
      for (final n in children[id]!) {
        visit(n, depth + 1);
      }
      deepest = math.max(deepest, depth);
      final x = children[id]!.isEmpty
          ? 80 + leaf++ * 152.0
          : children[id]!.map((n) => positions[n]!.dx).reduce((a, b) => a + b) /
                children[id]!.length;
      positions[id] = Offset(x, 64 + depth * 142.0);
    }

    for (final id in ids) {
      if (!visited.contains(id)) visit(id, 0);
    }
    size = Size(math.max(240, leaf * 152.0 + 8), (deepest + 1) * 142.0 + 36);
  }
  final positions = <String, Offset>{};
  final treeEdges = <String>{};
  late final Size size;
}

class StoryMapDialog extends StatefulWidget {
  const StoryMapDialog({
    super.key,
    required this.locations,
    required this.links,
    required this.current,
    required this.canMove,
    required this.ap,
  });
  final List<Json> locations, links;
  final String current;
  final bool canMove;
  final int ap;
  @override
  State<StoryMapDialog> createState() => _StoryMapDialogState();
}

class _StoryMapDialogState extends State<StoryMapDialog> {
  late String selected = widget.current;
  final transform = TransformationController();
  Size? fitted;
  late final layout = StoryMapLayout(widget.locations, widget.links);
  void fit(Size viewport) {
    final scale =
        math.min(
          viewport.width / layout.size.width,
          viewport.height / layout.size.height,
        ) *
        .92;
    transform.value = Matrix4.identity()
      ..translateByDouble(
        (viewport.width - layout.size.width * scale) / 2,
        (viewport.height - layout.size.height * scale) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void focus(Size viewport, String id) {
    final point = layout.positions[id]!;
    const scale = .9;
    transform.value = Matrix4.identity()
      ..translateByDouble(
        viewport.width / 2 - point.dx * scale,
        viewport.height * .3 - point.dy * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void zoom(double factor, Size viewport) {
    final scale = transform.value.getMaxScaleOnAxis();
    final ratio = (scale * factor).clamp(.2, 3) / scale;
    transform.value =
        (Matrix4.identity()
          ..translateByDouble(viewport.width / 2, viewport.height / 2, 0, 1)
          ..scaleByDouble(ratio, ratio, ratio, 1)
          ..translateByDouble(
            -viewport.width / 2,
            -viewport.height / 2,
            0,
            1,
          )) *
        transform.value;
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.locations.firstWhere((l) => l['id'] == selected);
    final routes = widget.links
        .where((e) => e['from'] == widget.current && e['to'] == selected)
        .toList();
    final link =
        routes.where((e) => e['allowed_now'] == true).firstOrNull ??
        routes.firstOrNull;
    final here = selected == widget.current;
    final enabled =
        !here &&
        widget.canMove &&
        link?['allowed_now'] == true &&
        (link?['cost'] ?? 0) <= widget.ap;
    final reason = here
        ? '你正在这里'
        : link == null
        ? '没有直接通路，请先移动到相邻地点'
        : link['allowed_now'] != true
        ? '通路尚未开放，需先完成相关调查'
        : !widget.canMove
        ? '请先读完当前叙事，或等待同伴完成行动'
        : (link['cost'] ?? 0) > widget.ap
        ? '行动点不足，结束本回合后再移动'
        : '移动消耗 ${link['cost']} 行动点';
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Dialog(
      backgroundColor: const Color(0xff13232c),
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 980,
        height: MediaQuery.sizeOf(context).height * .88,
        child: Padding(
          padding: EdgeInsets.all(narrow ? 16 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.map_outlined, color: novelGold),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '探索地图',
                      style: TextStyle(fontSize: 22, color: novelGold),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭地图',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text(
                '拖动或缩放查看 · 选择地点查看详情',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: narrow ? 4 : 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ColoredBox(
                    color: const Color(0xff0c1922),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final viewport = Size(box.maxWidth, box.maxHeight);
                        if (fitted != viewport) {
                          fitted = viewport;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              if (narrow) {
                                focus(viewport, widget.current);
                              } else {
                                fit(viewport);
                              }
                            }
                          });
                        }
                        return Stack(
                          children: [
                            InteractiveViewer(
                              transformationController: transform,
                              constrained: false,
                              boundaryMargin: const EdgeInsets.all(500),
                              minScale: .2,
                              maxScale: 3,
                              child: SizedBox(
                                width: layout.size.width,
                                height: layout.size.height,
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: StoryMapPaths(
                                          layout,
                                          widget.links,
                                          widget.current,
                                        ),
                                      ),
                                    ),
                                    for (final l in widget.locations)
                                      Positioned(
                                        left:
                                            layout.positions[l['id']]!.dx - 60,
                                        top: layout.positions[l['id']]!.dy - 30,
                                        width: 120,
                                        child: Semantics(
                                          button: true,
                                          label:
                                              '${l['label']}${l['id'] == widget.current ? '，当前位置' : ''}',
                                          child: InkWell(
                                            onTap: () => setState(
                                              () => selected = l['id'],
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 10,
                                                    horizontal: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: selected == l['id']
                                                    ? const Color(0xff3a4a47)
                                                    : const Color(0xff1d303a),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: selected == l['id']
                                                      ? novelGold
                                                      : const Color(0xff586e77),
                                                ),
                                              ),
                                              child: Column(
                                                children: [
                                                  Icon(
                                                    l['id'] == widget.current
                                                        ? Icons
                                                              .person_pin_circle_outlined
                                                        : Icons.home_outlined,
                                                    color: selected == l['id']
                                                        ? novelGold
                                                        : Colors.white70,
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    l['label'],
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      color: Color(0xfff0e9d9),
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
                            ),
                            Positioned(
                              right: 8,
                              top: 8,
                              child: Material(
                                color: const Color(0xff20343e),
                                borderRadius: BorderRadius.circular(8),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: '放大地图',
                                      onPressed: () => zoom(1.3, viewport),
                                      icon: const Icon(Icons.add),
                                    ),
                                    IconButton(
                                      tooltip: '缩小地图',
                                      onPressed: () => zoom(.77, viewport),
                                      icon: const Icon(Icons.remove),
                                    ),
                                    IconButton(
                                      tooltip: '显示完整地图',
                                      onPressed: () => fit(viewport),
                                      icon: const Icon(Icons.fit_screen),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Touch targets remain full size even while the graph is zoomed out.
              SizedBox(
                height: 42,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final l in widget.locations)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(l['label']),
                          selected: l['id'] == selected,
                          onSelected: (_) {
                            setState(() => selected = l['id']);
                            if (narrow && fitted != null) {
                              focus(fitted!, selected);
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: 3,
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!narrow && location['image_uri'] != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.asset(
                            location['image_uri'],
                            width: 180,
                            height: 110,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 20),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              location['label'],
                              style: const TextStyle(
                                fontSize: 20,
                                color: novelGold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            StoryText(
                              location['description'] ?? '',
                              style: const TextStyle(
                                height: 1.7,
                                color: Color(0xffdeded4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                reason,
                style: const TextStyle(fontSize: 12, color: Color(0xffbdd0c8)),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: enabled
                    ? () => Navigator.pop(context, location)
                    : null,
                icon: const Icon(Icons.directions_walk),
                label: Text(here ? '当前位置' : '移动到${location['label']}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StoryMapPaths extends CustomPainter {
  StoryMapPaths(this.layout, this.links, this.current);
  final StoryMapLayout layout;
  final List<Json> links;
  final String current;
  @override
  void paint(Canvas canvas, Size size) {
    final seen = <String>{};
    var extra = 0;
    for (final e in links) {
      final from = e['from'] as String, to = e['to'] as String;
      final pair = _pair(from, to);
      if (!seen.add(pair)) {
        continue; // A bidirectional passage is one connection.
      }
      final a = layout.positions[from], b = layout.positions[to];
      if (a == null || b == null) continue;
      final paint = Paint()
        ..color = (from == current || to == current)
            ? const Color(0xffbba578)
            : const Color(0xff526b78)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      if (layout.treeEdges.contains(pair)) {
        final parent = a.dy < b.dy ? a : b, child = a.dy < b.dy ? b : a;
        canvas.drawLine(
          parent + const Offset(0, 38),
          child - const Offset(0, 31),
          paint,
        );
      } else {
        final bend = 40.0 + extra++ * 22;
        canvas.drawPath(
          Path()
            ..moveTo(a.dx, a.dy)
            ..quadraticBezierTo(
              (a.dx + b.dx) / 2 + bend,
              math.min(a.dy, b.dy) - bend,
              b.dx,
              b.dy,
            ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(StoryMapPaths old) =>
      old.current != current || old.links != links || old.layout != layout;
}
