import 'package:flutter_test/flutter_test.dart';
import 'package:ruxi/data/cache_policy.dart';

void main() {
  final now = DateTime.utc(2026, 10, 8);
  Map<String, dynamic> fixture() => {
    'pending': {
      'command': {'type': 'chat_send'},
    },
    'snapshot': {
      'room': {
        'body_expires_at': now.toIso8601String(),
        'recap_expires_at': now
            .add(const Duration(days: 173))
            .toIso8601String(),
      },
      'chat': [
        {'text': 'private-body'},
      ],
      'hints': {
        'entries': [
          {'text': 'private-hint'},
        ],
        'pending_job_id': 'work',
      },
      'own_clues': [
        {'text': 'authorized-clue'},
      ],
    },
  };
  test('offline terminal caches scrub expired bodies but preserve authorized recap', () {
    final original = fixture();
    final scrubbed = retainedCache(original, now)!;
    expect(scrubbed['snapshot']['chat'], isEmpty);
    expect(scrubbed['snapshot']['hints']['entries'], isEmpty);
    expect(scrubbed['pending'], isEmpty);
    expect(scrubbed['snapshot']['own_clues'], [
      {'text': 'authorized-clue'},
    ]);
    expect(original['snapshot']['chat'], isNotEmpty);
    expect(
      retainedCache(
        fixture(),
        now.subtract(const Duration(seconds: 1)),
      )!['snapshot']['chat'],
      isNotEmpty,
    );
  });
  test('expired recap is removed and active recovery data has no artificial age limit', () {
    expect(
      retainedCache(fixture(), now.add(const Duration(days: 173))),
      isNull,
    );
    final active = fixture();
    active['snapshot']['room'] = {
      'body_expires_at': null,
      'recap_expires_at': null,
    };
    expect(
      retainedCache(
        active,
        now.add(const Duration(days: 200)),
      )!['snapshot']['chat'],
      isNotEmpty,
    );
  });
}
