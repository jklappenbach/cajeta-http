#!/usr/bin/env bash
# Prints key=value lines: toolchain from rustc, library versions from Cargo.lock.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUSTC="${RUSTC:-$HOME/.cargo/bin/rustc}"
[[ -x "$RUSTC" ]] || RUSTC="$(command -v rustc)"
LOCK="$DIR/Cargo.lock"
ver() {  # version of crate $1 in Cargo.lock
  awk -v n="$1" '$0=="[[package]]"{p=0} $0=="name = \""n"\""{p=1} p && /^version = /{gsub(/"/,"",$3); print $3; exit}' "$LOCK"
}
echo "language=rust"
echo "language_version=$("$RUSTC" --version | awk '{print $2}')"
echo "server=axum $(ver axum)"
echo "h2=hyper $(ver hyper)"
echo "ws=tokio-tungstenite $(ver tokio-tungstenite)"
echo "ws_deflate=no"
echo "sse=axum $(ver axum)"
echo "tls=rustls $(ver rustls)"
echo "client=reqwest $(ver reqwest)"
