# cajeta-http — HTTP / WebSocket / SSE

HTTP/1.1 · HTTP/2 · HTTP/3, WebSocket (RFC 6455), and Server-Sent Events —
client and server — built on the stdlib transport layer `cajeta.io.net`.

> **This spec unifies two predecessors.** The shipped HTTP/1.1 + WebSocket
> reality previously documented in the stdlib (`cajeta/docs/Net.md`) and the
> HTTP/2 + middleware + SSE forward design (`cajeta/docs/specification/io/net/
> Networking.md`) are combined here, with HTTP **extracted out of the stdlib**
> into this library. Where the two disagreed, the shipped behaviour wins
> (e.g. handlers are **un-colored** — there is no separate async-handler type —
> and TLS is the bundled stdlib stack, not redefined here).

## Why this is a library, not stdlib

HTTP is an *application* protocol over transport. HTTP/1.1 and HTTP/2 ride TCP;
**HTTP/3 rides QUIC over UDP** — so HTTP is transport-independent and sits *above*
the transport layer. The stdlib (`cajeta.io.net`) ships the transport substrate;
HTTP ships here, opt-in. Rust draws the same line (`std::net` in std, HTTP in
crates). A raw-TCP or UDP-multicast service never links HTTP.

## Layering and boundaries

```
primavera          — REST/web POLICY: @Rest endpoints, annotation routing, auto-serde
   └─ cajeta-http  — HTTP/1.1·2·3, WebSocket, SSE; imperative client + server
        └─ cajeta.io.net (stdlib)  — sockets, TCP/UDP, reactor, TLS, URI, framing
```

- **From `cajeta.io.net` (consumed, not redefined here):** `TcpStream`/`TcpListener`,
  the cross-platform reactor (epoll/kqueue/IOCP), the two server **accept models**
  (fiber-per-connection / shared-pool), `cajeta.io.net.tls.TlsStream` (bundled
  BoringSSL), `Uri`, and the buffer/view/stream substrate.
- **This library provides:** the HTTP/WS/SSE protocol codecs and the imperative
  `HttpClient` / `HttpServer` / `Router` / `WebSocket` surface.
- **primavera provides (not here):** `@Rest`/`@WebSocket` endpoint annotations,
  routing-by-signature, and automatic serialization to/from a typed object model.

## Execution model — inherited, un-colored

HTTP does **not** define its own reactor or handler-coloring. A server runs under
one of `cajeta.io.net`'s accept models, chosen at the listener:

- **fiber-per-connection** (default) — one fiber per connection; handlers are
  ordinary blocking-looking code (the reactor turns "blocking" reads into
  park/resume). Lowest latency; ~64KB stack/conn.
- **shared-pool(N)** — a bounded worker pool drains a readiness/completion queue;
  bounded memory for C10K-style mostly-idle fan-out.

Either way the handler is the **same** un-colored shape — `(HttpRequest) -> HttpResponse`.
There is no `AsyncHandler`; fibers make "blocking" handlers non-blocking for free.

## Package layout

```
dev.cajeta.http              — Method, Status, Version, MediaType, HeaderValues,
                               PathParams, HttpRequest/HttpResponse, exceptions
                               (Headers and Uri are consumed from cajeta.io.net)
dev.cajeta.http.body         — Body: in-memory + streaming; chunked; multipart
dev.cajeta.http.client       — HttpClient: pooling, redirects, retry, timeouts
dev.cajeta.http.server       — HttpServer, request lifecycle, graceful shutdown
dev.cajeta.http.routing      — Router: typed path params, route trees, dispatch
dev.cajeta.http.middleware   — Middleware + bundled set
dev.cajeta.http.h1           — HTTP/1.1 wire protocol (internal)
dev.cajeta.http.h2           — HTTP/2: HPACK, framing, multiplexing, flow control (internal)
dev.cajeta.http.compression  — gzip / deflate / brotli
dev.cajeta.http.sse          — Server-Sent Events
dev.cajeta.http.ws           — WebSocket frame protocol + client/server
```

