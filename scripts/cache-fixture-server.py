"""Loopback-only HTTP fixture for background cache integration tests."""

import argparse
import io
import json
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit


buffer = io.BytesIO()
with wave.open(buffer, "wb") as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(44100)
    audio.writeframes(b"\0" * (44100 * 2 * 4))
AUDIO = buffer.getvalue()
COUNTS = {}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except ConnectionResetError:
            pass

    def send_json(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path.endswith("/play/url"):
            track_id = body.get("songId", body.get("trackId", "fixture"))
            self.send_json({"url": f"http://127.0.0.1:{self.server.server_port}/audio?{urlencode({'id': track_id})}"})
        else:
            self.send_error(404)

    def do_GET(self):
        request = urlsplit(self.path)
        if request.path == "/health":
            self.send_json({"fixture": "lemon-cache-tests"})
            return
        if request.path == "/stats":
            with LOCK:
                self.send_json(dict(COUNTS))
            return
        if request.path.endswith("/settings"):
            self.send_json({"player.playQuality": "320k"})
            return
        if request.path != "/audio":
            self.send_error(404)
            return
        track_id = parse_qs(request.query).get("id", ["fixture"])[0]
        with LOCK:
            COUNTS[track_id] = COUNTS.get(track_id, 0) + 1
        start = 0
        header = self.headers.get("Range", "")
        if header.startswith("bytes="):
            start = int(header.removeprefix("bytes=").split("-")[0])
        if start >= len(AUDIO):
            self.send_error(416)
            return
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(AUDIO) - start))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"fixture-wav-v1"')
        self.send_header("Last-Modified", "Thu, 01 Oct 2026 00:00:00 GMT")
        if start:
            self.send_header("Content-Range", f"bytes {start}-{len(AUDIO) - 1}/{len(AUDIO)}")
        self.end_headers()
        try:
            for offset in range(start, len(AUDIO), 16384):
                self.wfile.write(AUDIO[offset:offset + 16384])
                self.wfile.flush()
                time.sleep(0.06)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18763)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
