"""Field extraction shared by every document type: amounts, dates, times,
labels and the merchant. The per-type modules only say which labels matter
and how much to trust them.

One rule runs through all of it: when the text is ambiguous, say less. A
missing total makes the app show "unverified"; a wrong total makes it accuse a
good receipt.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from datetime import date

# MARK: - Profiles


@dataclass(frozen=True)
class Profile:
    """What one kind of document calls things. Labels are listed most
    trusted first, each with the confidence a value found beside it earns."""

    name: str
    keywords: tuple[tuple[str, float], ...]
    total_labels: tuple[tuple[str, float], ...] = ()
    date_labels: tuple[str, ...] = ()
    period_start_labels: tuple[str, ...] = ()
    period_end_labels: tuple[str, ...] = ()

    def score(self, text: str) -> float:
        return sum(weight for pattern, weight in self.keywords if re.search(pattern, text))


GENERIC_TOTALS: tuple[tuple[str, float], ...] = (
    ("grand total", 0.95), ("total amount payable", 0.95), ("net amount payable", 0.95),
    ("total payable", 0.95), ("amount payable", 0.95), ("net payable", 0.95),
    ("total invoice value", 0.95), ("total invoice amount", 0.95), ("invoice total", 0.95),
    ("total amount paid", 0.95), ("amount paid", 0.9), ("total paid", 0.9), ("paid amount", 0.9),
    ("amount charged", 0.9), ("total charged", 0.9), ("total bill", 0.9), ("bill amount", 0.9),
    ("bill total", 0.9), ("total fare", 0.9), ("total amount", 0.9), ("invoice value", 0.85),
    ("net amount", 0.85), ("total", 0.85), ("amount", 0.65),
)

# Lines carrying a figure that is not what was paid.
NOT_THE_TOTAL = (
    "sub total", "subtotal", "sub-total", "taxable", "cgst", "sgst", "igst", "utgst", "cess",
    "total tax", "total taxes", "tax amount", "total gst", "gst amount", "vat amount",
    "discount", "savings", "you saved", "round off", "round-off", "rounding", "rounded off by",
    "total qty", "total quantity", "total items", "no of items", "no. of items", "item count",
    "in words", "tip", "change", "tendered", "advance", "deposit", "balance", "previous",
    "wallet", "points", "mrp", "per night", "per km", "rate", "price per", "base fare",
)

GENERIC_DATE_LABELS = (
    "invoice date", "date of invoice", "inv date", "invoice dt", "bill date", "bill dt",
    "receipt date", "date of issue", "issue date", "issued on", "transaction date", "txn date",
    "order date", "booking date", "date of booking", "booked on", "payment date",
    "date & time", "date and time", "date/time", "dated", "date",
)

NOT_THE_INVOICE_DATE = (
    "due date", "due on", "valid till", "valid until", "valid upto", "expiry", "exp date",
    "date of birth", "dob", "member since", "registration date", "pay by",
)

TIME_LABELS = ("bill time", "txn time", "transaction time", "invoice time", "time")

INVOICE_NUMBER_LABELS = (
    "invoice no", "invoice number", "invoice #", "inv no", "inv. no", "bill no", "bill number",
    "receipt no", "receipt number", "folio no", "folio number", "document no", "ticket no",
    "ticket number", "booking id", "booking ref", "booking reference", "trip id", "order id",
    "order no", "pnr", "transaction id",
)

SELLER_LABELS = (
    "sold by", "seller name", "seller", "supplier name", "supplier", "merchant name", "merchant",
    "billed by", "service provider", "company name", "hotel name", "restaurant name", "outlet",
    "issued by", "operated by",
)

GENERIC_TITLES = (
    "tax invoice", "invoice", "receipt", "bill", "bill of supply", "cash memo", "cash bill",
    "retail invoice", "guest folio", "folio", "e-ticket", "eticket", "electronic ticket",
    "electronic reservation slip", "booking confirmation", "original for recipient",
    "duplicate for transporter", "payment receipt", "trip receipt", "your trip", "customer copy",
    "merchant copy", "welcome", "estimate", "order summary", "invoice cum receipt",
)

ENTITY_WORDS = re.compile(
    r"\b(pvt|private|ltd|limited|llp|inc|corporation|hotels?|resorts?|restaurants?|cafe|café|"
    r"inn|residency|suites|kitchen|dhaba|bhavan|foods?|eatery|bistro|lounge|bar|petroleum|"
    r"fuels?|filling station|service station|travels|tours|airlines?|aviation)\b", re.I,
)

# Known brands, matched anywhere: (pattern, name shown, registered name).
BRANDS: tuple[tuple[str, str, str | None], ...] = (
    (r"\buber\b", "Uber", "Uber India Systems Private Limited"),
    (r"\bani technologies\b|\bola ?cabs\b|\bola\b", "Ola", "ANI Technologies Private Limited"),
    (r"\brapido\b|\broppen transportation\b", "Rapido", "Roppen Transportation Services Private Limited"),
    (r"\bblu ?smart\b", "BluSmart", None),
    (r"\bmeru\b", "Meru", None),
    (r"\bnamma yatri\b", "Namma Yatri", None),
    (r"\bindigo\b|\binterglobe aviation\b", "IndiGo", "InterGlobe Aviation Limited"),
    (r"\bair india express\b", "Air India Express", None),
    (r"\bair india\b", "Air India", "Air India Limited"),
    (r"\bvistara\b", "Vistara", None),
    (r"\bspice ?jet\b", "SpiceJet", "SpiceJet Limited"),
    (r"\bakasa air\b|\bsnv aviation\b", "Akasa Air", "SNV Aviation Private Limited"),
    (r"\birctc\b|\bindian railway catering\b", "IRCTC",
     "Indian Railway Catering and Tourism Corporation Ltd"),
    (r"\bmakemytrip\b", "MakeMyTrip", "MakeMyTrip (India) Private Limited"),
    (r"\bgoibibo\b", "Goibibo", None),
    (r"\bcleartrip\b", "Cleartrip", None),
    (r"\beasemytrip\b", "EaseMyTrip", None),
    (r"\bixigo\b", "ixigo", None),
    (r"\boyo\b|\boravel stays\b", "OYO", "Oravel Stays Limited"),
    (r"\bzomato\b", "Zomato", None),
    (r"\bswiggy\b|\bbundl technologies\b", "Swiggy", "Bundl Technologies Private Limited"),
    (r"\bstarbucks\b", "Starbucks", "Tata Starbucks Private Limited"),
    (r"\bindian ?oil\b|\biocl\b", "Indian Oil", "Indian Oil Corporation Limited"),
    (r"\bhindustan petroleum\b|\bhpcl\b", "HPCL", "Hindustan Petroleum Corporation Limited"),
    (r"\bbharat petroleum\b|\bbpcl\b", "BPCL", "Bharat Petroleum Corporation Limited"),
)

# A brand mentioned as the channel, not the seller: "booked via MakeMyTrip".
VIA = re.compile(r"\b(via|through|powered by|booked on|booked through|partner)\b", re.I)

# MARK: - Patterns

MONTH = (r"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|"
         r"sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?")
MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8,
          "sep": 9, "oct": 10, "nov": 11, "dec": 12}

ISO_DATE = re.compile(r"(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)")
NUM_DATE = re.compile(r"(?<![\d/.-])(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?![\d/])")
DMY_TEXT = re.compile(r"(?<![a-z\d])(\d{1,2})(?:st|nd|rd|th)?[\s\-/.,']*" + MONTH
                      + r"(?![a-z])[\s\-/.,']*(\d{4}|\d{2})(?!\d)", re.I)
MDY_TEXT = re.compile(r"(?<![a-z])" + MONTH + r"(?![a-z])\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)",
                      re.I)
TIME = re.compile(r"(?<![\d:])(\d{1,2})[:.](\d{2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|hrs|hours)?"
                  r"(?![\d%])", re.I)

CURRENCY = r"(₹|rs\.?|inr|usd|us\$|\$|eur|€|gbp|£|aed|sgd|thb|myr)"
NUMBER = r"(\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)"
AMOUNT = re.compile(r"(?<![\w.,/])" + CURRENCY + r"?\s*" + NUMBER + r"(?![\w%]|[.,]\d|/(?!-))", re.I)
PERCENT = re.compile(r"\d+(?:\.\d+)?\s*%")

CURRENCY_CODES = {"₹": "INR", "rs": "INR", "rs.": "INR", "inr": "INR", "$": "USD", "us$": "USD",
                  "usd": "USD", "€": "EUR", "eur": "EUR", "£": "GBP", "gbp": "GBP"}


@dataclass
class Amount:
    value: float
    currency: str | None
    start: int


@dataclass
class Found:
    value: object
    confidence: float
    line: int = -1


# MARK: - Text


def clean_lines(text: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text)
    # Old Indian fonts drew the rupee sign on the backtick key.
    text = re.sub(r"`\s*(?=\d)", "₹", text)
    lines = (re.sub(r"[ \t ]+", " ", line).strip() for line in text.splitlines())
    return [line for line in lines if line]


def has_label(line_lower: str, label: str) -> re.Match | None:
    return re.search(r"(?<![a-z])" + re.escape(label) + r"(?![a-z])", line_lower)


def has_any(line_lower: str, labels) -> bool:
    return any(has_label(line_lower, label) for label in labels)


# MARK: - Dates and times


def dates_in(line: str) -> list[tuple[date, int, int]]:
    """Every date on the line as (date, start, end). Numbers are read
    day-first, as Indian invoices print them, unless that can't be a date."""
    found: list[tuple[date, int, int]] = []
    taken: list[tuple[int, int]] = []

    def add(y: int, m: int, d: int, span):
        if y < 100:
            y += 2000
        try:
            value = date(y, m, d)
        except ValueError:
            return
        if not 2000 <= value.year <= 2100:
            return
        if any(span[0] < e and s < span[1] for s, e in taken):
            return
        taken.append(span)
        found.append((value, span[0], span[1]))

    for m in ISO_DATE.finditer(line):
        add(int(m.group(1)), int(m.group(2)), int(m.group(3)), m.span())
    for m in DMY_TEXT.finditer(line):
        add(int(m.group(3)), MONTHS[m.group(2)[:3].lower()], int(m.group(1)), m.span())
    for m in MDY_TEXT.finditer(line):
        add(int(m.group(3)), MONTHS[m.group(1)[:3].lower()], int(m.group(2)), m.span())
    for m in NUM_DATE.finditer(line):
        a, b, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        day, month = (b, a) if b > 12 >= a else (a, b)
        add(y, month, day, m.span())
    return sorted(found, key=lambda item: item[1])


