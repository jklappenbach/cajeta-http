#!/usr/bin/env bash
# Builds the Go net/http competitor into build/server and build/client.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
export GOTOOLCHAIN=local
GO="${GO:-/usr/bin/go}"
mkdir -p build
echo "[go-nethttp] $("$GO" version)" >&2
echo "[go-nethttp] downloading/verifying modules" >&2
"$GO" mod download
"$GO" mod verify >&2
echo "[go-nethttp] building build/server" >&2
"$GO" build -trimpath -mod=readonly -o build/server ./cmd/server
echo "[go-nethttp] building build/client" >&2
"$GO" build -trimpath -mod=readonly -o build/client ./cmd/client
echo "[go-nethttp] done" >&2
