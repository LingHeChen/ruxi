import 'package:flutter/material.dart';

import '../data/room_client.dart';
import 'novel_widgets.dart';

enum GamePanel { clues, inventory, history }

extension GamePanelInfo on GamePanel {
  String get title => switch (this) {
    GamePanel.clues => '线索册',
    GamePanel.inventory => '随身背包',
    GamePanel.history => '行动记录',
  };
  String get shortTitle => switch (this) {
    GamePanel.clues => '线索',
    GamePanel.inventory => '物品',
    GamePanel.history => '历史',
  };
  IconData get icon => switch (this) {
    GamePanel.clues => Icons.search,
    GamePanel.inventory => Icons.backpack_outlined,
    GamePanel.history => Icons.history,
  };
}

class GameInventory extends StatefulWidget {
  const GameInventory({
    super.key,
    required this.initialPanel,
    required this.clues,
    required this.inventory,
    required this.history,
    this.onShare,
  });
  final GamePanel initialPanel;
  final List<Json> clues, inventory, history;
  final void Function(Json)? onShare;
  @override
  State<GameInventory> createState() => _GameInventoryState();
}

class _GameInventoryState extends State<GameInventory> {
  late GamePanel panel = widget.initialPanel;
  String? selected;
  List<Json> get entries =>
      panel == GamePanel.clues ? widget.clues : widget.inventory;
  String entryTitle(Json item) =>
      '${item['label'] ?? (panel == GamePanel.clues ? '调查线索 ${widget.clues.indexOf(item) + 1}' : '随身物品')}';
  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xff12202a),
    insetPadding: const EdgeInsets.all(16),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: const BorderSide(color: Color(0xff526672)),
    ),
    child: SizedBox(
      width: 860,
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(panel.icon, color: novelGold),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    panel.title,
                    style: const TextStyle(
                      fontFamily: 'Songti SC',
                      fontSize: 25,
                      color: novelGold,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭面板',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final kind in GamePanel.values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: kind == panel
                              ? const Color(0xff2c404a)
                              : Colors.transparent,
                          foregroundColor: kind == panel
                              ? novelGold
                              : Colors.white54,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => setState(() {
                          panel = kind;
                          selected = null;
                        }),
                        icon: Icon(kind.icon, size: 18),
                        label: Text(kind.shortTitle),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: panel == GamePanel.history
                  ? history()
                  : LayoutBuilder(
                      builder: (context, size) {
                        final narrow = size.maxWidth < 550;
                        final item = entries
                            .where((e) => e['id'] == selected)
                            .firstOrNull;
                        if (entries.isEmpty) return empty();
                        final grid = slots(narrow);
                        final details = detail(item);
                        return narrow
                            ? Column(
                                children: [
                                  SizedBox(
                                    height: size.maxHeight * .43,
                                    child: grid,
                                  ),
                                  const SizedBox(height: 16),
                                  Expanded(child: details),
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(flex: 5, child: grid),
                                  const SizedBox(width: 24),
                                  Expanded(flex: 4, child: details),
                                ],
                              );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget slots(bool narrow) => GridView.builder(
    itemCount: entries.length,
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: narrow ? 110 : 135,
      mainAxisExtent: 112,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
    ),
    itemBuilder: (context, index) {
      final item = entries[index];
      final active = item['id'] == selected;
      return Semantics(
        button: true,
        selected: active,
        label: entryTitle(item),
        child: Material(
          color: active ? const Color(0xff374a50) : const Color(0xff1b2d37),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => selected = item['id']),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: active ? novelGold : const Color(0xff425661),
                ),
              ),
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (item['image_uri'] != null)
                    Image.asset(
                      item['image_uri'],
                      height: 40,
                      width: 64,
                      fit: BoxFit.cover,
                    )
                  else
                    Icon(
                      panel == GamePanel.clues
                          ? Icons.description_outlined
                          : item['reserved'] == true
                          ? Icons.lock_clock_outlined
                          : Icons.inventory_2_outlined,
                      color: active ? novelGold : const Color(0xffb3c2c5),
                      size: 30,
                    ),
                  const SizedBox(height: 10),
                  Text(
                    entryTitle(item),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget detail(Json? item) => Container(
    decoration: BoxDecoration(
      color: const Color(0xff0d1a23),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0xff344853)),
    ),
    padding: const EdgeInsets.all(20),
    child: item == null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(panel.icon, size: 36, color: Colors.white24),
                const SizedBox(height: 16),
                Text(
                  panel == GamePanel.clues ? '选中一条线索，回看发现。' : '选中一件物品，查看详情。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, height: 1.8),
                ),
              ],
            ),
          )
        : SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item['image_uri'] != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.asset(
                      item['image_uri'],
                      height: 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                Text(
                  entryTitle(item),
                  style: const TextStyle(
                    fontFamily: 'Songti SC',
                    fontSize: 23,
                    color: novelGold,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '${panel == GamePanel.clues ? item['text'] : item['description'] ?? '这件物品已经放入你的背包。相关用途会在场景互动中出现。'}',
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.9,
                    color: Color(0xffdeded1),
                  ),
                ),
                if (panel == GamePanel.clues && item['source'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      '${item['category'] == 'reported' ? '转述 · 尚未证实' : '亲历记录'} · ${item['source']} · 第 ${item['acquired_tick']} 回合',
                      style: const TextStyle(color: novelGold, fontSize: 12),
                    ),
                  ),
                if (item['reserved'] == true)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text(
                      '正在用于一项待执行行动',
                      style: TextStyle(color: novelGold),
                    ),
                  ),
                if (panel == GamePanel.clues &&
                    item['shareable'] == true &&
                    widget.onShare != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: OutlinedButton.icon(
                      onPressed: () => widget.onShare!(item),
                      icon: const Icon(Icons.ios_share, size: 16),
                      label: const Text('分享给同伴'),
                    ),
                  ),
              ],
            ),
          ),
  );
  Widget empty() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(panel.icon, size: 44, color: Colors.white24),
        const SizedBox(height: 16),
        Text(
          panel == GamePanel.clues ? '还没有发现线索' : '背包暂时是空的',
          style: const TextStyle(fontSize: 18, color: novelGold),
        ),
        const SizedBox(height: 10),
        Text(
          panel == GamePanel.clues ? '调查场景中的事物，发现会收录在这里。' : '获得的物品会放进背包。',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, height: 1.8),
        ),
      ],
    ),
  );
  Widget history() => widget.history.isEmpty
      ? const Center(
          child: Text(
            '还没有执行行动。故事正等待你的第一步。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, height: 1.8),
          ),
        )
      : ListView.separated(
          itemCount: widget.history.length,
          separatorBuilder: (_, _) =>
              const Divider(color: Color(0xff30434f), height: 1),
          itemBuilder: (context, i) {
            final item = widget.history.reversed.elementAt(i);
            final failed =
                item['status'] == 'invalidated' || item['success'] == false;
            final moving = '${item['action_id']}'.startsWith('move:');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xff253b46),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      moving ? Icons.directions_walk : Icons.touch_app_outlined,
                      size: 20,
                      color: novelGold,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item['label'] ?? '一次行动'}',
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '第 ${item['round'] ?? 1} 回合 · ${item['cost'] ?? 0} 行动点 · ${failed ? '未成功' : '已完成'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: failed
                                ? const Color(0xffd49b87)
                                : const Color(0xff9ab6b0),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
}
