"""Flutter preview server with COOP/COEP headers for CanvasKit."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import argparse
from functools import partial
parser=argparse.ArgumentParser()
parser.add_argument('--directory',default='apps/mobile/build/web')
parser.add_argument('--port',type=int,default=8080)
a=parser.parse_args()
class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy','same-origin')
        self.send_header('Cross-Origin-Embedder-Policy','credentialless')
        super().end_headers()
ThreadingHTTPServer(('127.0.0.1',a.port),partial(Handler,directory=a.directory)).serve_forever()
