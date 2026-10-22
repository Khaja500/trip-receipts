"""OCR for photographed receipts, when the host has Tesseract installed.

Optional: the app already sends the text its own on-device reader found, so a
host without Tesseract still parses photos. This covers clients that send
only the image.
"""

from __future__ import annotations

import shutil
import subprocess

TIMEOUT_SECONDS = 20


def available() -> bool:
    return shutil.which("tesseract") is not None


def image_text(data: bytes) -> str:
    if not available():
        return ""
    try:
        done = subprocess.run(
            ["tesseract", "stdin", "stdout", "-l", "eng", "--psm", "4"],
            input=data, capture_output=True, timeout=TIMEOUT_SECONDS, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout.decode("utf-8", errors="replace")
