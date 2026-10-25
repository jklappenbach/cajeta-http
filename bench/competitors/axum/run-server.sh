#!/usr/bin/env bash
# run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -lt 2 ]]; then echo "usage: run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]" >&2; exit 2; fi
case "$1" in
  h1|h2c) ;;
  tls) [[ $# -ge 4 ]] || { echo "run-server.sh: tls needs <cert.pem> <key.pem>" >&2; exit 2; } ;;
  *) echo "run-server.sh: unknown mode $1" >&2; exit 2 ;;
esac
exec "$DIR/target/release/server" "$@"
