import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_picker_stub.dart' show PickedVideo;
export 'file_picker_stub.dart' show PickedVideo;

Future<PickedVideo?> pickVideo() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'video/mp4,video/webm,video/quicktime';
  final selected = Completer<web.File?>();
  input.onchange = ((web.Event e) {
    if (!selected.isCompleted) selected.complete(input.files?.item(0));
  }).toJS;
  input.oncancel = ((web.Event e) {
    if (!selected.isCompleted) selected.complete(null);
  }).toJS;
  input.click();
  final file = await selected.future;
  if (file == null) return null;
  if (file.size < 1 || file.size > 524288000) {
    throw ArgumentError('视频应小于 500 MiB。');
  }
  final buffer = await file.arrayBuffer().toDart;
  final digest = await web.window.crypto.subtle
      .digest('SHA-256'.toJS, buffer)
      .toDart;
  if (digest == null) throw StateError('文件摘要生成失败。');
  final hash = (digest as JSArrayBuffer).toDart
      .asUint8List()
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final mime = file.type.isEmpty
      ? (file.name.toLowerCase().endsWith('.webm')
            ? 'video/webm'
            : file.name.toLowerCase().endsWith('.mov')
            ? 'video/quicktime'
            : 'video/mp4')
      : file.type;
  return PickedVideo(file.name, mime, buffer.toDart.asUint8List(), hash);
}
