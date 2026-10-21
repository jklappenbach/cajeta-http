# cajeta-http

HTTP/1.1 · HTTP/2, WebSocket, and Server-Sent Events — client and server —
for [Cajeta](https://github.com/jklappenbach/cajeta), built **on** the stdlib
transport layer `cajeta.io.net`. (HTTP/3 is out of scope until the stdlib
ships QUIC — see Status.)

> **Why a library, not stdlib?** HTTP is an *application* protocol, not transport.
> HTTP/1.1 and HTTP/2 ride TCP; **HTTP/3 rides QUIC over UDP** — so HTTP sits
> *above* the transport layer and picks one. The language stdlib ships the
> transport substrate (`cajeta.io.net`: sockets and the cross-platform reactor);
> HTTP ships here as an opt-in library, the way Rust keeps `std::net` but leaves
> HTTP to crates. A program that only speaks raw TCP or UDP multicast never pulls
> HTTP in.

## Layering

```
primavera          — REST/web policy: @Rest endpoints, routing-by-annotation, auto-serde
   └─ cajeta-http  — HTTP/1.1·2, WebSocket, SSE; client + server     ← this repo
        ├─ dev.cajeta.crypto       — TLS, SHA-1 and SHA-256 (used here since 0.9.0)
        └─ cajeta.io.net (stdlib)  — sockets, TCP/UDP/multicast, reactor, URI
```

cajeta-http provides the **imperative HTTP engine** (`HttpClient`, `HttpServer`,
`Router`, `WebSocket`). Annotation-driven endpoints and automatic
serialization-to-object-model are **primavera's** job, layered on top.

## Status: v0.9.1

0.9.1 fixes a server-side WebSocket crash: a `close` parked behind a sender on a peer that had
stopped reading resumed after `abort` on a socket the serve loop had already dropped (cajeta
open-defects D-19). The serve loop now ends the transport and waits for every fiber inside a
send or close before `onClose` runs, and a write that resumes after an abort raises
`ConnectionClosedException` with the abort's code. A shutdown may say `close` then `abort` from
two fibers; from one fiber the `close` parks until the peer reads, as any send does.

0.9.0 takes TLS and its digests from `dev.cajeta.crypto` 0.1.0 rather than the stdlib, which is
removing `cajeta.io.net.tls` and the `cajeta.hash` cryptographic types. Nothing in this library's
API changes. A caller that imports `TlsStream` itself changes `cajeta.io.net.tls` to
`dev.cajeta.crypto.tls`, and `cajeta.hash.Sha256` to `dev.cajeta.crypto.Sha256`.

| Capability | State |
|---|---|
| HTTP/1.1 client, server, router and middleware | ✓ (`dev.cajeta.http`), loopback-tested |
| Request dispatch: framers hold a connection until it carries a complete unit, pooled fibers run handlers | ✓ the default server model since 0.7.0; `fiberPerConnection()` keeps a fiber per connection |
| Developer framing over an upgraded connection | ✓ (`dev.cajeta.http.framing`): `Framer`, `Protocol`, handlers by kind, a per-call budget |
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

v0.6.0 makes a warm WebSocket connection allocate nothing per message. A
handler's `WsMessage` is lent for the call and reused: `bytes()` and
`length()` read it in place, and a handler that keeps a message copies it out
with `text()` or `getPayload()`. That is the breaking change. Also new:
`WebSocket.next()`, `sendText` and `sendBinary` over a byte range, `abort(code)`
for a peer that has stopped reading, and `HttpServer.idleBuffers()`.
`WsUpgrade.accept(q, r, #h, ...)` hands a per-connection handler to its
connection, which frees it at close; before, it was freed when `accept`
returned.

v0.8.0 gives an HTTP/2 stream's request body the same three modes an
HTTP/1.1 request has, under both server models. With `streamRequestBody` on,
or on a STREAM multipart route, the handler starts at end of HEADERS and reads
the body through `bodyStream()` as it arrives, in the memory of one pooled slab
whose size is the stream's flow-control window, so a slow handler slows only
its own stream (2 GB on one stream allocated 1.9 MB in the process; 50
concurrent 40 MB uploads cost 2.8 MB beyond their slabs). A PART route runs
the handler once per completed part. Trailers end a body; a body that misses
its content-length resets the stream; a handler that returns early has the
stream drained up to 256 KB, then reset after its response. A held stream's
trailers no longer fail the connection. The server now advertises the default
65,535-byte initial stream window and raises it per stream at head complete.
`HttpServer.streamedDispatches()` counts units dispatched at head complete.
Behavior change: a server with `streamRequestBody` on now dispatches h2
handlers at head complete rather than at END_STREAM, as that flag always
meant for HTTP/1.1.

v0.7.2 fixes a 0.7.0 WebSocket regression: a message that arrives just
before a protocol violation is delivered to `onMessage` before the 1002
close; 0.7.0 dropped it (Autobahn now matches 0.6.0 case for case). It also
carries the first two units of h2 streaming request bodies, ahead of their
0.8.0 release: with `streamRequestBody` on, or on a STREAM multipart route,
an h2 stream's handler now starts at end of HEADERS and reads the body as it
arrives in the memory of one slab, with the stream's flow-control window as
the back-pressure. Servers without either setting see no change beyond one
WINDOW_UPDATE per stream with a body.

v0.7.1 makes the per-route multipart modes hold under `fiberPerConnection()`
as they do under the pool: a PART route runs the handler per completed part
and a STREAM route hands the body over at head complete on the connection
loop too (request-dispatch §4.6, amended). It also fixes a PART-mode hole in
both models: a read that ended between the final `--boundary` and its
closing `--` ran the last part with `multipartLast()` false and never sent
the response; a counted part now waits until it is known to be last. h2
streams still take every route as whole; that is cajeta-http 0.8.0's work.

v0.7.0 changes how a server assigns fibers. Request dispatch is the default:
framer fibers, one per carrier, read every socket and hold a connection until
it carries a complete unit of work (an HTTP/1.1 request, an h2 stream, a
WebSocket message, a multipart part), and only then does a pooled fiber run
the handler, so an idle connection costs no fiber. `sharedPool(n)` is gone;
`maxInFlight(n)` bounds the work in flight and `fiberPerConnection()` keeps
the old model. New: `multipart(method, pattern, mode)`, `wsMaxMessageLength`,
`maxPartBytes`, and the `dev.cajeta.http.framing` package (`Framer`,
`Protocol`) for developer-framed streams over an upgraded connection. The
handler, request, response and WebSocket surfaces are unchanged; see
`docs/migrating-to-0.7.md`. Built on cajeta v0.43.0, which carries the stdlib
reads the framers need.

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
