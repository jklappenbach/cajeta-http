# cajeta-http tour

A self-checking walkthrough of the library surface, one section per layer
(modeled on the language's own [`samples/tour`](https://github.com/jklappenbach/cajeta)):

1. **Message model + wire codec** — build an `HttpRequest`, serialize it,
   print the wire text, parse it back, decode the body.
2. **Router** — typed path params (`/users/{id}`), and the 404 / 405+`Allow`
   defaults.
3. **Live HTTP over loopback** — an `HttpServer` bound on `127.0.0.1:0`
   serving a real `HttpClient` GET and POST-echo, then a clean drain.
4. **WebSocket** — the pure RFC 6455 handshake (`Sec-WebSocket-Accept`
   against the RFC's own example vector), then a live upgraded echo.

Every section asserts what it demonstrates. The exit code is the number of
failed checks — `0` means the tour passed.

## Run

Requires the cajeta toolchain (`cajeta` on `PATH`, or `CAJETA_BIN=<path>`):

```sh
./run.sh          # build the library if stale, compile the tour, run it
RUN=0 ./run.sh    # compile only
```

The tour compiles against the library's built `.cja` via `--classpath`
(the same flow as `cajeta test` — see the manifest's `test` task), so it
exercises exactly what a consumer of the published archive gets.

## Layout

```
samples/tour/
├── README.md
├── run.sh                        ← library build (if stale) + compile + run
└── src/tour/http/HttpTour.cajeta ← the tour: 4 sections, 15 self-checks
```

## What you'll see

```
=== cajeta-http tour ===

-- The message model and the HTTP/1.1 wire codec --
  serialized 78 bytes:
POST /form HTTP/1.1
host: tour.example
content-length: 8
...
-- The Router: typed path params, 404/405 defaults --
-- A live HttpServer + HttpClient over loopback --
-- WebSocket: RFC 6455 handshake + live echo --

=== tour complete: 15 checks passed, 0 failed ===
```
