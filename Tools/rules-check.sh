#!/bin/bash
# Checks the decisions between "a message arrived" and "it is filed under a
# trip": duplicates, refunds, trip dates, retention, categories, proof.
# Runs with the plain Swift toolchain — no Xcode, no simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

cat > "$out/main.swift" <<'MAIN'
import Foundation
exit(RulesCheck.run() ? 0 : 1)
MAIN

echo "Rules check"
swiftc -O \
  TripReceipts/Models/ExpenseCategory.swift \
  TripReceipts/Services/SMSParser.swift \
  TripReceipts/Services/MatchingRules.swift \
  TripReceipts/Services/ReceiptTotalReader.swift \
  TripReceipts/Services/CategoryGuesser.swift \
  TripReceipts/Services/ProofHasher.swift \
  ParserCheck/RulesCheck.swift \
  "$out/main.swift" \
  -o "$out/rules-check"

"$out/rules-check"
