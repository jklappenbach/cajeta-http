"""Raw ASGI app for the cajeta-http bench (no framework: the bytes on the wire are exactly ours)."""
import json
from urllib.parse import parse_qs

PLAINTEXT_BODY = b"Hello, World!"
PLAINTEXT_HEADERS = [(b"content-type", b"text/plain"), (b"content-length", b"13")]
NOT_FOUND_HEADERS = [(b"content-type", b"text/plain"), (b"content-length", b"9")]
SSE_HEADERS = [(b"content-type", b"text/event-stream"), (b"cache-control", b"no-cache")]
SSE_BATCH = 100  # flush at least every 100 events


async def _simple(send, status, headers, body):
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


async def _sse(scope, send):
    n = 1000
    qs = parse_qs(scope.get("query_string", b"").decode("latin-1"))
    if "n" in qs:
        try:
            n = int(qs["n"][0])
        except ValueError:
            n = 1000
    await send({"type": "http.response.start", "status": 200, "headers": SSE_HEADERS})
    i = 0
    while i < n:
        end = min(i + SSE_BATCH, n)
        chunk = b"".join(b"data: %d\n\n" % j for j in range(i, end))
        await send({"type": "http.response.body", "body": chunk, "more_body": True})
        i = end
    await send({"type": "http.response.body", "body": b"", "more_body": False})


async def _ws(receive, send):
    msg = await receive()
    if msg["type"] != "websocket.connect":
        return
    await send({"type": "websocket.accept"})
    while True:
        msg = await receive()
        t = msg["type"]
        if t == "websocket.receive":
            b = msg.get("bytes")
            if b is not None:
                await send({"type": "websocket.send", "bytes": b})
            else:
                await send({"type": "websocket.send", "text": msg.get("text") or ""})
        elif t == "websocket.disconnect":
            return


async def app(scope, receive, send):
    t = scope["type"]
    if t == "http":
        path = scope["path"]
        if path == "/plaintext":
            await _simple(send, 200, PLAINTEXT_HEADERS, PLAINTEXT_BODY)
        elif path == "/json":
            body = json.dumps({"message": "Hello, World!"}, separators=(",", ":")).encode()
            await _simple(send, 200, [(b"content-type", b"application/json"),
                                      (b"content-length", str(len(body)).encode())], body)
        elif path == "/sse":
            await _sse(scope, send)
        else:
            await _simple(send, 404, NOT_FOUND_HEADERS, b"Not Found")
    elif t == "websocket":
        if scope["path"] == "/ws":
            await _ws(receive, send)
        else:
            await receive()  # websocket.connect
            await send({"type": "websocket.close", "code": 1008})
    elif t == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
