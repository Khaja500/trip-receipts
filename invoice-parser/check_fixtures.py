#!/usr/bin/env python3
"""Runs every invoice in fixtures/ through the parser and compares the fields
with its .expected.json. Add each misread real invoice here before touching
an extractor.

    python3 check_fixtures.py            # the rule-based reader
    python3 check_fixtures.py --gemini   # Gemini too, live (needs GEMINI_API_KEY)

With --gemini each invoice is sent twice: with an SMS for the same payment,
which Gemini must call a match, and with the amount 40% higher, a mismatch.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from api import gemini  # noqa: E402
from api.parse import parse_file  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"
INPUTS = (".pdf", ".png", ".jpg", ".jpeg", ".txt")


def main() -> int:
    live = "--gemini" in sys.argv
    if live and not gemini.enabled():
        print("Set GEMINI_API_KEY to check Gemini.")
        return 2
    failures = []
    expectations = sorted(FIXTURES.glob("*.expected.json"))
    for expected_path in expectations:
        stem = expected_path.name[: -len(".expected.json")]
        source = next((FIXTURES / (stem + ext) for ext in INPUTS if (FIXTURES / (stem + ext)).exists()), None)
        if source is None:
            print(f"  FAIL  {stem}: no input file")
            failures.append(stem)
            continue
        expected = json.loads(expected_path.read_text())
        result = run(source, payment(expected) if live else {}, live)
        problems = compare(expected, result)
        if live:
            problems += verdicts(source, expected, result)
        label = f"{source.name} ({result.get('text_source')})"
        if problems:
            print(f"  FAIL  {label}")
            for problem in problems:
                print(f"          {problem}")
            failures.append(stem)
        else:
            print(f"  ok    {label}")

    print()
    if failures:
        print(f"{len(failures)} of {len(expectations)} failed: {', '.join(failures)}")
        return 1
    print(f"{len(expectations)} invoices, all read as expected.")
    return 0


def run(source: Path, hints: dict, live: bool = False) -> dict:
    data = source.read_bytes()
    if source.suffix == ".txt":
        # Text fixtures stand in for a photo the phone has already read: sent
        # as a tiny image with the phone's text alongside.
        return parse_file(PIXEL, client_text=data.decode("utf-8"), hints=hints, use_gemini=live)
    client = FIXTURES / (source.stem + ".client.txt")
    text = client.read_text() if client.exists() else None
    return parse_file(data, client_text=text, hints=hints, use_gemini=live)


def payment(expected: dict, scale: float = 1.0) -> dict:
    """The payment an invoice's own figures describe, as the app would send it."""
    total = expected.get("total")
    if total is None:
        return {}
    amount = round(total * scale, 2)
    day = expected.get("invoice_date") or expected.get("period_start") or "2025-10-12"
    payee = (expected.get("merchant") or "merchant").upper()
    return {"amount": amount, "currency": expected.get("currency", "INR"),
            "date": f"{day}T{expected.get('invoice_time', '12:00')}:00+05:30", "payee": payee,
            "message": f"Rs.{amount:.2f} spent on HDFC Bank Card XX1234 at {payee} on {day}."}


def verdicts(source: Path, expected: dict, same: dict) -> list[str]:
    if "ai_error" in same:
        return [f"Gemini: {same['ai_error']}"]
    if expected.get("total") is None:
        return []
    problems = []
    if same["ai_check"]["verdict"] != "match":
        problems.append(f"same payment called {same['ai_check']['verdict']}: {same['ai_check']['explanation']}")
    other = run(source, payment(expected, 1.4), live=True)
    if other.get("ai_check", {}).get("verdict") != "mismatch":
        problems.append(f"40% more called {other.get('ai_check') or other.get('ai_error')}")
    return problems


def compare(expected: dict, result: dict) -> list[str]:
    problems = []
    for key, want in expected.items():
        got = result.get(key)
        if key == "merchant" and want is not None:
            names = " | ".join(n for n in (result.get("merchant"), result.get("legal_name")) if n)
            if want.lower() not in names.lower():
                problems.append(f"merchant {names or 'nothing'!r}, wanted one containing {want!r}")
        elif isinstance(want, float) and isinstance(got, (int, float)):
            if abs(got - want) > 0.005:
                problems.append(f"{key} {got}, wanted {want}")
        elif got != want:
            problems.append(f"{key} {got!r}, wanted {want!r}")
    return problems


# 1x1 white PNG.
PIXEL = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c63f8ffff3f0005fe02fea73581e40000000049454e44ae426082"
)

if __name__ == "__main__":
    sys.exit(main())
