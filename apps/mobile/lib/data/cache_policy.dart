import 'dart:convert';

/// Terminal caches obey the same body and recap limits while offline.
Map<String, dynamic>? retainedCache(Map<String, dynamic> saved, DateTime now) {
  final result = Map<String, dynamic>.from(jsonDecode(jsonEncode(saved)));
  final snapshot = result['snapshot'];
  final room = snapshot['room'];
  final recap = DateTime.tryParse(room['recap_expires_at'] ?? '');
  if (recap != null && !now.isBefore(recap)) return null;
  final bodies = DateTime.tryParse(room['body_expires_at'] ?? '');
  if (bodies != null && !now.isBefore(bodies)) {
    snapshot['chat'] = [];
    snapshot['hints']['entries'] = [];
    snapshot['hints']['pending_job_id'] = null;
    result['pending'] = {};
  }
  return result;
}
