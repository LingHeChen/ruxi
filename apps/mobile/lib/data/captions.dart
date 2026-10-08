import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

Future<ClosedCaptionFile> authorizedCaptions(
  String url, {
  http.Client? transport,
}) async {
  final client = transport ?? http.Client();
  try {
    return await _readCaptions(
      client,
      url,
    ).timeout(const Duration(seconds: 15));
  } catch (_) {
    // Subtitle failure does not prevent the authorized video or text summary.
    return WebVTTCaptionFile('WEBVTT\n\n');
  } finally {
    client.close();
  }
}

Future<ClosedCaptionFile> _readCaptions(http.Client client, String url) async {
  final response = await client.send(http.Request('GET', Uri.parse(url)));
  if (response.statusCode != 200) throw StateError('Subtitle unavailable');
  final bytes = <int>[];
  await for (final chunk in response.stream) {
    if (bytes.length + chunk.length > 1048576) {
      throw StateError('Subtitle too large');
    }
    bytes.addAll(chunk);
  }
  final text = utf8.decode(bytes);
  if (!text.startsWith('WEBVTT')) throw StateError('Invalid subtitle');
  return WebVTTCaptionFile(text);
}