Deferred to follow-ups: `dev.cajeta.http.h3` (HTTP/3 over QUIC), and `cajeta-grpc`
(a separate library over HTTP/2).

---

## Core types

Shipped (`http:1.2` / `1.2b`) — signatures as implemented:

```cajeta
public enum Method {                  // RFC 9110 §9 registry + EXTENSION sentinel
    GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, CONNECT, TRACE, EXTENSION;
    public static Method of(String token);           // unregistered → EXTENSION
    public static boolean isRegistered(String token);
    public String token();
    public boolean isSafe(); public boolean isIdempotent(); public boolean allowsBody();
}
public enum Version { HTTP_1_0, HTTP_1_1, HTTP_2, HTTP_3;
    public static Version of(String wire);
    public String wireString(); public boolean supportsKeepAlive();
}
public final class Status {           // full RFC 9110 §15 registry + class predicates
    public static #Status of(int32 code); public static #Status of(int32 code, String reason);
    public int32 code(); public String reason();
    public static #String reasonFor(int32 code);     // THE reason-phrase registry
    public boolean isInformational(); public boolean isSuccess(); public boolean isRedirection();
    public boolean isClientError(); public boolean isServerError();
}
public final class MediaType {        // RFC 6838 parse; lowercased type/subtype/param names
    public static #MediaType parse(String input);    // quoted values handled
    public String type(); public String subtype(); public #String essence();
    public boolean is(String t, String sub); public #String parameter(String name);
    public static #MediaType applicationJson(); /* … textPlain, textHtml,
        applicationOctetStream, applicationFormUrlencoded, multipartFormData */
}
```

An enum value is an i32 and cannot be null, so `Method.of` answers the tenth
`EXTENSION` constant for unregistered tokens (`isRegistered` is the predicate).

**`Headers` is the stdlib's** (`cajeta.io.net.Headers` — case-insensitive,
multi-value, insertion-order-preserving), not redefined here. The typed reads
live library-side in **`HeaderValues`** statics — `contentLength(Headers)` →
`int64` (−1 for absent/malformed, RFC 9110 §8.6 `1*DIGIT`) and
`contentType(Headers)` → `MediaType` (null on absent/malformed) — and are
mirrored as typed views on the messages themselves:
`HttpRequest.methodType()/versionType()/contentType()/contentLength()` and
`HttpResponse.statusType()/versionType()/contentType()/contentLength()`. The
raw `String`/`int32` wire fields stay authoritative — extension tokens are
legal on the wire and the serializer emits fields verbatim.

URLs use the stdlib `cajeta.io.net.uri.Uri` (RFC 3986 parse/build, percent-encoding,
ordered query multi-map, reference resolution for relative `Location` headers).

---

## Body — streaming by default

```cajeta
public abstract class Body {
    public abstract int64 contentLength();       // -1 = unknown/chunked
    public abstract MediaType contentType();
    public abstract AsyncReader reader();        // cajeta.io.net reader (there is
}                                                // no stdlib InputStream)
public final class BytesBody extends Body { ... }
public final class StringBody extends Body { ... }
public final class StreamBody extends Body { ... }   // upload/download, no materialize
public final class FormBody extends Body { ... }     // x-www-form-urlencoded
public final class MultipartBody extends Body { ... }
public final class MultipartParser { public Iterator<MultipartPart> parts(); }
```

Large uploads pull from `body.stream()` without materializing; small bodies use
`bytes`/`asString()`. Bodies stream through `cajeta.io.net`'s bounded
`AsyncReader`/`AsyncWriter` — nothing forces a full payload into memory.

---

## Client

**Shipped core (extracted from the stdlib):** construct, optionally pin a trust
anchor, `get`/`send`. Each call parks the calling fiber and returns the buffered
`HttpResponse` directly (no `await`); `https://` verifies against the OS trust store.

```cajeta
HttpClient client = heap HttpClient();
// client.trustAnchor(pem, pemLen);                 // optional private-CA pin
HttpResponse resp = client.get("https://example.test/path");
int32 status = resp.statusCode();
int8[] body = resp.body;                            // buffered
```

