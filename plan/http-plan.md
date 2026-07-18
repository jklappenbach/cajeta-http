# cajeta-http plan (`http`)

cajeta-http is the HTTP/WebSocket/SSE library over the stdlib `cajeta.io.net`
transport. Spec: [`docs/http-spec.md`](../docs/http-spec.md). The HTTP/1.1 +
WebSocket core already exists in the stdlib (`cajeta/docs/Net.md`,
`runtime/src/cajeta/io/net/http/` + `.../ws/`) and is being **extracted** into
this library; the HTTP/2, middleware, and SSE surface is new design layered on top.

Tasks carry outline ids (`http:<id>`); each unit is worked test-first
(tests → code → acceptance). `- [x]` = done, `- [~]` = blocked (blocker noted).

## 0 — Extraction (from stdlib into this library)

- [x] **0.1 Test harness bootstrap.** A `test/src` tree compiled against the
  built `.cja` (raw compiler CLI: `--emit=exe --classpath=${art.path}`,
  entry `dev.cajeta.http.test.TestMain::main`), wired into the manifest's
  `test` task (build → exec compile → test). The toolchain's
  `src/test/cajeta` + `cajeta.testkit` pipeline is designed but not yet
  implemented (no test-source-root support, testkit unpublished), and the
  scaffolded `test` task nested params the runner never reads — this unit
  replaces both with what works today.
  - TDD: smoke test (`Http.version()`) fails before wiring, passes after.
  - Acceptance: `cajeta test` exits 0 and runs the test binary.
- [x] **0.2 Extract the HTTP/1.1 wire codec** — `HttpRequest`, `HttpResponse`,
  `HttpParser(+Limits)`, `HttpSerializer`, `BodyFraming`, `BodyReader`,
  `ChunkedEncoder`, `KeepAlive`, and the HTTP exception family — from
  `cajeta.io.net.http` into `dev.cajeta.http` (package + import retarget only;
  no redesign). *(Was blocked on a cajeta compiler bug — any user class whose
  simple name collided with an embedded-stdlib class failed the build; fixed
  in the cajeta repo via scoped bare-name resolution in `CajetaType`.)*
  - TDD first: parser golden vectors (status line, headers, content-length +
    chunked bodies, malformed rejects), serializer round-trip, chunked
    encode/decode, keep-alive decisions.
  - Acceptance: library `.cja` builds; codec suite passes.
- [x] **0.3 Extract the server** — `HttpServer(+Builder)`, `Router`, `Route`,
  `PathParams`, `ServerLimits`, `Exchange`, `ExpectContinue`,
  `RequestBodyStream`, `ResponseBodyWriter` → `dev.cajeta.http`.
  - TDD first: router match/dispatch (param binding, 404, 405+Allow),
    loopback server exercised with raw `TcpStream` requests.
  - Acceptance: server suite passes (fiber-per-connection model; the
    shared-pool accept model is exercised by the stdlib's own harness and
    rides the same `Server` core).
- [x] **0.4 Extract the client** — `HttpClient` → `dev.cajeta.http`.
  - TDD first: loopback client↔server exchange (GET + POST body, status,
    headers).
  - Acceptance: client suite passes against the 0.3 server.
- [x] **0.5 Extract WebSocket** — the RFC 6455 stack (`WebSocket`, frame
  codec, handshakes, control frames, assembler, close codes, exceptions)
  from `cajeta.io.net.ws` into `dev.cajeta.http.ws`.
  - TDD first: frame encode/decode round-trips (masking, 7/16/64-bit
    lengths), `Sec-WebSocket-Accept` derivation, fragmentation reassembly,
    loopback echo over an upgraded connection.
  - Acceptance: WS suite passes.
- [x] **0.6 samples/tour** — a self-checking tour of the library surface,
  modeled on `cajeta/samples/tour`: HttpServer + Router over loopback, an
  HttpClient exchange against it, and a WebSocket echo; README + run script;
  exits non-zero on any failed check.
  - Acceptance: `samples/tour/run.sh` prints the walkthrough and exits 0.
