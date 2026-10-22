"""Restaurant and café bills. Service charge and GST sit above the grand
total; a tip, if any, is added at the card machine and so appears only in the
payment — which the app treats as close, not wrong."""

from .common import Profile

PROFILE = Profile(
    name="restaurant",
    keywords=(
        (r"\brestaurants?\b", 2), (r"\bcaf[eé]\b", 2), (r"\btable\b", 2), (r"\bkot\b", 3),
        (r"\bcovers?\b|\bpax\b", 1), (r"\bservice charge\b", 1), (r"\bsteward\b|\bwaiter\b|\bserver\b", 2),
        (r"\bdine\b|\bdining\b", 1), (r"\bkitchen\b|\bbistro\b|\beatery\b|\bdhaba\b", 2),
        (r"\bstarbucks\b|\bchaayos\b", 3), (r"\bfood\b|\bbeverages?\b", 1), (r"\bbar\b", 1),
        (r"\bdosa\b|\bidli\b|\bthali\b|\bbiryani\b|\bnaan\b|\bpaneer\b|\bcoffee\b|\bchai\b", 1),
    ),
    total_labels=(
        ("grand total", 0.95), ("net amount", 0.95), ("amount payable", 0.95), ("bill amount", 0.9),
        ("net payable", 0.95), ("total amount", 0.9), ("total", 0.85),
    ),
    date_labels=("bill date", "bill dt", "date"),
)
