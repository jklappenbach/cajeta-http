# Migrating from cajeta-http 0.3 to 0.4

cajeta-http 0.4 replaces the owned message model of 0.3 with a view model.
On the server, `HttpRequest` is a view over the request head in the
connection's input buffer, and `HttpResponse` writes straight into the
connection's output buffer. Both buffers come from a pool and are reused, so a
keep-alive exchange allocates nothing. The client has its own pair of types,
`ClientRequest` and `ClientResponse`. Most changes are mechanical. A handler
now receives the response as a parameter instead of returning one.

## What to know first

- **Windows live as long as the exchange.** `q.header(name)`, `q.path()`,
  `q.param(name)` and `q.body()` return `Slice<int8>` windows into the
  connection's buffer. They are valid until the handler returns. Copy a value
  that must outlive the exchange with `headerString`, `paramString`,
  `pathString`, `Bytes.toString` or `Bytes.copyOf`. A `ClientResponse` window
  is valid until the response is reused or closed.
- **A held request body must fit in the input buffer.** The default buffer is
  64 KiB (`HttpServer.DEFAULT_BUFFER_BYTES`). A larger body is answered 413.
  Turn on `ServerLimits.streamRequestBody` to read large uploads through
  `q.bodyStream()`, or give the server a larger pool with
  `HttpServerBuilder.bufferPool`.
- **The head is sent at the first flush.** The response head is composed when
  the handler returns. A body that outgrows the output buffer is flushed in
  pieces, as chunks unless the handler set `Content-Length`. Set the status and
  headers before writing a large body.
- **Throw a status.** A handler that throws one of the
  `dev.cajeta.http.status.*Exception` classes gets that status with an empty
  body. Anything the handler already wrote is discarded. Any other exception
  is a 500.
- **`ServerLimits.requestBudgetMs` is gone.** Use the per-phase read deadlines
  `headReadTimeoutMs` and `bodyReadTimeoutMs`, and `Timeout.middleware` for a
  handler budget. `bodyReadTimeoutMs` is now an idle timer that restarts on
  each read.
- **`HttpRequest` and `HttpResponse` are `final`.** Code that subclassed them
  needs a wrapper or a middleware instead.

## Before and after

The 0.3 blocks are shown for comparison and use the old API.

### A handler, routed and served

0.3:

<!-- snippet: skip -->
```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.routing.Router;
import dev.cajeta.http.server.HttpServer;
import dev.cajeta.http.server.HttpServerBuilder;

public class OrdersApp {
    public static #HttpResponse health(HttpRequest req) {
        return HttpResponse.of(204);
    }

    public static void serve(String addr) {
        Router router = heap Router();
        router.route("GET", "/health", (req) -> OrdersApp.health(req));
        (HttpRequest) -> #HttpResponse app = (req) -> router.dispatch(req);
        HttpServerBuilder b #= HttpServer.builder();
        b.bind(addr);
        b.handler(app);
        HttpServer srv #= b.build();
        srv.serve();
    }
}
```

0.4:

```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.routing.Router;
import dev.cajeta.http.server.HttpServer;
import dev.cajeta.http.server.HttpServerBuilder;

public class OrdersApp {
    public static void health(HttpRequest q, HttpResponse r) {
        r.status(204);
    }

    public static void serve(String addr) {
        Router router = heap Router();
        router.route("GET", "/health", (HttpRequest q, HttpResponse r) -> OrdersApp.health(q, r));
        (HttpRequest, HttpResponse) -> void app = (HttpRequest q, HttpResponse r) -> router.dispatch(q, r);
        HttpServerBuilder b #= HttpServer.builder();
        b.bind(addr);
        b.handler(app);
        HttpServer srv #= b.build();
        srv.serve();
    }
}
```

### A middleware

A 0.3 middleware took the request and the rest of the chain and returned a
response. A 0.4 middleware takes the request, the response and the rest of
the chain, and returns nothing. `compose` becomes `build` followed by `run`.
The chain keeps the composition, so running it allocates nothing. The handler
passed to `build` must outlive the chain.

0.3:

