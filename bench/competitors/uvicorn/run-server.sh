#!/usr/bin/env bash
# run-server.sh <mode> <port> [<cert.pem> <key.pem>]   mode: h1 | h2c | tls
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1  # keep __pycache__ out of the source dir
if [[ $# -lt 2 ]]; then
  echo "usage: run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]" >&2; exit 2
fi
mode="$1"; port="$2"
cd "$DIR"
common=(--host 127.0.0.1 --port "$port" --loop uvloop --http httptools --ws websockets
        --ws-per-message-deflate true --no-access-log --log-level warning
        --no-server-header --no-date-header)
case "$mode" in
  h1)
    exec "$DIR/.venv/bin/python" -m uvicorn app:app "${common[@]}" ;;
  h2c)
    echo "uvicorn does not implement HTTP/2 (h2c unsupported)" >&2; exit 3 ;;
  tls)
    if [[ $# -lt 4 ]]; then echo "tls mode needs <cert.pem> <key.pem>" >&2; exit 2; fi
    exec "$DIR/.venv/bin/python" -m uvicorn app:app "${common[@]}" \
      --ssl-certfile "$3" --ssl-keyfile "$4" ;;
  *)
    echo "unknown mode: $mode" >&2; exit 2 ;;
esac
