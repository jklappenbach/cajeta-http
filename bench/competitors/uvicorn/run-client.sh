#!/usr/bin/env bash
# run-client.sh get <url> <total> <conns> <keepalive>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1  # keep __pycache__ out of the source dir
exec "$DIR/.venv/bin/python" "$DIR/client.py" "$@"
