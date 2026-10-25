# cajeta-http benchmarks

The benchmark project for `cajeta-http`. It measures every id on the compiler
repo's `bench/http/` pages (Server, WebSocket, Sse, Tls, Client, Startup) on
cajeta-http and on five competitor stacks: Go `net/http`, Rust `axum` on
hyper, Java Netty, Node.js `http` and Python `uvicorn`. Rows are written in
the schema-v2 CSV of the shared harness `dev.cajeta.bench`
(cajeta `specs/benchmark-reference-spec.md` §3, §7.3; plan unit 18).

## Run it

```sh
cd bench
./bench.sh                         # every id on cajeta-http
./bench.sh --competitors           # ... and on all five competitors
./bench.sh --bench plaintext-h1    # one id (harness --bench / --area pass through)
HTTP_BENCH_STACKS=cajeta-http,axum ./bench.sh
CAJETA_BENCH_SMOKE=1 ./bench.sh    # warmup 1, trials 3, 2 s of load; rows tagged smoke
test/bench_smoke.sh [cajeta|competitors|all]   # plan 18.1.1 / 18.1.2
cajeta bench                       # the manifest task: build, then --run on every stack
cajeta list                        # build, then --list
```

`bench.sh` builds `loadgen/`, each selected competitor (`competitors/<stack>/build.sh`),
and `build/http-bench` with `$CAJETA build` (default: `cajeta` on PATH, else
`../../cajeta/build/src/cajeta`). It then writes
`results/<machine>/<run-id>/results.csv` and `env.csv`, where
`run-id = <yyyymmddThhmmZ>-<cajeta version>`. It never writes `LATEST`; the
publish step does that, and it skips smoke rows.

Before you run, you need `oha` (pinned 1.16.0, `~/.cargo/bin/oha`), `wrk`
(`../../cajeta/bench/competitors/bin/wrk`, 4.2.0 @ a211dd5), `curl`, Go 1.22
for `loadgen`, and the competitor toolchains from the compiler repo's
`bench/competitors/toolchains-<machine>.tsv`: Rust via `~/.cargo`, Java 25,
Node 22 under nvm, Python 3.12. The Netty jars are read in place from
`../../cajeta/bench/competitors/third_party/java/` and checked against
`pins.tsv`.

| Environment | |
|---|---|
| `HTTP_BENCH_STACKS` | comma list of stacks (bench.sh default `cajeta-http`, `--competitors` = all; the binary alone defaults to all) |
| `HTTP_BENCH_SECONDS` | seconds of load per trial (10; 2 in smoke mode) |
| `HTTP_BENCH_H2_STREAMS` | `oha -p` on the h2 rows (8) |
| `HTTP_BENCH_TLS_CONNS` | concurrent handshakes on the TLS row (64) |
| `HTTP_BENCH_OHA`, `HTTP_BENCH_WRK` | tool paths |
| `CAJETA_BENCH_*` | the harness's: `SMOKE`, `MACHINE`, `RUN_ID`, `CAJETA_VERSION`, `FLAGS` |

## What a row is

There is one `Benchmark` per page id, with `area()` = `http` and `name()` the
slug, so ids look like `http/plaintext-h1`. Its harness variants are
`<stack>|<variant>` labels, and each label produces one row:

- `platform`: the stack. One of `cajeta-http`, `go-nethttp`, `axum`, `netty`, `node-http` or `uvicorn`.
- `variant`: the page's variant, which for most ids is the connection or client count. For example, `64`, `512`, and `64-wrk`.
- `language` and `language_version`: the stack's toolchain, measured by its `versions.sh`.
- `library` and `library_version`: the library that serves the row. Server rows use the HTTP server library; ws, h2, tls and client rows use the library for that feature.
- `throughput` / `throughput_unit`: the median of the trials (`req/s`, `msg/s`, `events/s`, `handshakes/s`; `x` for the reuse ratio).
- `notes`: `requests=N; errors=E` (E must be 0), the load generator and its version (`loadgen=oha 1.16.0`), the parameters, and `body-equal` once the stack's response has been byte-compared with cajeta-http's.
- `peak_rss_kb`: the server's VmHWM, summed over it and its children, sampled by the harness after every trial and before the stop. On client rows it is the client's own peak RSS, taken from an untimed run under `/usr/bin/time`. On `idle-rss` it is the idle VmRSS.
- `flags`: on cajeta-http rows the build of this binary (`--debug (O0)`, below); empty on competitor rows.

Every column is the harness's (dev.cajeta.bench 0.1.5): each id is a
`ServiceBenchmark`, whose per-variant hooks give the row its identity, and
which starts the stack's server for each variant (a free port in
20100..20199, ready when `GET /plaintext` answers 200, or on a TCP connect
for h2c and TLS, polled every 1 ms), samples its resident set, and stops it
by its PID (TERM, then KILL after 5 s). Each trial runs one external
command and reports its throughput (`reportedThroughput`); a start-up trial
reports its launch's exec-to-200 (`reportedNanos`). A trial that reports any
error, or a server that dies under load, fails the row (`status=failed`, with
the reason in `notes`). A stack that lacks a feature gets a `skipped` row with
the reason: uvicorn has no HTTP/2, and axum's tokio-tungstenite has no
permessage-deflate.

