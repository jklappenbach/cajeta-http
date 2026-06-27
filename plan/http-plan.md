# cajeta-http roadmap

cajeta-http is the HTTP/WebSocket/SSE library over the stdlib `cajeta.io.net`
transport. Spec: [`docs/http-spec.md`](../docs/http-spec.md). The HTTP/1.1 +
WebSocket core already exists in the stdlib (`cajeta/docs/Net.md`,
`runtime/src/cajeta/io/net/http/` + `.../ws/`) and is being **extracted** into
this library; the HTTP/2, middleware, and SSE surface is new design layered on top.

## Phase 0 — Extraction (from stdlib into this library)

- Move the shipped HTTP/1.1 client + server + router and the RFC 6455 WebSocket
  out of the `cajeta.io.net.http` / `cajeta.io.net.ws` stdlib roots into
  `dev.cajeta.http` / `dev.cajeta.http.ws` here.
- Re-target onto the stdlib transport API (`cajeta.io.net` sockets + reactor +
  `cajeta.io.net.tls`); HTTP consumes TLS, does not own it.
- Server execution model comes from `cajeta.io.net`'s accept models
  (fiber-per-connection / shared-pool) — handlers are **un-colored**; no
  HTTP-specific reactor.

## Phase 1 — HTTP/1.1 core (parity with the shipped reality)

- Core types: `Method`, `Status`, `Headers`, `Url`, `MediaType`, `Version`.
- `Body` abstraction: in-memory + streaming, chunked, multipart.
- Incremental HTTP/1.1 parser/serializer; keep-alive; hard limits.
- `HttpClient`: single exchange → connection pool, redirects, retry, timeouts,
  streaming bodies, `getJson<T>`, transparent gzip/deflate.
- `HttpServer` + `Router` (typed path params) over both accept models.

## Phase 2 — Middleware

- Composable middleware: RequestId, Logging, Recover, Timeout, CORS,
  Compression/Decompression, RateLimit, BasicAuth, BearerAuth, StaticFile, ETag,
  ProxyHeaders. Registration-order composition.

## Phase 3 — HTTP/2

- HPACK, frame framing (zero-copy via `view`), stream multiplexing, flow control,
  ALPN negotiation, h2c upgrade, opt-in server push. Plugs in behind the same
  client/server surface.

## Phase 4 — WebSocket completeness + SSE

- WebSocket: `permessage-deflate` (RFC 7692); one-line `connect`/upgrade
  convenience; Autobahn conformance.
- Server-Sent Events (text/event-stream) server + client.

## Phase 5 — HTTP/3 (deferred)

- HTTP/3 over QUIC over UDP — gated on a QUIC state machine over `cajeta.io.net`
  UDP sockets. Designed-for in the transport abstraction; not in the near term.

## Out of scope (other layers own these)

- Transport (sockets, reactor, TLS, URI) — stdlib `cajeta.io.net`.
- REST endpoints, annotation routing, auto-serde-to-object — **primavera**.
- gRPC — a separate library over HTTP/2.
