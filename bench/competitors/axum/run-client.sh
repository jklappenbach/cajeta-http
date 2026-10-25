#!/usr/bin/env bash
# run-client.sh get <url> <total> <conns> <keepalive>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -ne 5 || "$1" != "get" ]]; then
  echo "usage: run-client.sh get <url> <total> <conns> <keepalive 0|1>" >&2; exit 2
fi
exec "$DIR/target/release/client" "$@"
