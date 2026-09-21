# cajeta-http

HTTP/1.1 · HTTP/2, WebSocket, and Server-Sent Events — client and server —
for [Cajeta](https://github.com/jklappenbach/cajeta), built **on** the stdlib
transport layer `cajeta.io.net`. (HTTP/3 is out of scope until the stdlib
ships QUIC — see Status.)

> **Why a library, not stdlib?** HTTP is an *application* protocol, not transport.
> HTTP/1.1 and HTTP/2 ride TCP; **HTTP/3 rides QUIC over UDP** — so HTTP sits
> *above* the transport layer and picks one. The language stdlib ships the
> transport substrate (`cajeta.io.net`: sockets, the cross-platform reactor, TLS);
> HTTP ships here as an opt-in library, the way Rust keeps `std::net` but leaves
> HTTP to crates. A program that only speaks raw TCP or UDP multicast never pulls
> HTTP in.

## Layering

```
primavera          — REST/web policy: @Rest endpoints, routing-by-annotation, auto-serde
   └─ cajeta-http  — HTTP/1.1·2, WebSocket, SSE; client + server     ← this repo
        └─ cajeta.io.net (stdlib)  — sockets, TCP/UDP/multicast, reactor, TLS, URI
```

cajeta-http provides the **imperative HTTP engine** (`HttpClient`, `HttpServer`,
`Router`, `WebSocket`). Annotation-driven endpoints and automatic
serialization-to-object-model are **primavera's** job, layered on top.

## Status — v0.3.1

| Capability | State |
|---|---|
| HTTP/1.1 message model, wire codec, client, server, router | ✓ (`dev.cajeta.http`), loopback-tested |
| WebSocket (RFC 6455) client + server | ✓ (`dev.cajeta.http.ws`): close handshake, ping/pong, permessage-deflate |
| HTTP/2 (HPACK, multiplexing, flow control) | ✓ (`dev.cajeta.http.h2`), prior-knowledge client + server |
| Middleware (logging, CORS, auth, compression, rate-limit, …) | ✓ (`dev.cajeta.http.middleware`) |
| Server-Sent Events | ✓ (`dev.cajeta.http.sse`) client + server |
| HTTP/3 over QUIC (UDP) | not planned for this line — requires QUIC in `cajeta.io.net`; intentionally not advertised |

v0.3.0 was the long-connection release. HTTP/2 returns receive-window credit, so
a transfer is no longer capped at one window per round trip. Request bodies are
capped on h2 as h1 already capped them. Per-request state is reclaimed, so a
connection can serve without growing. HTTPS reads honour their deadline.

v0.3.1 changes no library behaviour. It moves the toolchain pin to v0.29.0 and
republishes from it, which closes the one gap v0.3.0 had to name. Reclaiming the
Task behind each request's handler fiber is a runtime fix, and it landed in
cajeta after v0.28.0. Measured over 3000 streams on one connection, the server's
live-object count climbs by one per request on v0.28.0 and stays flat on
v0.29.0. Because the fix is in the runtime, a consumer building against v0.3.0
on a v0.29.0 toolchain already has it.

See [`docs/http-spec.md`](docs/http-spec.md) for the design,
[`plan/http-plan.md`](plan/http-plan.md) for the build order, and
[`samples/tour`](samples/tour) for a runnable, self-checking walkthrough.

## Build & test

Requires the Cajeta toolchain on `PATH`:

```
cajeta build    # compile to a .cja library archive
cajeta test     # build + run unit tests
```

## License

Apache-2.0.
