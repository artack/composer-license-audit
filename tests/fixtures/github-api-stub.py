#!/usr/bin/env python3
"""Minimal GitHub REST API stub for the PR-comment tests.

Usage: github-api-stub.py <state-dir>

- Writes the chosen port to <state-dir>/port once listening.
- Appends every request as one JSON line to <state-dir>/requests.jsonl
  ({"method", "path", "headers", "body"}).
- GET responses come from <state-dir>/responses.json, a map of
  "<path?query>" -> JSON body; unknown paths return [].
- POST answers {"id": 1001} with 201; PATCH echoes the id from the path.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler
from socketserver import TCPServer

state_dir = sys.argv[1]
responses = {}
responses_path = os.path.join(state_dir, "responses.json")
if os.path.exists(responses_path):
    with open(responses_path, encoding="utf-8") as fh:
        responses = json.load(fh)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep test output quiet
        pass

    def _record(self, body):
        entry = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body,
        }
        with open(os.path.join(state_dir, "requests.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")

    def _send(self, obj, code=200):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return raw

    def do_GET(self):
        self._record(None)
        self._send(responses.get(self.path, []))

    def do_POST(self):
        self._record(self._read_body())
        self._send({"id": 1001}, 201)

    def do_PATCH(self):
        self._record(self._read_body())
        self._send({"id": int(self.path.rsplit("/", 1)[-1])})


TCPServer.allow_reuse_address = True
with TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(os.path.join(state_dir, "port"), "w", encoding="utf-8") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
