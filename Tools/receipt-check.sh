#!/bin/bash
# End to end, without a phone: starts the invoice parser, then sends real
# receipt files through the app's own InvoiceParseClient and judges each
# answer with ReceiptVerifier — verified, warned, and unverified when the
# server is off or silent. Needs python3 and the Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d)
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
port=$(free_port)
silent_port=$(free_port)

PARSER_TOKEN_SECRET=receipt-check python3 invoice-parser/server.py --port "$port" 2>"$out/server.log" &
server=$!
# Accepts connections and never answers, to exercise the timeout.
python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',$silent_port)); s.listen(8); time.sleep(120)" &
silent=$!
trap 'kill $server $silent 2>/dev/null; wait $server $silent 2>/dev/null; rm -rf "$out"' EXIT

cat > "$out/main.swift" <<'MAIN'
import Foundation
let env = ProcessInfo.processInfo.environment
let ok = await LiveParserCheck.run(
    server: URL(string: env["PARSER_URL"]!)!,
    silent: URL(string: env["SILENT_URL"]!)!,
    fixtures: URL(fileURLWithPath: env["FIXTURES"]!)
)
exit(ok ? 0 : 1)
MAIN

echo "Receipt check, end to end"
swiftc -O \
  TripReceipts/Models/Money.swift \
  TripReceipts/Services/MatchingRules.swift \
  TripReceipts/Services/VerifierRules.swift \
  TripReceipts/Services/ReceiptVerifier.swift \
  TripReceipts/Services/InvoiceParseClient.swift \
  VerifierCheck/VerifierCases.swift \
  VerifierCheck/LiveParserCheck.swift \
  "$out/main.swift" \
  -o "$out/receipt-check"

for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/healthz" >/dev/null && break; sleep 0.1; done

PARSER_URL="http://127.0.0.1:$port" SILENT_URL="http://127.0.0.1:$silent_port" \
FIXTURES="$PWD/invoice-parser/fixtures" "$out/receipt-check"
