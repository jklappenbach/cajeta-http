#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
cd "$DIR"
echo "node-http: node $("$NODE" --version), npm $(npm --version)" >&2
echo "node-http: npm ci" >&2
npm ci --no-audit --no-fund --loglevel=error 1>&2
"$NODE" --check server.js
"$NODE" --check client.js
"$NODE" -e 'require("ws"); require("undici")'
echo "node-http: build ok" >&2
