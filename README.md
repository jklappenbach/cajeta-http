# cajeta-http

HTTP/1.1 · HTTP/2 · HTTP/3, WebSocket, and Server-Sent Events — client and
server — for [Cajeta](https://github.com/jklappenbach/cajeta), built **on** the
stdlib transport layer `cajeta.io.net`.

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
   └─ cajeta-http  — HTTP/1.1·2·3, WebSocket, SSE; client + server   ← this repo
        └─ cajeta.io.net (stdlib)  — sockets, TCP/UDP/multicast, reactor, TLS, URI
```

cajeta-http provides the **imperative HTTP engine** (`HttpClient`, `HttpServer`,
`Router`, `WebSocket`). Annotation-driven endpoints and automatic
serialization-to-object-model are **primavera's** job, layered on top.

## Status — v0.1.0 (early)

| Capability | State |
|---|---|
| HTTP/1.1 message model, client, server, router | ◻ porting from the stdlib `Net.md` reality |
| WebSocket (RFC 6455) client + server | ◻ porting |
| HTTP/2 (HPACK, multiplexing, flow control) | ▢ planned |
| Middleware (logging, CORS, auth, compression, rate-limit, …) | ▢ planned |
| Server-Sent Events | ▢ planned |
| HTTP/3 over QUIC (UDP) | ▢ deferred (needs QUIC) |

See [`docs/http-spec.md`](docs/http-spec.md) for the design and
[`plan/http-plan.md`](plan/http-plan.md) for the build order.

## Build & test

Requires the Cajeta toolchain on `PATH`:

```
cajeta build    # compile to a .cja library archive
cajeta test     # build + run unit tests
```

## License

Apache-2.0.
