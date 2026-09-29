#!/usr/bin/env bash
#
# Autobahn|Testsuite conformance for the cajeta-http WebSocket server. Builds
# the library and the echo testee through run-tests.sh, serves it on :9001,
# runs the fuzzingclient in docker against it, and reads the report with
# AutobahnReport. A tagged run, not part of the suite: about 500 cases.
#
#     test/autobahn/run.sh
#
# Needs a docker daemon (crossbario/autobahn-testsuite) and cajeta on PATH or
# in CAJETA_BIN.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="${IMAGE:-crossbario/autobahn-testsuite}"
PORT=9001
REPORTS="$HERE/reports"

echo "== [1/4] building the library and the testee =="
( cd "$ROOT" && AUTOBAHN=1 ./run-tests.sh )

echo "== [2/4] starting the echo server on :$PORT =="
rm -rf "$REPORTS"
mkdir -p "$REPORTS"
"$HERE/build/autobahn-echo" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; break; fi
    sleep 0.1
done

echo "== [3/4] running the Autobahn fuzzingclient =="
docker run --rm --network host \
    -v "$HERE/config:/config:ro" \
    -v "$REPORTS:/reports" \
    "$IMAGE" \
    wstest -m fuzzingclient -s /config/fuzzingclient.json

echo "== [4/4] reading the report =="
"$HERE/build/autobahn-report" "$REPORTS/index.json"