<!-- snippet: skip -->
```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.middleware.Middleware;
import dev.cajeta.http.middleware.MiddlewareChain;
import dev.cajeta.http.middleware.Recover;
import dev.cajeta.http.server.HttpServer;
import dev.cajeta.http.server.HttpServerBuilder;

public class Stamped {
    public static #Middleware stamp() {
        (HttpRequest, (HttpRequest) -> #HttpResponse) -> #HttpResponse f =
            (req, next) -> {
                HttpResponse resp #= next(req);
                resp.setHeader("X-Api-Status", "" + resp.statusCode());
                return #resp;
            };
        return Middleware.of(#f);
    }

    public static #HttpResponse hello(HttpRequest req) {
        String text = "hello";
        HttpResponse r #= HttpResponse.ok();
        r.body(text.toBytes(), text.byteLength());
        return #r;
    }

    public static void serve(String addr) {
        Middleware rec #= Recover.middleware();
        Middleware st #= Stamped.stamp();
        MiddlewareChain chain = heap MiddlewareChain();
        chain.use(#rec).use(#st);
        (HttpRequest) -> #HttpResponse handler = (req) -> Stamped.hello(req);
        (HttpRequest) -> #HttpResponse app #= chain.compose(handler);
        HttpServerBuilder b #= HttpServer.builder();
        b.bind(addr);
        b.handler(app);
        HttpServer srv #= b.build();
        srv.serve();
    }
}
```

0.4:

```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.middleware.Middleware;
import dev.cajeta.http.middleware.MiddlewareChain;
import dev.cajeta.http.middleware.Recover;
import dev.cajeta.http.server.HttpServer;
import dev.cajeta.http.server.HttpServerBuilder;

public class Stamped {
    public static #Middleware stamp() {
        return Middleware.of((HttpRequest q, HttpResponse r, (HttpRequest, HttpResponse) -> void next) -> {
            next(q, r);
            r.header("X-Api-Status", "" + r.status());
        });
    }

    public static void hello(HttpRequest q, HttpResponse r) {
        r.body("hello");
    }

    public static void serve(String addr) {
        (HttpRequest, HttpResponse) -> void handler = (HttpRequest q, HttpResponse r) -> Stamped.hello(q, r);
        MiddlewareChain chain = heap MiddlewareChain();
        chain.use(#Recover.middleware()).use(#Stamped.stamp());
        chain.build(handler);
        (HttpRequest, HttpResponse) -> void app = (HttpRequest q, HttpResponse r) -> chain.run(q, r);
        HttpServerBuilder b #= HttpServer.builder();
        b.bind(addr);
        b.handler(app);
        HttpServer srv #= b.build();
        srv.serve();
    }
}
```

### A client GET and POST

`HttpClient.send` takes a `ClientRequest`, which carries its own URL. `get`
and `sendFollowing` follow redirects, and `send` makes exactly one exchange.

0.3:

<!-- snippet: skip -->
```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.client.HttpClient;
import cajeta.io.net.uri.Uri;

public class OrdersClient {
    public static #String fetch(HttpClient client, String base) {
        HttpResponse r #= client.get(base + "/orders/7");
        int32 n = r.bodyLength();
        int8[] copy = heap int8[n];
        int32 i = 0;
        while (i < n) {
            copy[i] = r.body[i];
            i = i + 1;
        }
        return heap String(#copy, n);
    }

    public static int32 create(HttpClient client, String base) {
        Uri uri #= Uri.parse(base + "/orders");
        HttpRequest req #= HttpRequest.fromUri("POST", uri);
        String order = "{\"symbol\":\"ACME\",\"qty\":250}";
        req.setHeader("Content-Type", "application/json");
        req.body(order.toBytes(), order.byteLength());
        HttpResponse r #= client.send(uri, req);
        return r.statusCode();
    }
}
```

0.4:

```cajeta
import dev.cajeta.http.ClientRequest;
import dev.cajeta.http.ClientResponse;
import dev.cajeta.http.client.HttpClient;

public class OrdersClient {
    public static #String fetch(HttpClient client, String base) {
        ClientResponse resp #= client.get(base + "/orders/7");
        return resp.bodyString();
    }

    public static int32 create(HttpClient client, String base) {
        ClientRequest req #= ClientRequest.post(base + "/orders");
        req.header("Content-Type", "application/json");
        req.body("{\"symbol\":\"ACME\",\"qty\":250}");
        ClientResponse resp #= client.send(req);
        return resp.status();
    }
}
```

