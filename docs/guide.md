# cajeta-http guide

This guide covers cajeta-http 0.4. Coming from 0.3, read
[migrating-to-0.4.md](migrating-to-0.4.md) for the member-by-member mapping.
[`samples/tour`](../samples/tour) runs every feature below as a self-checking
program.

## A handler is a request view and a response writer

A server runs one function for every request.

```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.server.HttpServer;
import dev.cajeta.http.server.HttpServerBuilder;

public class HelloServer {
    static void handle(HttpRequest q, HttpResponse r) {
        r.header("Content-Type", "text/plain");
        r.body("hello");
    }

    public static void serve(String addr) {
        HttpServerBuilder b #= HttpServer.builder();
        b.bind(addr);
        b.handler((HttpRequest q, HttpResponse r) -> HelloServer.handle(q, r));
        HttpServer srv #= b.build();
        srv.serve();
    }
}
```

The request and the response belong to the connection. The server makes them
once and resets them between requests, so a keep-alive connection reuses both.

**The request is a view.** Its head is parsed in place in the connection's input
buffer. `q.method()` and `q.version()` are enums. `q.path()`, `q.header(name)`,
`q.param(name)` and `q.body()` return `Slice<int8>` windows into that buffer,
and reading them copies nothing. A window is valid until the handler returns.
When a value must outlive the request, ask for a copy: `q.headerString(name)`,
`q.paramString(name)`, `q.pathString()`, or `Bytes.copyOf(q.body())`. Typed
reads convert without allocating: `q.paramInt64(name, fallback)`,
`q.paramBool(name, fallback)`, `q.contentLength()`. `q.contentType()` parses
`Content-Type` into a `MediaType`.

**The response is a writer.** `r.status(code)`, `r.header(name, value)`,
`r.body(text)`, `r.bodyBytes(window)` and `r.write(text)` copy straight into the
connection's output buffer. The head is written in front of the body when the
handler returns, so a response that fits is one write. A handler that sets no
status answers 200. `r.body(#b)` streams a `Body` after the handler returns,
and the body's media type becomes `Content-Type` unless one was set.

**A status is thrown.** A handler that throws one of the
`dev.cajeta.http.status` exceptions (`NotFoundException`,
`TooManyRequestsException`, and the rest of the 39) answers that status with
no body. Whatever the handler had written is discarded, so a detail in the
message never reaches the client. Any other exception answers 500.

## Buffers

Each connection takes one input and one output buffer from the server's pool
when it opens and returns them when it closes. The default buffers are 64 KiB
(`HttpServer.DEFAULT_BUFFER_BYTES`). `HttpServerBuilder.bufferPool(#pool)`
supplies a pool of another size.

The input buffer bounds a request head and a held body. A body that does not
fit is answered 413, unless the server streams request bodies:

```
ServerLimits limits #= ServerLimits.of(30000, 60000, (int64) 0, true);
limits.streamRequestBody = true;
```

With `streamRequestBody` on, `q.bodyStreamed()` is true for every request that
has a body, and `q.bodyStream().reader()` decodes it off the connection as the
handler reads. An upload of any size is served through the same buffer.
Whatever the handler leaves unread is skipped, up to 256 KiB, so the next
request on the connection is framed correctly. Past that the connection closes.

The output buffer bounds nothing. A response that outgrows it is flushed in
pieces of the buffer's size, framed by `Content-Length` when the handler set
one and chunked otherwise. Set the status and headers before writing a large
body, since the head goes out with the first piece.

## The allocation invariant

After warm-up, a keep-alive exchange allocates nothing, on the server and on the
client. The suite holds this with `Cajeta.allocatedBytes()`: 200 loopback
keep-alive exchanges allocate 0 bytes, client and server together.

A handler keeps the invariant when it reads through windows and typed
accessors and writes through the response writer. These allocate, and are
fine when a value must be kept:

- The copying accessors (`headerString`, `paramString`, `pathString`,
  `contentType`, `Bytes.copyOf`).
- Building a `String` by concatenation.
- A lambda created per request. Build routers and middleware chains once, at
  startup.

## Routing and middleware

A `Router` maps a method and a pattern to a handler.

```
router.route("GET", "/orders/{id:int64}", (HttpRequest q, HttpResponse r) -> Orders.get(q, r));
router.dispatch(q, r);
```

