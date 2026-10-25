#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/.venv/bin/python" - <<'PY'
import platform, ssl
from importlib.metadata import version as v
print("language=python")
print("language_version=" + platform.python_version())
print("server=uvicorn " + v("uvicorn"))
print("h2=none")
print("ws=websockets " + v("websockets"))
print("sse=uvicorn " + v("uvicorn"))
print("tls=ssl " + ssl.OPENSSL_VERSION.split()[0] + "-" + ssl.OPENSSL_VERSION.split()[1])
print("client=httpx " + v("httpx"))
PY
