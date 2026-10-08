import 'package:flutter/material.dart';

class OperationsPanel extends StatefulWidget {
  const OperationsPanel({super.key, required this.load});
  final Future<dynamic> Function() load;
  @override
  State<OperationsPanel> createState() => _OperationsPanelState();
}

class _OperationsPanelState extends State<OperationsPanel> {
  late Future<dynamic> report;
  @override
  void initState() {
    super.initState();
    report = widget.load();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 640,
    child: FutureBuilder<dynamic>(
      future: report,
      builder: (c, s) {
        if (s.hasError) return Text('读取失败：${s.error}');
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final data = s.data;
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('业务结果来自服务端已提交事实。此页不包含聊天、提示或玩家身份。'),
              Text(
                '待发送投影：${data['outbox_pending']} · 最长等待 ${data['oldest_outbox_age_ms']} ms',
              ),
              Text(
                '运行内存：${(data['runtime']['memory_bytes'] / 1048576).toStringAsFixed(1)} MiB',
              ),
              for (final section in ['rooms', 'work', 'outcomes']) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    {
                      'rooms': '房间状态',
                      'work': '任务状态',
                      'outcomes': '终局结果',
                    }[section]!,
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
                for (final row in data[section])
                  ListTile(
                    title: Text(
                      '${const {'lobby': '等待开场', 'running': '进行中', 'paused': '已暂停', 'suspended': '等待重连', 'finished': '已完成', 'abandoned': '已结束', 'player_hint': '玩家提示', 'editor_proposal': '制作建议', 'media_transcode': '素材转码', 'E1': '真相公布', 'E2': '错过的答案', 'E3': '回声'}[row['kind'] ?? row['ending_code'] ?? row['lifecycle']] ?? row['kind'] ?? row['ending_code'] ?? row['lifecycle'] ?? '—'} ${const {'queued': '排队中', 'leased': '处理中', 'completed': '已完成', 'failed': '已失败'}[row['status']] ?? ''}',
                    ),
                    trailing: Text('${row['count']}'),
                  ),
              ],
              TextButton(
                onPressed: () => setState(() => report = widget.load()),
                child: const Text('刷新'),
              ),
            ],
          ),
        );
      },
    ),
  );
}
