# cajeta-http wire sample

A custom protocol end to end on the request-dispatch pool (spec §5): a route
upgrades into a `Protocol` over a length-prefixed `Framer`, two unit kinds
run their handlers on worker turns, and a raw client drives it.

```sh
CAJETA_BIN=/path/to/cajeta ./samples/wire/run.sh
RUN=0 ./samples/wire/run.sh    # compile only
```

What it shows, in `src/wire/WireSample.cajeta`:

- `Wire implements Framer`: two bytes of big-endian length, one byte of kind,
  the payload. `unit` looks at the header only and reports that through
  `scanned`, so the server charges it three bytes per call rather than the
  whole buffer (spec §3.5).
- The route: `Protocol.over(WIRE)` with `maxUnit`, two `on(kind, handler)`
  registrations and an `onClose`, then `r.status(101); r.upgrade(#p)`.
  The framer instance is server-wide, so it is lent; `over(#f)` hands one over.
- Handlers get a `ProtocolConnection` to `send` on and a `ProtocolUnit` with
  the unit's bytes; two units in one segment run on one turn, in order.
- The client sends `hello` as kind 1 and `wire` as kind 2 and expects
  `1:hello,2:WIRE,`. Exit code 0 on a match.

`run.sh` builds the library `.cja` when stale, compiles the sample against it
with `--classpath`, and runs it.
