"""POST /v1/parse: one receipt in, the fields it states out.

The file lives only in this request's memory. Nothing about its content —
not the text, not the name — is stored or logged.
"""

from __future__ import annotations

import json

import extractors
import reading

from . import VERSION, gemini

MAX_FILE_BYTES = 12 * 1024 * 1024


class BadRequest(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def handle(fields: dict) -> dict:
    upload = fields.get("file")
    if upload is None or not upload.data:
        raise BadRequest(400, "Send the receipt as the multipart field 'file'.")
    if len(upload.data) > MAX_FILE_BYTES:
        raise BadRequest(413, "The receipt is larger than 12 MB.")

    text = fields["text"].data.decode("utf-8", errors="replace") if "text" in fields else None
    try:
        hints = json.loads(fields["hints"].data) if "hints" in fields else {}
    except ValueError:
        raise BadRequest(400, "'hints' must be JSON.") from None
    return parse_file(upload.data, client_text=text, hints=hints if isinstance(hints, dict) else {})


def parse_file(data: bytes, client_text: str | None, hints: dict, use_gemini: bool | None = None) -> dict:
    kind = reading.sniff(data)
    if kind is None:
        raise BadRequest(415, "Only PDF, JPEG, PNG and HEIC receipts can be read.")
    text, source = reading.read_text(data, kind, client_text)
    result = extractors.extract(text, hints)
    result["text_source"] = source
    result["file_type"] = kind
    result["version"] = VERSION
    if gemini.enabled() if use_gemini is None else use_gemini:
        try:
            result = gemini.merge(result, gemini.check(data, kind, client_text, hints), hints)
        except gemini.Unavailable as reason:
            result["ai_error"] = str(reason)
    return result