def times_in(line: str) -> list[tuple[str, int, int]]:
    """Every clock time as ("HH:MM", start, end). A bare "12.30" with no
    am/pm is a price, not a time, so dots need a suffix."""
    out = []
    for m in TIME.finditer(line):
        hour, minute, suffix = int(m.group(1)), int(m.group(2)), (m.group(4) or "").lower()
        separator = line[m.start(2) - 1]
        if separator == "." and suffix not in ("am", "pm", "a.m.", "p.m."):
            continue
        if suffix.startswith("p") and hour < 12:
            hour += 12
        elif suffix.startswith("a") and hour == 12:
            hour = 0
        if hour > 23 or minute > 59:
            continue
        out.append((f"{hour:02d}:{minute:02d}", m.start(), m.end()))
    return out


def mask_dates_and_times(line: str) -> str:
    spans = [(s, e) for _, s, e in dates_in(line)] + [(s, e) for _, s, e in times_in(line)]
    chars = list(line)
    for s, e in spans:
        for i in range(s, e):
            chars[i] = " "
    return "".join(chars)


# MARK: - Amounts


def amounts_in(line: str, start: int = 0) -> list[Amount]:
    """Money on the line from `start`, skipping dates, times, percentages and
    the long digit runs that are phone numbers or ids."""
    masked = mask_dates_and_times(line)
    masked = PERCENT.sub(lambda m: " " * len(m.group(0)), masked)
    out = []
    for m in AMOUNT.finditer(masked, start):
        symbol, digits = m.group(1), m.group(2)
        plain = digits.replace(",", "")
        if symbol is None and "." not in plain and "," not in digits and len(plain) >= 7:
            continue
        value = float(plain)
        if value <= 0 or value >= 10_000_000:
            continue
        code = CURRENCY_CODES.get(symbol.lower(), symbol.upper()) if symbol else None
        out.append(Amount(value, code, m.start()))
    return out


