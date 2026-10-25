#!/usr/bin/env bash
# Run the cajeta-http benchmarks (see README.md).
#
#   ./bench.sh                               # every page id on cajeta-http
#   ./bench.sh --competitors                 # ... and on all five competitor stacks
#   ./bench.sh --bench plaintext-h1          # one id (the harness's --bench/--area pass through)
#   HTTP_BENCH_STACKS=cajeta-http,axum ./bench.sh
#   CAJETA_BENCH_SMOKE=1 ./bench.sh          # warmup 1, trials 3, 2 s of load; rows tagged smoke
#
# Builds loadgen, the selected competitors and build/http-bench, then writes
# results/<machine>/<run-id>/results.csv and env.csv. Every server it starts
# is recorded by PID in build/pids and killed by that PID on exit.
#
# Env: CAJETA (compiler; default `cajeta` on PATH, else ../../cajeta/build/src/cajeta),
#      CAJETA_BENCH_MACHINE, CAJETA_BENCH_RUN_ID, HTTP_BENCH_SECONDS, HTTP_BENCH_OHA,
#      HTTP_BENCH_WRK (default ../../cajeta/bench/competitors/bin/wrk).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ALL_COMPETITORS="go-nethttp,axum,netty,node-http,uvicorn"
args=()
competitors=no
for a in "$@"; do
    if [[ "$a" == "--competitors" ]]; then
        competitors=yes
    else
        args+=("$a")
    fi
done
if [[ -z "${HTTP_BENCH_STACKS:-}" ]]; then
    if [[ "$competitors" == yes ]]; then
        export HTTP_BENCH_STACKS="cajeta-http,$ALL_COMPETITORS"
    else
        export HTTP_BENCH_STACKS="cajeta-http"
    fi
fi

# --- tools ---------------------------------------------------------------
if [[ -z "${CAJETA:-}" ]]; then
    if command -v cajeta >/dev/null 2>&1; then
        CAJETA="$(command -v cajeta)"
    elif [[ -x "$HERE/../../cajeta/build/src/cajeta" ]]; then
        CAJETA="$(cd "$HERE/../../cajeta/build/src" && pwd)/cajeta"
    else
        echo "bench.sh: no cajeta compiler (set CAJETA=)" >&2; exit 2
    fi
fi
export HTTP_BENCH_OHA="${HTTP_BENCH_OHA:-$(command -v oha || echo "$HOME/.cargo/bin/oha")}"
if [[ -z "${HTTP_BENCH_WRK:-}" ]]; then
    if command -v wrk >/dev/null 2>&1; then
        HTTP_BENCH_WRK="$(command -v wrk)"
    else
        HTTP_BENCH_WRK="$(cd "$HERE/../.." && pwd)/cajeta/bench/competitors/bin/wrk"
    fi
fi
export HTTP_BENCH_WRK
for t in "$HTTP_BENCH_OHA" "$HTTP_BENCH_WRK" curl go; do
    command -v "$t" >/dev/null 2>&1 || { echo "bench.sh: missing $t" >&2; exit 2; }
done

# --- the pins agree ---------------------------------------------------------
pin="$(sed -n 's/.*"dev\.cajeta\.http"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' cajeta.json | head -1)"
code="$(sed -n 's/.*String HTTP = "\([^"]*\)".*/\1/p' src/main/cajeta/dev/cajeta/http/bench/Versions.cajeta)"
if [[ "$pin" != "$code" ]]; then
    echo "bench.sh: cajeta.json pins dev.cajeta.http $pin but Versions.cajeta says $code" >&2; exit 2
fi

CAJETA_VERSION="$("$CAJETA" --version 2>/dev/null | awk '{print $2}')"
export CAJETA_BENCH_CAJETA_VERSION="${CAJETA_BENCH_CAJETA_VERSION:-$CAJETA_VERSION}"

# --- build ------------------------------------------------------------------
mkdir -p build
echo "bench.sh: building loadgen" >&2
loadgen/build.sh >&2
IFS=',' read -r -a stacks <<<"$HTTP_BENCH_STACKS"
for s in "${stacks[@]}"; do
    [[ "$s" == cajeta-http || "$s" == all ]] && continue
    echo "bench.sh: building competitors/$s" >&2
    "competitors/$s/build.sh" >&2
done
if [[ " ${stacks[*]} " == *" all "* ]]; then
    for s in ${ALL_COMPETITORS//,/ }; do "competitors/$s/build.sh" >&2; done
fi
echo "bench.sh: building build/http-bench with $CAJETA ($CAJETA_VERSION)" >&2
"$CAJETA" build >build/build.log 2>&1 || { tail -20 build/build.log >&2; exit 1; }

# --- run --------------------------------------------------------------------
machine="${CAJETA_BENCH_MACHINE:-$(hostname | tr '[:upper:]' '[:lower:]')}"
export CAJETA_BENCH_MACHINE="$machine"
export CAJETA_BENCH_RUN_ID="${CAJETA_BENCH_RUN_ID:-$(date -u +%Y%m%dT%H%MZ)-$CAJETA_BENCH_CAJETA_VERSION}"
out="$HERE/results/$machine/$CAJETA_BENCH_RUN_ID/results.csv"
export HTTP_BENCH_ROOT="$HERE"

: >build/pids
cleanup() {
    while read -r pid; do
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done <build/pids
}
trap cleanup EXIT

echo "bench.sh: start $(date -u +%H:%M:%SZ) stacks=$HTTP_BENCH_STACKS run=$CAJETA_BENCH_RUN_ID" >&2
t0=$(date +%s)
rc=0
build/http-bench --run --out "$out" "${args[@]}" || rc=$?
echo "bench.sh: end $(date -u +%H:%M:%SZ) ($(( $(date +%s) - t0 ))s), exit $rc" >&2
echo "bench.sh: results $out"
exit "$rc"
