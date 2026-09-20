# mallprobe — a native allocator probe

`LD_PRELOAD` shim that counts **live** malloc blocks and bytes, with a
power-of-two size histogram. It answers "is anything actually leaked" directly,
where RSS only hints.

```sh
gcc -O2 -fPIC -shared -o mallprobe.so mallprobe.c -ldl

LD_PRELOAD=$PWD/mallprobe.so ./build/test/http-tests --only=NOSUCHSUITE --soakserve=18603 &
./build/test/http-tests --only=NOSUCHSUITE --soakdrive=20000 --soakport=18603

kill -USR1 <server pid>   # dump live blocks, bytes, and the size histogram
kill -USR2 <server pid>   # malloc_trim(0), to see whether RSS was trimmable
```

## Why this exists

Two better-known tools do not work here.

**Valgrind cannot run the binary at all.** It stops with `Unrecognised
instruction` inside generated code: cajeta targets the host CPU (znver5), and
valgrind 3.26 does not emulate those instructions. This is the same reason it
misled an earlier JIT investigation.

**bpftrace needs root**, which a test run should not.

The shim needs neither, and runs at close to native speed.

## Reading the output

`liveBlocks` and `liveBytes` flat across a long run means no leak, whatever RSS
does. Compare against `/proc/<pid>/smaps_rollup`: `Anonymous` is the heap and
should track `liveBytes`, while the rest of `Rss` is file-backed code and
read-only data paged in as execution touches it, which plateaus.

A worked example, the h2 server over 20000 requests on one connection:
1,013,974 allocations against 1,013,374 frees, live blocks steady at 590-622,
live bytes steady at 2.18 MB, `Anonymous` 2016 kB. No leak. The RSS above that
was the binary's own text and libc/libcrypto pages.
