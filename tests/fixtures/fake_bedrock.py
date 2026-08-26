#!/usr/bin/env python3
"""A fake Bedrock sidecar for tests/test_engine.nim.

It answers the Messages API shape the game's LLM client expects and RECORDS
every request's in-flight window to a log file, so the test can prove all four
seats' calls really were issued as ONE PARALLEL BATCH rather than one after
another. `--hang <seconds>` makes it sleep instead, which is how the per-turn
deadline is exercised without a network.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_PATH = sys.argv[1]
HANG = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
LOCK = threading.Lock()
START = time.monotonic()

REPLY = {
    "note": "hold the gate, I take the north lane",
    "cogs": [{"intent": "screen", "target": [820, 300],
              "face": [900, 290], "say": "north"}],
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        began = time.monotonic() - START
        length = int(self.headers.get("content-length") or 0)
        self.rfile.read(length)
        # Every seat gets the SAME reply; the test only cares about timing and
        # about the reply being usable.
        if HANG > 0:
            time.sleep(HANG)
        body = json.dumps({
            "content": [{"type": "text", "text": json.dumps(REPLY)}],
            "stop_reason": "end_turn",
        }).encode()
        ended = time.monotonic() - START
        with LOCK:
            with open(LOG_PATH, "a", encoding="utf-8") as log:
                log.write(f"{began:.4f} {ended:.4f}\n")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
