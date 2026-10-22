#!/usr/bin/env python3
"""Invoice parser for Trip Receipts. Standard library only (Python 3.9+).

    python3 server.py                  # http://127.0.0.1:8787
    python3 server.py --host 0.0.0.0 --port 8080

Endpoints
    GET  /healthz     {"ok": true, ...}
    POST /v1/install  issues a per-install token
    POST /v1/parse    multipart: file (+ optional text, hints) -> fields as JSON

Logs carry method, path, status, size and time — never a file, its name, its
text or the caller's address.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from api import VERSION, auth, limits, multipart, parse  # noqa: E402
from reading import ocr  # noqa: E402

MAX_BODY_BYTES = 16 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    server_version = f"invoice-parser/{VERSION}"
    timeout = 30

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"ok": True, "version": VERSION, "server_ocr": ocr.available()})
        else:
            self._send(404, {"error": "Not found."})

    def do_POST(self):
        started = time.monotonic()
        try:
            if self.path == "/v1/install":
                self._install()
            elif self.path == "/v1/parse":
                self._parse()
            else:
                self._send(404, {"error": "Not found."})
        except parse.BadRequest as error:
            self._send(error.status, {"error": str(error)})
        except Exception:  # never echo internals, never log content
            self._send(500, {"error": "The receipt couldn't be read."})
        finally:
            self._log(started)

    def _install(self):
        self._read_body(limit=4096)
        if not limits.INSTALLS_PER_HOUR.allow(self._caller()):
            return self._send(429, {"error": "Too many installs from here; try later."})
        self._send(201, {"token": auth.issue()})

    def _parse(self):
        install = auth.verify(self.headers.get("Authorization"))
        if install is None:
            return self._send(401, {"error": "Register at /v1/install and send the token."})
        if not (limits.PARSE_PER_MINUTE.allow(install) and limits.PARSE_PER_DAY.allow(install)):
            return self._send(429, {"error": "Too many receipts at once; try again shortly."})
        body = self._read_body(limit=MAX_BODY_BYTES)
        try:
            fields = multipart.parse(self.headers.get("Content-Type", ""), body)
        except ValueError:
            raise parse.BadRequest(400, "Send multipart/form-data.") from None
        self._send(200, parse.handle(fields))

    def _read_body(self, limit: int) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit:
            raise parse.BadRequest(413, "Too large.")
        return self.rfile.read(length) if length else b""

    def _caller(self) -> str:
        if os.environ.get("PARSER_TRUST_PROXY") == "1":
            forwarded = self.headers.get("X-Forwarded-For", "")
            if forwarded:
                return forwarded.split(",")[0].strip()
        return self.client_address[0]

    def _send(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
        self._status = status

    def _log(self, started: float):
        size = self.headers.get("Content-Length") or "0"
        elapsed = (time.monotonic() - started) * 1000
        print(f"{self.command} {self.path} {getattr(self, '_status', '-')} {size}B {elapsed:.0f}ms",
              file=sys.stderr, flush=True)

    def log_message(self, format, *args):
        pass  # the default line includes the caller's address


def main():
    options = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    options.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"))
    options.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8787")))
    args = options.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"invoice-parser {VERSION} on http://{args.host}:{args.port}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