To reuse one response across calls, pass it to `send(req, resp)`. The client
returns the buffer the response held to its pool before filling it again.

### Reading a header

A header is a window. Test it in place with `Bytes`, `headerIs` or
`headerHasToken`, parse a number with `headerInt64`, and copy it with
`headerString` only when you keep it.

0.3:

<!-- snippet: skip -->
```cajeta
import dev.cajeta.http.HttpRequest;

public class RequestHeaders {
    public static boolean isJson(HttpRequest req) {
        String ct #= req.getHeaders().get("Content-Type");
        return ct != null && ct.startsWith("application/json");
    }

    public static #String traceId(HttpRequest req) {
        return req.getHeaders().get("X-Trace-Id");
    }
}
```

0.4:

```cajeta
import dev.cajeta.http.Bytes;
import dev.cajeta.http.HttpRequest;

public class RequestHeaders {
    public static boolean isJson(HttpRequest q) {
        return Bytes.startsWith(q.header("Content-Type"), "application/json");
    }

    public static #String traceId(HttpRequest q) {
        return q.headerString("X-Trace-Id");
    }

    public static int64 declaredLength(HttpRequest q) {
        return q.headerInt64("Content-Length", (int64) 0);
    }
}
```

`ClientResponse` has the same accessors: `header`, `hasHeader`,
`headerHasToken`, `headerInt64` and `headerString`.

### Reading a path parameter

Path parameters bind onto the request. `param` returns the raw window with
percent escapes intact. `paramString` returns a decoded copy.

0.3:

<!-- snippet: skip -->
```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;

public class OrderParams {
    public static #HttpResponse show(HttpRequest req) {
        int64 id = req.pathParamInt64("id", (int64) 0);
        String slug #= req.pathParam("slug");
        String text = slug + " " + id;
        HttpResponse r #= HttpResponse.ok();
        r.body(text.toBytes(), text.byteLength());
        return #r;
    }
}
```

0.4:

```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;

public class OrderParams {
    public static void show(HttpRequest q, HttpResponse r) {
        int64 id = q.paramInt64("id", (int64) 0);
        String slug #= q.paramString("slug");
        r.body(slug + " " + id);
    }
}
```

### Setting a status and body

`body(...)` replaces the body and `write(...)` appends to it. Both copy what
they are given into the output buffer.

0.3:

<!-- snippet: skip -->
```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;

public class OrderReply {
    public static #HttpResponse created(HttpRequest req) {
        String json = "{\"id\":7}";
        HttpResponse r #= HttpResponse.of(201);
        r.setHeader("Content-Type", "application/json");
        r.setHeader("Location", "/orders/7");
        r.body(json.toBytes(), json.byteLength());
        return #r;
    }

    public static #HttpResponse missing(HttpRequest req) {
        return HttpResponse.notFound();
    }
}
```

0.4:

```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.status.NotFoundException;

public class OrderReply {
    public static void created(HttpRequest q, HttpResponse r) {
        r.status(201);
        r.header("Content-Type", "application/json");
        r.header("Location", "/orders/7");
        r.body("{\"id\":7}");
    }

    public static void missing(HttpRequest q, HttpResponse r) {
        throw heap NotFoundException("no such order");
    }
}
```

`header` adds a field. `setHeader` replaces every field of that name.

### A streamed request body

0.3:

<!-- snippet: skip -->
```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.body.Body;
import cajeta.io.net.AsyncReader;

public class Ingest {
    public static #HttpResponse ingest(HttpRequest req) {
        Body b = req.getBody();
        if (b == null) {
            return HttpResponse.of(400);
        }
        AsyncReader rd = b.reader();
        int8[] buf = heap int8[16384];
        int64 total = 0;
        int32 got = rd.read(buf, 0, 16384);
        while (got > 0) {
            total = total + (int64) got;
            got = rd.read(buf, 0, 16384);
        }
        String text = "ingested " + total;
        HttpResponse r #= HttpResponse.ok();
        r.body(text.toBytes(), text.byteLength());
        return #r;
    }
}
```

