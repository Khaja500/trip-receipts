"""Flight and train tickets. The invoice date is when the ticket was
booked — usually the day of the payment — and the journey date becomes the
travel window."""

from .common import Profile

_JOURNEY_START = ("date of journey", "journey date", "date of travel", "travel date",
                  "departure date", "departure", "departs", "flight date", "boarding date", "depart")
_JOURNEY_END = ("arrival date", "arrival", "arrives", "return date")
_BOOKED = ("booking date", "date of booking", "booked on", "issue date", "date of issue",
           "issued on", "transaction date", "invoice date", "ticket issued")
_TOTALS = (
    ("total fare", 0.95), ("total amount paid", 0.95), ("grand total", 0.95),
    ("total amount", 0.9), ("amount paid", 0.9), ("ticket fare", 0.85), ("total", 0.85),
)

AIRLINE = Profile(
    name="airline",
    keywords=(
        (r"\bindigo\b|\binterglobe\b", 3), (r"\bair india\b", 3), (r"\bvistara\b", 3),
        (r"\bspice ?jet\b", 3), (r"\bakasa\b", 3), (r"\bflight\b", 2), (r"\bairlines?\b", 2),
        (r"\bboarding\b", 1), (r"\bbaggage\b", 1), (r"\bsector\b", 1), (r"\bterminal\b", 1),
        (r"\be-?ticket\b", 1), (r"\bpnr\b", 0.5),
    ),
    total_labels=_TOTALS,
    date_labels=_BOOKED,
    period_start_labels=_JOURNEY_START,
    period_end_labels=_JOURNEY_END,
)

RAIL = Profile(
    name="rail",
    keywords=(
        (r"\birctc\b", 3), (r"\belectronic reservation slip\b", 3), (r"\btrain\b", 2),
        (r"\bberth\b", 2), (r"\bcoach\b", 1), (r"\bquota\b", 1), (r"\bpnr\b", 0.5),
    ),
    total_labels=_TOTALS,
    date_labels=_BOOKED,
    period_start_labels=_JOURNEY_START + ("start date",),
    period_end_labels=_JOURNEY_END,
)
