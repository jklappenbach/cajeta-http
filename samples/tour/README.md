# cajeta-http tour

A self-checking walkthrough of the library, one demo per layer, ordered as a
learning path. Every demo asserts what it demonstrates (150 checks); the exit
code is the number of failed checks, so the tour doubles as a smoke test.

```sh
CAJETA_BIN=/path/to/cajeta ./samples/tour/run.sh
RUN=0 ./samples/tour/run.sh    # compile only
```

`run.sh` builds the library `.cja` when stale (globbing the produced archive —
the version lives in `cajeta.json`), resolves `dev.cajeta.codec` at the
version the manifest pins, extracts its native zlib tree for the linker, and
compiles + runs the tour against both archives — so it exercises exactly what
a consumer of the published archive gets.

## The demos

| Demo | What it teaches |
|------|-----------------|
| `WireDemo` | The message model + typed vocabulary (Method/Status/Version/MediaType), serialize→parse, chunked framing, keep-alive decisions, gzip content-coding, and the typed exception per hostile-input class |
| `RoutingDemo` | Router patterns: typed path params, precedence, 404/405+Allow, per-route body caps, mounts |
| `MiddlewareDemo` | `MiddlewareChain` mechanics + the catalogue: Recover, RequestId, Logging, Basic/Bearer auth, RateLimit, Timeout, CORS, ETag, Compression, StaticFile, ProxyHeaders |
| `ServerDemo` | A live server the public way: Router behind a chain behind `builder() → serve() → shutdown(deadline)`, ServerLimits enforcing 413 pre-handler, inbound gzip, Expect: 100-continue |
| `ClientDemo` | The operational client: exchangeTimeout, retryPolicy, redirect caps, cookies, pool reuse, getJson, downloadTo — with the typed failure for each misbehavior |
| `BodiesDemo` | The body model: String/Bytes/Form/Multipart/Stream/GzipCompress, chunked uploads, upload limits |
| `TlsDemo` | The same exchange TLS-terminated: server PEM pair, client trust anchor |
| `Http2Demo` | h2 prior-knowledge server + `Http2Client`, HPACK (with RFC 7541 pins), the frame layer, SETTINGS, flow control, server push entries |
| `SseDemo` | Server-Sent Events: stream + live channel responses, `SseClient.subscribe` with Last-Event-ID resume, the wire format |
| `WebSocketDemo` | RFC 6455: handshake math, live text/binary echo, the handler API, the CLOSE handshake, control frames, fragmentation, permessage-deflate, and every ws exception provoked |

HTTP/3 is intentionally absent: it needs QUIC, which the stdlib does not ship
— the library no longer advertises it.

Coverage is enforced: `scripts/check-library-tour-coverage.sh src/main/cajeta
samples/tour scripts/tour-coverage-ignore.txt` requires every public top-level
type to be exercised (the ignore file exempts genuine internals, each with a
stated reason). CI runs suite + tour + gate via `scripts/ci-checks.sh`.

## Known issue

**This tour frequently hangs when run locally.** The runtime can lose a fiber
wakeup during a server shutdown-and-await teardown, leaving the process
blocked forever — see the cajeta repo's `runtime-lost-wakeup-under-load`
spec. Measured 2026-07-31 on an idle machine: 6 of 6 runs wedged, with
binaries from both cajeta 0.12.0 and 0.13.0. It stops right after an
"Expect: 100-continue" or "StreamBody uploads" line, always at a teardown,
never mid-request.

CI passes the same tour, so the gate is meaningful — but do not read a green
CI badge as evidence the bug is rare. If the tour freezes for you, that is
the known defect, not your change; kill it and re-run, or wait for the fix.

## Adding a demo

Extend `DemoClass` in `src/tour/http/` (print to narrate,
`this.check(cond, "…")` to verify), then add one block to `HttpTour.main`.
Support classes live beside the demos, marked `// support:`.
