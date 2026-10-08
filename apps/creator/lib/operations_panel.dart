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
                      '${row['kind'] ?? row['ending_code'] ?? row['lifecycle'] ?? '—'} ${row['status'] ?? ''}',
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
