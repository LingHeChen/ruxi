import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/room_client.dart';
import 'novel_widgets.dart';

Future<void> showInteraction(
  BuildContext context,
  Json interaction,
  Future<Json> Function() quote,
  Future<String?> Function(Json, String?) submit,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      InteractionDialog(interaction: interaction, quote: quote, submit: submit),
);

class InteractionDialog extends StatefulWidget {
  const InteractionDialog({
    super.key,
    required this.interaction,
    required this.quote,
    required this.submit,
  });
  final Json interaction;
  final Future<Json> Function() quote;
  final Future<String?> Function(Json, String?) submit;
  @override
  State<InteractionDialog> createState() => _InteractionDialogState();
}

class _InteractionDialogState extends State<InteractionDialog> {
  final input = TextEditingController();
  Json? quote;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final q = await widget.quote();
      if (mounted) setState(() => quote = q);
    } catch (e) {
      if (mounted) setState(() => error = RoomClient.explain(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (busy || quote == null) return;
    final spec = quote!['input_spec'];
    if (spec != null) {
      final text = input.text;
      // Server applies authoritative Unicode normalization. PIN validation preserves zeros.
      final length = text.runes.length;
      final validateLength =
          spec['format'] == 'pin' || spec['normalization'] == 'exact';
      if ((validateLength &&
              (length < spec['min_length'] || length > spec['max_length'])) ||
          (spec['format'] == 'pin' && !RegExp(r'^[0-9]+$').hasMatch(text))) {
        setState(
          () => error =
              '请按格式填写 ${spec['min_length']}–${spec['max_length']} 位${spec['format'] == 'pin' ? '数字' : '文字'}。',
        );
        return;
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    String? problem;
    try {
      problem = await widget.submit(quote!, spec == null ? null : input.text);
    } catch (e) {
      problem = RoomClient.explain(e);
    }
    if (!mounted) return;
    if (problem == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        busy = false;
        error = problem;
      });
    }
  }

  @override
  void dispose() {
    input.clear();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final check = widget.interaction['kind'] == 'check';
    final preview = quote?['check_preview'];
    final spec = quote?['input_spec'];
    return Dialog(
      backgroundColor: const Color(0xff152129),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.interaction['label'],
                style: const TextStyle(color: novelGold, fontSize: 22),
              ),
              const SizedBox(height: 20),
              if (widget.interaction['image_uri'] != null) ...[
                Image.asset(
                  widget.interaction['image_uri'],
                  height: 150,
                  fit: BoxFit.cover,
                ),
                const SizedBox(height: 16),
              ],
              if (busy) const LinearProgressIndicator(),
              if (quote != null) ...[
                Text(
                  '${quote!['cost']} 余力 · 剩余 ${quote!['attempts_remaining']} 次尝试',
                ),
                const SizedBox(height: 20),
                if (check && preview != null) ...[
                  Text(
                    '成功率 ${preview['target']}%',
                    style: const TextStyle(fontSize: 32, color: novelGold),
                  ),
                  ExpansionTile(
                    title: const Text('查看判定规则'),
                    children: [
                      Text(
                        '1d100 ≤ ${preview['target']}\n基础 ${preview['base_target']}%',
                      ),
                      for (final m in preview['modifiers'])
                        Text(
                          '${m['label']} ${m['delta'] >= 0 ? '+' : ''}${m['delta']}%',
                        ),
                    ],
                  ),
                ],
                if (!check && spec != null)
                  TextField(
                    controller: input,
                    enabled: !busy,
                    autofocus: true,
                    keyboardType: spec['format'] == 'pin'
                        ? TextInputType.number
                        : TextInputType.text,
                    inputFormatters: spec['format'] == 'pin'
                        ? [FilteringTextInputFormatter.digitsOnly]
                        : [],
                    decoration: InputDecoration(
                      labelText: spec['format'] == 'pin' ? '输入密码' : '输入答案',
                      helperText: '保留前导零；确认后等待本步结算。',
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                const SizedBox(height: 16),
                Text(
                  quote!['risk_text'],
                  style: const TextStyle(height: 1.7, color: Color(0xffc7c5b8)),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: const TextStyle(color: Color(0xffedb4a0)),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    child: const Text('返回场景'),
                  ),
                  if (quote == null)
                    FilledButton(
                      onPressed: busy ? null : load,
                      child: const Text('重新获取'),
                    ),
                  if (quote != null)
                    FilledButton(
                      onPressed: busy ? null : submit,
                      child: Text(check ? '确认判定' : '确认提交'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
