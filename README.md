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

## Status: v0.4.0

| Capability | State |
|---|---|
| HTTP/1.1 client, server, router and middleware | ✓ (`dev.cajeta.http`), loopback-tested |
| Request and response as views over pooled connection buffers | ✓ a keep-alive exchange allocates nothing after warm-up |
| Content-coding registry (gzip, deflate, identity, and any a dependency registers) | ✓ (`dev.cajeta.http.coding`) |
| WebSocket (RFC 6455) client + server | ✓ (`dev.cajeta.http.ws`): close handshake, ping/pong, permessage-deflate |
| HTTP/2 (HPACK, multiplexing, flow control) | ✓ (`dev.cajeta.http.h2`), ALPN and prior-knowledge client + server |
| Server-Sent Events | ✓ (`dev.cajeta.http.sse`) client + server |
| HTTP/3 over QUIC (UDP) | not planned for this line — requires QUIC in `cajeta.io.net`; intentionally not advertised |

v0.4.0 replaces the owned message model with views. On the server,
`HttpRequest` is a view over the request head in the connection's input
buffer, and `HttpResponse` writes straight into its output buffer. Both
buffers come from a pool and are reused, so a keep-alive exchange allocates
nothing, measured by the suite on the server, on the client and through a
routed handler with path parameters. The client has its own pair,
`ClientRequest` and `ClientResponse`. Content codings are a registry of
`cajeta.wire` compressors, request bodies can stream, and a middleware owns
its configuration.

The upgrade is a breaking change. [`docs/migrating-to-0.4.md`](docs/migrating-to-0.4.md)
maps every removed member to its replacement, and [`docs/guide.md`](docs/guide.md)
explains the model. v0.4.0 needs cajeta v0.32.0 or later, the release that
extends the `cajeta.wire` compression interfaces.

v0.5.0 republishes on cajeta v0.35.0, which enforces the field-store rule.
The WebSocket `forServer` and `forClient` factories and
`SseByteChannel.overChannel` now take `^T` parameters, so they borrow their
transport or channel and refuse an owned temporary. Media type parameters
and captured log lines keep their strings when their arrays grow.

v0.5.1 republishes 0.5.0 unchanged on cajeta v0.36.0 and codec 0.8.5.
v0.5.2 republishes it unchanged on cajeta v0.38.0 and codec 0.8.6.
v0.5.3 republishes it unchanged on cajeta v0.39.0 and codec 0.8.7.

Earlier releases: v0.3.0 made long HTTP/2 connections flat (receive-window
credit returns, per-request state is reclaimed) and v0.3.1 republished it on
the v0.29.0 toolchain.

See [`docs/http-spec.md`](docs/http-spec.md) for the design and
[`samples/tour`](samples/tour) for a runnable, self-checking walkthrough.

## Build & test

Requires the Cajeta toolchain on `PATH`:

```
cajeta build    # compile to a .cja library archive
cajeta test     # build + run unit tests
```

`scripts/ci-checks.sh` runs the full CI chain: the suite, the self-checking
tour, and the gate that every public type appears in the tour.

## License

Apache-2.0.
