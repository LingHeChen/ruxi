import 'dart:typed_data';

class PickedVideo {
  PickedVideo(this.name, this.mime, this.bytes, this.sha256);
  final String name, mime, sha256;
  final Uint8List bytes;
}

Future<PickedVideo?> pickVideo() async => throw UnsupportedError('请在浏览器中上传素材。');