def only_amount(line: str) -> bool:
    return bool(re.fullmatch(r"\s*(₹|rs\.?|inr|\$|€|£)?\s*[\d,]+(\.\d{1,2})?\s*(/-)?\s*", line, re.I))


# MARK: - Fields


def find_total(lines: list[str], labels) -> tuple[Found | None, str | None]:
    """The labelled total, most trusted label first; a later line wins a tie,
    since the grand total sits at the bottom."""
    best = None  # (rank, line index, amount, confidence)
    for i, line in enumerate(lines):
        lower = line.lower()
        if has_any(lower, NOT_THE_TOTAL):
            continue
        for rank, (label, confidence) in enumerate(labels):
            match = has_label(lower, label)
            if not match:
                continue
            found = amounts_in(line, match.end())
            if not found and i + 1 < len(lines) and only_amount(lines[i + 1]):
                found = amounts_in(lines[i + 1])
            if found:
                candidate = (rank, i, found[-1], confidence)
                if best is None or (rank, -i) < (best[0], -best[1]):
                    best = candidate
            break
    if best:
        return Found(best[2].value, best[3], best[1]), best[2].currency

    # Nothing labelled: the largest sum of money, trusted too little to compare.
    marked = [a for line in lines for a in amounts_in(line) if a.currency]
    if marked:
        top = max(marked, key=lambda a: a.value)
        return Found(top.value, 0.5), top.currency
    return None, None


