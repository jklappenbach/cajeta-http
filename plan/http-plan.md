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
- [x] **0.7 Retire the stdlib copies** — *(done 2026-07-19, cajeta
  `f23e3e59` on `main`)* `cajeta.io.net.http` / `.ws` removed from the
  stdlib (the stdlib keeps the transport: TCP/UDP/reactor/TLS/DNS/URI);
  skills/docs retargeted; 19 protocol test suites deleted (coverage is
  this repo's suite), compiler-feature tests refixtured; cajeta's
  `tools/mcp` now depends on `dev.cajeta.http@0.1.0` from the `~/.olla`
  store. Verified: full cajeta ctest with every failure A/B-attributed
  to pre-existing causes, MCP stdio + HTTP transports green.
  Two follow-ups this created **here**:
  - The stdlib's HTTP-on-shared-pool parity coverage retired with it —
    this suite runs fiber-per-connection only, so add a both-models
    loopback run (fits 1.5c's accept-control work).
  - The retired `test/net/golden/http|ws` corpus (RFC message/abuse/
    frame vectors, deleted at `f23e3e59~1`) is worth adopting into this
    repo's golden tests.
  - Note: the installed 0.9.1 deb (`880f334f`) predates the removal and
    still embeds the stdlib twins — harmless (0.10's collision fix
    handles it); the next cut deb drops them.
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

- [x] **0.11 Residual ~2.5% heap-corruption crash in the client loopback.**
  **ROOT-CAUSED AND FIXED 2026-07-19 (cajeta-repo side): the frame bump
  arena was per-carrier-THREAD, but fibers interleave on carriers.** The
  gdb backtrace out of a crashing run landed in `HttpParser.feed`
  indexing `data` — the client's 8 KiB `scratch` — whose array-header
  length qword read 0 while its *contents* were the correctly-received
  response bytes: the buffer's memory had been reclaimed out from under
  the parked fiber. `heap int8[8192]` in `readResponse` is arena-
  allocated (`__cajeta_new_array_header_arena`); the arena's O(1)
  mark/reset assumes LIFO scope nesting per *logical stack*, and a fiber
  that **parks** mid-frame (`readAsync` → `Reactor.awaitReadable`)
  leaves live allocations above marks that co-hosted fibers reset right
  through — the server connection fiber's scope exit rolled the shared
  bump pointer back over the client fiber's live buffers. Explains the
  ~4ms crash timing (first parked read), the layout sensitivity
  (25% ↔ 0% ↔ 7.5% by allocation interleaving), and retro-explains the
  0.9-era "fiber park duplicates active drop entries" double-close
  (object memory reuse across fibers) and likely the long-open
  lambda-capture double-free. A deterministic split-sweep (every 2-way
  split of the response wire + bytewise, 100 rounds) was green —
  exonerating the parser and pinning the runtime.
  **Fix:** per-FIBER arenas (`cajeta_arena` in `struct cajeta_fiber`,
  selected by `__cajeta_arena_ptr()` — the same accessor pattern as
  `drop_top`/`exc_top`/`scope_top`), lazily mapped, recycled through a
  process-wide mapping pool at fiber teardown; non-fiber threads keep
  the `__thread` arena. Landed as cajeta **`84ebcec4`** on main, with a
  deterministic C-level regression test
  (`test/runtime/FiberArenaIsolationTests.cpp`: two fibers pinned to
  one carrier replay the mark-park/alloc-park/reset interleave —
  8192/8192 bytes corrupted pre-fix, clean post-fix). Verified: suite
  **300/300 + 100/100**, tour 60/60 (was ~4.6%/run at this layout);
  full cajeta ctest — no regressions (residual failures reproduce
  pre-change: Xpu textures, MCP cache race, two near-timeout tests).
  NOT cured (separate bugs, now cleanly disambiguated): the cajeta
  repo's own tour SIGSEGV (WildcardsDemo region) and the cajeta-unit
  reflective-runner abort blocking codec v0.5.0. The 0.9-era
  double-close probe now shows exactly one close per fd. The installed
  deb still carries the bug until a 0.9.3 release lands — local dev
  should use the release-worktree compiler on PATH.
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
  - **Rate is layout-sensitive (re-confirmed at 1.3b):** with the body/
    form code added the same signature runs ~**6/80 ≈ 7.5%** (drop chain
    now rooted at `ClientTests.cajeta:51-55` — moved with the binary,
    body/form code not involved). History: 25-30% → 0/60 → 2.5% → 7.5%
    across layouts. Judge regressions by *signature*, and expect the
    rate to wander as the library grows. At 1.3c the same signature
    (rooted `ClientTests.cajeta:29-33` again) ran 6/130 ≈ **4.6%**.

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
  - [x] **1.3a `Body` core + in-memory bodies.** `Body` base **class**
    (`contentLength()` −1 = unknown/chunked, `contentType()`,
    `reader()` → a **body-owned** `AsyncReader` borrow), `BytesBody`
    (adopts its buffer), `StringBody` (copies via `toBytes()`), and
    `BytesChannel` — the read-only memory-backed `ByteChannel` adapter
    the stdlib lacked. 25 new checks; suite 190/190, 0/20 loop.
    **Compiler bug found + worked around:** dispatching an
    *object-typed return* through a user-defined **interface** returns
    a corrupt object (scalar returns dispatch correctly; first plan was
    `interface Body`) — SIGSEGV/garbage, cajeta-repo-side, first-ever
    exercise of the path since stdlib interfaces are consumed
    concretely. Class-based virtual dispatch is sound, so `Body` is a
    concrete base with sentinel defaults (`abstract` isn't in the
    language), which also matches the spec's original shape.
    - TDD: length/type reporting, full-read round-trip (bytes + string,
      UTF-8 multibyte), zero-length bodies, chunked reads draining
      exactly contentLength, EOF-on-0 contract, polymorphic dispatch
      (param + upcast + reader through the base).
    - Acceptance: body suite green; no message-model changes yet. Met.
  - [x] **1.3b `FormBody`** — `application/x-www-form-urlencoded`
    encode + `parse` decode: unreserved `[A-Za-z0-9*-._]` verbatim,
    space↔`+`, uppercase `%XX` over UTF-8 bytes; insertion-ordered
    pairs (repeats legal), lazy re-encode on `add`, stored strings are
    owned copies, positional + first-match accessors. 24 new checks;
    suite 214/214 when green (0.11 note above). One more instance of
    the branch-scoped-owned-local trap found during TDD (decode value
    assigned inside an `if` → borrow of a dying temp; restructured to a
    single adopting init-decl).
  - [x] **1.3c `StreamBody`** — wrap a caller-supplied reader; unknown
    length serializes chunked (rides `ChunkedEncoder`), known length
    rides content-length framing; never materializes.
    - TDD: large body (≫ one buffer) streamed through the h1 serializer
      and re-parsed over loopback without full-payload buffering;
      unknown-length → chunked on the wire; known-length → exact framing.
    - **Shipped:** `body/StreamBody` adopts a caller-supplied
      `AsyncReader` (`of` = unknown length/−1 → chunked; `sized` = exact
      `Content-Length`; typed variants of each). Single-shot by design —
      `reader()` returns the same never-rewound reader; the backing
      channel stays the caller's and must outlive the body. Tests pump a
      64 KiB pattern in 1 KiB pieces: known-length re-parses through
      `BodyReader.forContentLength` exactly; unknown-length frames each
      piece via `ChunkedEncoder.encodeChunk` as read (nothing
      accumulated encode-side) and round-trips through
      `BodyReader.forChunked`. Suite 214 → **235** checks. (The
      socket-loopback streaming pass rides 1.3e/1.4d where the
      serializer/client actually drive a Body.)
  - [x] **1.3d Multipart** — `MultipartBody` (part composition + boundary
    generation), `MultipartPart` (headers, name/filename, body),
    `MultipartParser` (boundary scan over a streaming source, per-part
    headers, part bodies as readers; max-part / max-parts limits).
    - TDD: RFC 2046 golden vectors (preamble/epilogue tolerance, CRLF
      edges, quoted boundary), compose→parse round-trip, malformed
      rejects (missing terminal boundary, oversize part → early 413-class
      error), binary part payloads.
    - **Shipped:** four types in `dev.cajeta.http.body` —
      `MultipartPart` (quoted-string `Content-Disposition` with `\`/`"`
      escaping; `field()`/`file()` factories), `MultipartBody` (ordered
      parts, lazily built + cached wire, generated
      `----cajeta-<hex>` boundary from the clock + a per-process
      counter, canonical `Title-Case` header names on the wire since
      `Headers` lowercases on the way in), `MultipartParser` (the
      incremental state machine), and `MultipartScan` (pure buffer
      scanning + `Content-Disposition` parameter extraction, split out
      because it touches no parser state). Suite 235 → **282** checks
      (+47), 100/100 stable.
    - **Design — the `DELIM` state.** The machine is
      `PREAMBLE → DELIM → HEADERS → CONTENT → DELIM → … → DONE`. Emitting
      a part and resolving the delimiter that follows it are *separate*
      steps because both must be re-entrant at every byte: TDD's
      byte-at-a-time feed caught the parser re-emitting a part when the
      delimiter needed more bytes (content had been scanned but not yet
      consumed), and caught `openPart` misreading the closing `--` as the
      start of a new part when only the first `-` had arrived. A lone `-`
      is genuinely undecidable, so `openPart` now returns false without
      changing state until its successor lands. Peak memory is one part:
      content is dropped from the buffer the moment it is emitted.
    - **Compiler-order landmine (cajeta 0.9.3 `080171da`).** With the
      `forBoundaryWithLimits` / `boundaryOf` statics declared *before*
      `MultipartParser`'s instance methods, `feed` (and other later
      methods) vanish from the compiler's method index — every call site
      reports `CAJETA_ERROR_MEMBER_NOT_FOUND` for a method that is
      plainly declared, with no diagnostic on the library build. Moving
      the two statics below the instance methods is the entire fix and is
      commented in the source. It did not reduce to a small standalone
      case (isolated repros of the obvious suspects — `&&` operands,
      field arguments, `throw` in void, same-arity method counts, long
      doc comments — all compile), so the reproducer is this file. Cost
      a long bisect; re-check on a future toolchain before reordering.
  - [~] **1.3e Message-model adoption.** *(core landed; the streaming
    server/client legs stay open — see below.)* `HttpRequest`/`HttpResponse`
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
      **fixed** as of cajeta v0.9.3, so a red is now a real red).
    - **Landed:** `HttpRequest`/`HttpResponse` each carry an optional
      `Body` (`bodyModel`) with a `body(#Body)` overload beside the raw
      `body(int8[], int32)` path, plus `getBody()` and `asBody()` (a
      `BytesBody` view over a *received* message so handlers and clients
      read parsed bodies through the same `contentLength`/`contentType`/
      `reader` surface). Attaching a body sets `Content-Type` **with
      parameters** unless one is already set — which needed
      `MediaType.format()` (+ `parameterNameAt`/`parameterValueAt`), new
      here: without it a `multipart/form-data` boundary never reaches the
      wire and the receiver cannot frame the body at all. Known-length
      bodies drain into the raw byte path at attach time so every
      existing serializer path keeps working; unknown-length bodies are
      carried, not drained. Tests: attach-and-frame for String/Form/
      Multipart, explicit-Content-Type precedence, `asBody()` round-trip,
      and a **live loopback POST of each body kind** client→server with
      the multipart payload re-parsed off the echo. Suite 282 → **299**,
      100/100 stable, tour 15/15.
    - **Still open in this unit** (deliberately deferred, each wants its
      own TDD pass): the streamed *response* leg through
      `ResponseBodyWriter` (unknown-length `Body` → chunked on the wire —
      pairs with 1.4d), `Exchange`/`RequestBodyStream` exposing the
      request body as a `Body` before it is buffered, per-route 413
      thresholds (the global `ServerLimits.maxBodyBytes` cap already
      rejects pre-handler, extracted in 0.3), and implicit drain-on-return
      with the ownership opt-out.
    - **Trap re-learned:** `body()` returns a **borrow** of `this`, so
      `return resp.body(...)` from a `#HttpResponse` function hands back a
      local that drops at exit — the server then dereferences freed memory
      in `decideReuse` (SIGSEGV). Mutate, then `return #resp`. The
      chained `return HttpResponse.ok().body(...)` form is fine and is
      what the older handlers use.
