#!/usr/bin/env python3
"""
Live dashboard for radar-bench's stream mode.

radar-bench (--telemetry 127.0.0.1:7700) connects to this server and sends
one JSON frame per line; browsers viewing http://<host>:8080/ long-poll
/frame?after=<seq> for the next one. (Each poll is a complete response, so
proxies and antivirus web filters that buffer streamed responses, such as
Server-Sent Events, can't hold frames back.) It uses only the Python standard
library.

usage: server.py [--http-port 8080] [--telemetry-port 7700]
"""

import argparse
import os
import socket
import socketserver
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))


class Latest:
    """The most recent frame, and a condition to wait for the next one."""

    def __init__(self):
        self.cond = threading.Condition()
        self.frame = None
        self.seq = 0
        self.producer = False

    def put(self, frame):
        with self.cond:
            self.frame = frame
            self.seq += 1
            self.cond.notify_all()

    def wait(self, seq, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.seq != seq, timeout)
            return self.seq, self.frame


latest = Latest()


class TelemetryHandler(socketserver.StreamRequestHandler):
    """One radar-bench connection: a stream of JSON lines."""

    def handle(self):
        latest.producer = True
        print(f"radar-bench connected from {self.client_address[0]}")
        try:
            for line in self.rfile:
                if line.strip():
                    latest.put(line.rstrip(b"\n"))
        finally:
            latest.producer = False
            print("radar-bench disconnected")


class TelemetryServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class HttpHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/frame"):
            self.frame()
        else:
            self.send_error(404)

    def frame(self):
        """The first frame after ?after=<seq>, waiting up to 2 s for it."""
        after = -1
        if "after=" in self.path:
            try:
                after = int(self.path.split("after=", 1)[1].split("&")[0])
            except ValueError:
                pass
        seq, frame = latest.wait(after, 2.0)
        body = frame if (seq != after and frame is not None) else b""
        try:
            self.send_response(200 if body else 204)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Seq", str(seq))
            self.send_header("X-Producer", "live" if latest.producer else "idle")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--http-port", type=int, default=8080)
    ap.add_argument("--telemetry-port", type=int, default=7700)
    a = ap.parse_args()

    tel = TelemetryServer(("127.0.0.1", a.telemetry_port), TelemetryHandler)
    threading.Thread(target=tel.serve_forever, daemon=True).start()
    http = ThreadingHTTPServer(("0.0.0.0", a.http_port), HttpHandler)
    http.daemon_threads = True
    print(f"dashboard: http://{socket.gethostname()}:{a.http_port}/ "
          f"(radar-bench --telemetry 127.0.0.1:{a.telemetry_port})")
    try:
        http.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
