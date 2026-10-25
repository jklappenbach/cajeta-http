#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/env.sh"
cd "$DIR"
NV="$("$NODE" --version)"
OSSL="$("$NODE" -p 'process.versions.openssl')"
lockver() {
  "$NODE" -p "require('./package-lock.json').packages['node_modules/$1'].version"
}
echo "language=javascript"
echo "language_version=$NV"
echo "server=node:http $NV"
echo "h2=node:http2 $NV"
echo "ws=ws $(lockver ws)"
echo "sse=node:http $NV"
echo "tls=node:https $NV+OpenSSL$OSSL"
echo "client=undici $(lockver undici)"
