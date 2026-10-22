"""Pulls the text layer out of a PDF, standard library only.

Enough for invoices that billing systems generate: Flate-compressed content,
embedded fonts with ToUnicode maps, object streams. A scanned PDF has no text
layer and comes back as "" so the caller can fall back to OCR.
"""

from __future__ import annotations

import re
import zlib

MAX_PAGES = 10


class Name(str):
    pass


class Ref(tuple):
    pass


class Stream:
    def __init__(self, info: dict, raw: bytes):
        self.info = info
        self.raw = raw


def extract_text(data: bytes, max_pages: int = MAX_PAGES) -> str:
    doc = _Document(data)
    lines: list[str] = []
    for page in doc.pages()[:max_pages]:
        fonts = doc.fonts(page)
        for content in doc.contents(page):
            lines.extend(_render(content, fonts))
    return "\n".join(line for line in lines if line.strip())


# MARK: - Objects

_WS = b" \t\r\n\x0c\x00"
_DELIMS = b"()<>[]{}/%"
_OBJ_RE = re.compile(rb"(?<![0-9])(\d+)\s+(\d+)\s+obj\b")


class _Document:
    def __init__(self, data: bytes):
        self.data = data
        self.objects: dict[int, object] = {}
        for match in _OBJ_RE.finditer(data):
            try:
                value, end = _parse(data, match.end())
            except (ValueError, IndexError):
                continue
            if isinstance(value, dict):
                value = self._maybe_stream(value, end)
            # Later definitions (incremental updates) replace earlier ones.
            self.objects[int(match.group(1))] = value
        self._unpack_object_streams()

    def _maybe_stream(self, info: dict, end: int):
        pos = _skip_ws(self.data, end)
        if not self.data.startswith(b"stream", pos):
            return info
        start = pos + len(b"stream")
        if self.data.startswith(b"\r\n", start):
            start += 2
        elif self.data[start:start + 1] in (b"\n", b"\r"):
            start += 1
        length = info.get("Length")
        if isinstance(length, int):
            after = _skip_ws(self.data, start + length)
            if self.data.startswith(b"endstream", after):
                return Stream(info, self.data[start:start + length])
        stop = self.data.find(b"endstream", start)
        if stop < 0:
            return info
        return Stream(info, self.data[start:stop].rstrip(b"\r\n"))

    def _unpack_object_streams(self):
        for value in list(self.objects.values()):
            if not (isinstance(value, Stream) and value.info.get("Type") == "ObjStm"):
                continue
            body = _decode(value)
            if body is None:
                continue
            count, first = value.info.get("N", 0), value.info.get("First", 0)
            header = body[:first].split()
            for i in range(min(count, len(header) // 2)):
                num, offset = int(header[2 * i]), int(header[2 * i + 1])
                if num in self.objects:
                    continue
                try:
                    self.objects[num], _ = _parse(body, first + offset)
                except (ValueError, IndexError):
                    continue

    def get(self, value):
        seen = 0
        while isinstance(value, Ref) and seen < 32:
            value = self.objects.get(value[0])
            seen += 1
        return value

    def pages(self) -> list[dict]:
        root = None
        for match in re.finditer(rb"/Root\s+(\d+)\s+(\d+)\s+R", self.data):
            root = self.get(Ref((int(match.group(1)), int(match.group(2)))))
        found: list[dict] = []
        if isinstance(root, dict):
            self._walk(self.get(root.get("Pages")), found, depth=0)
        if found:
            return found
        # No usable catalogue: take every page object in file order.
        return [v for _, v in sorted(self.objects.items())
                if isinstance(v, dict) and v.get("Type") == "Page"]

    def _walk(self, node, found: list, depth: int):
        if not isinstance(node, dict) or depth > 32:
            return
        if node.get("Type") == "Page" or "Kids" not in node:
            found.append(node)
            return
        for kid in self.get(node.get("Kids")) or []:
            self._walk(self.get(kid), found, depth + 1)

    def contents(self, page: dict) -> list[bytes]:
        contents = self.get(page.get("Contents"))
        items = contents if isinstance(contents, list) else [contents]
        out = []
        for item in items:
            stream = self.get(item)
            if isinstance(stream, Stream):
                decoded = _decode(stream)
                if decoded:
                    out.append(decoded)
        return out

    def fonts(self, page: dict) -> dict:
        resources, node, depth = None, page, 0
        while isinstance(node, dict) and depth < 32:
            resources = self.get(node.get("Resources"))
            if isinstance(resources, dict):
                break
            node, depth = self.get(node.get("Parent")), depth + 1
        if not isinstance(resources, dict):
            return {}
        table = self.get(resources.get("Font")) or {}
        return {name: _Font(self, self.get(ref)) for name, ref in table.items()}


def _decode(stream: Stream) -> bytes | None:
    filters = stream.info.get("Filter")
    filters = filters if isinstance(filters, list) else ([filters] if filters else [])
    data = stream.raw
    for f in filters:
        if f in ("FlateDecode", "Fl"):
            try:
                data = zlib.decompressobj().decompress(data)
            except zlib.error:
                return None
        else:
            return None  # DCT images and rarer text filters carry no text we can read
    return data


# MARK: - Fonts

class _Font:
    """Turns the bytes a text operator shows into characters."""

    def __init__(self, doc: _Document, font):
        self.width = 1
        self.map: dict[int, str] = {}
        self.differences: dict[int, str] = {}
        if not isinstance(font, dict):
            return
        if font.get("Subtype") == "Type0":
            self.width = 2
        cmap = doc.get(font.get("ToUnicode"))
        if isinstance(cmap, Stream):
            body = _decode(cmap) if cmap.info.get("Filter") else cmap.raw
            if body:
                self._read_cmap(body)
        encoding = doc.get(font.get("Encoding"))
        if isinstance(encoding, dict):
            code = 0
            for item in encoding.get("Differences") or []:
                if isinstance(item, int):
                    code = item
                elif isinstance(item, Name):
                    self.differences[code] = _glyph(item)
                    code += 1

    def _read_cmap(self, body: bytes):
        widths = set()
        for block in re.findall(rb"beginbfchar(.*?)endbfchar", body, re.S):
            for src, dst in re.findall(rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>", block):
                widths.add(len(src) // 2)
                self.map[int(src, 16)] = _utf16(dst)
        for block in re.findall(rb"beginbfrange(.*?)endbfrange", body, re.S):
            pattern = rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]*>|\[[^\]]*\])"
            for lo, hi, dst in re.findall(pattern, block):
                widths.add(len(lo) // 2)
                lo_i, hi_i = int(lo, 16), int(hi, 16)
                if hi_i - lo_i > 0xFFFF:
                    continue
                if dst.startswith(b"["):
                    for i, item in enumerate(re.findall(rb"<([0-9A-Fa-f]*)>", dst)):
                        self.map[lo_i + i] = _utf16(item)
                else:
                    base = _utf16(dst[1:-1])
                    for i in range(hi_i - lo_i + 1):
                        self.map[lo_i + i] = base[:-1] + chr(ord(base[-1]) + i) if base else ""
        if widths:
            self.width = max(widths)

    def decode(self, raw: bytes) -> str:
        out = []
        step = self.width
        for i in range(0, len(raw) - step + 1, step):
            code = int.from_bytes(raw[i:i + step], "big")
            if code in self.map:
                out.append(self.map[code])
            elif code in self.differences:
                out.append(self.differences[code])
            elif step == 1:
                out.append(bytes([code]).decode("cp1252", errors="replace"))
        return "".join(out)


def _utf16(hexdigits: bytes) -> str:
    if len(hexdigits) % 4:
        hexdigits = hexdigits.ljust(len(hexdigits) + 4 - len(hexdigits) % 4, b"0")
    try:
        return bytes.fromhex(hexdigits.decode()).decode("utf-16-be", errors="ignore")
    except ValueError:
        return ""


_GLYPHS = {
    "space": " ", "period": ".", "comma": ",", "colon": ":", "semicolon": ";", "hyphen": "-",
    "minus": "-", "slash": "/", "parenleft": "(", "parenright": ")", "percent": "%",
    "ampersand": "&", "at": "@", "numbersign": "#", "plus": "+", "equal": "=",
    "quotesingle": "'", "quotedbl": '"', "underscore": "_", "rupee": "₹", "rupeeindian": "₹",
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
    "seven": "7", "eight": "8", "nine": "9", "dollar": "$", "Euro": "€", "sterling": "£",
}


def _glyph(name: str) -> str:
    if len(name) == 1:
        return name
    if name in _GLYPHS:
        return _GLYPHS[name]
    if name.startswith("uni") and len(name) >= 7:
        try:
            return chr(int(name[3:7], 16))
        except ValueError:
            return ""
    return ""


# MARK: - Content streams

def _render(content: bytes, fonts: dict) -> list[str]:
    """Replays the text operators, starting a new line whenever the text
    moves down the page and a gap whenever it jumps along the line."""
    lines: list[str] = []
    current: list[str] = []
    font = None
    size = 1.0
    scale = 1.0
    line_y = None
    operands: list = []

    def gap():
        if current and not current[-1].endswith(" "):
            current.append(" ")

    def newline():
        nonlocal current
        text = "".join(current).strip()
        if text:
            lines.append(text)
        current = []

    run = 0  # characters shown since the last move

    def move_to(y: float, dx: float | None = None):
        """dx is set for a move along the line (Td). Generators that kern by
        nudging the next glyph ("T", then "otal") move less than the text
        just drawn; a move past it is a gap between words or cells."""
        nonlocal line_y, run
        if line_y is not None and abs(y - line_y) > 2:
            newline()
        elif dx is None or dx > (run * 0.55 + 0.15) * size * scale:
            gap()
        line_y = y
        run = 0

    def show(value):
        nonlocal run
        if isinstance(value, bytes):
            text = font.decode(value) if font else value.decode("cp1252", errors="replace")
            current.append(text)
            run += len(text)

    pos = 0
    while True:
        try:
            token, pos = _next(content, pos)
        except (ValueError, IndexError):
            break
        if token is None:
            break
        if not isinstance(token, _Op):
            operands.append(token)
            continue
        op = token
        if op == "Tf" and len(operands) >= 2:
            font = fonts.get(operands[-2])
            size = abs(_num(operands[-1])) or 1.0
        elif op == "Tm" and len(operands) >= 6:
            scale = abs(_num(operands[-3])) or 1.0
            move_to(_num(operands[-1]) * 1.0)
        elif op in ("Td", "TD") and len(operands) >= 2:
            dy = _num(operands[-1]) * scale
            move_to((line_y or 0) + dy, dx=abs(_num(operands[-2])) * scale)
        elif op == "T*":
            newline()
            line_y = (line_y or 0) - size * scale
        elif op == "Tj" and operands:
            show(operands[-1])
        elif op in ("'", '"') and operands:
            newline()
            show(operands[-1])
        elif op == "TJ" and operands and isinstance(operands[-1], list):
            for item in operands[-1]:
                if isinstance(item, bytes):
                    show(item)
                elif _num(item) < -180:
                    gap()
        elif op == "ET":
            gap()
        operands = []
    newline()
    return lines


def _num(value) -> float:
    return float(value) if isinstance(value, (int, float)) else 0.0


class _Op(str):
    pass


def _next(buf: bytes, pos: int):
    """The next operand or operator in a content stream."""
    pos = _skip_ws(buf, pos)
    if pos >= len(buf):
        return None, pos
    c = buf[pos:pos + 1]
    if c in (b"(", b"<", b"[", b"/") or c in b"+-.0123456789":
        if buf.startswith(b"<<", pos):
            return _parse(buf, pos)
        if c == b"[":
            items, pos = [], pos + 1
            while True:
                pos = _skip_ws(buf, pos)
                if buf[pos:pos + 1] == b"]":
                    return items, pos + 1
                item, pos = _next(buf, pos)
                if item is None:
                    return items, pos
                items.append(item)
        return _parse(buf, pos)
    end = pos
    while end < len(buf) and buf[end] not in _WS and buf[end] not in _DELIMS:
        end += 1
    if end == pos:
        return _Op(chr(buf[pos])), pos + 1
    word = buf[pos:end].decode("latin-1")
    if word == "BI":  # inline image: skip its data entirely
        stop = buf.find(b"EI", end)
        return _Op("EI"), (stop + 2 if stop >= 0 else len(buf))
    return _Op(word), end


# MARK: - Syntax

def _skip_ws(buf: bytes, pos: int) -> int:
    while pos < len(buf):
        if buf[pos] in _WS:
            pos += 1
        elif buf[pos:pos + 1] == b"%":
            while pos < len(buf) and buf[pos] not in b"\r\n":
                pos += 1
        else:
            break
    return pos


def _parse(buf: bytes, pos: int):
    pos = _skip_ws(buf, pos)
    c = buf[pos:pos + 1]
    if buf.startswith(b"<<", pos):
        result, pos = {}, pos + 2
        while True:
            pos = _skip_ws(buf, pos)
            if buf.startswith(b">>", pos):
                return result, pos + 2
            key, pos = _parse(buf, pos)
            value, pos = _parse(buf, pos)
            if isinstance(key, Name):
                result[str(key)] = value
    if c == b"[":
        result, pos = [], pos + 1
        while True:
            pos = _skip_ws(buf, pos)
            if buf[pos:pos + 1] == b"]":
                return result, pos + 1
            item, pos = _parse(buf, pos)
            result.append(item)
    if c == b"/":
        end = pos + 1
        while end < len(buf) and buf[end] not in _WS and buf[end] not in _DELIMS:
            end += 1
        raw = buf[pos + 1:end].decode("latin-1")
        return Name(re.sub(r"#([0-9A-Fa-f]{2})", lambda m: chr(int(m.group(1), 16)), raw)), end
    if c == b"(":
        return _literal(buf, pos + 1)
    if c == b"<":
        end = buf.index(b">", pos)
        digits = re.sub(rb"\s", b"", buf[pos + 1:end])
        if len(digits) % 2:
            digits += b"0"
        return bytes.fromhex(digits.decode()), end + 1
    match = re.compile(rb"[+-]?(\d+\.?\d*|\.\d+)").match(buf, pos)
    if match:
        text = match.group(0)
        number = float(text) if b"." in text else int(text)
        ref = re.compile(rb"\s+(\d+)\s+R(?![A-Za-z])").match(buf, match.end())
        if ref and isinstance(number, int):
            return Ref((number, int(ref.group(1)))), ref.end()
        return number, match.end()
    end = pos
    while end < len(buf) and buf[end] not in _WS and buf[end] not in _DELIMS:
        end += 1
    word = buf[pos:end]
    if end == pos:
        raise ValueError("unexpected byte")
    return {b"true": True, b"false": False, b"null": None}.get(word, Name(word.decode("latin-1"))), end


_ESCAPES = {ord("n"): b"\n", ord("r"): b"\r", ord("t"): b"\t", ord("b"): b"\b",
            ord("f"): b"\f", ord("("): b"(", ord(")"): b")", ord("\\"): b"\\"}


def _literal(buf: bytes, pos: int):
    out = bytearray()
    depth = 1
    while pos < len(buf):
        b = buf[pos]
        if b == 0x5C:  # backslash
            nxt = buf[pos + 1]
            if nxt in _ESCAPES:
                out += _ESCAPES[nxt]
                pos += 2
            elif 0x30 <= nxt <= 0x37:
                digits = re.compile(rb"[0-7]{1,3}").match(buf, pos + 1).group(0)
                out.append(int(digits, 8) & 0xFF)
                pos += 1 + len(digits)
            elif nxt in (0x0A, 0x0D):
                pos += 3 if buf[pos + 1:pos + 3] == b"\r\n" else 2
            else:
                out.append(nxt)
                pos += 2
            continue
        if b == 0x28:
            depth += 1
        elif b == 0x29:
            depth -= 1
            if depth == 0:
                return bytes(out), pos + 1
        out.append(b)
        pos += 1
    return bytes(out), pos
