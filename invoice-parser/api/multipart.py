"""A small, binary-safe multipart/form-data reader."""

from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass
class Part:
    data: bytes
    filename: str | None
    content_type: str | None


def parse(content_type: str, body: bytes) -> dict[str, Part]:
    match = re.search(r'boundary="?([^";]+)"?', content_type or "")
    if not content_type.lower().startswith("multipart/form-data") or not match:
        raise ValueError("expected multipart/form-data")
    delimiter = b"--" + match.group(1).encode("latin-1")
    fields: dict[str, Part] = {}
    for chunk in body.split(delimiter)[1:]:
        if chunk.startswith(b"--"):
            break
        chunk = chunk[2:] if chunk.startswith(b"\r\n") else chunk
        head, separator, data = chunk.partition(b"\r\n\r\n")
        if not separator:
            continue
        if data.endswith(b"\r\n"):
            data = data[:-2]
        headers = head.decode("utf-8", errors="replace")
        name = re.search(r'name="([^"]*)"', headers)
        if not name:
            continue
        filename = re.search(r'filename="([^"]*)"', headers)
        kind = re.search(r"(?im)^content-type:\s*([^\r\n;]+)", headers)
        fields[name.group(1)] = Part(data, filename.group(1) if filename else None,
                                     kind.group(1).strip() if kind else None)
    return fields