def find_currency(lines: list[str], near: str | None, hint: str | None) -> str:
    if near:
        return near
    counts: dict[str, int] = {}
    for line in lines:
        for amount in amounts_in(line):
            if amount.currency:
                counts[amount.currency] = counts.get(amount.currency, 0) + 1
    if counts:
        return max(counts, key=counts.get)
    return (hint or "INR").upper()


def find_tax(lines: list[str]) -> float | None:
    for line in reversed(lines):
        lower = line.lower()
        if has_any(lower, ("total tax", "total taxes", "total gst", "tax amount", "gst amount")):
            found = amounts_in(line)
            if found:
                return found[-1].value
    parts: dict[str, float] = {}
    for line in lines:
        lower = line.lower()
        for component in ("cgst", "sgst", "utgst", "igst"):
            if has_label(lower, component):
                found = amounts_in(line)
                if found:
                    parts[component] = found[-1].value
    return round(sum(parts.values()), 2) if parts else None


def find_dates(lines: list[str], profile: Profile) -> dict:
    """The invoice's own date and time, and any stay or travel window."""
    period_start = period_end = None
    period_lines = set()
    for i, line in enumerate(lines):
        lower = line.lower()
        found = dates_in(line)
        if not found:
            continue
        if period_start is None and has_any(lower, profile.period_start_labels):
            period_start = found[0][0]
            period_lines.add(i)
            if len(found) > 1 and period_end is None:
                period_end = found[1][0]
        elif period_end is None and has_any(lower, profile.period_end_labels):
            period_end = found[0][0]
            period_lines.add(i)

    labels = profile.date_labels + GENERIC_DATE_LABELS
    best = None  # (rank, line, date, start)
    for i, line in enumerate(lines):
        if i in period_lines:
            continue
        lower = line.lower()
        found = dates_in(line)
        if not found or has_any(lower, NOT_THE_INVOICE_DATE):
            continue
        rank = next((r for r, label in enumerate(labels) if has_label(lower, label)), 999)
        candidate = (rank, i, found[0][0], found[0][2])
        if best is None or (rank, i) < (best[0], best[1]):
            best = candidate

    result = {"invoice_date": None, "invoice_time": None, "period_start": period_start,
              "period_end": period_end, "date_confidence": 0.0, "time_confidence": 0.0}
    if best is None:
        return result
    rank, line_index, value, after = best
    result["invoice_date"] = value
    result["date_confidence"] = 0.95 if rank < len(labels) - 1 else (0.9 if rank < 999 else 0.75)

    line = lines[line_index]
    same_line = [t for t in times_in(line) if t[1] >= after - 1] or times_in(line)
    if same_line:
        result["invoice_time"], result["time_confidence"] = same_line[0][0], 0.9
        return result
    following = lines[line_index + 1] if line_index + 1 < len(lines) else ""
    if following and not dates_in(following) and times_in(following) and line_index + 1 not in period_lines:
        result["invoice_time"], result["time_confidence"] = times_in(following)[0][0], 0.85
        return result
    for i, other in enumerate(lines):
        if i in period_lines or has_any(other.lower(), profile.period_start_labels + profile.period_end_labels):
            continue
        lower = other.lower()
        if any(lower.startswith(label) for label in TIME_LABELS) and times_in(other):
            result["invoice_time"], result["time_confidence"] = times_in(other)[0][0], 0.8
            break
    return result


