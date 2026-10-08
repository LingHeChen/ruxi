import 'dart:convert';
import 'dart:js_interop';

@JS('sessionStorage')
external _TabStorage get _storage;

extension type _TabStorage(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

// Private view caches share the same tab boundary as the Web credentials.
class RoomCache {
  Future<Map<String, dynamic>?> read(String account) async {
    final value = _storage.getItem('ruxi.view.$account');
    return value == null ? null : Map<String, dynamic>.from(jsonDecode(value));
  }

  Future<void> write(String account, Map<String, dynamic> value) async {
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > 1048576) {
      throw StateError('cache capacity exceeded');
    }
    _storage.setItem('ruxi.view.$account', encoded);
  }

  Future<void> clear(String account) async {
    _storage.removeItem('ruxi.view.$account');
  }
}
