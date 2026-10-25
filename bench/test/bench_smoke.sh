#!/usr/bin/env bash
# cajeta-http bench smoke (benchmark-reference plan 18.1.1 and 18.1.2).
#
#   test/bench_smoke.sh            # both parts
#   test/bench_smoke.sh cajeta     # 18.1.1: every page id on cajeta-http
#   test/bench_smoke.sh competitors# 18.1.2: every page id on the five competitor stacks
#
# Each part runs ./bench.sh with CAJETA_BENCH_SMOKE=1 (warmup 1, trials 3, a
# couple of seconds of load per trial) and then checks the results.csv the
# harness wrote: 37 schema-v2 columns, one row per id (and per variant and
# stack), every measured row ok with its correctness check true, requests > 0
# and errors=0 on every load row, the load generator's version recorded, the
# competitor's library and version in library/library_version, platform the
# stack name, and for every competitor a body byte-compared against ours
# before any load. A skipped row must carry its reason.
#
# Durations: part 1 is about 3 minutes, part 2 about 8 (each part prints
# its own start and end time).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PART="${1:-all}"

fail() { echo "BENCH-SMOKE FAIL: $*" >&2; exit 1; }

IDS="plaintext-h1 json-h1 plaintext-h2 json-h2 ws-echo ws-echo-deflate sse-fanout-1k tls-handshake-rate client-get-throughput client-connection-reuse startup-time idle-rss"
COMPETITORS="go-nethttp,axum,netty,node-http,uvicorn"

# --- the binary lists exactly the page ids ---------------------------------
check_list() {
    local bin="$ROOT/build/http-bench"
    [[ -x "$bin" ]] || fail "no bench binary at $bin (./bench.sh builds it)"
    local listed
    listed="$("$bin" --list)" || fail "--list exited non-zero"
    for id in $IDS; do
        grep -q "^  http/$id  \[cpu\]$" <<<"$listed" || fail "--list does not show http/$id: $listed"
    done
    local n
    n="$(grep -c '^  http/' <<<"$listed")"
    [[ "$n" == 12 ]] || fail "--list shows $n benchmarks, expected the 12 page ids"
}

# --- run one part and check its CSV -----------------------------------------
run_part() {
    local name="$1" stacks="$2"
    local t0; t0="$(date +%s)"
    echo "[bench-smoke] $name: start $(date -u +%H:%M:%SZ), stacks=$stacks"
    local log="$ROOT/build/smoke-$name.log"
    mkdir -p "$ROOT/build"
    ( cd "$ROOT" && CAJETA_BENCH_SMOKE=1 HTTP_BENCH_STACKS="$stacks" ./bench.sh ) >"$log" 2>&1
    local rc=$?
    local out; out="$(sed -n 's/^bench.sh: results \(.*\)$/\1/p' "$log" | tail -1)"
    echo "[bench-smoke] $name: bench.sh exit $rc, $(( $(date +%s) - t0 ))s, log $log"
    [[ -n "$out" && -f "$out" ]] || { tail -30 "$log" >&2; fail "$name: no results.csv reported by bench.sh"; }
    [[ -f "$(dirname "$out")/env.csv" ]] || fail "$name: no env.csv beside $out"
    case "$out" in
        "$ROOT"/results/*/*/results.csv) ;;
        *) fail "$name: results not under bench/results/<machine>/<run>/: $out" ;;
    esac
    check_list
    python3 - "$out" "$name" "$stacks" "$IDS" <<'PY' || fail "$name: CSV checks failed ($out)"
import csv, re, sys
path, part, stacks, ids = sys.argv[1], sys.argv[2], sys.argv[3].split(","), sys.argv[4].split()
HEADER = "schema_version,run_id,timestamp_unix,benchmark,area,dataset_name,dataset_bytes,dataset_sha256,input_size,language,language_version,library,library_version,flags,warmup,trials,min_ns,median_ns,mean_ns,p95_ns,throughput,throughput_unit,peak_rss_kb,cgroup_peak_kb,alloc_bytes,alloc_count,working_set_kb,status,check_ok,notes,variant,backend,machine,os,driver,model,platform"
LANG = {"cajeta-http": "cajeta", "go-nethttp": "go", "axum": "rust", "netty": "java",
        "node-http": "javascript", "uvicorn": "python"}
OHA = {"plaintext-h1", "json-h1", "plaintext-h2", "json-h2", "tls-handshake-rate"}
BODY = {"plaintext-h1", "json-h1", "plaintext-h2", "json-h2", "tls-handshake-rate", "sse-fanout-1k"}
LOAD = OHA | {"ws-echo", "ws-echo-deflate", "sse-fanout-1k", "client-get-throughput",
              "client-connection-reuse"}
bad = []
def err(row, msg):
    bad.append("%s/%s [%s] variant=%r: %s | notes=%r" % (row["area"], row["benchmark"],
               row["platform"], row["variant"], msg, row["notes"]))