0.4:

```cajeta
import dev.cajeta.http.HttpRequest;
import dev.cajeta.http.HttpResponse;
import dev.cajeta.http.server.HttpServer;
import dev.cajeta.http.server.HttpServerBuilder;
import dev.cajeta.http.server.ServerLimits;
import cajeta.io.net.AsyncReader;

public class Ingest {
    public static void ingest(HttpRequest q, HttpResponse r) {
        if (!q.bodyStreamed()) {
            r.status(400);
            return;
        }
        AsyncReader rd = q.bodyStream().reader();
        int8[] buf = heap int8[16384];
        int64 total = 0;
        int32 got = rd.read(buf, 0, 16384);
        while (got > 0) {
            total = total + (int64) got;
            got = rd.read(buf, 0, 16384);
        }
        r.body("ingested " + total);
    }

    public static void serve(String addr) {
        ServerLimits limits #= ServerLimits.of(5000, 5000, (int64) 0, true);
        limits.streamRequestBody = true;
        HttpServerBuilder b #= HttpServer.builder();
        b.bind(addr);
        b.handler((HttpRequest q, HttpResponse r) -> Ingest.ingest(q, r));
        b.serverLimits(#limits);
        HttpServer srv #= b.build();
        srv.serve();
    }
}
```

An unread streamed body is drained by the connection when the handler
returns, so the handler does not need to finish reading it.

### Testing a handler without a socket

0.3 tests called `HttpServer.handleRequestBytes(handler, bytes, n)`. In 0.4,
serve the request through a real `Http1Connection` over any `ByteChannel` that
plays the request bytes and captures what is written back:

```
Http1Connection conn = heap Http1Connection(ch, in, out, parseLimits,
    headMs, bodyMs, maxBody, expectEnabled, handler);
conn.serve();
```

`samples/tour/src/tour/http/Served.cajeta` is a complete example.

## Migration table

Every public member removed since 0.3, grouped by class. A handler type
written `Handler` below is `(HttpRequest, HttpResponse) -> void`, which
replaces `(HttpRequest) -> #HttpResponse` everywhere.

### dev.cajeta.http.HttpRequest

On the server, `HttpRequest` is a view the connection fills and reuses. An
outbound request is now a `ClientRequest`.

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `HttpRequest()` | `HttpRequest(int32 maxHeaders)`, filled by `HeadScanner.parseRequest`. Outbound: `ClientRequest` | The connection owns one request view and reuses it. |
| `of(method, target)`, `get(target)`, `post(target)` | `ClientRequest.of(method, url)`, `ClientRequest.get(url)`, `ClientRequest.post(url)` | Outbound requests have their own type and take an absolute URL. |
| `fromUri(method, uri)` | `ClientRequest.of(method, url)`, or `req.uri(uri)` on an existing request | Same. |
| `header(name, value)` | `ClientRequest.header(name, value)`. A received request keeps `setHeader(name, value)` | A received request is read, not built. |
| `body(int8[] data, int32 length)`, `body(#Body b)` | `ClientRequest.body(data, length)`, `ClientRequest.body(#b)`. A middleware that rewrites a received body uses `replaceBody(#data, length)` | Same. |
| `target(String t)` | `ClientRequest.url(url)` | The URL carries the target. |
| `version(String v)` | `ClientRequest.version(Version v)` | Versions are the `Version` enum. |
| `getMethod()`, `methodType()` | `method()` returns `Method`. Also `methodIs(token)` and `methodBytes()` | The method is parsed once into the enum. |
| `getTarget()` | `target()` window, `targetString()` copy, `path()`, `query()` | The target is a window into the head. |
| `getVersion()`, `versionType()` | `version()` returns `Version` | Same as the method. |
| `getHeaders()` | `header(name)`, `hasHeader(name)`, `headerString(name)`, `headers()` returns `HeaderTable` | Headers are windows, not a map of strings. |
| `pathParam(name)` | `paramString(name)` decoded copy, or `param(name)` raw window | Parameters bind onto the request as windows into the path. |
| `pathParamInt64`, `pathParamInt32`, `pathParamBool` | `paramInt64`, `paramInt32`, `paramBool` | Renamed with the other parameter accessors. |
| `bindPathParams(#PathParams)` | `bindParams`, `bindSegment`, `bindRest`, `bindEmpty`, called by `Route.bind` | No parameter map is allocated per request. |
| `getBody()` | `bodyStream()` for a streamed body, `body()` for a held one | The held body is a window. |
| `asBody()` | Removed. Wrap a copy: `BytesBody.of(Bytes.copyOf(q.body()), q.bodyLength())` | A `Body` owns its bytes and the held body is a window. |
| Fields `method`, `target`, `version`, `headers`, `body`, `hasBody`, `bodyModel`, `pathParams` | The accessors above, plus `hasBody()` and `bodyLength()` | The view stores offsets, not owned fields. |

