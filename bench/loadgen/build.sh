#!/usr/bin/env bash
# Builds build/loadgen (and build/testserver, the example server used to self-test it).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
export GOTOOLCHAIN=local
export GOFLAGS="${GOFLAGS:-} -mod=readonly"
mkdir -p build
echo "loadgen: $(go version)" >&2
go build -trimpath -o build/loadgen .
go build -trimpath -o build/testserver ./testserver
echo "loadgen: built $here/build/loadgen" >&2
