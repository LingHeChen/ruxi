import 'package:web/web.dart' as web;

class SessionStore {
  String? read(String key) =>
      web.window.sessionStorage.getItem('ruxi.creator.$key');
  void write(String key, String value) =>
      web.window.sessionStorage.setItem('ruxi.creator.$key', value);
  void clear() {
    for (final key in ['access', 'refresh', 'device']) {
      web.window.sessionStorage.removeItem('ruxi.creator.$key');
    }
  }
}
