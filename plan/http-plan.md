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
  - **FIXED (2026-07-19, cajeta `13fef7a4`) — carrier starvation in the
    timed I/O wait.** `Reactor.awaitReadableTimed` ran the portable
    blocking `select()` probe, which stalls the calling OS **thread**; on
    a fiber that froze the whole carrier for up to the deadline, starving
    every co-hosted fiber — including the peer whose bytes were being
    awaited. The server's head-read (`readWithin`, 30s default budget)
    would park its carrier while the client fiber sat un-runnable on the
    same carrier's deque; the head read "timed out" against a peer never
    allowed to run, the server dropped the connection with no response,
    and the client read EOF mid-head. The proof was timing: passing runs
    6ms, a failing run **30.016s** — the head budget exactly. Fiber
    placement roulette explains the rate and the layout sensitivity.

    *(An interim theory — "fiber park duplicates drop entries", recorded
    here on 2026-07-19 — was **wrong**: the double `close(fd)` behind it
    was an ephemeral reactor epoll fd coincidentally reusing the same
    number. An `LD_PRELOAD` close-backtracer disproved it and led to the
    real cause. Kept for honesty of the record.)*

    Fix: `__cajeta_io_wait_timed`, a deadline-bounded **fiber-parking**
    wait combining the reactor's one-shot fd waiter with the timer wheel;
    `awaitReadableTimed`/`awaitWritableTimed` ride it. Verified: suite
    165/165 with **0 failures in 60 runs** (none over 2s), tour 15/15
    with **0 failures in 25 runs**; cajeta Net/Task regression suites
    64/64.
  - [x] Acceptance: 25 consecutive green runs of both the suite and the
    tour — **met** (60 + 25).
- [x] **0.10 Unblock the toolchain at cajeta HEAD.** *(Fixed 2026-07-19,
  cajeta `a70084b8`.)* The `NO_MATCHING_OVERLOAD` at
  `HttpServer.bindWithModel` was not one bug but **three scoped-resolution
  gaps**, all silent misses that `silent-resolution-diagnostics` correctly
  turned into errors:

  1. `scopePackageOf` fell through to the merged stdlib module's meaningless
     `cajeta.runtime` package when no current method was set, so the
     *stdlib's own* bare `HttpServer.serveConnectionWithLimits(...)` receiver
     resolved via the global short-name key to **this repo's** `HttpServer`
     (the un-retired `http:0.7` twin colliding with its own extraction) and
     matched stdlib-typed args against dev formals. The error's `:303` was
     the stdlib twin's line, unlocatable due to the known unlocated-
     diagnostics gap. Fix: consult the structure stack before the module
     qName.
  2. `NewExpression::resolveTypes` ran the global short-name key *before*
     the scoped lookup (backwards from its own `generateCode`), so a bare
     `heap X()` stamped a same-named class from another package into the
     call's arg types.
  3. `BinaryOpExpression::resolveTypes` typed comparisons/logicals as their
     LHS operand type; `s != null && s.equals(...)` typed as `String` and
     missed every overload. Now boolean. **This had silently elided
     `ServerTests`' `"405 carries Allow: GET"` check since it was written —
     the suite counts 64 checks now, not 63.**

  Diagnosed with a new env-gated tracer: `CAJETA_DBG_RESOLVE=<method>`
  dumps call keys, arg canonicals, and indexed buckets per resolve attempt.
  - **Resolved for local dev (2026-07-18):** `/usr/bin/cajeta` was 0.8.0
    while the manifest pinned 0.9.0, and the buildtool does not enforce the
    pin — a bare `cajeta test` silently ran a compiler that cannot compile
    this source. A `.deb` built from `8c10658b` + the 0.9 fix
    (`cpack -G DEB` in `cajeta/build`) is now installed, so plain
    `cajeta test` works and carries the fix. Note this deliberately omits
    the four newest cajeta commits (transform-intrinsics U4/U5, Vmap,
    silent-resolution-diagnostics) — reinstalling the **official** GitHub
    0.9.0 deb would regress 0.9, since tag `v0.9.0` (`32942b53`) predates
    the fix. The real fix is to land `#conn` upstream and cut a release.

- [ ] **0.11 Residual ~2.5% heap-corruption crash in the client loopback.**
  Surfaced 2026-07-19 while pre-flighting the `13fef7a4` compiler deb:
  2 failures in 65 runs, both `SIGABRT: array index 0 out of bounds for
  dimension size 0` in `ClientTests` (crash in ~4ms — NOT the fixed
  0.9 starvation mode, which pinned at the 30s budget). Distinct,
  pre-existing bug in the memory/ownership family (likely kin to the
  long-open lambda-capture double-free); it hid under 0.9's 25% rate and
  a lucky 0/60 post-fix loop (P≈22% of missing a 2.5% flake in 60).
  Cajeta-repo-side. Loop ≥100 runs when measuring anything against this.

## 1 — HTTP/1.1 core (beyond extracted parity)

- [x] **1.1** Spec package layout: split flat `dev.cajeta.http` into
  `.client` / `.server` / `.routing` / `.h1` per the spec (`9092f7e`;
  `.body`/`.middleware`/etc. come with the units that populate them).
  `PathParams` stays at the root — `HttpRequest` carries it as a field and
  `.routing` depends on `HttpRequest`, so moving it would be circular.
- [~] **1.2** Core-type completion. The four types exist in spec shape with
  49+35 golden-vector checks (suite 148/148): **`Method`/`Version` as real
  enums with methods** (`isSafe`/`isIdempotent`/`allowsBody`,
  `wireString`/`supportsKeepAlive`) — enum bodies were a compiler gap,
  built for this unit in cajeta `1c98c3a8`+`55a62950`+`4d601e3a`; an enum
  value is an i32 and can't be null, so `Method.of()` answers a tenth
  `EXTENSION` constant for unregistered tokens (`isRegistered` is the
  predicate). **`Status`** (RFC 9110 §15 registry + class predicates) and
  **`MediaType`** (RFC 6838 parse, lowercased type/subtype/param-names,
  quoted values, `essence`/`is`/`parameter`) as final classes.
  **Remaining:** adopt the types across the message model —
  `HttpRequest.method`/`HttpResponse.status` are still raw
  `String`/`int32`, `HttpResponse.reasonFor` duplicates `Status`'s
  registry, and the typed `Headers` accessors (`contentType()` etc.) are
  unwritten. That adoption changes parser/serializer/router signatures and
  should ride its own commit(s).
- [ ] **1.2b** Core-type adoption: retype `Method`/`Status`/`Version`
  through `HttpRequest`/`HttpResponse`/`Router`/`h1`, consolidate the
  reason-phrase registry into `Status`, add `Headers`' typed accessors
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
