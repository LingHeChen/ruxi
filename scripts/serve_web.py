"""Flutter preview server with path routing and CanvasKit isolation headers."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        # Navigation paths use the entry point; missing static assets stay 404.
        # /assets is also a creator page, despite Flutter's assets directory.
        path = urlsplit(self.path).path
        is_asset = path.startswith(("/assets/", "/canvaskit/", "/icons/"))
        if (not Path(self.translate_path(path)).is_file()
                and "." not in path.rsplit("/", 1)[-1] and not is_asset):
            self.path = "/index.html"
        super().do_GET()

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
        super().end_headers()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", default="apps/mobile/build/web")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    ThreadingHTTPServer(
        ("127.0.0.1", args.port), partial(Handler, directory=args.directory)
    ).serve_forever()
