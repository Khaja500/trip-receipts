#!/bin/bash
# Runs the sample-SMS suite against the parser with the plain Swift toolchain.
# No Xcode needed — useful before touching any pattern in SMSParser.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

cat > "$out/main.swift" <<'MAIN'
import Foundation
exit(ParserCheckRunner.run() ? 0 : 1)
MAIN

echo "Parser check"
swiftc -O \
  TripReceipts/Services/SMSParser.swift \
  ParserCheck/SampleMessages.swift \
  ParserCheck/ParserCheckRunner.swift \
  "$out/main.swift" \
  -o "$out/parser-check"

"$out/parser-check"