### dev.cajeta.http.HttpResponse

On the server, `HttpResponse` is a writer the handler receives. A received
response is now a `ClientResponse`.

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `HttpResponse()` | `HttpResponse(ByteBuffer out, ByteChannel ch, int32 fieldBytes, int32 maxFields)`. The server passes one to every handler | The response writes into the connection's output buffer. |
| `of(status)`, `ok()`, `notFound()` | `r.status(n)`. The default is 200. For 404, `r.status(404)` or `throw heap NotFoundException()` | Handlers no longer return a response. |
| `reasonFor(status)` | `Status.reasonFor(code)` | Moved to `Status`. |
| `statusCode()` | `status()` | Same method name as the setter. |
| `statusType()` | `Status.of(r.status())` | The writer keeps only the code. |
| `isInformational()`, `isSuccess()`, `isRedirect()`, `isClientError()`, `isServerError()` | `Status.of(code).isInformational()` and so on, with `isRedirection()` for `isRedirect()`. Client: `ClientResponse.isSuccess()` | Same. |
| `reason(phrase)`, `getReason()` | Removed on the server. Client: `ClientResponse.reason()` | The server writes the standard phrase for the code. |
| `version(v)`, `getVersion()`, `versionType()` | Removed on the server. Client: `ClientResponse.version()` | The server writes `HTTP/1.1` and frames the body for the peer's version. |
| `getHeaders()` | `header(name)`, `hasHeader(name)`, `headerHasToken(name, token)`, `fieldCount()`, `fieldName(i)`, `fieldValue(i)`. Client: `ClientResponse.headers()` | Fields are stored as bytes in the writer. |
| `contentType()` | `r.header("Content-Type")`. Client: `ClientResponse.contentType()` | Same. |
| `contentLength()` | `bodyLength()`. Client: `resp.headerInt64("Content-Length", fallback)` | Same. |
| `getBody()` | `bodyStream()` | A held body is `body()`, a window. |
| `asBody()` | Removed. Client: `ClientResponse.body()` or `bodyString()` | A received body is read in place. |
| `pushPathAt(i)`, `pushStatusAt(i)`, `pushBodyAt(i)`, `pushBodyLenAt(i)` | `pushAt(i)` returns a `PushEntry` with `path`, `status`, `body` and `bodyLen` | One accessor per push. |
| Fields `version`, `status`, `reason`, `headers`, `body`, `hasBody`, `bodyModel`, `pushes` | `status()`, `body()`, `bodyLength()`, `bodyStream()`, `pushCount()`, `pushAt(i)` | The writer's state is private. |

### dev.cajeta.http.HeaderValues (type removed)

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `HeaderValues` | Removed | The views parse these headers themselves. |
| `contentType(Headers)` | `q.contentType()`, `ClientResponse.contentType()` | Same. |
| `contentLength(Headers)` | `q.contentLength()`, `resp.headerInt64("Content-Length", fallback)` | Same. |

### dev.cajeta.http.PathParams (type removed)

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `PathParams`, `PathParams()` | Removed. The request holds the parameters | Parameters are windows into the path. |
| `get(name)` | `q.paramString(name)` | Same. |
| `getInt32`, `getInt64`, `getBool` | `q.paramInt32`, `q.paramInt64`, `q.paramBool` | Same. |
| `contains(name)` | `q.hasParam(name)` | Same. |
| `size()` | `q.paramCount()` | Same. |
| `nameAt(i)`, `valueAt(i)` | Removed. Read parameters by name | There is no index accessor on the request. |
| `put(name, value)` | `Route.bind(q, pathLen)` | Routing binds windows and copies nothing. |
| `isKnownType(type)`, `matchesType(type, value)` | Removed. `Route.patternError(pattern)` rejects an unknown type | Type checks are private to `Route`. |