**Planned, each layered over that single exchange:**

- **Connection pool + keep-alive** keyed on `(scheme, host, port)`; idle reaping;
  `maxConnectionsPerOrigin`. HTTP/2 uses one multiplexed connection per origin.
- **Redirects** (301/302/303/307/308) with hop cap, method/body rewrite,
  relative-`Location` resolution, cross-origin `Authorization` stripping.
- **Timeouts / cancellation** via `cajeta.concurrent` `Tasks.withTimeout` — no
  HTTP-specific timeout vocabulary.
- **Streaming bodies**, `downloadTo(path)` with running SHA-256, `getJson<T>`,
  transparent gzip/deflate.

A builder (`HttpClient.builder()…`) configures version, redirect/retry policy,
pool sizes, proxy, TLS, default headers.

---

## Server + routing

```cajeta
Router router = heap Router();
router.route(Method.GET, "/users/{id:int64}", (HttpRequest req) -> {
    int64 id = req.pathParam("id");
    return HttpResponse.of(200).setHeader("Content-Type", "application/json").body(lookup(id));
});

HttpServer server = HttpServer.builder()
    .bind("0.0.0.0:8443")
    .model(ServerModel.fiberPerConnection())   // or .sharedPool(n) — from cajeta.io.net
    .tls(serverTls)                            // a cajeta.io.net.tls config
    .router(router)
    .serve();
```

- **Accept model** is `cajeta.io.net`'s (`fiberPerConnection()` / `sharedPool(n)`),
  not an HTTP-specific mode. Handlers are un-colored.
- **Router** — method + typed path patterns: `/users/{id}` (string),
  `/users/{id:int64}` (typed; mismatch → 404, never reaches the handler),
  `/files/{p:*}` (segment), `/static/{p:**}` (recursive). `mount(prefix, sub)` nests.
- **Streaming** handlers read/write chunked bodies incrementally.
- **HTTPS** — TLS termination via `cajeta.io.net.tls` in front; ALPN.
- **Hardening** — request timeout, max body size, slowloris header-read deadline,
  `100-continue`, configurable backlog.

### Middleware (planned)

```cajeta
public abstract class Middleware { public abstract HttpResponse wrap(HttpRequest req, Handler next); }
```

Bundled: `RequestId`, `Logging`, `Recover`, `Timeout`, `Cors`, `Compression`,
`Decompression`, `RateLimit`, `BasicAuth`, `BearerAuth`, `StaticFile`, `ETag`,
`ProxyHeaders`. Composition is registration order; middleware and handlers share the
same shape, so composition is function composition.

> **The stdlib provides a *minimal* router, deliberately not a framework**
> (Go `net/http.ServeMux` spirit). Rich endpoint ergonomics — annotation routing,
> auto-serde — are **primavera's** layer on top.

---

## HTTP/2 (planned)

HPACK header compression, frame framing, stream multiplexing, flow control, server
push (opt-in; deprecated upstream but kept for non-browser clients). Negotiated via
ALPN over TLS, h2c upgrade for cleartext. Plugs in behind the same client/server
surface — user code unchanged. Frame parsing is the canonical zero-copy **`view`**
use case: the 9-byte frame header decodes in place over a pooled buffer
(`H2FrameHeader(buf)`), no per-frame allocation.

## HTTP/3 (deferred)

HTTP/3 over QUIC over **UDP** — gated on a QUIC state machine over `cajeta.io.net`
UDP sockets. The transport abstraction is designed to accommodate it; not near-term.

---

## WebSocket

RFC 6455 client + server; rides the HTTP upgrade handshake.

**Shipped core:** `WebSocket` wraps an `AsyncReader`/`AsyncWriter` pair over an
upgraded transport (`forClient`/`forServer`); the handshake runs first. Calls park
the fiber directly.

```cajeta
WebSocket ws = WebSocket.forClient(reader, writer);
ws.send("hello");                          // text
WsMessage m = ws.receive();                // m.isText() / m.isBinary()
ws.sendBinary(payload, len);
ws.close(WsCloseCode.NORMAL, "bye");       // 1000
```

