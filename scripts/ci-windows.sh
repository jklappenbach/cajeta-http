#!/usr/bin/env bash
# The Windows CI leg for dev.cajeta.http.
#
# Why this exists rather than pointing lib-release.yml straight at
# `./run-tests.sh`: the suite links the codec's NATIVE zlib backend, and on
# Windows that archive is not inside the codec `.cja`.
#
# It looks like it should be. `cajeta.json` says the per-platform
# `libcajeta_zlib.a` is baked into the archive at publish, and it is — but only
# for the HOST platform of the machine that published it. Baking several
# platforms from one host is unimplemented (cajeta-codec plan 7.7), so a codec
# released from ubuntu-latest carries `native/linux-x64/` and nothing else.
# Verified against the downloaded v0.8.2 artifact, not assumed.
#
# The other five ARE published, as separate release assets named
# `libcajeta_zlib-<platform>.a`. So the Windows leg fetches the one it needs and
# points CAJETA_NATIVE_PATH at it. `run-tests.sh` only sets that variable when
# it is unset, so an externally supplied tree wins over its extract-bridge —
# which on Windows would otherwise yield a native/ tree holding only the Linux
# archive and fail to resolve `cajeta_zlib` at link time.
#
# A developer box with a sibling cajeta-codec checkout does not need any of
# this: run-tests.sh builds that checkout's own native tree. This is the CI
# path, where no checkout exists.
#
# That premise expired at the 0.8.3 peg, and this leg is now redundant rather
# than load-bearing. cajeta b07545c3 bakes every PROVISIONED native platform
# instead of only the build host's, and 0.8.3 is the first codec cut from a
# toolchain carrying it. Counted out of the two archives rather than read off
# that commit: 0.8.2 holds one `.a`, `linux-x64`, and 0.8.3 holds six, which are
# linux-x64, linux-arm64, linux-riscv64, macos-x64, macos-arm64 and windows-x64.
# So the extract-bridge in run-tests.sh would now find windows-x64 on its own.
#
# It stays anyway, and deliberately. Nothing here can run a Windows leg, so
# deleting it would trade a path that works for one that only looks like it
# should, and the externally supplied CAJETA_NATIVE_PATH still wins over the
# bridge either way. Retire it on a green Windows run, not on this note.
set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${CAJETA_NATIVE_PLATFORM:-windows-x64}"

# Same read run-tests.sh uses, so the two can never disagree about the pin.
CODEC_VER="$(sed -n 's/.*"dev\.cajeta\.codec"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    cajeta.json | head -1)"
if [ -z "$CODEC_VER" ]; then
    echo "ci-windows.sh: could not read dev.cajeta.codec version from cajeta.json" >&2
    exit 1
fi

NATIVE_ROOT="$PWD/.cajeta-native-ci"
rm -rf "$NATIVE_ROOT"
mkdir -p "$NATIVE_ROOT/$PLATFORM"

ASSET="libcajeta_zlib-${PLATFORM}.a"
echo "==> fetching $ASSET from cajeta-codec v$CODEC_VER"
gh release download "v$CODEC_VER" \
    --repo jklappenbach/cajeta-codec \
    --pattern "$ASSET" \
    --output "$NATIVE_ROOT/$PLATFORM/libcajeta_zlib.a"

# Fail loudly here rather than let the link fail with a resolver error that
# does not mention the codec at all.
if [ ! -s "$NATIVE_ROOT/$PLATFORM/libcajeta_zlib.a" ]; then
    echo "ci-windows.sh: $ASSET missing or empty on cajeta-codec v$CODEC_VER" >&2
    exit 1
fi
ls -l "$NATIVE_ROOT/$PLATFORM/libcajeta_zlib.a"

export CAJETA_NATIVE_PATH="$NATIVE_ROOT"
echo "==> CAJETA_NATIVE_PATH=$CAJETA_NATIVE_PATH (codec release asset)"

exec ./run-tests.sh