### dev.cajeta.http.body.Body

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `class Body` | `interface Body`. Implement `contentLength`, `contentType`, `reader`, `abort` and the new `live` | Every body type now implements the interface instead of extending a class. |
| `Body()` | Removed | An interface has no constructor. |

### dev.cajeta.http.client

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `HttpClient.get(url)` returning `#HttpResponse` | `get(url)` returning `#ClientResponse` | Received responses have their own type. |
| `HttpClient.send(Uri uri, HttpRequest req)` | `send(ClientRequest req)`, or `send(req, resp)` to fill an existing response | The request carries its URL. |
| `HttpClient.sendFollowing(Uri uri, HttpRequest req)` | `sendFollowing(ClientRequest req)`, or `sendFollowing(req, resp)` | Same. |
| `OriginEntry.of(key, maxPerOrigin)` | `OriginEntry.of(host, port, maxPerOrigin)` | The pool keys on host and port, not a joined string. |
| Field `OriginEntry.key` | Fields `host`, `port` | Same. |
| `PooledConnection.of(#stream, #originKey)` | `ConnectionPool.adopt(#stream, host, port)` | The pool builds the connection with its buffers. |
| Field `PooledConnection.originKey` | Fields `host`, `port`. The new `conn` field holds the `Http1ClientConnection` | Same. |

### dev.cajeta.http.h2

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `Http2Client.exchange(reader, writer, HttpRequest req, scheme, authority)` returning `#HttpResponse` | `exchange(reader, writer, ClientRequest req, ClientResponse resp, scheme, authority, ConnectionBuffers bufs)` fills `resp` | The response is read into a pooled buffer. |
| `Http2Connection.handleStream(ws, gate, h, sid, ...)` | `handleStream(Http2Connection c, #Http2StreamSlot slot, maxFrame, pushEnabled, initWin)` | Internal stream entry point, now slot based. |
| `Http2Connection(reader, writer, handler)` (signature change) | `Http2Connection(reader, writer, Handler, ConnectionBuffers bufs, HttpParserLimits limits)` | Streams take pooled buffers. |
| `Http2Connection.serve(reader, writer, handler)` and `serve(..., maxBodyBytes)` (signature change) | `serve(reader, writer, Handler, bufs, limits, maxBodyBytes)` | Same. |
| `Http2Requests.requestFields(HttpRequest req, scheme, authority)` | `requestFields(ClientRequest req, scheme, authority)` | Outbound requests are `ClientRequest`. |
| `Http2Requests.fromFields(fields)` | Removed. The connection decodes HEADERS into the request view with `HpackDecoder.decodeInto`, `fieldName(i)` and `fieldValue(i)` | Fields are decoded as windows. |
| `Http2Requests.responseFromFields(fields)` | Removed. `Http2Client.exchange` fills the `ClientResponse` | Same. |
| `Http2Requests.responseFields(resp)` | Removed. The stream writes the head from the `HttpResponse` | Same. |

### dev.cajeta.http.middleware

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| Field `Middleware.fn` | Same field, typed `(HttpRequest, HttpResponse, Handler) -> void` | Middleware writes into the response it is given. |
| `Middleware(fn)`, `Middleware.of(fn)` | Same, with the new function type | Same. |
| `Middleware.identity()` | Removed. A chain with no layers runs the handler directly | Not needed. |
| `Middleware.wrapOne(m, inner)` | Removed. `MiddlewareChain.build(handler)` composes every layer once | Composition happens at build time. |
| `MiddlewareChain.compose(terminal)` | `build(handler)`, then `run(q, r)` | The chain keeps the composition, so running allocates nothing. |