- [ ] **0.7 Retire the stdlib copies** — remove `cajeta.io.net.http` /
  `cajeta.io.net.ws` from the cajeta repo stdlib and migrate its tests/docs.
  **Cajeta-repo-side work** — tracked there (see
  `cajeta/agents/cajeta/external/cajeta-http-completion.md`); not workable
  from this repo.
- [x] **0.8 Migrate to toolchain 0.9.0.** Pin `settings.toolchain` in
  `cajeta.json` and carry the library, tests, and tour onto the 0.9.0
  language/stdlib. Two rule changes drove it, both of which compile clean
  and fail only at runtime:
  - *String re-core* — `byteLength` is a method, not a field; the raw
    `.bytes` field is gone in favor of `toBytes()` (a fresh **owned** copy);
    `String(#int8[], int32)` **adopts** its buffer, so constructing a String
    from a borrowed array hands away bytes the caller doesn't own.
  - *Move semantics at the use site* — an owned (`#`) param, field, or array
    slot consumed with a plain `=` is treated as a **borrow**, so the
    original owner's drop still fires and frees memory the new holder
    references. Storing an owned value needs `= #x` (including through a
    local receiver, e.g. `m.payload = #payload` in a static factory);
    hoisting an owned field/slot into a local to move it out needs the
    `#=` move-bind. Symptoms were SIGSEGV on first use, `count()` on a freed
    array returning garbage that flowed into `heap T[n]`, and bogus lengths
    tripping limit checks.

    Fixed: `Router.append`, `Route.appendSegment`, `PathParams.put`,
    `HttpRequest.bindPathParams`, `WsFrame.of`, `WsMessage.of`,
    `WsCloseReason.of`, the four `WsReadAction` factories, and
    `WsFrameDecoder.{nextFrame,finishIfPayloadComplete}`. Added
    `WsMessage.text()` so callers get a text message's `String` without
    hand-rolling the adopt-a-borrow trap.

    Note: the builder chain `HttpResponse.ok().body(...)` returned as
    `#HttpResponse` is **correct** despite `body()` returning a borrow — it
    reads like the same defect and is not one; leave it alone.
  - Acceptance: on a passing run `cajeta test` → 63 passed / 0 failed and
    `samples/tour/run.sh` → 15 checks passed, exit 0. **Both are
    intermittent** — see 0.9 below; every 0.8 check that runs, passes, and
    the failures are a transport race outside the migrated code.
- [~] **0.9 Fix the HttpClient loopback race** (found 2026-07-18 while
  landing 0.8; **pre-existing**, not introduced by the migration). Was
  roughly **1 run in 3** of both `cajeta test` and `samples/tour/run.sh`
  dying with `uncaught exception: stream ended before the HTTP head
  terminated` — the client reads EOF before the response head is complete.

  **Root cause — an upstream stdlib ownership bug, now fixed.**
  `cajeta.io.net.Server.dispatch` declares `#TcpStream conn` (owned) but
  spawned the worker with a *borrow*:

  ```cajeta
  public void dispatch(#TcpStream conn) {
      spawn serveConnection(this.handler, this.inflight, conn);   // no '#'
  }
  ```

  `serveConnection` takes `#TcpStream`, so under the 0.9.0 rules (see 0.8)
  `dispatch` stayed the owner and its scope-exit drop closed the socket
  immediately after spawning — racing the connection fiber. Fix is `#conn`.
  Same bug class as the 13 fixed inside this repo in 0.8; the 0.9.0
  migration evidently did not sweep the stdlib's own `io.net`.

  - Effect: suite went **7/20 failing → 0 failures in 60 runs**; the tour
    went ~35% → **1 failure in 60**.
  - **The fix lives in the cajeta repo**, not here:
    `runtime/src/cajeta/io/net/Server.cajeta:291`. It is currently an
    *uncommitted* change on branch `feature/nucleo-transform-intrinsics`
    and must be committed + released there for this repo to stay green.
  - Ruled out along the way: swallowed server-fiber exceptions (the fiber
    never throws), keep-alive reuse (`HttpClient.send` already stamps
    `Connection: close`), and `#=` move-binding the `acceptNext()` result
    (7/20 either way).
  - Measure with a loop, never a single run — a single green run proves
    nothing here.
  - **Still open:** a residual ~1-in-60 failure with the same signature,
    seen only in the tour (suite is 0/60). Same first-exchange EOF; cause
    not yet identified.
  - Acceptance: 25 consecutive green runs of both the suite and the tour.
    The suite meets this; the tour does **not** yet.
