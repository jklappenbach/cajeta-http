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

Under heavy CPU contention (another workload saturating the machine) the
runtime can lose a fiber wakeup during a server teardown and wedge the
process — see the cajeta repo's `runtime-lost-wakeup-under-load` spec. Idle
machines and CI runners have not shown it; if the tour freezes right after an
"Expect: 100-continue" or "StreamBody uploads" line on a busy box, that is
the known defect, not your change.

## Adding a demo

Extend `DemoClass` in `src/tour/http/` (print to narrate,
`this.check(cond, "…")` to verify), then add one block to `HttpTour.main`.
Support classes live beside the demos, marked `// support:`.