### dev.cajeta.http.routing

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `Route(method, pattern, handler)` | Same, taking a `Handler` | New handler type. |
| Field `Route.handler` | Removed. `run(q, r)` runs the handler through the route's middleware | The handler is private. |
| `Route.paramName(i)`, `paramType(i)`, `literal(i)`, `isParam(i)`, `patternSegmentCount()` | Removed. The `segmentCount` field remains | The pattern compiles into private tables. |
| Field `Route.segments` | Removed | Same. |
| `Route.methodMatches(String m)` | `methodMatches(Slice<int8> m)` | The method is a window into the head. |
| `Route.tryMatch(pathSegs, pathLen, out)`, `matchAndScore(pathSegs, pathLen, out)` | `q.splitPath()`, then `score(q, pathLen)` and `bind(q, pathLen)` | Matching runs over the request's own path segments. |
| `Router.route(method, pattern, handler)`, `routeLimited(...)`, `routeMw(...)` | Same, taking a `Handler` | New handler type. |
| `Router.dispatch(request)` returning `#HttpResponse` | `dispatch(q, r)`. `select(q, r)` picks the route without running it | Handlers write into `r`. |
| `Router.patternError(pattern)` | `Route.patternError(pattern)` | Moved to the class that parses patterns. |

### dev.cajeta.http.server

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| Field `HttpServer.handler`, `HttpServer(handler)` | Same, typed `Handler` | New handler type. |
| `HttpServer.bind(addr, handler)`, `bindAddress(addr, handler)`, `bindAddressWithModel(addr, model, handler)`, `bindTlsAddress(addr, handler, ...)` | Same, taking a `Handler` | Same. |
| `HttpServer.bindAddressWithModelAndLimits(..., boolean h2Prior)` (signature change) | `bindAddressWithModelAndLimits(..., #BufferPool pool)`. Prior knowledge is `HttpServerBuilder.h2PriorKnowledge()` | The server takes its buffer pool here. |
| `HttpServerBuilder.handler(handler)` | Same, taking a `Handler` | Same. |
| `HttpServer.handleRequest`, `handleRequestWithLimits`, `handleRequestBytes` | `Http1Connection(...).serve()` over any `ByteChannel`. See "Testing a handler without a socket" | Requests are served only through a connection and its buffers. |
| `HttpServer.serveConnection`, `serveConnectionWithLimits`, `serveLoop`, `serveLoopWithLimits` | `srv.serveChannel(ch)`, or `Http1Connection.serve()` | Same. |
| `HttpServer.serveTlsStream(handler, parseLimits, limits, #tls)` | `srv.serveChannel(tls)` after the handshake. `bindTlsAddress` and `HttpServerBuilder.tls(...)` do both | Same. |
| `HttpServer.expectAction(...)`, `continueResponse()` | Removed. The connection decides `Expect: 100-continue` from the head | See `ExpectContinue`. |
| `ExpectContinue`, `wantsContinue(request)`, `decide(request, framing, limits)`, `ACTION_*` constants | Removed. Set `ServerLimits.expectContinueEnabled` and `maxBodyBytes`. The connection answers 100, 413 or 417 before the handler runs | The decision needs only the head. |
| `RequestBodyChannel`, its constructor, `readAsync`, `readWithin`, `writeAllAsync`, `close` | `q.bodyStream().reader()`. The channel moved to `dev.cajeta.http` and is no longer public | Handlers read through the `Body`. |
| `RequestBodyStream`, `forRequest`, `over`, `read`, `isComplete`, `drainToReader`, `PULL` | `q.bodyStream().reader()`. The connection drains an unread body | Same. |
| `ResponseBodyWriter`, `begin`, `write`, `finish`, `isFinished` | `r.write(...)` flushes in bounded pieces, chunked unless `Content-Length` is set. `r.body(#Body)` streams after the handler returns | The response is itself a streaming writer. |
| `ServerLimits.hasRequestBudget()`, field `requestBudgetMs` | Removed. Use `headReadTimeoutMs`, `bodyReadTimeoutMs` and `Timeout.middleware(budgetMs)` | Each phase has its own deadline. |