- [ ] **1.4** Client completeness. Broken to TDD granularity 2026-07-19.
  Decision encoded from the spec's lean: **cookie jar off by default**,
  explicit `CookieJar` opt-in (1.4g). `getJson` ships **untyped**
  (`JsonValue` via the stdlib `cajeta.codec.json`) — typed `getJson<T>`
  auto-serde is primavera's layer per the spec boundary. 1.4e is gated
  on 1.6.
  - [x] **1.4a Connection pool + keep-alive.** `ConnectionPool` keyed
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
    - **Shipped:** `client/ConnectionPool` + `OriginEntry` +
      `PooledConnection`. Key is `host:port` (scheme implicit — see the
      TLS note). Per-origin `Semaphore` whose permits ARE the connection
      budget (over-cap fibers park in `acquire`); LIFO idle stack
      threaded through the connections; a `Lock` guards table+stacks
      with every fiber-park kept outside it. Reaping is **lazy** at
      acquire (no timer-wheel fiber — nothing to reap when nobody
      calls; a background reaper can ride later without surface
      change). Revive probe: non-blocking raw `read` — 0 = FIN, >0 =
      protocol garbage, both evict; would-block revives. `HttpClient`
      leases around each plaintext exchange and pools when
      `KeepAlive.canReuse` AND the response framing self-terminates;
      `poolLimits(maxPerOrigin, idleMaxMs)` configures. **TLS stays
      dial-per-exchange** (probing a TLS stream would consume record
      bytes; needs a stdlib consume-free readiness probe) and keeps its
      honest `Connection: close`. Known gap for 1.4c: a dial that
      RAISES leaks the lease permit (structured cleanup across a
      parking call). Tests +12 checks (suite 299 → **311**), 240
      consecutive clean runs, tour 15/15.
    - **Land-mine, ROOT-CAUSED + FIXED upstream (cajeta `4e7d68ab`):
      `Server.dispatch` JOINED the connection fiber.** The cause was a
      cajeta codegen bug, not the stdlib: a statement-position
      `spawn f(...);` was wired into the *innermost block's drop frame*,
      and the Task drop's wait-before-free joined it at that brace — a
      per-site stack alloca that holds one Task, so `dispatch` blocked
      until the connection fiber ENDED, and a spawn loop serialized
      entirely (contra Concurrency.md's own concurrent-`scope`-`for`
      example). A handler that parked mid-request deadlocked the
      dispatcher. **Fix:** a discarded spawn now registers with the
      runtime *scope frame* as scope-owned (joined AND freed at scope
      exit, which holds N entries); `Server.serve` spawns inline in its
      accept-loop `scope { }` so connections overlap. `dispatch()` keeps
      its join-before-return semantics as the manual/harness surface.
      Regression: `SpawnScopeJoinTests` (loop concurrency, brace-join,
      throw-across-spawn). The cap test's fiber-dispatch dance is no
      longer *required* but is left as-is (still correct). Cost a full
      core-dump session (fiber-registry gdb walk in the playbook) plus a
      second one when a first fix — unwinding the scope chain inside
      `__cajeta_throw` — freed live frames (an exc-frame watermark can
      name an already-popped scope frame); the catching function's
      `scope_exit_to` already joins them, so the throw path needs no
      scope walk. Verified: http 311/311 + 440 clean runs, tour 15/15,
      cajeta concurrency suite 58/58.
    - **cajeta wrinkle found:** `#=` move from a **null** owned field
      throws (uncaught `0x3`) — null-guard before moving out of
      nullable owned fields (pool list ops do).
  - [x] **1.4b Redirects.** 301/302/303/307/308 with a hop cap; 303 →
    GET and drop the body, 307/308 preserve method + body; relative
    `Location` resolved via the stdlib `Uri`; `Authorization` stripped
    on cross-origin hops; loop → error.
    - TDD: loopback chains per code (method/body rewrite table), hop-cap
      trip, cross-origin auth strip, relative-Location resolution.
    - **Shipped:** `HttpClient.sendFollowing(uri, req)` — `send` stays
      the single-exchange primitive; `get()` now rides `sendFollowing`.
      Table as the de-facto consensus (Go/curl/browsers): 303 → `GET`
      for everything but `HEAD`; 301/302 → `GET` for `POST`/**`PUT`**;
      307/308 never rewrite; the body is forwarded **only** on 307/308
      (`Content-Type` goes with it when dropped). Each hop rebuilds from
      the ORIGINAL request: target + `Host` via `HttpRequest.fromUri`,
      original headers re-applied minus `host`/`content-length` (both
      re-derived) and `authorization` unless the hop targets the **same
      origin the caller addressed** (scheme + host + effective port —
      so a chain that returns to the origin regains auth). `Location`
      resolves through the stdlib RFC 3986 `Uri.resolve` (merge-path +
      dot-segments; the old origin-rebase `resolveRedirect` is deleted).
      Past `MAX_REDIRECTS` (10) — which is how a loop surfaces — it
      raises the new `TooManyRedirectsException extends HttpException`
      (carries `hops`); `get()`'s old return-the-last-3xx-at-cap
      behavior is gone with it. An unfollowable 3xx (no `Location`)
      still returns as-is. Tests: `/final` echoes
      `method|authorization|body` so one string pins each row of the
      table; chains ride ONE pooled connection (accept accounting), and
      the redirect responses carry small bodies so their framing
      self-terminates — a handler answering a bodyless 301 without
      `content-length` is close-delimited on the wire (server-side
      ergonomics for 1.5 to consider). Suite 311 → **338**, 120/120
      loop, tour 15/15, on cajeta 0.9.4 (`1b9987d4`).
    - **cajeta wrinkle found:** `spawn` rejects a class-qualified static
      call (`spawn Other.f(x)` → `CAJETA_ERROR_ASYNC_R3A` "doesn't
      support instance-method calls") — only bare same-class invocations
      spawn; RedirectTests carries its own `acceptAndDispatch` copy.
  - [x] **1.4c Timeouts, cancellation, retry.** Per-exchange budget over
    `cajeta.concurrent.Tasks.withTimeout` (no HTTP-specific timeout
    vocabulary) plus a connect timeout; auto-retry policy — idempotent
    methods only (`Method.isIdempotent`), connect-failure or
    pre-first-byte only, capped, with backoff.
    - TDD: stalled-server exchange times out at the budget (measurable
      now that 0.9's fiber-parking wait landed); POST never
      auto-retries; GET retries once on refused-then-listening; a
      cancelled exchange releases its pooled connection.
    - **Design deviation, forced by a verified substrate gap:**
      `Tasks.withTimeout` CANNOT bound a stalled exchange — probed
      standalone: `taskCancel` only sets the `cancel_with` marker, and
      nothing ever UNPARKS a fiber parked in socket I/O or a channel
      receive, so withTimeout's cancel-and-drain `await` hangs forever
      (a yield-free CPU body times out fine; parked bodies never
      observe the cancel). The budget therefore rides
      **`TcpStream.readWithin`** (NET-3.4, fiber-parking timed wait)
      inside the client instead — and since a budgeted exchange always
      settles, `withTimeout` composes ON TOP for callers who want the
      combinator. **Upstream follow-up wanted: cancel-unpark** —
      `__cajeta_fiber_cancel` should wake the target out of whatever
      park holds it (task_wait's resume path already checks the
      marker; channel/reactor parks need the wake + check).
    - **Shipped:** `HttpClient.exchangeTimeout(ms)` (0 = unbounded
      default) — one absolute deadline computed per `send`, shared by
      retries and every response read (`readBudgeted` passes the
      REMAINING budget to each `readWithin`; over → `TimedOutException`,
      the OS-level type, propagated as-is). `retryPolicy(maxRetries,
      backoffMs)` (defaults 1, 100 ms; `retryPolicy(0, 0)` disables) —
      `send` is now a retry loop over `sendOnce`: retry iff idempotent
      (`Method.isIdempotent`) AND transport-fault kind (refused / reset
      / aborted / host- or net-unreachable / broken-pipe — never
      `TimedOutException`, never a parse fault) AND budget left;
      backoff parks via `Tasks.sleepMillis` (new in 0.9.4). Phase is
      approximated by KIND (a mid-body reset on an idempotent GET
      re-fetches — idempotency is the true safety guard; a
      pre-first-byte `UnexpectedEof(bytesBuffered==0)` is deliberately
      NOT retried — conservative, the pool's revive probe already nets
      pooled corpses). **Structured cleanup on the raise path** (the
      1.4a gap, closed): a dial that raises frees its permit
      (`pool.releaseFailed`) before propagating; a mid-exchange raise
      evicts the connection AND frees the lease (`release(pc, false)`)
      — pinned by the maxPerOrigin=1 tests (a leak parks the follow-up
      exchange forever). Tests +14 (suite 338 → **352**), 120/120
      loop, tour 15/15.
    - **Land-mine, ROOT-CAUSED + FIXED upstream: `connectAsync` threw
      legacy integer TAGS.** The intrinsic's failure paths did
      `__cajeta_throw(IntToPtr(0x106/0x107))` — no exception object —
      and the catch dispatch binds a legacy int throw to the FIRST
      clause unconditionally, so `catch (NetException e)` bound
      `e = 0x107`; the 1.4c retry policy was the first code to READ a
      caught dial failure (`e.kind`) and SIGSEGV'd at 0x13f (= 0x107 +
      kind's offset). Every prior catch "worked" only by never touching
      `e` (same disease as 1.4a's recorded "`#=` from null throws
      uncaught `0x3`"). **Fix (cajeta, this session):** the intrinsic
      is renamed `connectAsyncNative` and now encodes the normalized
      `cajeta_net_err` ordinal into the tag (`0x200 + err`; the
      hard-fail path captures `last_error` BEFORE `close()` clobbers
      errno), and the public `TcpStream.connectAsync` is a cajeta
      wrapper catching the tag and materializing the typed exception
      via `NetErrors.fromErrno` — a refused dial now surfaces as a
      catchable `ConnectionRefusedException` with a readable `kind`.
      **cajeta `8db619a2`**; regression
      `test/parser/ConnectFailureTypedTests.cpp` (read the caught kind;
      live-dial path untouched). The sync `connect` / `bind` /
      socket-alloc tag throws (0x100–0x105) remain — same cleanup
      wanted upstream when something reads them. NOTE: this unit's
      tests REQUIRE a toolchain containing `8db619a2` (no released tag
      carries it yet — v0.9.4 = `1b9987d4` predates it; bump the CI pin
      when the next release ships). Also observed on cajeta main,
      PRE-existing: `SpawnDropTests.bareSpawnStillDrops` fails on clean
      `4e7d68ab` — it asserts the drop-at-spawn-site contract that
      commit replaced with scope-owned registration; stale test or
      instrumentation gap, needs its own look.
    - **Substrate gaps noted for later:** no `writeWithin` (request
      writes unbudgeted), no timed-connect primitive (a SYN-blackhole
      dial is unboundable; refused fails fast), no `TlsStream.readWithin`
      (TLS exchanges unbudgeted — the plan's TLS-reuse note grows a
      twin), `Semaphore` has no timed acquire (an origin-cap park is
      outside the budget).
  - [x] **1.4d Streaming + download.** Request/response `Body` streaming
    through the client (rides 1.3c/1.3e); `downloadTo(path)` over
    `cajeta.io.file` returning a running `cajeta.hash.Sha256` digest.
    - TDD: large download lands byte-identical, digest matches, memory
      stays bounded; streamed upload arrives intact server-side.
    - **Shipped — upload:** `HttpClient.writeRequest` is the streaming
      seam: a request whose `bodyModel` is unknown-length (raw path
      empty — 1.3e drains known-length at attach, so that combination
      IS the streaming case) goes out as
      `HttpSerializer.requestChunkedHead` (new; request twin of
      `responseChunkedHead`) + the body's reader pumped through
      `ChunkedEncoder` 8 KiB at a time + `encodeLast`; nothing
      materializes. Both exchange paths (pooled/timed and TLS) ride it.
    - **Shipped — download:** `downloadTo(url, destPath) → #Sha256` —
      follows redirects with 1.4b's exact table (bodyless GET, so the
      rewrite degenerates), streams ONLY the final 2xx body to the file
      via `downloadExchange`: head parse, then `BodyReader` fed 8 KiB
      reads and `drain()`ed incrementally into `FileWriter` + a running
      `Sha256` — one scratch + one drained piece is the whole in-flight
      footprint (bounded-memory is a construction property; tests prove
      byte-identity by re-hashing the file). Non-2xx bodies buffer as
      usual (Location handling unchanged); a non-2xx final raises
      `HttpException("downloadTo: HTTP <status>")`; hop cap raises
      `TooManyRedirectsException`. Budget (`exchangeTimeout`) applies
      per hop on the pooled path; downloads do NOT auto-retry (a
      mid-stream retry would corrupt the file — resume is a later
      increment). Same raise-path lease cleanup as `sendOnce`.
    - **The 1.4b caveat, now FIXED at the serializer:** a pooled GET to
      a bodyless `HttpResponse.notFound()` stalled 30 s — no
      `content-length`, so the response was close-delimited while the
      keep-alive server held the socket; the client (correctly) read
      until the server's head-read deadline killed it.
      `HttpSerializer.writeResponse` now stamps `content-length: 0` on
      bodyless responses (EXCEPT 1xx/204/304 where CL is forbidden);
      requests deliberately don't get the stamp. Killed the stall and
      shaved the whole suite (~4.5 s → ~1.2 s/run — other bodyless
      responses had been quietly close-delimited too).
    - Tests (DownloadTests, +14; suite 352 → **366**, 150/150 loop,
      tour 15/15): 4 MiB known-length download (digest + re-hashed file
      match, one accepted connection), download through a 302, CHUNKED
      4 MiB wire response via a raw one-shot server (decode through the
      same pump), 404 → `HttpException`, and a 1 MiB unknown-length
      `StreamBody` POST whose server-side echo pins the received
      sha256 AND the observed `transfer-encoding: chunked` framing.
    - Still open from 1.3e (server-side legs, unchanged): streamed
      *response* through `ResponseBodyWriter`, request body as a `Body`
      pre-buffering, per-route 413, implicit drain-on-return.
  - [x] **1.4e `getJson()` + transparent decompression** *(gated on
    1.6)*. `getJson()` → `JsonValue`; the client advertises
    `Accept-Encoding: gzip, deflate` and inflates transparently,
    clearing `Content-Encoding` and fixing lengths up.
    - TDD: gzip/deflate/identity responses yield identical bodies;
      corrupt compressed stream → clean error, not garbage; JSON
      round-trip against the stdlib codec.
    - **Shipped:** `send` stamps `Accept-Encoding: gzip, deflate` only
      when the caller set none (an explicit `identity` opt-out rides
      through); `decodeResponse` runs after every `sendOnce` — a
      supported single `Content-Encoding` token (`gzip`/`x-gzip`/
      `deflate`) is inflated via `ContentCoding.decode` under a new
      `decodeLimit(maxBytes)` cap (default 64 MiB), `Content-Encoding`
      cleared, `content-length` re-stamped (`resp.body #= decoded` —
      owned-field reassign); `identity` just clears the header; unknown
      tokens (`br`) and multi-coding chains pass through UNTOUCHED,
      body + header both. `getJson(url)` = `get` → require 2xx (else
      `HttpException`) → Tier-3 `Json.parse` → owned `JsonValue` DOM.
      ClientCodingTests: +14 checks (suite 384 → **398**) — three
      codings byte-identical over ONE pooled connection, advertise +
      caller-override echoed off the wire, corrupt gzip →
      `ContentCodingException`, cap trip, unknown-coding passthrough,
      getJson field asserts + `Json.toBytes` byte round-trip + 404
      raise. 150-run loop clean, tour 15/15.
    - **Upstream find (the round-trip test caught it): READS corrupted
      the stdlib JSON DOM.** The `(#int8[], int32)` String ctor's
      @Native core consumes its buffer unconditionally (inline-copy +
      FREE ≤ cap, adopt above it) because @Native bodies never see the
      runtime title flag — and `JsonValue.asString()` /
      `JsonObject.keys()` fed it the DOM's own buffers. First read
      freed/aliased the tree; the next allocation recycled it; stale
      single reads masked it (every earlier consumer read once). Fixed
      in cajeta `65588252` (+ `JsonStringOwnershipTests`, 4 red→green,
      read-churn-read pattern); the @Native title-flag gap is recorded
      on cajeta's focus stack. **Suite now requires a compiler ≥
      `65588252`** — bump the CI pin alongside the 8db619a2 note.
  - [x] **1.4f Builder + proxy.** `HttpClient.builder()` — default
    headers, version pin, pool sizes, redirect/retry/timeout policy,
    TLS trust, HTTP proxy (absolute-form for `http`, CONNECT tunnel
    for `https`).
    - TDD: builder defaults observable on the wire; proxied loopback
      exchange through a minimal in-test proxy, both forms.
    - **Shipped:** `HttpClientBuilder` (clone-at-build discipline;
      unset knobs keep client defaults; drives the client's own
      setters — `heap HttpClient()` + setters stays equivalent). New
      client surface: `defaultHeader` (stamped only when the request
      lacks the name — caller wins), `version` pin (stamped in `send`;
      `null` default leaves requests alone), `redirectLimit`
      (`redirectMax` field now backs `sendFollowing`/`downloadTo`;
      `MAX_REDIRECTS` is the default), `proxy(host, port)`. Proxy
      routing: plaintext dials AND pools on the proxy authority with
      the target rewritten absolute-form (`ensureAbsoluteTarget`,
      idempotent for retries/hops; `HttpRequest.target(t)` setter
      added); `https` runs `connectTunnel` — `CONNECT host:port` via
      `connectAny(proxy)`, head read to the blank line (4 KiB cap),
      2xx required (`statusOfHead`), then the usual origin-host TLS
      wrap rides the tunnel (proxy never sees plaintext); `downloadTo`
      routes identically. ClientBuilderTests +13 checks (suite 398 →
      **411**): default-header + override and version pin echoed off
      the wire, redirectLimit(2) passes a 2-hop chain / (1) trips,
      absolute-form proven by an HttpServer-as-proxy echoing the
      target for a nonexistent origin, and the CONNECT leg runs a REAL
      raw proxy (head validated, 200, bidirectional pump relay) into a
      raw `TlsStream.server` origin — first in-repo TLS-server test;
      self-signed P-256 cert (SAN IP:127.0.0.1, 2036 expiry) embedded
      in the test, pinned via `trustAnchor`. 150-run loop clean, tour
      15/15.
  - [x] **1.4g `CookieJar`** (decision: **off by default**, explicit
    `.cookieJar(jar)` opt-in). RFC 6265 subset: `Set-Cookie` parse,
    domain/path matching, expiry/max-age, `Secure`/`HttpOnly` honored.
    - TDD: no jar → nothing echoed back; with jar → set/return across
      exchanges, domain/path scoping, expiry drops the cookie.
    - **Shipped:** `Cookie` (owned-chain node, pool linked-stack idiom
      — no growable array) + `CookieJar`: §5.2 parse (`Domain`/`Path`/
      `Max-Age`/`Expires`/`Secure`/`HttpOnly`, unknown attrs ignored),
      §5.1.3 domain-match with store-time rejection of a non-matching
      `Domain` (no public-suffix list in v1), §5.1.4 default-path +
      path-match, `Max-Age` wins over `Expires` (`<= 0` deletes), a
      strict RFC 1123 `Expires` parser (days-from-civil; unparseable →
      session cookie), lazy expiry eviction at match time, same
      `(name, domain, path)` replaces. Send order is creation order
      (§5.4 longest-path-first sort deferred — noted in the class
      doc). Client: `cookieJar(#jar)` adopts (`null` default = OFF —
      nothing stored or sent); `send` stamps `Cookie` only when the
      caller set none, and admits every response `Set-Cookie` via
      `getAll`. Builder: `.cookieJar()` attaches a fresh jar at build.
      ClientCookieTests +10 checks (suite 411 → **421**): default-off,
      cross-exchange round-trip incl. two `Set-Cookie` in one
      response, `/app` path scoping, `Max-Age=0` delete + future/past
      `Expires` (both RFC 1123 arms), `Secure` withheld over http,
      foreign `Domain` rejected. 150-run loop clean, tour 15/15.
      Compiler wrinkle recorded: an owned-chain detach temp
      (`X rest #= …`) must not live across a loop backedge —
      use-after-move flags it; one-unlink-per-call helpers dodge it.
- [ ] **1.5** Server hardening. Broken to TDD granularity 2026-07-19.
  Substrate check: the head-read deadline already exists (`readWithin`,
  30s default), `HttpServer.shutdown(Duration)` already drains, and the
  stdlib ships `ConnectionLimits`/`ConnectionLimiter`/`LoadShedPolicy`
  for accept control — this unit makes budgets configurable, adds the
  missing phases, and proves the existing pieces under test.
  - [x] **1.5a Deadlines.** Configurable per-phase budgets on
    `ServerLimits`: header-read (slowloris) deadline, body inter-read
    timeout, whole-request budget; 408 where a response is still
    possible, close otherwise.
    - TDD: drip-fed headers cut at the deadline (and not before);
      stalled body read cut; handler overrun cut at the request budget;
      timings asserted against configured values, not wall-clock
      guesses.
    - **Shipped:** the pre-1.5a `headReadTimeoutMs` was a PER-READ
      timeout — it bounded the idle wait for each byte, so a slowloris
      dripping one byte per (sub-deadline) interval never tripped it.
      Now it stays the idle/keep-alive wait for a request's FIRST byte,
      but from that byte an **absolute whole-head deadline** caps the
      complete head; a spent deadline degrades the next read to a 1 ms
      grace whose `TimedOutException` is the cut (`remainingMs` /
      `clampReadMs` helpers). `bodyReadTimeoutMs` stays the inter-read
      body budget (each arriving piece resets it — a live trickle
      survives, a stall is cut). New `ServerLimits.requestBudgetMs`
      (`0` = off): an absolute whole-request deadline from the first
      byte spanning head + body reads AND the handler — it caps every
      read (so it bounds a drip even with no per-phase deadline armed)
      and, via `dispatchBudgeted`, runs the handler on its own fiber
      polled (5 ms) against the deadline; an overrun writes `503` +
      `Connection: close` AT the deadline, then drains the stray
      handler fiber (can't cancel — parked fibers never observe
      `taskCancel`, and the abandoned Task's drop joins it anyway). A
      `TimedOutException` from the head/body read path now answers
      **408** (best-effort) before closing, instead of a silent drop.
      New pieces: `HandlerRun` (atomic-flag handoff cell — a `Channel`
      won't do, its v1 `send(T)` borrows and the handler's response
      would dangle), `Exchange.written` (loop must not re-write the
      already-flushed 503), builder `serverLimits(#l)` +
      `bindAddressWithModelAndLimits` (limits installed BEFORE the
      accept closure captures them by value — a post-bind swap never
      reaches an accepted connection; this was a real hang in dev).
      ServerDeadlineTests +11 checks (suite 421 → **432**), every cut
      asserted `>= configured && < 4x`: drip-head 408, slow-but-
      in-budget served, stalled-body 408 with the reset-clock control,
      handler-overrun 503 before the handler's own 900 ms, budget-
      bounds-a-drip with no per-phase deadline. 150-run loop clean,
      tour 15/15.
  - [x] **1.5b Size limits.** Per-server max body size — early 413,
    sharing 1.3e's parse-time enforcement (global cap here; per-route
    came with 1.3e) — and `HttpParserLimits`' header caps surfaced on
    `ServerLimits`.
    - TDD: over-limit content-length 413s before the handler runs;
      over-limit chunked cut mid-stream; exactly-at-limit passes.
    - **Shipped:** the body-cap enforcement already existed
      (`maxBodyBytes` → 413 up front for a declared `Content-Length`,
      mid-stream for chunked, `errorResponse` mapping
      `PayloadTooLargeException.httpStatus()`); this unit adds the
      **head caps surfaced on `ServerLimits`** — `maxHeadBytes` /
      `maxLineBytes` / `maxHeaderCount` fields mirroring
      `HttpParserLimits`, plus `ServerLimits.toParserLimits()`, and
      `bindAddressWithModelAndLimits` installs them onto `srv.limits`
      **before** the accept closure captures it by value (the same
      capture-order discipline 1.5a needed). So a server's whole
      hardening posture — deadlines, body cap, head caps — is now
      configured in ONE place and reaches both the read loop and the
      parser. ServerSizeLimitTests +10 checks (suite 432 → **442**):
      every rejection proven not just by status but by the handler's
      "HANDLED" sentinel being ABSENT — over-`Content-Length` 413
      before the handler, at-cap body served, chunked cut mid-stream
      with 413, too-many-header-fields 431, over-long header line 431.
      150-run loop clean, tour 15/15.
  - [ ] **1.5c Accept control + graceful shutdown.** Configurable
    listener backlog; `ConnectionLimits` + shed policy wired through
    `HttpServer.builder()`; `shutdown(Duration)` proven — stop
    accepting, drain in-flight, hard-close at the deadline.
    - TDD: capacity + shed behavior observable under concurrent
      connects; shutdown mid-exchange completes that exchange and
      refuses new ones; a hung exchange is cut at the deadline.
- [ ] **1.6** Compression — a **prerequisite for 1.4e, 2.2c, and 4.1**.
  *(Re-planned 2026-07-19: the original from-scratch DEFLATE plan is
  obsolete — the external **`dev.cajeta.codec`** library
  (`~/code/cpp/cajeta-codec`, published in `~/.olla` at 0.5.0) already
  ships block-mode `compress.Deflate` (fixed + dynamic Huffman,
  `deflate`/`inflate`/`inflateGrow`), `Gzip` (+`crc32`), and `Zlib`
  (+`adler32`) — pure cajeta, already consumed by cajeta's `tools/mcp`.
  The stdlib itself still has only the `cajeta.wire`
  Compressor/Decompressor interfaces.)* Brotli stays deferred.
  - [x] **1.6a Adopt `dev.cajeta.codec`.** Add the dependency (olla
    store, like tools/mcp does), route HTTP content-coding through
    `Gzip`/`Zlib`/`Deflate`, and pin interop with golden vectors
    (fixtures produced by system zlib — test-only).
    **Known upstream blocker (found 2026-07-19 via the MCP inbound-gzip
    crash):** `Deflate.inflate` mishandles real-world DEFLATE — a stock
    `gzip` of a 46-byte JSON (fixed-Huffman + LZ77 back-references)
    decompresses to an *empty* buffer standalone, and in-server dies
    with `array index -4 out of bounds for dimension size 46` (a
    back-reference copy with `dist > outPos` into the ISIZE output).
    Its own deflate output round-trips, which is how it hid. Fix is
    cajeta-codec-side; the 1.6a system-zlib vectors are exactly the
    regression net.
    - TDD: round-trips through the dependency; **system-zlib/gzip
      produced fixtures must inflate correctly** (the case above is
      vector #1); malformed/truncation/trailing-garbage rejects at the
      HTTP boundary; wrong-`destLen` handling for `Zlib.decompress`.
    - **Codec-side (cajeta-codec `6dc4e43` + `48b3c7a`, published
      `dev.cajeta.codec@0.5.1` to the local olla):** the 2026-07-19
      inflate blocker was ALREADY cured by `017ded2`'s ownership sweep
      (verified against the MCP vector) — the olla 0.5.0 artifact just
      predated it. What 1.6a's hostile-input probes then found:
      **malformed DEFLATE trapped the process** (truncation = uncatchable
      OOB abort in the bit reader; reserved BTYPE spun; an invalid
      Huffman code silently ended the block with partial output), and
      neither envelope verified anything. Hardened: `DeflateException`
      (new) raised on truncation / BTYPE 3 / invalid codes /
      dist-past-output / stored NLEN mismatch / code-length overruns;
      `Gzip.decompress` validates magic+CM+bounds, inflates via the
      GROWING path (ISIZE is untrusted, not an allocation hint) and
      verifies CRC-32 + ISIZE; `Zlib.decompress` validates CMF/FLG and
      verifies Adler-32, `destLen` demoted to an initial-buffer hint.
      Plus one more latent 0.9 ownership bug the new tests exposed:
      `ensure()`'s grown buffer was PLAIN-assigned into the owned field
      (`this.out = nb`) — use-after-free; the growth path had never
      been exercised. Verified first via a direct driver (11/11 ×5), then — after the
      abort was ROOT-CAUSED (see below) — under the runner itself.
      **The "reflective-runner abort" was never a runner bug**: it
      reproduced with direct calls, and was codec heap corruption from
      a SECOND family of 0.9 ownership misses (cajeta-codec `d02175c`):
      five growth writers plain-assigning their grown buffer into the
      owned field (AvroWriter/ProtobufWriter/IonWriter/
      ThriftCompactWriter/BitWriter — freed buffer, dangling field,
      `malloc: corrupted top size` at the next allocation; the passing
      tests simply never grew past 64 bytes), and IonCursor storing
      `IonIndex.buildAt`'s owned return / stepIn's owned local straight
      into `frames[]` slots (dropped at statement end; SIGSEGV in
      `String.equals` once the heap got reused). Codec suite:
      20-then-SIGABRT → **173/173, 0 failed** ×3 through the vindicated
      runner. Release chain: codec `v0.5.1` tagged + pushed; CI pin
      bumped v0.7.1 → v0.9.3, GPU-decode oracle non-blocking (XPU
      surface is feature-branch-only); first tag run red on
      cajeta-unit's UNPUSHED `#Invocation` migration fix (885a5bf on
      `feature/0.9.0-migration` — needs a push to its main).
    - **http-side:** `dev.cajeta.http.coding.ContentCoding`
      (`encode`/`decode(token, data, len, maxOut)`/`isSupported`) +
      `ContentCodingException extends HttpException`. Tokens: `gzip` +
      `x-gzip`, `deflate` (= STRICT zlib per RFC 9110 §8.4.1.2;
      raw-deflate leniency deferred), `identity`. `maxOut` is the
      decompression-bomb cap — v1 enforces it post-inflation (1.6b's
      streaming surface makes it pre-allocation). Tests +18 (suite 366
      → **384**, 150/150 loop, tour 15/15): round-trips, system
      python-zlib/gzip fixtures (level 9, dynamic Huffman + back-refs,
      360-byte output through the growth path), truncation/CRC/garbage
      rejects, cap trip, token surface.
    - **Wiring notes:** manifest gains
      `"dev.cajeta.codec": "0.5.1"`; the raw-CLI test compile and the
      tour's `run.sh` need the codec `.cja` appended to `--classpath`
      (comma-separated) — archive sources re-compile downstream, so
      every consumer classpath must carry the transitive dep. **Release
      chain:** codec `v0.5.1` is only in the LOCAL olla — tag it so CI
      (remote Olla) can resolve cajeta-http builds.
    - **cajeta wrinkle found:** a cross-archive class in CATCH POSITION
      resolves to `int64` (the catch var binds as the legacy int-catch;
      `e.getMessage()` → "no member on int64") — the scoped-resolution
      bug class, catch-clause tier. Dodge: catch the stdlib
      `RecoverableException` root instead; upstream fix wanted in
      `Statement.cpp`'s catch-type lookup.
  - [x] **1.6b Streaming surface.** The gap the dependency does not
    cover: incremental inflate/deflate with the dictionary/window
    preserved across calls plus flush modes — what 4.1's context
    takeover and 2.2c's streamed bodies need. Build it **against
    cajeta-codec's block core, preferably upstreamed there** (it is
    that repo's natural API growth), with cajeta-http consuming it.
    - TDD: chunk-at-a-time equals one-shot on the 1.6a vectors; sync
      flush boundaries decode standalone; context carries across
      messages.
    - **Shipped (upstreamed — cajeta-codec `ae12c81`, 0.5.1 → 0.6.0):**
      `InflateStream` — `feed()` arbitrary chunks (splits mid-symbol
      fine) / `drain()` committed output / `finished()` / `endInput()`
      (truncation raises there and only there). Resume discipline:
      whole-block trial decode from the last committed BLOCK BOUNDARY;
      input exhaustion mid-block throws the internal `InflateNeedMore`
      subtype → trial rolled back → same block re-decodes next feed
      (corruption still raises `DeflateException` to the caller). A
      sync-flush boundary is an ordinary empty stored block, so it
      commits and drains with no lookahead; output slides post-drain
      (O(window + largest block)); the back-ref reach check is against
      TOTAL output so carried context counts — and a context-dependent
      segment fed to a FRESH stream rejects, proving the context real.
      `DeflateStream` — `write()` + `syncFlush()` (non-final
      fixed-Huffman block + the `00 00 FF FF` empty stored block,
      byte-aligned) / `finish()` (BFINAL); window carries via
      `Deflate.deflateFixedInto`, the encoder core range-parameterized
      so retained history PRIMES the match finder without re-emission
      (`deflateFixed` is now a thin wrapper). Concatenated segments
      form one valid DEFLATE stream the block core inflates whole.
      Codec suite 173 → **182** ×3 clean (`StreamingDeflateTest`, 9
      tests incl. 1/3/7-byte feeds over huffman + stored, the
      second-identical-message-compresses-smaller context proof, and
      truncation-only-at-endInput). http side: dep + classpaths bumped
      to 0.6.0, `StreamingCodingTests` consumes the surface through
      the classpath (+6 checks, suite 442 → **448**), tour 15/15.
      Loop: 300 runs total — ONE unexplained red (run 54 of the first
      150; output discarded by the loop harness, signature lost), then
      0/150 on an instrumented rerun. Watch for a repeat; the capture
      loop (save failing run's stdout) is the tool. Also RE-LEARNED
      twice in one session: a `cd` inside a BACKGROUND compound
      command leaks into later background tasks — the test binary must
      run from the repo root (downloadTo writes relative paths) via an
      explicit `cd` in the same command string. **Release chain: codec
      0.6.0 is local-olla only — tag v0.6.0 when ready so CI (remote
      Olla) resolves it; the http CI pin note from 1.6a still
      stands.**
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
- [x] **1.8** Server TLS termination — found unplanned during the
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
  - **Shipped:** `builder().tls(cert, certLen, key, keyLen)` (PEM
    copies) → `bindTlsAddress`: a PLAIN `TcpListener` bind — NOT
    `TlsListener`, whose accept fuses the handshake into the accept
    path where one hostile peer would stall the acceptor. Each
    accepted socket goes to its own `tlsWorker` fiber: `TlsStream
    .server` wrap + `http/1.1` ALPN + handshake (failure closes THAT
    connection, isolated), then the exact hardened h1 loop via the
    pre-existing `serveTlsStream` — TLS is pure termination above the
    ByteChannel seam, so deadlines/size caps/budgets all apply
    unchanged. Accept surface mirrors the plaintext core
    (`acceptTlsNext`/`dispatchTls` for accept-accounting tests;
    `serve()` runs the loop via a one-accept-per-call helper — the
    owned-local-across-backedge rule; `shutdown` closes the listener,
    scope-join drains workers; plaintext-core-style drain accounting
    noted as 1.5c-tier follow-up). ServerTlsTests +10 checks (suite
    448 → **458**): HTTPS exchange with the SHIPPED client (1.4f cert
    fixture pinned via `trustAnchor`), plaintext-to-TLS-port clean
    failure THEN a served TLS peer, three garbage handshakes then a
    clean exchange, WSS upgrade + echo over `TlsStream` end-to-end.
    Tour gains the HTTPS leg (15 → **17** checks). 150-run loop
    clean — under a concurrently running full compiler sweep, which
    also exercises the deadline tests' timing margins.

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

- [ ] **4.1** `permessage-deflate` (RFC 7692) *(gated on 1.6b)*:
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
