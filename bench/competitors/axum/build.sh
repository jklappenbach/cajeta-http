#!/usr/bin/env bash
# Build the axum/hyper competitor (release, target-cpu=native) into ./target. Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
[[ -x "$CARGO" ]] || CARGO="$(command -v cargo)" || { echo "build.sh: cargo not found" >&2; exit 1; }
echo "axum: cargo build --release (target-cpu=native)" >&2
cd "$DIR"
RUSTFLAGS="-C target-cpu=native" CARGO_TARGET_DIR="$DIR/target" \
  "$CARGO" build --release --locked --bins 1>&2
for b in server client; do
  [[ -x "$DIR/target/release/$b" ]] || { echo "build.sh: missing target/release/$b" >&2; exit 1; }
done
echo "axum: built $DIR/target/release/{server,client}" >&2
