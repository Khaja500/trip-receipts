"""Per-install tokens, signed rather than stored.

A token is an install id and its issue time, signed with the server's
secret, so checking one needs no database. Set PARSER_TOKEN_SECRET to keep
tokens valid across restarts; without it each restart issues a fresh secret
and the app quietly registers again.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import sys
import time

PREFIX = "tr1"


def _secret() -> bytes:
    configured = os.environ.get("PARSER_TOKEN_SECRET", "")
    if configured:
        return configured.encode()
    print("PARSER_TOKEN_SECRET not set: tokens last until this process stops.", file=sys.stderr)
    return secrets.token_bytes(32)


SECRET = _secret()


def issue() -> str:
    payload = f"{secrets.token_urlsafe(12)}.{int(time.time())}"
    return f"{PREFIX}.{payload}.{_sign(payload)}"


def verify(header: str | None) -> str | None:
    """The install id behind a valid `Authorization: Bearer` header."""
    if not header or not header.startswith("Bearer "):
        return None
    parts = header[len("Bearer "):].strip().split(".")
    if len(parts) != 4 or parts[0] != PREFIX:
        return None
    payload = f"{parts[1]}.{parts[2]}"
    if not hmac.compare_digest(_sign(payload), parts[3]):
        return None
    return parts[1]


def _sign(payload: str) -> str:
    return hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()[:32]