Patterns take literal segments, `{name}`, typed parameters (`{id:int64}`,
`int32`, `int8`, `uint32`, `bool`, `string`), `{w:*}` for one segment and
`{rest:**}` for the rest of the path. A literal beats a parameter, which beats
`*`, which beats `**`. An unknown path is 404, a known path with the wrong
method is 405 with `Allow`, and a body over a `routeLimited` cap is 413.
`Route.patternError(pattern)` checks a pattern before registration. `mount`
places a sub-router under a prefix.

A middleware is a function of the request, the response and the next step. A
chain is built once around its handler and run per request:

```
MiddlewareChain chain = heap MiddlewareChain();
chain.use(#Recover.middleware()).use(#RequestId.middleware());
chain.build(handler);
(HttpRequest, HttpResponse) -> void app = (HttpRequest q, HttpResponse r) -> chain.run(q, r);
```

`routeMw(method, pattern, #chain, handler)` gives one route its own chain.

## The client

A request is a `ClientRequest` and the answer a `ClientResponse`.

```
HttpClient client = heap HttpClient();
ClientRequest req #= ClientRequest.post("https://api.example/orders");
req.header("Content-Type", "application/json");
req.body("{\"qty\":2}");
ClientResponse resp #= client.send(req);
String answer #= resp.bodyString();
```

`send` makes one exchange. `get` and `sendFollowing` follow redirects up to the
client's limit. The response owns the bytes it was read into, and its
`header(name)` and `body()` windows stay valid until it is reused or closed.

To keep the allocation invariant, reuse one request and one response:
`client.send(req, resp)` fills `resp` in place.

## Content codings

A content coding is a `cajeta.wire.Compressor` and `Decompressor` registered
under a token in `ContentCodings`. gzip (with its alias `x-gzip`), deflate and
identity are built in. Everything that encodes or decodes a body looks the
coding up there: `Accept-Encoding` negotiation, the Compression and
Decompression middleware, the client's transparent decoding, and
`ContentCoding.encode` and `decode`.

A dependency adds a coding before a server or client uses it:

```
ContentCodings.register("br", heap Brotli(), heap Brotli());
```

From then on `Accept-Encoding: br` can select it, a `Content-Encoding: br`
upload is decoded, and a 415 for an unknown coding names it in
`Accept-Encoding`. On a tie in quality, the coding registered first wins, so
gzip beats deflate.

Decoding always takes a cap. `Decompressor.decompress(src, len, maxOut)` raises
`DecompressionLimitException` rather than produce more than `maxOut` bytes,
which is the guard against a small body that expands without bound. The
Decompression middleware answers that with 413.

The Compression middleware encodes a held body only when it shrinks, and
otherwise sends it as it is. A streamed body is wrapped in a `CodedBody`,
which compresses each piece through the coding's `CompressStream` and flushes
it, so a live stream still reaches the client as it is produced.

## Limits

`ServerLimits` bounds what a server reads before and while a handler runs.

| Field | Meaning |
|---|---|
| `headReadTimeoutMs` | From a request's first byte to the end of its head. Past it, 408. |
| `bodyReadTimeoutMs` | How long each body read may wait. Past it, 408. |
| `maxBodyBytes` | A larger declared body is 413 before it is read. A chunked body is cut with 413 once it crosses. `0` disables the cap. |
| `expectContinueEnabled` | Answers `Expect: 100-continue` with 100, or 413 when the declared length is over the cap. |
| `maxHeadBytes`, `maxLineBytes`, `maxHeaderCount` | Head caps. Over any of them is 431. |
| `streamRequestBody` | Streams HTTP/1.1 request bodies to the handler. |

`HttpServerBuilder.connectionLimits(#limits)` bounds concurrent connections,
refusing or queueing the surplus. `shutdown(deadline)` stops accepting and
waits for open connections until the deadline.

## HTTP/2, WebSocket and server-sent events

The same handler serves HTTP/2. Over TLS, ALPN picks h2 or HTTP/1.1. On a
plaintext port, `HttpServerBuilder.h2PriorKnowledge()` serves a connection that
opens with the h2 preface as h2.

A route upgrades to WebSocket with `WsUpgrade.accept(q, r, handler, deflate)`.
After the 101 the connection belongs to the handler. `r.upgrade(#takeover)` is
the general form, for any protocol behind a 101.

`SseResponse.stream(r, #events, n)` answers with a fixed batch of events, and
`SseResponse.channel(r, channel)` streams what a producer sends.
`SseClient.subscribe` reconnects with `Last-Event-ID`.