| id | per trial | variants |
|---|---|---|
| `plaintext-h1` | `oha -z 10s -c <n> -w` on `GET /plaintext`, HTTP/1.1 keep-alive | `64`, `512`; `64-wrk` (cajeta-http only): `wrk -t4 -c64`, notes carry `crosscheck=wrk/oha <ratio>` and the row is invalid outside 0.25..4 |
| `json-h1` | the same on `GET /json` | `64` |
| `plaintext-h2`, `json-h2` | `oha --http2 -z 10s -c 64 -p 8` (h2c prior knowledge, 512 streams) | `64` |
| `ws-echo` | `loadgen ws`: 64 clients, 1 KB binary echo, each echo byte-compared, 10 s | `64` |
| `ws-echo-deflate` | the same, permessage-deflate offered and required on every client | `64` |
| `sse-fanout-1k` | `loadgen sse`: every subscriber at once on `/sse?n=1000`, each must get events 0..999 in order | `1000` (`100` in smoke mode) |
| `tls-handshake-rate` | `oha -n 10000 -c 64 --disable-keepalive` over https: a fresh TLS 1.3 handshake per request (1000 in smoke mode) | `64` |
| `client-get-throughput` | the stack's client: 1e5 GETs over 16 reused connections against cajeta-http's server (1e4 in smoke mode) | `16` |
| `client-connection-reuse` | 1e4 GETs on one keep-alive connection, then 1e4 on fresh connections; the row is elapsed(fresh)/elapsed(keep-alive) | `1` |
| `startup-time` | `loadgen startup`: exec to the first 200 on `/plaintext`, one launch per trial, 20 trials. The timing columns are the launches' own times | - |
| `idle-rss` | `loadgen idle-rss`: start, first 200, 2 s idle, VmRSS of the process tree | - |

## Byte comparison

Before any load, each competitor's response is fetched with `curl` and
compared with cajeta-http's, byte for byte: status, `Content-Type`, and body.
cajeta-http's response comes from a short-lived server of ours. The routes
checked are `/plaintext` and `/json` (h1, h2c), `/plaintext` over TLS 1.3, and
`/sse?n=3`. Any difference fails the row and no load is run. Headers the
servers add on their own (`Date`, `Server`, Node's `Keep-Alive`) are not part
of the comparison.

## The competitor contract

Every stack lives in `competitors/<stack>/` and provides four scripts:

- `build.sh` builds it. It is idempotent, and its dependency versions are
  pinned (go.sum, Cargo.lock, package-lock.json, requirements.txt with `==`,
  and the Netty jar sha256s).
- `versions.sh` prints `key=value` lines: `language`, `language_version`, and
  `server`, `h2`, `ws`, `sse`, `tls`, `client` as `<library> <version>` or
  `none`. It may add `ws_deflate=no`.
- `run-server.sh <h1|h2c|tls> <port> [<cert> <key>]` execs the server, so its
  PID is the server's. The bench kills that PID and nothing else.
- `run-client.sh get <url> <total> <conns> <keepalive>` prints
  `{"requests":N,"errors":E,"elapsed_ns":T}`.

The h1 server serves these routes:

| Route | Response |
|---|---|
| `GET /plaintext` | 200 `text/plain`, `Hello, World!` |
| `GET /json` | 200 `application/json`, `{"message":"Hello, World!"}`, serialized per request |
| `GET /ws` | echo, with permessage-deflate when offered, every message compressed |
| `GET /sse?n=N` | 200 `text/event-stream`, `data: <i>\n\n` for i < N |

The h2c mode serves `/plaintext` and `/json` over HTTP/2 prior knowledge. The
tls mode serves `/plaintext` over TLS 1.3 with ALPN `http/1.1`, using the P-256
pair in `fixtures/tls/`. cajeta-http serves the same contract as
`build/http-bench --serve ...` and `--client get ...`, through `Serve.cajeta`
and `ClientLoad.cajeta`.

Node and uvicorn each run as their default single process. Go, axum and
Netty use every core.

## Ports and processes

Servers bind 127.0.0.1 on ports 20100..20199. That range sits below the
ephemeral range on purpose: a port inside it can be held by a client socket in
TIME_WAIT, and then a bind fails even though nothing listens there. Every PID
the bench starts is appended to `build/pids`. `bench.sh` and the smoke kill any
survivor on exit, by that PID. `loadgen` kills only the process group it
started.

## Build flavor

`build/http-bench` is a **debug (O0)** build, and every cajeta-http row says
so in its `flags` column. cajeta 0.46.3 cannot link anything that uses
cajeta-http at O1 or above. The optimizer drops the stdlib module's linkonce
copy of `__cajeta_stack_cajeta_lang_Optional_dev_cajeta_http_server_Dispatch__drop`
while `DispatchPool.worker` still calls it. This was measured with
`--release`, `--debug-release`, `--debug --opt=O1/O2/O3`, `--link-mode=full`
and `--tree-shake=off`, against both the Olla archive and the sources. Until
that is fixed, the cajeta-http numbers here are O0 numbers and must not be
published against `-O3` competitors.

## Layout

```
bench/
├── cajeta.json, bench.sh, README.md
├── src/main/cajeta/dev/cajeta/http/bench/   HttpBench (entry), StackBench and its
│                                            subclasses, Serve, ClientLoad, Ctx
├── competitors/<stack>/                     the five competitor stacks
├── loadgen/                                 Go: ws, sse, startup, idle-rss, wait, free
├── fixtures/tls/                            the P-256 test certificate and key
├── test/bench_smoke.sh
└── results/<machine>/<run-id>/              results.csv + env.csv (gitignored: smoke runs are never committed)
```
