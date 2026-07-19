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
- [x] **0.9 Fix the HttpClient loopback race** (found 2026-07-18 while
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
    `runtime/src/cajeta/io/net/Server.cajeta:291`. *(Since committed
    upstream as cajeta `9295a16f` — on `main`, and carried by the
    installed `13fef7a4` deb along with the fiber-parking fix below.)*
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
    this source. An interim `.deb` built from `8c10658b` + the 0.9 fix
    bridged the gap. **Superseded 2026-07-19:** the installed deb is now
    **`cajeta 0.9.0 (13fef7a4)`** — cajeta `main`, carrying the `#conn`
    fix (`9295a16f`), the enum-body work (1.2's dependency), the
    silent-resolution-diagnostics that exposed 0.10, and the fiber-parking
    timed wait (0.9's fix). Plain `cajeta test` runs the right compiler.
    Still true: the buildtool doesn't enforce the manifest's toolchain pin,
    and the official GitHub `v0.9.0` tag (`32942b53`) predates all of these
    fixes — don't "upgrade" to it. A proper upstream release remains the
    durable fix.

- [ ] **0.11 Residual ~2.5% heap-corruption crash in the client loopback.**
  Surfaced 2026-07-19 while pre-flighting the `13fef7a4` compiler deb:
  2 failures in 65 runs, both `SIGABRT: array index 0 out of bounds for
  dimension size 0` in `ClientTests` (crash in ~4ms — NOT the fixed
  0.9 starvation mode, which pinned at the 30s budget). Distinct,
  pre-existing bug in the memory/ownership family (likely kin to the
  long-open lambda-capture double-free); it hid under 0.9's 25% rate and
  a lucky 0/60 post-fix loop (P≈22% of missing a 2.5% flake in 60).
  Cajeta-repo-side. Loop ≥100 runs when measuring anything against this.
  - **Re-measured 2026-07-19 with the `13fef7a4` deb installed:** 1/120
    suite failures + 0/40 tour (direct-binary loop), same signature —
    SIGABRT `array index 0 out of bounds for dimension size 0` in
    `client: loopback`, ~4ms in, drop-chain entries rooted at
    `ClientTests.cajeta:29-33`. Cumulative 3/185 ≈ **1.6%**. Everything
    else green: suite 165/165, tour 15/15 on every non-crashing run.

## 1 — HTTP/1.1 core (beyond extracted parity)

- [x] **1.1** Spec package layout: split flat `dev.cajeta.http` into
  `.client` / `.server` / `.routing` / `.h1` per the spec (`9092f7e`;
  `.body`/`.middleware`/etc. come with the units that populate them).
  `PathParams` stays at the root — `HttpRequest` carries it as a field and
  `.routing` depends on `HttpRequest`, so moving it would be circular.
- [x] **1.2** Core-type completion. The four types exist in spec shape with
  49+35 golden-vector checks (suite 148/148): **`Method`/`Version` as real
  enums with methods** (`isSafe`/`isIdempotent`/`allowsBody`,
  `wireString`/`supportsKeepAlive`) — enum bodies were a compiler gap,
  built for this unit in cajeta `1c98c3a8`+`55a62950`+`4d601e3a`; an enum
  value is an i32 and can't be null, so `Method.of()` answers a tenth
  `EXTENSION` constant for unregistered tokens (`isRegistered` is the
  predicate). **`Status`** (RFC 9110 §15 registry + class predicates) and
  **`MediaType`** (RFC 6838 parse, lowercased type/subtype/param-names,
  quoted values, `essence`/`is`/`parameter`) as final classes.
  Adoption across the message model rode its own commit — 1.2b.
- [x] **1.2b** Core-type adoption (`cd8afa9`): `HeaderValues` hosts the
  spec's typed header reads library-side (`contentLength()` → `int64`,
  −1 for absent/malformed per RFC 9110 §8.6; `contentType()` →
  `MediaType` or null) since `Headers` is stdlib-owned
  (`cajeta.io.net.Headers`); `HttpRequest`/`HttpResponse` grow typed
  views (`methodType()`/`versionType()`/`statusType()`/`contentType()`/
  `contentLength()`) while the raw `String`/`int32` wire fields stay
  authoritative (extension tokens are legal on the wire and the
  serializer emits fields verbatim); `HttpResponse.reasonFor` delegates
  to `Status`'s consolidated RFC 9110 §15 registry (own 27-entry table
  deleted); `KeepAlive`'s version default rides
  `Version.supportsKeepAlive()`. 17 new checks; suite 165/165.
- [ ] **1.3** `Body` abstraction: in-memory + streaming, form, multipart
  (+ `MultipartParser`). Broken to TDD granularity 2026-07-19; decisions
  encoded from the spec's leans: body-size limits reject **early** (413 at
  parse, global + per-route), and streaming bodies **drain implicitly** on
  handler return with an opt-out for handlers that take ownership.
  Substrate note: there is **no stdlib `InputStream`** — bodies stream
  over `cajeta.io.net`'s `AsyncReader`/`AsyncWriter`/`ByteBuffer`, and the
  h1 plumbing (`BodyReader`, `RequestBodyStream`, `ResponseBodyWriter`)
  already speaks it. Ownership discipline throughout: adopting
  constructors take `#` buffers explicitly; accessors hand out borrows
  (the 0.8 migration's `= #x` / `#=` rules apply to every factory).
  - [ ] **1.3a `Body` core + in-memory bodies.** Abstract `Body`
    (`contentLength()` −1 = unknown/chunked, `contentType()`,
    `reader()` → an `AsyncReader`-shaped source), `BytesBody`,
    `StringBody`. If the stdlib lacks a buffer-backed reader, a small
    adapter over `ByteBuffer` ships here (library-side).
    - TDD: length/type reporting, full-read round-trip (bytes + string,
      UTF-8), zero-length body, reader yields exactly contentLength bytes.
    - Acceptance: body suite green; no message-model changes yet.
  - [ ] **1.3b `FormBody`** — `application/x-www-form-urlencoded` encode
    + a decode helper (percent-encoding per the stdlib `Uri` rules,
    `+` for space, UTF-8).
    - TDD: golden vectors (reserved chars, UTF-8 multibyte, empty
      values, repeated keys), encode/decode round-trip.
  - [ ] **1.3c `StreamBody`** — wrap a caller-supplied reader; unknown
    length serializes chunked (rides `ChunkedEncoder`), known length
    rides content-length framing; never materializes.
    - TDD: large body (≫ one buffer) streamed through the h1 serializer
      and re-parsed over loopback without full-payload buffering;
      unknown-length → chunked on the wire; known-length → exact framing.
  - [ ] **1.3d Multipart** — `MultipartBody` (part composition + boundary
    generation), `MultipartPart` (headers, name/filename, body),
    `MultipartParser` (boundary scan over a streaming source, per-part
    headers, part bodies as readers; max-part / max-parts limits).
    - TDD: RFC 2046 golden vectors (preamble/epilogue tolerance, CRLF
      edges, quoted boundary), compose→parse round-trip, malformed
      rejects (missing terminal boundary, oversize part → early 413-class
      error), binary part payloads.
  - [ ] **1.3e Message-model adoption.** `HttpRequest`/`HttpResponse`
    carry an optional `Body`; `Exchange`/`RequestBodyStream` expose the
    request body as a `Body`; `ResponseBodyWriter` accepts one; client
    `send` takes a `Body` overload; raw byte-array paths stay (wire
    compatibility, small-body fast path). Early 413 enforcement lands
    here (parse-time, global + per-route thresholds); implicit drain on
    handler return with the ownership opt-out.
    - TDD: loopback POST of each body kind client→server and a streamed
      response server→client; 413 on an over-limit body **before** the
      handler runs; drained-connection reuse after a handler ignores its
      body.
    - Acceptance: full suite + tour green (loop ≥100 runs — 0.11 is
      still live at ~1.6%, so judge by signature, not by a single red).
- [ ] **1.4** Client completeness. Broken to TDD granularity 2026-07-19.
  Decision encoded from the spec's lean: **cookie jar off by default**,
  explicit `CookieJar` opt-in (1.4g). `getJson` ships **untyped**
  (`JsonValue` via the stdlib `cajeta.codec.json`) — typed `getJson<T>`
  auto-serde is primavera's layer per the spec boundary. 1.4e is gated
  on 1.6.
  - [ ] **1.4a Connection pool + keep-alive.** `ConnectionPool` keyed
    `(scheme, host, port)`; reuse honors `KeepAlive` decisions;
    `maxConnectionsPerOrigin` with waiting fibers; idle reaping on the
    timer wheel; drop `HttpClient.send`'s unconditional
    `Connection: close` stamp (it exists to defeat reuse — pooling
    supersedes it).
    - TDD: two sequential exchanges ride one socket (server-side
      connection count proves it); origin cap parks the over-cap fiber
      until a lease frees; idle reap closes after the window; a
      server-closed pooled connection is detected and replaced, not
      surfaced to the caller.
  - [ ] **1.4b Redirects.** 301/302/303/307/308 with a hop cap; 303 →
    GET and drop the body, 307/308 preserve method + body; relative
    `Location` resolved via the stdlib `Uri`; `Authorization` stripped
    on cross-origin hops; loop → error.
    - TDD: loopback chains per code (method/body rewrite table), hop-cap
      trip, cross-origin auth strip, relative-Location resolution.
  - [ ] **1.4c Timeouts, cancellation, retry.** Per-exchange budget over
    `cajeta.concurrent.Tasks.withTimeout` (no HTTP-specific timeout
    vocabulary) plus a connect timeout; auto-retry policy — idempotent
    methods only (`Method.isIdempotent`), connect-failure or
    pre-first-byte only, capped, with backoff.
    - TDD: stalled-server exchange times out at the budget (measurable
      now that 0.9's fiber-parking wait landed); POST never
      auto-retries; GET retries once on refused-then-listening; a
      cancelled exchange releases its pooled connection.
  - [ ] **1.4d Streaming + download.** Request/response `Body` streaming
    through the client (rides 1.3c/1.3e); `downloadTo(path)` over
    `cajeta.io.file` returning a running `cajeta.hash.Sha256` digest.
    - TDD: large download lands byte-identical, digest matches, memory
      stays bounded; streamed upload arrives intact server-side.
  - [ ] **1.4e `getJson()` + transparent decompression** *(gated on
    1.6)*. `getJson()` → `JsonValue`; the client advertises
    `Accept-Encoding: gzip, deflate` and inflates transparently,
    clearing `Content-Encoding` and fixing lengths up.
    - TDD: gzip/deflate/identity responses yield identical bodies;
      corrupt compressed stream → clean error, not garbage; JSON
      round-trip against the stdlib codec.
  - [ ] **1.4f Builder + proxy.** `HttpClient.builder()` — default
    headers, version pin, pool sizes, redirect/retry/timeout policy,
    TLS trust, HTTP proxy (absolute-form for `http`, CONNECT tunnel
    for `https`).
    - TDD: builder defaults observable on the wire; proxied loopback
      exchange through a minimal in-test proxy, both forms.
  - [ ] **1.4g `CookieJar`** (decision: **off by default**, explicit
    `.cookieJar(jar)` opt-in). RFC 6265 subset: `Set-Cookie` parse,
    domain/path matching, expiry/max-age, `Secure`/`HttpOnly` honored.
    - TDD: no jar → nothing echoed back; with jar → set/return across
      exchanges, domain/path scoping, expiry drops the cookie.
- [ ] **1.5** Server hardening. Broken to TDD granularity 2026-07-19.
  Substrate check: the head-read deadline already exists (`readWithin`,
  30s default), `HttpServer.shutdown(Duration)` already drains, and the
  stdlib ships `ConnectionLimits`/`ConnectionLimiter`/`LoadShedPolicy`
  for accept control — this unit makes budgets configurable, adds the
  missing phases, and proves the existing pieces under test.
  - [ ] **1.5a Deadlines.** Configurable per-phase budgets on
    `ServerLimits`: header-read (slowloris) deadline, body inter-read
    timeout, whole-request budget; 408 where a response is still
    possible, close otherwise.
    - TDD: drip-fed headers cut at the deadline (and not before);
      stalled body read cut; handler overrun cut at the request budget;
      timings asserted against configured values, not wall-clock
      guesses.
  - [ ] **1.5b Size limits.** Per-server max body size — early 413,
    sharing 1.3e's parse-time enforcement (global cap here; per-route
    came with 1.3e) — and `HttpParserLimits`' header caps surfaced on
    `ServerLimits`.
    - TDD: over-limit content-length 413s before the handler runs;
      over-limit chunked cut mid-stream; exactly-at-limit passes.
  - [ ] **1.5c Accept control + graceful shutdown.** Configurable
    listener backlog; `ConnectionLimits` + shed policy wired through
    `HttpServer.builder()`; `shutdown(Duration)` proven — stop
    accepting, drain in-flight, hard-close at the deadline.
    - TDD: capacity + shed behavior observable under concurrent
      connects; shutdown mid-exchange completes that exchange and
      refuses new ones; a hung exchange is cut at the deadline.
- [ ] **1.6** Compression codec (`dev.cajeta.http.compression`) — a
  **prerequisite for 1.4e, 2.2c, and 4.1**. Planned 2026-07-19 after
  confirming the stdlib ships **only the interfaces**
  (`cajeta.wire.Compressor`/`Decompressor` — no DEFLATE implementation
  anywhere, native layer included, and no CRC32/Adler-32 in
  `cajeta.hash`). Pure-cajeta implementations of the stdlib interfaces
  (matching the stdlib's stated no-third-party policy), so they can
  migrate into `cajeta.wire` later. Brotli **deferred** — nothing gates
  on it.
  - [ ] **1.6a DEFLATE (RFC 1951).** Inflate + deflate: stored blocks,
    fixed and dynamic Huffman, LZ77 with the 32KB window;
    block-oriented first.
    - TDD: golden vectors both directions; round-trip on structured /
      random / empty / incompressible inputs; malformed rejects (bad
      Huffman tables, distance-too-far); window-edge matches.
  - [ ] **1.6b Wrappers + checksums.** zlib (RFC 1950, Adler-32) and
    gzip (RFC 1952, CRC32) framing; CRC32 and Adler-32 ship in this
    unit.
    - TDD: checksum vectors; interop fixtures produced by system zlib
      (test fixtures only — no runtime dependency); trailing-garbage
      and truncation rejects.
  - [ ] **1.6c Streaming surface.** Incremental inflate/deflate with the
    dictionary/window preserved across calls, plus flush modes — the
    shape 4.1's context takeover and 2.2c's streamed bodies need.
    - TDD: chunk-at-a-time equals one-shot on every 1.6a vector; sync
      flush boundaries decode standalone; context carries across
      messages.
- [ ] **1.7** Router completeness — found unplanned during the
  2026-07-19 sweep: the extracted Router matches only literal and
  `{name}` (string) segments, but the spec promises typed params,
  wildcards, and nesting.
  - [ ] **1.7a Typed path params.** `{id:int64}` (and the other core
    scalar types): parse at match time; a type mismatch is a **404**,
    never reaches the handler; `PathParams` grows typed getters.
    - TDD: match/404 matrix per type (overflow int64, leading zeros,
      negatives), typed getter round-trip, string params unchanged.
  - [ ] **1.7b Wildcards.** `{p:*}` — one segment; `{p:**}` — rest of
    the path (bound with `/` separators preserved); precedence: literal
    > typed/string param > `*` > `**`.
    - TDD: precedence table proven, `**` binding incl. empty rest,
      wildcard + trailing-route conflicts rejected at registration.
  - [ ] **1.7c `mount(prefix, sub)`.** Nest a sub-router under a
    prefix; path params allowed in the prefix; 405/Allow computed
    across the merged tree.
    - TDD: nested dispatch with prefix params, mount-shadowing rules,
      405 aggregation across mounts.
- [ ] **1.8** Server TLS termination — found unplanned during the
  2026-07-19 sweep: the client speaks `https` (shipped: `wrapTls` +
  ALPN offer + OS-trust verify) but `HttpServer` has **no TLS path**,
  despite the spec's `.tls(serverTls)` builder line. `HttpServer.builder()
  .tls(...)` accepting a stdlib `cajeta.io.net.tls` server config;
  accept path wraps each connection in the stdlib `TlsListener`/
  `TlsStream` handshake before h1; ALPN advertises `http/1.1` (3.4 adds
  `h2` later); WSS falls out for free once the upgrade path rides the
  same stream.
  - TDD: loopback HTTPS exchange against the shipped client with a
    test CA (client `trustAnchor` pin); plaintext request to a TLS
    port fails cleanly (no hang, no crash); handshake-failure
    connections don't leak inflight slots; WSS echo over the upgraded
    TLS stream.
  - Acceptance: suite + tour green with an HTTPS variant of the
    loopback exchange in each.

## 2 — Middleware

- [ ] **2.1** Composition. `Middleware.wrap(HttpRequest, Handler) →
  HttpResponse` with `Handler` as the shared handler shape; global
  (server-level) and per-route registration; registration order =
  wrapping order (first registered outermost); middleware and handlers
  compose as plain functions.
  - TDD: order proven by a trace-accumulating triple; a short-circuit
    (auth deny) skips inner middleware and the handler; a handler
    exception crosses the stack unharmed (catching it is `Recover`'s
    job, 2.2a); per-route composes inside global.
  - Acceptance: the Router/HttpServer wire-through lands here and is the
    only core change the whole bundled set needs.
- [ ] **2.2** Bundled set — grouped by dependency weight; every
  middleware is golden-tested through a real loopback server, not just
  unit-called.
  - [ ] **2.2a `Recover` + `RequestId` + `Logging`.** Recover: uncaught →
    500, but leaves the response alone if headers already streamed.
    RequestId: generate or propagate, echo response header. Logging: one
    line per exchange (method, path, status, duration).
    - TDD: throwing handler → 500 + connection survives; mid-stream
      throw → connection closed, no half-500; id propagation vs
      generation; log line shape.
  - [ ] **2.2b `Timeout` + `Cors`.** Timeout wraps `next` in
    `Tasks.withTimeout` (504 on trip, exchange cut). Cors: preflight
    OPTIONS, origin allowlist, allow/expose headers, max-age,
    credentials flag.
    - TDD: overrunning handler → 504 at the budget; preflight matrix
      (allowed/denied origin, methods, headers), actual-request headers,
      credentialed wildcards rejected per spec.
  - [ ] **2.2c `Compression`/`Decompression`** *(gated on 1.6)*.
    Response side: `Accept-Encoding` negotiation with q-values, min-size
    and content-type gates, streaming compress of streamed bodies,
    `Vary: Accept-Encoding`. Request side: inflate
    `Content-Encoding`d bodies with the size limits applied
    **post-inflate** (zip-bomb guard, interacts with 1.5b/1.3e).
    - TDD: negotiation matrix incl. `identity;q=0`; already-encoded and
      tiny bodies skipped; streamed body compresses incrementally;
      bomb-guard 413s.
  - [ ] **2.2d `RateLimit` + `BasicAuth`/`BearerAuth`.** RateLimit:
    token bucket keyed by remote address or a caller-supplied extractor,
    429 + `Retry-After`. Auth: constant-time comparison, 401 +
    `WWW-Authenticate`; the credential verifier is a caller-supplied
    lambda — no credential storage in this library.
    - TDD: bucket refill over an injected clock; per-key isolation;
      Basic round-trip via stdlib Base64 incl. colon-in-password;
      malformed auth headers → 401 not 500.
  - [ ] **2.2e `StaticFile` + `ETag` + `ProxyHeaders`.** StaticFile:
    root-jailed path resolution, MediaType from extension, index files,
    404/403 discipline. ETag: strong tag from content hash,
    `If-None-Match` → 304. ProxyHeaders: `X-Forwarded-For/Proto/Host`
    exposed as a request view, honored only from configured trusted
    proxies.
    - TDD: **traversal fuzz is the security floor** — `..`,
      percent-encoded dots, backslashes, absolute paths, symlink escape
      all stay jailed; 304 flow end-to-end; untrusted-source forwarded
      headers ignored.

## 3 — HTTP/2

Order: 3.1 and 3.2 are independent of each other; 3.3 needs both; 3.4
turns it on; 3.5 rides 3.3. The user-facing surface (client / server /
router / un-colored handlers) must not change — that is the phase's
acceptance bar.

- [ ] **3.1** HPACK (RFC 7541): integer/string primitives, static table,
  size-bounded dynamic table with eviction and table-size updates,
  Huffman encode/decode (the Appendix B code), never-indexed literals
  for sensitive headers.
  - TDD: Appendix C golden vectors verbatim (C.2–C.6 request/response
    sequences, with and without Huffman, asserting dynamic-table state
    after each block); decompressed-size bomb guard; eviction edges.
- [ ] **3.2** Frame layer: the 9-byte frame header decoded **zero-copy
  via `view`** over a pooled buffer (the spec's canonical `view` case);
  encode/decode for all frame types (DATA, HEADERS, PRIORITY,
  RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE,
  CONTINUATION); padding; `SETTINGS_MAX_FRAME_SIZE` enforcement.
  - TDD: per-type golden vectors + flag matrices; malformed frames →
    the exact RFC 9113 error codes; oversize → FRAME_SIZE_ERROR.
- [ ] **3.3** Streams: connection preface + SETTINGS handshake, the
  stream state machine, connection- and stream-level flow control
  (WINDOW_UPDATE accounting both directions), CONTINUATION reassembly,
  multiplexed dispatch onto the same un-colored handler
  (fiber-per-stream), RST_STREAM cancellation, GOAWAY. PRIORITY is
  parsed and ignored (RFC 9113 deprecates the priority tree).
  - TDD: interleaved concurrent streams over loopback settle correctly;
    window exhaustion parks the writing fiber and WINDOW_UPDATE resumes
    it; RST mid-body cancels the handler fiber; protocol-violation
    catalogue (headers after end-stream, even/reused stream ids, …) →
    GOAWAY/RST with the right codes.
- [ ] **3.4** Negotiation: ALPN `h2` via the stdlib TLS (`supportAlpn`
  exists on `TlsListener`/`TlsStream`), h2c via `Upgrade: h2c` +
  `HTTP2-Settings`, prior-knowledge preface detection; the client
  selects by ALPN with clean h1 fallback.
  - TDD: alpn=h2 serves the same Router over h2; alpn=http/1.1 falls
    back; h2c upgrade round-trip; a non-preface first byte on a
    prior-knowledge port degrades to h1.
- [ ] **3.5** Server push — decision per the spec's lean: **include**,
  with the deprecated-upstream note (non-browser clients still use it).
  Opt-in server API; the client defaults `SETTINGS_ENABLE_PUSH=0` and
  surfaces pushes only when explicitly enabled.
  - TDD: enabled → pushed resource delivered with correct cache keying;
    PUSH_PROMISE while disabled → connection error per RFC;
    disabled-by-default proven client-side.

## 4 — WebSocket completeness + SSE

- [ ] **4.1** `permessage-deflate` (RFC 7692) *(gated on 1.6c)*:
  offer/accept negotiation (window bits, `*_no_context_takeover`
  params), RSV1 discipline, per-message deflate with the sliding window
  shared across messages under context takeover. Decision per the
  spec's lean: **default on**, matching browsers.
  - TDD: the RFC 7692 worked examples; round-trips with and without
    context takeover in both roles; negotiation-reject falls back to
    plain frames; RSV1 on a continuation frame rejects; compressed
    control frames reject.
- [ ] **4.2** Convenience surfaces.
  - [ ] **4.2a One-line client connect.** `WebSocket.connect(url)` —
    `ws`/`wss` dial (TLS via stdlib), upgrade request,
    101 + `Sec-WebSocket-Accept` validation, subprotocol selection →
    ready `WebSocket`.
    - TDD: loopback connect against the extracted server upgrade; wrong
      Accept or status → `HandshakeRejected`; subprotocol negotiation.
  - [ ] **4.2b Server handler surface.** `WebSocketHandler`
    (`onConnect`/`onMessage`/`onClose`) over a `WebSocketConnection`
    (send/close), with the reader-fiber + writer-fiber pair and write
    mutex managed by the library; registered on routes like HTTP
    handlers (the spec's "richer server surface" paragraph).
    - TDD: callback lifecycle order, close initiated from each side;
      concurrent sends from multiple fibers interleave whole frames
      (mutex proof); a throwing handler → 1011 close.
- [ ] **4.3** Autobahn conformance: an external-harness runner
  (`test/autobahn/run.sh`, wstest via docker or pip — a test-fixture
  dependency only; long suite → the tagged-run discipline from
  `~/code/CLAUDE.md`) plus a report parser turning the JSON results
  into pass/fail.
  - Acceptance: all cases green excluding 12.*/13.* before 4.1 lands,
    including them after; "non-strict" allowed, no failures.
- [ ] **4.4** SSE (`dev.cajeta.http.sse`).
  - [ ] **4.4a Wire codec.** `SseEvent` (id / event / data / retry)
    serialize + parse: multi-line `data:`, comment lines (keep-alive),
    CR/LF/CRLF tolerance, UTF-8 + BOM tolerance.
    - TDD: golden vectors both directions (the WHATWG parsing
      examples); field-order and unknown-field tolerance.
  - [ ] **4.4b Server.** `SseResponse.stream(events)` and
    `.channel(Channel<SseEvent>)` (stdlib `cajeta.concurrent.Channel`):
    `text/event-stream` + no-cache headers, flush per event, periodic
    comment keep-alive, `Last-Event-ID` request view, client
    disconnect ends the producing fiber.
    - TDD: channel-pushed events arrive incrementally over loopback
      (not buffered to stream end); disconnect stops the producer;
      keep-alive cadence.
  - [ ] **4.4c Client.** `SseClient.subscribe(url)` → event iteration;
    auto-reconnect honoring `retry:` and replaying `Last-Event-ID`;
    an explicit stop/close surface.
    - TDD: a server-dropped stream reconnects and resumes from the last
      id; `retry:` honored (asserted via injected timing, not
      wall-clock sleeps); non-200 or wrong content-type → clean error.

## 5 — HTTP/3 (deferred)

- [ ] **5.1** HTTP/3 over QUIC over UDP — gated on a QUIC state machine over
  `cajeta.io.net` UDP sockets. Designed-for in the transport abstraction;
  not in the near term.

Phases 1–4 are broken to TDD granularity (2026-07-19). Phase 5 stays
headline — gated on a QUIC transport in `cajeta.io.net`; re-plan it when
that exists. Cross-phase dependencies: **1.6 (compression codec) gates
1.4e, 2.2c, and 4.1**; 3.1 + 3.2 precede 3.3; 1.3c/1.3e precede 1.4d;
everything else is order-independent within its phase.

## Out of scope (other layers own these)

- Transport (sockets, reactor, TLS, URI) — stdlib `cajeta.io.net`.
- REST endpoints, annotation routing, auto-serde-to-object — **primavera**.
- gRPC — a separate library over HTTP/2.
