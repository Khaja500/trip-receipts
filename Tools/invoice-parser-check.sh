#!/bin/bash
# Checks the invoice parser service: every fixture read as expected, then the
# real HTTP server — health, token, a PDF parsed over the wire, and the
# refusals (no token, not a receipt). Needs only python3 and curl.
set -euo pipefail
cd "$(dirname "$0")/../invoice-parser"

echo "Invoice parser fixtures"
python3 check_fixtures.py

echo ""
echo "Invoice parser over HTTP"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
log=$(mktemp)
PARSER_TOKEN_SECRET=check-secret python3 server.py --port "$port" 2>"$log" &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; rm -f "$log"' EXIT
base="http://127.0.0.1:$port"
for _ in $(seq 50); do curl -sf "$base/healthz" >/dev/null && break; sleep 0.1; done

failures=0
expect() {  # label, wanted status, actual status
  if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: HTTP $3, wanted $2"; failures=$((failures + 1)); fi
}

status=$(curl -s -o /dev/null -w '%{http_code}' "$base/healthz")
expect "health check answers" 200 "$status"

token=$(curl -s -X POST "$base/v1/install" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
[ -n "$token" ] && echo "  ok    an install gets a token" || { echo "  FAIL  no token"; failures=$((failures + 1)); }

body=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $token" \
  -F "file=@fixtures/uber_ride_pdf.pdf;type=application/pdf" \
  -F 'hints={"currency":"INR"}' "$base/v1/parse")
status=$(tail -n1 <<<"$body")
expect "a PDF receipt is parsed" 200 "$status"
fields=$(sed '$d' <<<"$body" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print(r["total"], r["invoice_date"], r["invoice_time"], r["merchant"], r["text_source"])')
if [ "$fields" = "486.0 2025-10-12 09:41 Uber pdf-text-layer" ]; then
  echo "  ok    ...and reads ₹486, 12 Oct 9:41, Uber from its text layer"
else
  echo "  FAIL  read: $fields"; failures=$((failures + 1))
fi

status=$(curl -s -o /dev/null -w '%{http_code}' -F "file=@fixtures/uber_ride_pdf.pdf" "$base/v1/parse")
expect "no token is refused" 401 "$status"

status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer tr1.forged.1.0000" \
  -F "file=@fixtures/uber_ride_pdf.pdf" "$base/v1/parse")
expect "a forged token is refused" 401 "$status"

status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
  -F "file=@fixtures/uber_ride.txt" "$base/v1/parse")
expect "a file that isn't a receipt is refused" 415 "$status"

# Line one is the startup banner; every line after it is a request.
if tail -n +2 "$log" | grep -qiE 'uber|486|arjun|127\.0\.0\.1'; then
  echo "  FAIL  the server log mentions receipt content or the caller"; failures=$((failures + 1))
else
  echo "  ok    the log holds only method, path, status, size and time"
fi

echo ""
if [ "$failures" -eq 0 ]; then echo "The service answers as specified."; else echo "$failures HTTP checks failed."; exit 1; fi
