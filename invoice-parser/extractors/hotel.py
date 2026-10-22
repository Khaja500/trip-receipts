"""Hotel folios and stay invoices. The bill is dated at checkout, but the
stay — arrival to departure — is the window a payment may fall in: an
advance at check-in is the same stay."""

from .common import Profile

PROFILE = Profile(
    name="hotel",
    keywords=(
        (r"\bhotels?\b", 2), (r"\bresorts?\b", 2), (r"\bfolio\b", 3), (r"\bcheck[- ]?in\b", 2),
        (r"\bcheck[- ]?out\b", 1), (r"\barrival\b", 1), (r"\broom\b", 1), (r"\bnights?\b", 1),
        (r"\bguest\b", 1), (r"\bstay\b", 1), (r"\boyo\b|\boravel\b", 3), (r"\bsuites?\b", 1),
    ),
    total_labels=(
        ("grand total", 0.95), ("total amount", 0.9), ("total charges", 0.9), ("net amount", 0.9),
        ("amount paid", 0.9), ("total", 0.85),
    ),
    date_labels=("bill date", "folio date", "invoice date", "date of invoice"),
    period_start_labels=("arrival date", "date of arrival", "arrival", "check-in", "check in",
                         "checkin", "arr date", "arr. date", "stay from", "stay"),
    period_end_labels=("departure date", "date of departure", "departure", "check-out",
                       "check out", "checkout", "dep date", "dep. date"),
)
