#!/usr/bin/env bash
# run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -lt 2 ]]; then
  echo "usage: run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]" >&2
  exit 2
fi
exec "$DIR/build/server" "$@"
