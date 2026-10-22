#!/bin/bash
# Runs the payment + invoice pairs in VerifierCheck/ through ReceiptVerifier:
# what matches, what warns, what stays unverified.
# Runs with the plain Swift toolchain — no Xcode, no simulator, no server.
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

cat > "$out/main.swift" <<'MAIN'
import Foundation
exit(VerifierCheckRunner.run() ? 0 : 1)
MAIN

echo "Verifier check"
swiftc -O \
  TripReceipts/Models/Money.swift \
  TripReceipts/Services/MatchingRules.swift \
  TripReceipts/Services/VerifierRules.swift \
  TripReceipts/Services/ReceiptVerifier.swift \
  VerifierCheck/VerifierCases.swift \
  VerifierCheck/VerifierCheckRunner.swift \
  "$out/main.swift" \
  -o "$out/verifier-check"

"$out/verifier-check"
