"""Fuel pump slips: a thermal print with rate, volume and the sale amount."""

from .common import Profile

PROFILE = Profile(
    name="fuel",
    keywords=(
        (r"\bpetrol\b", 3), (r"\bdiesel\b", 3), (r"\bfuel\b", 2), (r"\bpump\b", 2),
        (r"\bnozzle\b", 3), (r"\bvolume\b|\blitres?\b|\bltrs?\b", 2),
        (r"\bindian ?oil\b|\bhpcl\b|\bbpcl\b|\bhindustan petroleum\b|\bbharat petroleum\b", 3),
        (r"\bshell\b|\bnayara\b", 2),
    ),
    total_labels=(
        ("sale amount", 0.95), ("amount (rs)", 0.9), ("amount(rs)", 0.9), ("total amount", 0.9),
        ("amount", 0.85), ("total", 0.85),
    ),
    date_labels=("date", "dt"),
)
