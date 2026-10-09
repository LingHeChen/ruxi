"""HTTP regression: deep links, route/directory collisions, missing assets."""
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from urllib.error import HTTPError
from urllib.request import urlopen
import unittest
from serve_web import Handler


class RoutingHandler(Handler):
    def log_message(self, *_):
        pass


class PreviewRoutes(unittest.TestCase):
    def test_navigation_fallback_keeps_real_and_missing_assets_distinct(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'index.html').write_text('entry point')
            (root / 'assets').mkdir()
            (root / 'assets/app.js').write_text('actual asset')
            server = ThreadingHTTPServer(('127.0.0.1', 0), partial(RoutingHandler, directory=directory))
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f'http://127.0.0.1:{server.server_port}'
            try:
                for path in ['/', '/me', '/rooms/uuid', '/discover?category=scifi', '/editor/uuid', '/assets']:
                    with urlopen(base + path) as response:
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.headers.get("Cache-Control"), "no-cache")
                        self.assertEqual(response.read(), b'entry point')
                with urlopen(base + '/assets/app.js') as response:
                    self.assertEqual(response.read(), b'actual asset')
                for path in ['/assets/missing.js', '/canvaskit/missing', '/missing.js']:
                    with self.assertRaises(HTTPError) as error:
                        urlopen(base + path)
                    self.assertEqual(error.exception.code, 404)
            finally:
                server.shutdown()
                thread.join()
                server.server_close()


if __name__ == '__main__':
    unittest.main()