def find_invoice_number(lines: list[str]) -> str | None:
    for line in lines:
        lower = line.lower()
        for label in INVOICE_NUMBER_LABELS:
            match = has_label(lower, label)
            if not match:
                continue
            rest = line[match.end():]
            value = re.match(r"[\s:#.\-]*(?:no\.?|number)?[\s:#.\-]*([A-Za-z0-9][A-Za-z0-9/\-_]{2,})",
                             rest, re.I)
            if value and not dates_in(value.group(1)) and re.search(r"\d", value.group(1)):
                return value.group(1)
    return None


def find_merchant(lines: list[str]) -> tuple[str | None, str | None, float]:
    """(name, registered name, confidence). A labelled seller beats a brand
    in the header, which beats a company name, which beats the first line."""
    header = lines[:8]

    for i, line in enumerate(lines):
        lower = line.lower()
        for label in SELLER_LABELS:
            match = has_label(lower, label)
            if not match or match.start() > 3:
                continue
            value = _clean_name(line[match.end():].lstrip(" :-#"))
            if not value and i + 1 < len(lines):
                value = _clean_name(lines[i + 1])
            if value and re.search(r"[A-Za-z]{2}", value):
                return value, _registered(lines, value), 0.9

    outlet = _entity_line(lines[:10])
    brand = _brand(header)
    if brand:
        # A fuel pump or franchise prints the brand and its own name; the
        # bank SMS usually carries the latter, so keep it as the second name.
        second = outlet if outlet and outlet.lower() != brand[0].lower() else None
        return brand[0], second or brand[1] or _registered(lines, brand[0]), 0.9

    if outlet:
        return outlet, None, 0.85

    brand = _brand(lines)
    if brand:
        return brand[0], brand[1] or _registered(lines, brand[0]), 0.8

    for line in lines:
        if ENTITY_WORDS.search(line) and _mostly_words(line) and not _is_title(line):
            name = _clean_name(line)
            if name:
                return name, None, 0.75

    for line in header:
        if _mostly_words(line) and not _is_title(line) and "thank" not in line.lower():
            name = _clean_name(line)
            if name and len(name) >= 3:
                return name, None, 0.6
    return None, None, 0.0


def _entity_line(lines: list[str]) -> str | None:
    """A line that names a business: "Barbeque Nation Hospitality Ltd",
    "Shree Sai Service Station". Labelled lines ("Hotel: …") are fields."""
    for line in lines:
        if ":" in line or not ENTITY_WORDS.search(line):
            continue
        if _mostly_words(line) and not _is_title(line):
            name = _clean_name(line)
            if name:
                return name
    return None


def _brand(lines: list[str]):
    for line in lines:
        lower = line.lower()
        for pattern, name, legal in BRANDS:
            match = re.search(pattern, lower)
            if match and not VIA.search(lower[:match.start()]):
                return name, legal
    return None


def _registered(lines: list[str], name: str) -> str | None:
    for line in lines:
        if re.search(r"\b(pvt|private|ltd|limited|llp)\b", line, re.I) and _mostly_words(line):
            legal = _clean_name(line)
            if legal and legal.lower() != name.lower():
                return legal
    return None


def _clean_name(text: str) -> str:
    text = re.split(r"\s+(?:gstin|gst no|gst|cin|pan|fssai|ph|phone|tel|mob|mobile|email|www\.)\b|"
                    r"\s+[-|]\s+|,\s+", text, maxsplit=1, flags=re.I)[0]
    text = text.strip(" :-|,.*")
    return text[:80]


def _mostly_words(line: str) -> bool:
    letters = sum(c.isalpha() for c in line)
    digits = sum(c.isdigit() for c in line)
    return letters >= 3 and digits <= letters / 3


def _is_title(line: str) -> bool:
    lower = re.sub(r"[^a-z ]", "", line.lower()).strip()
    return lower in GENERIC_TITLES or any(lower.startswith(t + " ") and len(lower) < len(t) + 12
                                          for t in GENERIC_TITLES)


def find_line_items(lines: list[str], until: int) -> list[dict]:
    items = []
    for line in lines[:until if until >= 0 else len(lines)]:
        lower = line.lower()
        if has_any(lower, NOT_THE_TOTAL) or has_any(lower, [label for label, _ in GENERIC_TOTALS]):
            continue
        if has_any(lower, INVOICE_NUMBER_LABELS) or dates_in(line) or times_in(line):
            continue
        found = amounts_in(line)
        if not found:
            continue
        description = line[:found[0].start].strip(" :-=x*")
        if len(re.findall(r"[A-Za-z]", description)) < 3:
            continue
        items.append({"description": description[:80], "amount": found[-1].value})
        if len(items) == 25:
            break
    return items
