import 'dart:js_interop';

@JS('sessionStorage')
external _TabStorage get _storage;

extension type _TabStorage(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

// The Web player is a preview: each independently opened tab is a player.
// Keep reload recovery within that tab; never reuse origin-wide credentials.
class Credentials {
  Future<String?> read({required String key}) async =>
      _storage.getItem('ruxi.tab.$key');
  Future<void> write({required String key, required String value}) async {
    _storage.setItem('ruxi.tab.$key', value);
  }

  Future<void> delete({required String key}) async =>
      _storage.removeItem('ruxi.tab.$key');
}
