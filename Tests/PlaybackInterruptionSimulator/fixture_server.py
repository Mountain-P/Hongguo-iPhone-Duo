"""Two generated H.264 clips served only at loopback, with verifiable interruption per episode."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import socket
import time
import threading

class LocalClips(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, directory, marker):
        self.directory = directory
        self.marker = marker
        self.interrupted, self.resumed = threading.Event(), threading.Event()
        super().__init__(('127.0.0.1', 0), ClipReader)


class ClipReader(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path not in ('/201.mp4','/202.mp4'):
            self.send_error(404)
            return
        server = self.server
        request_started = time.time()
        first = self.path == '/201.mp4'
        def offline():
            try:
                return time.time() < float(server.marker.read_text())
            except (OSError,ValueError):
                return False
        if offline():
            if first: server.interrupted.set()
            self.send_error(503)
            return
        path = server.directory / self.path[1:]
        length = path.stat().st_size
        match = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range',''))
        if not match:
            self.send_error(416)
            return
        start,end = int(match[1]), min(int(match[2]), length-1)
        if start > end:
            self.send_error(416)
            return
        self.send_response(206)
        self.send_header('Content-Length',str(end-start+1))
        self.send_header('Content-Type','video/mp4')
        self.send_header('Content-Range',f'bytes {start}-{end}/{length}')
        self.send_header('ETag','"fixed-'+path.name+'"')
        self.end_headers()
        try:
            with path.open('rb') as file:
                file.seek(start)
                while start <= end:
                    block = file.read(min(16384, end+1-start))
                    if not block:
                        return
                    if offline():
                        if first: server.interrupted.set()
                        self.connection.shutdown(socket.SHUT_RDWR)
                        return
                    self.wfile.write(block)
                    start += len(block)
                    if not server.marker.exists(): time.sleep(len(block)/550_000)
            if first and server.interrupted.is_set() and not server.resumed.is_set():
                until = float(server.marker.read_text())
                if request_started >= until:
                    server.marker.with_name('outage-first-episode-read').write_text(str(time.time()))
                    server.resumed.set()
        except OSError:
            pass
