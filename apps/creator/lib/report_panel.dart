import 'package:flutter/material.dart';

class ReportPanel extends StatefulWidget {
  const ReportPanel({super.key, required this.load, required this.review});
  final Future<dynamic> Function() load;
  final Future<dynamic> Function(String, String) review;
  @override
  State<ReportPanel> createState() => _ReportPanelState();
}

class _ReportPanelState extends State<ReportPanel> {
  List<dynamic> reports = [];
  bool busy = true;
  String status = '';
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    setState(() => busy = true);
    try {
      final result = await widget.load();
      if (mounted) {
        setState(() {
          reports = result['items'];
          status = '';
        });
      }
    } catch (_) {
      if (mounted) setState(() => status = '无法读取举报，请检查会话和审核权限。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> review(String id, String outcome) async {
    setState(() => busy = true);
    try {
      await widget.review(id, outcome);
      if (mounted) {
        setState(() {
          reports.removeWhere((r) => r['report_id'] == id);
          status = '处理结果已保存并记录审计。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => status = '处理失败，可刷新列表后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 680,
    height: 520,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('仅展示玩家主动提交的聊天消息；不会读取私人线索或投票。'),
        TextButton(
          onPressed: busy ? null : refresh,
          child: const Text('刷新待处理举报'),
        ),
        if (busy) const LinearProgressIndicator(),
        if (status.isNotEmpty) Text(status),
        Expanded(
          child: reports.isEmpty && !busy
              ? const Center(child: Text('暂无待处理举报'))
              : ListView(
                  children: [
                    for (final report in reports)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '举报原因：${const {'harassment': '辱骂或骚扰', 'privacy': '泄露隐私', 'spam': '垃圾信息', 'other': '其他问题'}[report['reason']] ?? '其他问题'}',
                              ),
                              const SizedBox(height: 8),
                              SelectableText(
                                report['message_text'] ?? '消息已按注销或保留策略清理。',
                              ),
                              Wrap(
                                spacing: 12,
                                children: [
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => review(
                                            report['report_id'],
                                            'remove',
                                          ),
                                    child: const Text('移除消息并处理'),
                                  ),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => review(
                                            report['report_id'],
                                            'resolved',
                                          ),
                                    child: const Text('标记已处理'),
                                  ),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => review(
                                            report['report_id'],
                                            'dismissed',
                                          ),
                                    child: const Text('不予受理'),
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
      ],
    ),
  );
}