### dev.cajeta.http.sse

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `SseResponse.stream(#events, n)` returning `#HttpResponse` | `stream(r, #events, n)` | Handlers write into `r`. |
| `SseResponse.channel(ch)`, `channel(ch, keepAliveMillis)` | `channel(r, ch)`, `channel(r, ch, keepAliveMillis)` | Same. |
| `SseClient.buildRequest()` | `requestHead()` returns the request head as text | The client writes the head straight to the connection. |
| `SseClient.checkHead(HttpResponse resp)` | `checkHead(ClientResponse resp)` | Received responses have their own type. |

### dev.cajeta.http.ws

| 0.3.x | 0.4.0 | Reason |
|---|---|---|
| `WsClientHandshake.buildRequest(uri, key)` | `requestHead(uri, key, extensions)` returns the head as text | Same as `SseClient`. |
| `WsClientHandshake.validateAccept(HttpResponse, key)`, `requireAccept(HttpResponse, key)` | Same, taking a `ClientResponse` | Same. |
| `WsServerHandshake.accept(request)` returning `#HttpResponse` | `accept(q, r)` writes the 101 on `r`. To switch the connection over, use `WsUpgrade.accept(q, r, handler, allowCompression)` | Handlers write into `r`. |
| `WsServerHandshake.reject(e)` returning `#HttpResponse` | `reject(e, r)` | Same. |

### Internals removed

These types were public in 0.3 but were never meant for applications.

| 0.3.x | Role in 0.4.0 |
|---|---|
| `server.Exchange` (constructor, `getResponse`, `isKeepAlive`, fields `response`, `keepAlive`, `written`) | `Http1Connection` serves each exchange in place. |
| `server.HandlerRun` (constructor, `put`, `take`, `pending`) | The handler runs inline and writes into the response. |
| `middleware.TimeoutRun` (constructor, `put`, `take`, `pending`, `threw`, `fail`) | `Timeout.middleware` checks the deadline around `next(q, r)`. |
| `h1.HttpParser` (`forRequest`, `forRequestWithLimits`, `forResponse`, `forResponseWithLimits`, `feed`, `endInput`, `isComplete`, `getRequest`, `getResponse`, `takeRequest`, `takeResponse`, `getFraming`, `leftover`, `leftoverLength`) | `HeadScanner` (`scan`, `readHead`, `parseRequest`, `parseResponse`) indexes the head in place. `h1.BodyReader` still decodes bodies. |
| `h1.HttpSerializer` (constructor, `writeRequest`, `writeRequestChunked`, `writeResponse`, `writeResponseChunked`, `toBytes`, `toStringValue`, `size`, `request`, `requestChunked`, `requestChunkedHead`, `response`, `responseChunked`, `responseChunkedHead`) | `HttpResponse` composes its own head. `Http1ClientConnection` writes a `ClientRequest`. |
| `h1.ChunkedEncoder` (`encodeChunk`, `encodeLast`) | `HttpResponse` chunks a body that outgrows the buffer. |
| `h1.KeepAlive` (`canReuse`, `messageAllowsReuse`, `responseAllowsReuse`, `connectionToken`, `connectionTokenExplicit`, `applyConnectionHeader`) | `HttpRequest.keepAlive()`, `HttpResponse.keepsAlive()`, `ClientResponse.keptAlive()`. |

### Unchanged apart from spelling

These appear in a raw signature diff but need no code change:
`Http.version()` now returns `"0.4.0"`. `HttpRequest`, `HttpResponse`,
`WsServerHandshake` and `WsUpgrade` became `final`. `BytesBody`, `FormBody`,
`GzipCompressBody`, `MultipartBody`, `StreamBody`, `StringBody` and `SseBody`
now say `implements Body`. `Body.reader`, `contentType`, `contentLength` and
`abort` are unchanged interface methods. `HttpServerBuilder` moved to its own
file with the same API (`HttpServerBuilder()`, `bind`, `model`,
`fiberPerConnection`, `sharedPool`, `serverLimits`, `connectionLimits`, `tls`,
`h2PriorKnowledge`, `selectedModel`, `build`). `HttpResponse.push`,
`Http2Requests.promisedRequestFields` and `WsUpgrade.serve` were reformatted
onto one line. `SseResponse.lastEventId`, `WsServerHandshake.isUpgradeRequest`
and `WsServerHandshake.validate` only renamed their parameter.
