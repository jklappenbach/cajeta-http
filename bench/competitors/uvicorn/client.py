"""httpx.AsyncClient (HTTP/1.1) load client: get <url> <total> <conns> <keepalive>."""
import asyncio
import json
import sys
import time

import httpx
import uvloop

EXPECTED = b"Hello, World!"


async def main(url, total, conns, keepalive):
    limits = httpx.Limits(max_connections=conns,
                          max_keepalive_connections=conns if keepalive else 0)
    counts = {"requests": 0, "errors": 0}
    remaining = [total]

    async with httpx.AsyncClient(http1=True, http2=False, limits=limits, timeout=30.0,
                                 trust_env=False) as client:
        async def worker():
            while remaining[0] > 0:
                remaining[0] -= 1
                try:
                    r = await client.get(url)
                    counts["requests"] += 1
                    if r.status_code != 200 or r.content != EXPECTED:
                        counts["errors"] += 1
                except Exception:
                    counts["errors"] += 1

        start = time.perf_counter_ns()
        await asyncio.gather(*(worker() for _ in range(conns)))
        elapsed = time.perf_counter_ns() - start
    return counts, elapsed


def run():
    if len(sys.argv) != 6 or sys.argv[1] != "get":
        print("usage: client.py get <url> <total> <conns> <keepalive>", file=sys.stderr)
        sys.exit(2)
    url = sys.argv[2]
    try:
        total, conns, keepalive = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    except ValueError:
        print("total, conns, keepalive must be integers", file=sys.stderr)
        sys.exit(2)
    if total < 0 or conns < 1 or keepalive not in (0, 1):
        print("need total>=0, conns>=1, keepalive in {0,1}", file=sys.stderr)
        sys.exit(2)
    counts, elapsed = uvloop.run(main(url, total, conns, keepalive))
    print(json.dumps({"requests": counts["requests"], "errors": counts["errors"],
                      "elapsed_ns": elapsed}, separators=(",", ":")))


if __name__ == "__main__":
    run()
