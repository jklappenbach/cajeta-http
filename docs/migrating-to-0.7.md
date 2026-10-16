# Migrating from cajeta-http 0.6 to 0.7

cajeta-http 0.7 changes how a server assigns fibers. The default is now
request dispatch: framer fibers, one per carrier, read every socket and hold a
connection until it carries a complete unit of work; only then does a pooled
fiber run your handler. An idle connection costs no fiber, so a server holds
tens of thousands of mostly idle connections with a few hundred fibers. The
handler signature, `HttpRequest`, `HttpResponse`, `WebSocketHandler`,
`Takeover` and the routing and middleware layers are unchanged. Most servers
need no source change.

## What to know first

- **No model call means the pool.** A builder with no model call runs the
  request-dispatch pool with `maxInFlight` 256 units in flight,
  `maxPendingUnits` 4 complete units held per connection before the framer
  stops reading its socket, and one framer per carrier (`Carriers.count()`).
  `HttpServer` reports these through `maxInFlight()`, `maxPendingUnits()`,
  `framerCount()`, and the live counters `dispatches()`, `inFlight()`,
  `idleConnections()` and `pausedSockets()`.
- **`sharedPool(n)` is gone.** It meant `n` workers each owning a whole
  connection, keep-alive idle time included. A build that called it no longer
  compiles. The nearest setting is `maxInFlight(n)`, which bounds the units a
  pool runs at once; connections are not what it counts. The stdlib
  `ServerModel.sharedPool(n)` is likewise refused: `build()` raises, and the
  message names `maxInFlight`.
- **`fiberPerConnection()` keeps 0.6 exactly.** One fiber per accepted
  socket, the connection's own loop, h2 spawning per stream, `WsUpgrade.run`
  on the connection fiber. Use it for a small number of long, busy connections,
  or to rule the new model out while chasing a difference.
- **A handler sees the same things.** A held body is read from memory without
  parking. Writes park on the socket as before. A handler that calls out parks
  inside the client, and the carrier runs other fibers meanwhile. `await` is
  unchanged and is for fan-out only.

## Units of work

| Protocol | The unit | Where the hold point is |
|---|---|---|
| HTTP/1.1 | one request: head and held body | end of the body, or head complete with streaming on |
| HTTP/2 | one stream at END_STREAM | streams on one connection run in parallel by default; `serializedStreams(true)` runs one at a time |
| WebSocket | one complete message | after fragment reassembly, under `wsMaxMessageLength` (default 64 MiB) |
| multipart, `PART` mode | one completed part | after that part's closing boundary |
| a developer `Protocol` | one unit the `Framer` reports | when `unit` returns its length |

Units from one connection run in order on one fiber at a time. The framer
answers WebSocket pings, completes WebSocket close handshakes, sends h2
control frames and refuses oversized heads and bodies itself; none of that
takes a fiber.

## New surface

- `multipart(method, pattern, mode)` on the builder, with
  `MultipartMode.WHOLE` (the default for every route), `PART` (the handler runs
  once per completed part, with `q.multipartPart()`, `q.multipartIndex()` and
  `q.multipartLast()` set, and the response goes out after the last part) and
  `STREAM` (head complete is the hold point for that route alone, and the
  handler reads `q.bodyStream()`). `maxPartBytes(n)` caps a single part in
  `PART` mode; over it the request ends with 413. `PART` applies to
  length-framed bodies; a chunked multipart body on a `PART` route is held
  whole. Whole-mode bodies must still fit the pooled input buffer: a 3 MB form
  needs `bufferPool(heap BufferPool(4194304, n))`.
- `wsMaxMessageLength(bytes)` on the builder. A larger message closes the
  connection with 1009 on the framer; `onMessage` never sees it, and `onClose`
  runs on a final turn.
- `dev.cajeta.http.framing`: a `Framer` (`unit`, `kind`, `scanned`) and a
  `Protocol` that registers it with handlers by kind, a `maxUnit` cap and an
  `onClose`. A route upgrades into it with `r.status(101); r.upgrade(#p)`.
  `Protocol.overWebSocket(framer)` applies the same `Framer` to each binary
  WebSocket message, registered through `Protocol.webSocketHandler(#p)` as a
  route's `WebSocketHandler`. `HttpServer.protocolUnknownKinds()` and
  `framerBudgetOverruns()` count units with no handler and parser calls over
  the 1 ms budget (or a `Framer` whose reported scanning falls behind linear).
  `samples/wire` shows a protocol end to end.
- `r.upgrade(#takeover)` for any other takeover now owns its connection on
  its own fiber under the pool: the socket moves to that fiber, the worker is
  free at once, and the connection leaves the server's tables, so it is not
  counted among its connections.

## Things that behave differently

- A whole-mode body on the pool must fit the pooled input buffer, as a held
  body did in 0.6; the limit is unchanged, the model is not.
- Under the pool the first `onConnect` of a WebSocket runs on the upgrade
  request's turn, before the framer takes the connection.
- A server stopping drops an idle WebSocket connection without a close frame
  or `onClose` under the pool, as it dropped an idle keep-alive connection
  before; a 1001 close on shutdown is noted for a later release.
- The multipart modes are applied by the pool only. Under
  `fiberPerConnection()` every route is `WHOLE`.