- [ ] **0.10 Unblock the toolchain at cajeta HEAD.** cajeta
  `7f24be9e` (`silent-resolution-diagnostics 2.1: un-park member-not-found`,
  on top of the transform-intrinsics U4/U5 work that added ~329 lines to
  `MethodCallExpression.cpp`) **breaks this repo's build**:

  ```
  :303:23: CAJETA_ERROR_NO_MATCHING_OVERLOAD: no overload of
    'serveConnectionWithLimits' ... accepts 4 argument(s). Candidates:
    serveConnectionWithLimits(..., cajeta.io.net.TcpStream)
  ```

  The message is self-contradictory — it rejects 4 arguments while listing a
  4-argument candidate — at `HttpServer.bindWithModel`'s
  `(conn) -> HttpServer.serveConnectionWithLimits(h, lim, slim, conn)`.
  Reproduces with this repo's tree unchanged, and an explicit
  `(TcpStream conn)` parameter type does not help, so it is an upstream
  regression rather than a latent fault here. Last known-good compiler is
  **`8c10658b`**, which is what the current `build/src/cajeta` binary is —
  note that binary no longer matches the checked-out cajeta source, so
  rebuilding cajeta at HEAD will break this repo until this is resolved.
  - Also: `/usr/bin/cajeta` is still **0.8.0** while `cajeta.json` pins
    `toolchain.version = 0.9.0`, and the buildtool does not enforce the pin
    — a bare `cajeta test` silently runs a compiler that cannot compile this
    source. Install 0.9.0 so the pin and reality agree.

## 1 — HTTP/1.1 core (beyond extracted parity)

- [ ] **1.1** Spec package layout: split flat `dev.cajeta.http` into
  `.body` / `.client` / `.server` / `.routing` / `.h1` per the spec.
- [ ] **1.2** Core-type completion: `Method`/`Status`/`Headers`/`MediaType`
  helpers per spec (`isSafe`, registry, typed accessors).
- [ ] **1.3** `Body` abstraction: in-memory + streaming, form, multipart
  (+ `MultipartParser`).
- [ ] **1.4** Client: connection pool + keep-alive, redirects, retry,
  timeouts, streaming bodies, `getJson<T>`, transparent gzip/deflate.
- [ ] **1.5** Server hardening: request timeout, max body size, slowloris
  header deadline, backlog config.

## 2 — Middleware

- [ ] **2.1** `Middleware` composition (registration order).
- [ ] **2.2** Bundled set: RequestId, Logging, Recover, Timeout, CORS,
  Compression/Decompression, RateLimit, BasicAuth, BearerAuth, StaticFile,
  ETag, ProxyHeaders.

## 3 — HTTP/2

- [ ] **3.1** HPACK; **3.2** frame framing (zero-copy `view`); **3.3** stream
  multiplexing + flow control; **3.4** ALPN negotiation + h2c upgrade;
  **3.5** opt-in server push. Behind the same client/server surface.

## 4 — WebSocket completeness + SSE

- [ ] **4.1** `permessage-deflate` (RFC 7692); **4.2** one-line
  `connect`/upgrade convenience; **4.3** Autobahn conformance.
- [ ] **4.4** SSE server + client (`text/event-stream`).

## 5 — HTTP/3 (deferred)

- [ ] **5.1** HTTP/3 over QUIC over UDP — gated on a QUIC state machine over
  `cajeta.io.net` UDP sockets. Designed-for in the transport abstraction;
  not in the near term.

Phases 1–5 are headline-level; break a unit into TDD granularity (design
skill) before implementing it.

## Out of scope (other layers own these)

- Transport (sockets, reactor, TLS, URI) — stdlib `cajeta.io.net`.
- REST endpoints, annotation routing, auto-serde-to-object — **primavera**.
- gRPC — a separate library over HTTP/2.
