"""Turns an uploaded file into text, in memory. Nothing is written to disk."""

from __future__ import annotations

from . import ocr, pdf_text


def sniff(data: bytes) -> str | None:
    """The file's real type from its first bytes; names and headers lie."""
    if data.startswith(b"%PDF"):
        return "pdf"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"mif1", b"msf1", b"hevc"):
        return "heic"
    return None


def read_text(data: bytes, kind: str, client_text: str | None) -> tuple[str, str]:
    """Text and where it came from. A PDF's own text layer is exact; for a
    photo, the phone's reading beats server OCR on a crumpled bill, so it is
    preferred when sent."""
    if kind == "pdf":
        text = pdf_text.extract_text(data)
        if text.strip():
            return text, "pdf-text-layer"
    if client_text and client_text.strip():
        return client_text, "client-text"
    if kind in ("jpeg", "png"):
        text = ocr.image_text(data)
        if text.strip():
            return text, "server-ocr"
    return "", "none"
