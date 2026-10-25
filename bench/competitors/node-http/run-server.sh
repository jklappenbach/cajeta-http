#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
if [[ $# -lt 2 ]]; then
  echo "usage: run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]" >&2
  exit 2
fi
exec "$NODE" "$DIR/server.js" "$@"