with open(path, newline="") as f:
    head = f.readline().rstrip("\r\n")
    if head != HEADER:
        print("header mismatch:\n  got  %s\n  want %s" % (head, HEADER)); sys.exit(1)
    f.seek(0)
    rows = list(csv.DictReader(f))
with open(path, newline="") as f:
    for i, cols in enumerate(csv.reader(f)):
        if len(cols) != 37:
            print("line %d has %d columns" % (i + 1, len(cols))); sys.exit(1)
seen = set()
for r in rows:
    if r["schema_version"] != "2": err(r, "schema_version " + r["schema_version"])
    if r["area"] != "http": err(r, "area " + r["area"])
    st = r["platform"]
    if st not in stacks: err(r, "platform %r not in the selected stacks" % st); continue
    seen.add((r["benchmark"], st))
    if r["language"] != LANG[st]: err(r, "language %r, expected %r" % (r["language"], LANG[st]))
    if not r["language_version"]: err(r, "no language_version")
    if "smoke" not in r["notes"]: err(r, "smoke row not tagged smoke")
    if r["status"] == "skipped":
        if r["notes"].strip() in ("", "smoke") or r["notes"].startswith("smoke"):
            err(r, "skipped without a reason")
        if st == "cajeta-http": err(r, "cajeta-http may not skip")
        continue
    if r["status"] != "ok" or r["check_ok"] != "true":
        err(r, "status %s check_ok %s" % (r["status"], r["check_ok"])); continue
    if not r["library"] or not r["library_version"]:
        err(r, "library/library_version empty: %r %r" % (r["library"], r["library_version"]))
    b = r["benchmark"]
    if b in LOAD:
        m = re.search(r"requests=(\d+)", r["notes"])
        if not m or int(m.group(1)) <= 0: err(r, "no requests=N>0 in notes")
        if not re.search(r"(^|; )errors=0(;|$)", r["notes"]): err(r, "errors not 0")
        try:
            tp = float(r["throughput"])
        except ValueError:
            tp = -1
        if tp <= 0: err(r, "throughput %r" % r["throughput"])
        if not r["throughput_unit"]: err(r, "no throughput_unit")
    if b in OHA:
        if "-wrk" in r["variant"]:
            if "loadgen=wrk " not in r["notes"] or "crosscheck=" not in r["notes"]:
                err(r, "wrk row without its version or cross-check")
        elif "loadgen=oha 1.16.0" not in r["notes"]:
            err(r, "oha version not recorded")
    if b in BODY and st != "cajeta-http" and "body-equal" not in r["notes"]:
        err(r, "no byte comparison against cajeta-http recorded")
    if b == "startup-time" and int(r["median_ns"]) <= 0: err(r, "startup median_ns")
    if b == "idle-rss" and int(r["peak_rss_kb"]) <= 0: err(r, "idle rss")
for b in ids:
    for st in stacks:
        if (b, st) not in seen:
            bad.append("missing row http/%s on %s" % (b, st))
v = sorted(r["variant"] for r in rows if r["benchmark"] == "plaintext-h1" and r["platform"] == stacks[0])
for want in ("64", "512"):
    if want not in v: bad.append("plaintext-h1 on %s has no %s-connection variant: %r" % (stacks[0], want, v))
if "cajeta-http" in stacks:
    if not any(r["variant"] == "64-wrk" for r in rows if r["benchmark"] == "plaintext-h1"):
        bad.append("no wrk cross-check row")
    sse = [r for r in rows if r["benchmark"] == "sse-fanout-1k" and r["platform"] == "cajeta-http"]
    if sse and "clients=100;" not in sse[0]["notes"] + ";": bad.append("sse smoke is not 100 clients")
for line in bad: print("  " + line)
ok = sum(1 for r in rows if r["status"] == "ok"); sk = sum(1 for r in rows if r["status"] == "skipped")
print("[bench-smoke] %s: %d rows (%d ok, %d skipped), %d problem(s)" % (part, len(rows), ok, sk, len(bad)))
sys.exit(1 if bad else 0)
PY
    # Every server the run started was recorded; none may outlive it.
    local pids="$ROOT/build/pids"
    if [[ -f "$pids" ]]; then
        while read -r pid; do
            [[ -z "$pid" ]] && continue
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
                fail "$name: server pid $pid outlived the run (killed now)"
            fi
        done <"$pids"
    fi
    echo "[bench-smoke] $name: PASS, end $(date -u +%H:%M:%SZ), $(( $(date +%s) - t0 ))s"
}

case "$PART" in
    cajeta)      run_part cajeta cajeta-http ;;
    competitors) run_part competitors "$COMPETITORS" ;;
    all)         # Both parts run; the smoke fails if either does.
                 ( run_part cajeta cajeta-http ); r1=$?
                 ( run_part competitors "$COMPETITORS" ); r2=$?
                 [[ $r1 == 0 && $r2 == 0 ]] || fail "part cajeta exit $r1, part competitors exit $r2" ;;
    *) echo "usage: $0 [cajeta|competitors|all]" >&2; exit 2 ;;
esac
echo "[bench-smoke] PASS"
