"""From invoice text to the fields the app compares with a payment.

Each document type (ride, airline, rail, hotel, restaurant, fuel, GST
invoice) is a profile of labels in its own module; the reading itself is
shared in `common`.
"""

from __future__ import annotations

from . import common, fuel, gst, hotel, restaurant, ride, travel

PROFILES = (ride.PROFILE, travel.AIRLINE, travel.RAIL, hotel.PROFILE, restaurant.PROFILE,
            fuel.PROFILE)
UNKNOWN = common.Profile(name="unknown", keywords=())


def detect(text: str) -> common.Profile:
    """The best-scoring specific type; a plain GST invoice only when none fits."""
    lower = text.lower()
    scored = [(profile.score(lower), -index, profile) for index, profile in enumerate(PROFILES)]
    score, _, profile = max(scored, key=lambda item: item[:2])
    if score >= 2:
        return profile
    return gst.PROFILE if gst.PROFILE.score(lower) >= 2 else UNKNOWN


def extract(text: str, hints: dict | None = None) -> dict:
    """Hints never decide what is read — a total chosen because it equals
    the payment would turn the check into an echo. Only the currency is taken
    from them, and only when the invoice prints none."""
    hints = hints or {}
    lines = common.clean_lines(text)
    profile = detect("\n".join(lines))

    labels = profile.total_labels + tuple(
        item for item in common.GENERIC_TOTALS if item[0] not in dict(profile.total_labels))
    total, total_currency = common.find_total(lines, labels)
    currency = common.find_currency(lines, total_currency, hints.get("currency"))
    dates = common.find_dates(lines, profile)
    merchant, legal_name, merchant_confidence = common.find_merchant(lines)

    def iso(value):
        return value.isoformat() if value else None

    return {
        "document_type": profile.name,
        "merchant": merchant,
        "legal_name": legal_name,
        "total": total.value if total else None,
        "currency": currency,
        "tax": common.find_tax(lines),
        "invoice_date": iso(dates["invoice_date"]),
        "invoice_time": dates["invoice_time"],
        "invoice_number": common.find_invoice_number(lines),
        "period_start": iso(dates["period_start"]),
        "period_end": iso(dates["period_end"]),
        "line_items": common.find_line_items(lines, total.line if total else -1),
        "confidence": {
            "merchant": merchant_confidence,
            "total": total.confidence if total else 0.0,
            "invoice_date": dates["date_confidence"],
            "invoice_time": dates["time_confidence"],
        },
    }
