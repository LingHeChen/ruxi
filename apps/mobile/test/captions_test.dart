import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ruxi/data/captions.dart';

void main() {
  test('authorized Unicode captions preserve timing and never send player credentials', () async {
    final file = await authorizedCaptions(
      'https://core.test/media/synthetic-capability',
      transport: MockClient((request) async {
        expect(request.headers.containsKey('authorization'), false);
        return http.Response(
          'WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n中文线索。\n',
          200,
          headers: {'content-type': 'text/vtt; charset=utf-8'},
        );
      }),
    );
    expect(file.captions.single.text, '中文线索。');
    expect(file.captions.single.start, const Duration(seconds: 1));
    expect(file.captions.single.end, const Duration(seconds: 3));
  });
  test(
    'expired subtitle capability does not prevent text/video fallback',
    () async {
      final file = await authorizedCaptions(
        'https://core.test/media/expired',
        transport: MockClient((_) async => http.Response('denied', 403)),
      );
      expect(file.captions, isEmpty);
    },
  );
  test('oversized subtitle is bounded and rejected', () async {
    final file = await authorizedCaptions(
      'https://core.test/media/oversized',
      transport: MockClient(
        (_) async => http.Response('WEBVTT\n\n${'x' * 1048576}', 200),
      ),
    );
    expect(file.captions, isEmpty);
  });
}
