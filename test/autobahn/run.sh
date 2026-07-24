#!/usr/bin/env bash
#
# http:4.3 — Autobahn|Testsuite conformance for the cajeta-http WebSocket
# SERVER. Builds the echo-server testee, runs the Autobahn `fuzzingclient`
# against it (in docker), and parses the JSON report into a pass/fail exit
# code.
#
# This is a TAGGED-RUN fixture (the full suite is ~500 cases and takes a few
# minutes) — not part of `cajeta test`. Run it deliberately:
#
#     test/autobahn/run.sh
#
# Requirements: a running docker daemon (pulls crossbario/autobahn-testsuite
# on first run) and the cajeta compiler. Override the compiler with
# CAJETA_BIN and the library archive with CJA.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

CAJETA_BIN="${CAJETA_BIN:-/home/julian/code/cpp/cajeta-release-091/build/src/cajeta}"
CJA="${CJA:-$ROOT/build/archive/dev.cajeta.http-0.1.1.cja}"
CODEC="${CODEC:-/home/julian/.olla/dev.cajeta.codec/0.6.0/dev.cajeta.codec-0.6.0.cja}"
IMAGE="${IMAGE:-crossbario/autobahn-testsuite}"
PORT="${PORT:-9001}"

BUILD_DIR="$HERE/build"
SERVER_BIN="$BUILD_DIR/autobahn-echo"
REPORTS="$HERE/reports"

echo "== [1/4] building the echo-server testee =="
mkdir -p "$BUILD_DIR" "$REPORTS"
if [[ ! -f "$CJA" ]]; then
    echo "library archive not found: $CJA" >&2
    echo "build it first, e.g.:" >&2
    echo "  $CAJETA_BIN '*' src/main/cajeta build/archive --emit=cja --classpath=$CODEC -o $CJA" >&2
    exit 1
fi
# Built at the default O0: cajeta-http currently fails to LINK at any --opt
# above O0 (missing `*_drop` destructor symbols — a toolchain bug). The codec's
# speedup is algorithmic (fast Huffman table + bit accumulator + explicit
# loadU64/storeU64 wide copies), so it lands in full at O0 regardless.
"$CAJETA_BIN" "dev.cajeta.http.autobahn.AutobahnEchoServer::main" \
    "$HERE/src" "$BUILD_DIR" --emit=exe \
    --classpath="$CJA,$CODEC" -o "$SERVER_BIN"

echo "== [2/4] starting the echo server on :$PORT =="
"$SERVER_BIN" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
# Wait for the port to accept connections.
for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; break; fi
    sleep 0.1
done

echo "== [3/4] running Autobahn fuzzingclient (docker, --network host) =="
docker run --rm --network host \
    -v "$HERE/config:/config:ro" \
    -v "$REPORTS:/reports" \
    "$IMAGE" \
    wstest -m fuzzingclient -s /config/fuzzingclient.json

echo "== [4/4] parsing the report =="
python3 "$HERE/parse_report.py" "$REPORTS/index.json"
