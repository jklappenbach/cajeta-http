#!/usr/bin/env bash
# Prints the versions of every library this stack uses, as key=value lines.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
export GOTOOLCHAIN=local
GO="${GO:-/usr/bin/go}"
gov="$("$GO" env GOVERSION)"
modver() { "$GO" list -mod=readonly -m -f '{{.Version}}' "$1"; }
echo "language=go"
echo "language_version=$gov"
echo "server=net/http $gov"
echo "h2=golang.org/x/net/http2 $(modver golang.org/x/net)"
echo "ws=gorilla/websocket $(modver github.com/gorilla/websocket)"
echo "sse=net/http $gov"
echo "tls=crypto/tls $gov"
echo "client=net/http $gov"