- **Handshake** — `Sec-WebSocket-Key` / `Sec-WebSocket-Accept` = `base64(SHA-1(key+GUID))`
  (uses `cajeta.hash.Sha1` + `cajeta.codec.Base64`).
- **Frame codec** — FIN/RSV/opcode/MASK/length (7/16/64-bit) + masking; client frames
  masked, server unmasked; incremental decoder. Frame headers decode via a `view`.
- **Fragmentation** — continuation frames reassemble with a max-message-size limit.
- **Control frames** — ping/pong (auto-pong default), bidirectional close handshake.
- **Concurrency** — a reader fiber + a writer fiber on one socket (write mutex
  serializes emission) — the standard WS pattern.
- **WSS** — over `cajeta.io.net.tls` via `wss://`.
- **Planned** — `permessage-deflate` (RFC 7692), one-line `connect` convenience,
  Autobahn conformance.

A richer server handler surface (`WebSocketHandler` with `onConnect`/`onMessage`/
`onClose` lifecycle, `WebSocketConnection` send/close API) layers over the core.

---

## Server-Sent Events (planned)

Server-to-client push without WebSocket's bidirectional complexity.

```cajeta
public final class SseEvent { public String id; public String eventName; public String data; public Duration retry; }
public final class SseResponse {
    public static SseResponse stream(Iterable<SseEvent> events);
    public static SseResponse channel(Channel<SseEvent> ch);     // fiber-pushed
}
public final class SseClient { public Iterable<SseEvent> subscribe(Url url); }
```

---

## TLS

Consumed from the stdlib — `cajeta.io.net.tls.TlsStream` (bundled BoringSSL, one
code path on all OSes, TLS 1.3 + ALPN, memory-BIO integration with the reactor).
HTTP/HTTPS and WSS use it for termination (server) and verification (client); ALPN
selects `http/1.1` / `h2`. This library does **not** redefine TLS.

## Error model

`dev.cajeta.http` HTTP/WS exceptions extend `cajeta.io.net.NetException` (itself a
`cajeta.error.RecoverableException`): `MalformedMessage`, `HeadersTooLarge`,
`InvalidChunkEncoding`, `UnexpectedEof` (HTTP); `HandshakeRejected`,
`ProtocolViolation`, `MessageTooLarge`, `ConnectionClosed` (WS, carrying the close
code). Transport/TLS/DNS errors propagate from `cajeta.io.net` unchanged.

---

## Implementation sequence

Phase 0 extraction → Phase 1 HTTP/1.1 core (types, body, h1, client, server,
routing) → Phase 2 middleware → Phase 3 HTTP/2 → Phase 4 WebSocket completeness +
SSE → Phase 5 HTTP/3. See [`plan/http-plan.md`](../plan/http-plan.md). The gating
step is a correct HTTP/1.1 wire codec; client/server are straightforward over it,
and HTTP/2 lifts the wire protocol without changing the surface above.

## Open questions

- **HTTP/2 server push** — include with a "deprecated upstream" note (some
  non-browser clients still use it), or omit? Lean: include.
- ~~**Streaming body lifecycle**~~ — **decided** (1.3 breakdown, 2026-07-19):
  implicit drain on handler return, with an opt-out for handlers that take
  ownership of the body (proxies). Lands with `http:1.3e`.
- ~~**Body-size enforcement timing**~~ — **decided** (1.3 breakdown,
  2026-07-19): reject early — 413 at parse time, before the handler runs —
  with global + per-route thresholds. Lands with `http:1.3e`.
- **Routing trie vs regex** — trie with `*`/`**` wildcards covers ~95% without
  regex complexity. Lean: trie.
- **Client cookie jar** — off by default; explicit `CookieJar` opt-in (avoid the
  "why is my client sending cookies" surprise).
- **WebSocket `permessage-deflate` default** — on, matching browsers.

(TLS choice is settled: the stdlib's bundled BoringSSL — not a per-library decision.)
