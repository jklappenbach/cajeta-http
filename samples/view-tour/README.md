# The view tour

A short, self-checking program that shows how cajeta-http 0.4.0 handles a
request and a response.

```sh
./run.sh
```

It starts a server on a loopback port, sends plain HTTP/1.1 requests over
one socket, and checks each answer. The exit code is the number of failed
checks.

## The model in one handler

```cajeta
router.route("GET", "/hello/{name}", (HttpRequest q, HttpResponse r) -> {
    r.header("Content-Type", "text/plain");
    r.write("hello, ");
    r.writeBytes(q.param("name"));
});
```

- The request is a view over the connection's input buffer. `q.param`,
  `q.header`, `q.path` and `q.body` return windows into bytes that were read
  once and never copied. `q.method()` and `q.version()` are enums.
- The response writes into the connection's output buffer. The head is
  composed in front of the body when the handler returns, so a response that
  fits is one write.
- A status defaults to 200. A handler that throws an `HttpException` answers
  with that exception's status.
- A value that must outlive the request is copied on purpose, with
  `q.headerString`, `q.paramString` or `Bytes.toString`. The window itself is
  only valid until the handler returns.

## What the tour checks

1. One request and one response, with the exact bytes printed.
2. More requests on the same connection: a typed path parameter, a body copied
   out and kept, a thrown exception, 404, and 405 with `Allow`.
3. 500 more requests on that connection allocate 0 bytes, client and server
   together, and the connection keeps its two pooled buffers throughout.
