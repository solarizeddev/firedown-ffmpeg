#!/usr/bin/env python3
"""Throttled local HTTP server for the okhttp read benchmark.

  /file?size=N&rate=R   N bytes with Content-Length, Range supported (206),
                        paced to R bytes/s (R=0: as fast as the socket takes)
  /live?rate=R          no Content-Length, close-delimited body that never
                        ends on its own (a live/ICY-style stream), paced to R

Byte p of every body is p % 251 (a prime period, so an offset or reordering
error shows up as a mismatch in the reader's check). Prints the bound port to
the file given as argv[1], then serves until killed.
"""
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PERIOD = 251
BLOCK = bytes(range(PERIOD)) * (1 << 12)  # ~1 MB, a whole number of periods


def body_slice(pos, n):
    """n pattern bytes starting at absolute position pos (n <= len(BLOCK) - PERIOD)."""
    off = pos % PERIOD
    return BLOCK[off:off + n]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, start, end, rate):
        """Send bytes [start, end) (end=None: forever), paced to rate bytes/s."""
        pos = start
        if rate > 0:
            tick = 0.02
            per_tick = max(1, int(rate * tick))
            t0 = time.monotonic()
            sent = 0
            while end is None or pos < end:
                n = per_tick if end is None else min(per_tick, end - pos)
                self.wfile.write(body_slice(pos, n))
                self.wfile.flush()
                pos += n
                sent += n
                due = t0 + sent / rate
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
        else:
            chunk = len(BLOCK) - PERIOD
            while end is None or pos < end:
                n = chunk if end is None else min(chunk, end - pos)
                self.wfile.write(body_slice(pos, n))
                pos += n

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        rate = int(q.get("rate", "0"))
        try:
            if u.path == "/live":
                self.protocol_version = "HTTP/1.0"
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header("Connection", "close")
                self.end_headers()
                self._send(0, None, rate)
                return
            if u.path != "/file":
                self.send_error(404)
                return
            size = int(q["size"])
            start, end = 0, size
            rng = self.headers.get("Range")
            if rng and rng.startswith("bytes="):
                a, _, b = rng[6:].partition("-")
                start = int(a) if a else 0
                end = min(size, int(b) + 1) if b else size
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.send_response(206)
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end - 1, size))
            else:
                self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start))
            self.end_headers()
            self._send(start, end, rate)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    srv = Server(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
