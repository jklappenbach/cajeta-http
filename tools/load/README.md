# cajeta-http load tool

The request-dispatch load instrument (spec §8, plan Unit 10). One program,
three modes:

```sh
# build, then run the selftest (10 idle connections, 2 in flight, 2 s)
CAJETA_BIN=/path/to/cajeta ./tools/load/run.sh

# a server: port, handler delay in ms, model, optional PEM cert and key
./tools/load/build/load-tool serve 8080 5 pool
./tools/load/build/load-tool serve 8080 5 fiber

# the client against it: port, idle connections, in flight, seconds, optional anchor PEM
./tools/load/build/load-tool run 8080 10000 1000 30
```

`serve` answers `/` with `ok`, sleeps the delay before answering `/work`,
and reports the process on `/stats` as JSON: `rss_kb` and `maps` from
`/proc/self`, `fibers` from the runtime, and the server's `model`,
`framers`, `dispatches`, `in_flight`, `idle`, `paused` and `connections`.

`run` opens the idle connections (each makes one request, then says
nothing), reads `/stats`, lets the in-flight fibers loop `/work` on their own
keep-alive connections for the given seconds, reads `/stats` again, and
prints requests, throughput, latency p50/p90/p99/max and the three stats
lines. With an anchor PEM both sides speak TLS, and ALPN picks h2; the idle
connections are plaintext only.

The `vm.max_map_count` wall: each fiber stack is a guard-paged mapping, two
entries in `/proc/self/maps`; the default ceiling of 65,530 is reached near
32K fibers. Under the pool the server's fiber count is the framers plus the
pool's pre-spawned workers (`maxInFlight`), not the connections, which is
what `maps` in `/stats` shows at 10K and 100K idle.
