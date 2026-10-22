"""Cab, auto and bike-taxi receipts: Uber, Ola, Rapido and the like. The
total sits beside "Total" or "Amount charged"; the date and time of the ride
usually head the receipt without a label."""

from .common import Profile

PROFILE = Profile(
    name="ride",
    keywords=(
        (r"\buber\b", 3), (r"\bola\b|\bani technologies\b", 3), (r"\brapido\b", 3),
        (r"\bblu ?smart\b", 3), (r"\bmeru\b", 2), (r"\bnamma yatri\b", 3),
        (r"\btrip fare\b|\bride fare\b", 2), (r"\bpick ?up\b", 2), (r"\bdrop\b", 1),
        (r"\bdriver\b|\bcaptain\b", 1), (r"\bbooking fee\b", 1), (r"\bkm\b|\bkms\b", 1),
        (r"\bcab\b|\btaxi\b|\bride\b", 1),
    ),
    total_labels=(
        ("total bill (rounded off)", 0.95), ("amount charged", 0.95), ("total fare", 0.95),
        ("total", 0.9), ("amount paid", 0.9), ("trip fare", 0.7),
    ),
    date_labels=("trip date", "ride date", "ride on", "trip on"),
)
