import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'file_picker_stub.dart'
    if (dart.library.js_interop) 'file_picker_web.dart';

typedef ProductionApi = Future<dynamic> Function(
  String,
  String, [
  Map<String, dynamic>?,
]);

class ProductionPanel extends StatefulWidget {
  const ProductionPanel({
    super.key,
    required this.api,
    required this.versionId,
    required this.revision,
    required this.graph,
    required this.onGraph,
    required this.onReload,
  });
  final ProductionApi api;
  final String versionId;
  final int revision;
  final Map<String, dynamic> graph;
  final ValueChanged<Map<String, dynamic>> onGraph;
  final Future<void> Function() onReload;
  @override
  State<ProductionPanel> createState() => _ProductionPanelState();
}

class _ProductionPanelState extends State<ProductionPanel> {
  final rights = TextEditingController(), instruction = TextEditingController();
  List<dynamic> assets = [];
  Map<String, dynamic>? job;
  String status = '', target = 'title';
  bool busy = false, polling = false;
  String? mediaId;
  Timer? timer;
  Timer? assetTimer;
  bool refreshingAssets = false;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    timer?.cancel();
    assetTimer?.cancel();
    rights.dispose();
    instruction.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (refreshingAssets) return;
    refreshingAssets = true;
    try {
      final d = await widget.api('GET', '/v1/admin/assets');
      if (mounted) {
        setState(() => assets = d['items']);
        final processing = assets.any((a) => a['status'] == 'processing');
        if (processing) {
          assetTimer ??= Timer.periodic(
            const Duration(seconds: 5),
            (_) => refresh(),
          );
        } else {
          assetTimer?.cancel();
          assetTimer = null;
        }
      }
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    } finally {
      refreshingAssets = false;
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '处理中…';
    });
    try {
      await action();
    } catch (e) {
      status = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> upload() async {
    if (rights.text.trim().isEmpty) throw Exception('请填写版权与来源。');
    final file = await pickVideo();
    if (file == null) {
      status = '已取消选择';
      return;
    }
    final bytes = file.bytes;
    final hash = file.sha256;
    final intent = await widget.api('POST', '/v1/admin/assets/upload-intents', {
      'command_id': const Uuid().v4(),
      'filename': file.name,
      'mime_type': file.mime,
      'size_bytes': bytes.length,
      'sha256': hash,
    });
    final r = await http
        .put(
          Uri.parse(intent['upload_url']),
          headers: Map<String, String>.from(intent['headers']),
          body: bytes,
        )
        .timeout(const Duration(minutes: 15));
    if (r.statusCode >= 400) throw Exception('上传失败，请重试。');
    await widget.api(
      'POST',
      '/v1/admin/assets/${intent['asset_id']}/complete',
      {
        'command_id': const Uuid().v4(),
        'sha256': hash,
        'size_bytes': bytes.length,
        'rights_source': rights.text.trim(),
      },
    );
    status = '已上传，正在转码，完成后将自动更新。';
    await refresh();
  }

  Future<void> requestAi() async {
    timer?.cancel();
    job = await widget.api(
      'POST',
      '/v1/admin/versions/${widget.versionId}/ai',
      {
        'command_id': const Uuid().v4(),
        'revision': widget.revision,
        'target': target,
        'instruction': instruction.text,
        if (target == 'asset_summary') 'media_id': mediaId,
      },
    );
    status = '正在生成建议，草稿尚未修改。';
    timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
  }

  Future<void> poll() async {
    if (polling || job == null) return;
    polling = true;
    try {
      final d = await widget.api('GET', '/v1/admin/ai/jobs/${job!['job_id']}');
      if (mounted) setState(() => job = Map<String, dynamic>.from(d));
      if (['completed', 'failed'].contains(d['status'])) timer?.cancel();
    } catch (e) {
      timer?.cancel();
      if (mounted) setState(() => status = '$e');
    } finally {
      polling = false;
    }
  }

  Future<void> editCaptions(Map asset) async {
    final text = TextEditingController(
      text: 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n请输入字幕。\n',
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('添加字幕版本'),
        content: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('使用纯文本 WebVTT，时间须在视频时长内。保存会生成新素材，已有发布内容保持冻结。'),
              TextField(
                controller: text,
                minLines: 8,
                maxLines: 16,
                maxLength: 50000,
                decoration: const InputDecoration(labelText: 'WebVTT 字幕'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('保存字幕版本'),
          ),
        ],
      ),
    );
    try {
      if (accepted == true) {
        await widget.api(
          'POST',
          '/v1/admin/assets/${asset['asset_id']}/captions',
          {'command_id': const Uuid().v4(), 'vtt': text.text},
        );
        await refresh();
        status = '字幕版本已生成，请选择它替换片段并保存草稿。';
      }
    } finally {
      text.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = (widget.graph['assets'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final proposal = job?['proposal'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('素材制作', style: TextStyle(fontSize: 22)),
            TextField(
              controller: rights,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: '版权与来源（原创、许可说明或授权链接）',
              ),
            ),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : () => run(upload),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('上传视频并转码'),
                ),
                TextButton(onPressed: refresh, child: const Text('刷新素材状态')),
              ],
            ),
            for (final asset in assets)
              ListTile(
                leading: asset['status'] == 'ready'
                    ? IconButton(
                        tooltip: '查看首帧',
                        icon: const Icon(Icons.image_outlined),
                        onPressed: () => run(() async {
                          final preview = await widget.api(
                            'GET',
                            '/v1/admin/assets/${asset['asset_id']}/preview',
                          );
                          if (!context.mounted) return;
                          final image = NetworkImage(preview['poster_url']);
                          await showDialog<void>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: Text('${asset['filename']}'),
                              content: Image(
                                image: image,
                                width: 480,
                                errorBuilder: (_, e, stack) =>
                                    const Text('预览已失效，请重新打开。'),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          );
                          await image.evict();
                        }),
                      )
                    : null,
                title: Text('${asset['filename']}'),
                subtitle: Text(
                  {
                        'uploading': '等待上传',
                        'uploaded': '上传完成',
                        'processing': '正在转码',
                        'ready': '可以使用',
                        'quarantined': '处理失败，请检查视频格式后重新上传',
                      }[asset['status']] ??
                      '状态待更新',
                ),
                trailing: asset['status'] == 'ready'
                    ? PopupMenuButton<String>(
                        tooltip: '替换草稿片段',
                        onSelected: (slot) {
                          if (slot == '__captions__') {
                            run(() => editCaptions(asset));
                            return;
                          }
                          widget.onGraph({
                            ...widget.graph,
                            'assets': [
                              for (final old in slots)
                                if (old['media_id'] == slot)
                                  {
                                    ...old,
                                    'asset_id': asset['asset_id'],
                                    'sha256':
                                        asset['outputs']['video']['sha256'],
                                    'duration_ms': asset['duration_ms'],
                                    'source': asset['rights_source'],
                                  }
                                else
                                  {...old},
                            ],
                          });
                          setState(() => status = '已替换 $slot，请保存草稿并验证、试玩。');
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: '__captions__',
                            child: Text('添加字幕版本'),
                          ),
                          for (final slot in slots)
                            PopupMenuItem(
                              value: '${slot['media_id']}',
                              child: Text('替换 ${slot['media_id']}'),
                            ),
                        ],
                      )
                    : null,
              ),
            const Divider(height: 36),
            const Text('AI 文字建议', style: TextStyle(fontSize: 22)),
            const Text('先保存草稿再生成。确认应用后需要重新验证与审核。'),
            DropdownButton<String>(
              value: target,
              items: const [
                DropdownMenuItem(value: 'title', child: Text('剧目名称')),
                DropdownMenuItem(value: 'description', child: Text('剧目介绍')),
                DropdownMenuItem(value: 'asset_summary', child: Text('片段摘要')),
              ],
              onChanged: busy ? null : (v) => setState(() => target = v!),
            ),
            if (target == 'asset_summary')
              DropdownButton<String>(
                value: mediaId,
                hint: const Text('选择片段'),
                items: [
                  for (final slot in slots)
                    DropdownMenuItem(
                      value: '${slot['media_id']}',
                      child: Text('${slot['media_id']}'),
                    ),
                ],
                onChanged: (v) => setState(() => mediaId = v),
              ),
            TextField(
              controller: instruction,
              maxLength: 500,
              decoration: const InputDecoration(labelText: '修改要求'),
            ),
            FilledButton(
              onPressed: busy || target == 'asset_summary' && mediaId == null
                  ? null
                  : () => run(requestAi),
              child: const Text('生成建议'),
            ),
            if (job != null)
              Text(
                '建议状态：${{'queued': '排队中', 'leased': '生成中', 'completed': '已完成', 'failed': '生成失败，请重试'}[job!['status']] ?? '待更新'}',
              ),
            if (job?['outcome']?['status'] == 'ignored')
              const Text('草稿已发生变化，请保存后重新生成建议。'),
            if (proposal is Map) ...[
              Text('原文：${proposal['original']}'),
              SelectableText('建议：${proposal['suggested']}'),
              Text('来源：${proposal['source'] == 'ai' ? '模型建议' : '固定建议'}'),
              FilledButton(
                onPressed: busy || job!['outcome']?['status'] != 'accepted'
                    ? null
                    : () => run(() async {
                        await widget.api(
                          'POST',
                          '/v1/admin/ai/jobs/${job!['job_id']}/apply',
                          {
                            'command_id': const Uuid().v4(),
                            'revision': widget.revision,
                          },
                        );
                        await widget.onReload();
                        job = null;
                        status = '建议已应用。';
                      }),
                child: const Text('确认应用建议'),
              ),
            ],
            if (status.isNotEmpty) Text(status),
          ],
        ),
      ),
    );
  }
}
