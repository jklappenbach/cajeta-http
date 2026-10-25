#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
if [[ $# -ne 5 || "$1" != "get" ]]; then
  echo "usage: run-client.sh get <url> <total> <conns> <keepalive>" >&2
  exit 2
fi
exec "$NODE" "$DIR/client.js" "$@"
