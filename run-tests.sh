#!/usr/bin/env bash
#
# Build + run the cajeta-http suite with the codec's NATIVE zlib backend linked.
#
# Why this exists (the "extract-bridge"): dev.cajeta.codec >= 0.7.0 ships a
# native zlib backend, and its published `.cja` BAKES the per-platform
# `native/<platform>/libcajeta_zlib.a`. But the current toolchain does not
# auto-extract native artifacts from a classpath `.cja` (cajeta-codec spec
# §3.2.2 is unimplemented) — the linker searches only $CAJETA_NATIVE_PATH, the
# project `native/` dir, and ~/.cajeta/native. So we explode the `native/` tree
# out of the codec archive we already have and point the resolver at it.
# Offline: no vendoring, no network. When §3.2.2 lands (codec plan 7.6) this
# whole bridge collapses to a plain `cajeta test`.
#
# Only the ONE-SHOT paths go native (ContentCoding's full-body gzip/zlib). The
# streaming paths (GzipCompressChannel, PerMessageDeflate) stay pure-cajeta
# until a native z_stream backend exists (codec spec §7.1).
#
# Usage:
#   ./run-tests.sh              # build + compile tests + run once
#   ./run-tests.sh 20           # ...then loop the binary 20x (flake hunting)
#
# Env overrides:
#   CAJETA_BIN   compiler to use (default: `cajeta` on PATH)
#   OLLA_HOME    dependency store root (default: ~/.olla)

set -euo pipefail

cd "$(dirname "$0")"

CAJETA_BIN="${CAJETA_BIN:-cajeta}"

# GzipCompressChannel keeps a borrow of its source reader in a field, and
# CAJETA_ERROR_CAPTURED_BORROW_PARAM rejects that outright. The code is
# CORRECT: GzipCompressBody.of owns both the body and the channel, hands the
# channel a `b.source.reader()` borrow, and the two die together -- the
# deliberate non-owning alias of the ownership guide 3. The checker cannot
# prove the borrow's owner outlives the borrower when a single parent owns
# both, and there is no spelling that says so: making the parameter `#T`
# fails at the call site instead, because `reader()` returns a borrow and
# there is no title to transfer.
#
# So warn rather than error, the same warn-first switch cajeta-llm and cabra
# already carry for this migration. Drop it when the checker learns
# co-ownership.
export CAJETA_CAPTURED_BORROW="${CAJETA_CAPTURED_BORROW:-warn}"

# --- artifact discovery -------------------------------------------------
# Where a checkout's .cja is. Prefers `cajeta artifact-path`, which reads
# that project's OWN manifest -- so a project that moves its artifacts with
# settings.output is followed rather than guessed, and the version comes
# from details.version instead of whichever file happens to be newest.
#
# Falls back to the historical build/archive glob only when the toolchain
# does not HAVE the verb (it lands after 0.24.0), so this keeps working on
# an older cajeta and starts using the verb as soon as a newer one is on
# PATH -- no flag day.
#
# The gate is the CAPABILITY, not the outcome. A fallback keyed on "the
# verb failed" would silently mask a verb that ran and answered wrongly,
# which is the very failure this replaces; keyed on "the verb is absent",
# it cannot. An empty result still means "not in this checkout", exactly
# as the glob did, so callers' registry fallbacks are unchanged.
cajeta_artifact_path() {
    local dir="$1" name="$2"
    local cj="${CAJETA:-${CAJETA_BIN:-cajeta}}"
    if [[ -z "${_cajeta_has_ap:-}" ]]; then
        if "$cj" artifact-path --help 2>/dev/null \
                | grep -q 'artifact-path \[options\]'; then
            _cajeta_has_ap=yes
        else
            _cajeta_has_ap=no
        fi
    fi
    if [[ "$_cajeta_has_ap" == yes ]]; then
        # Only report a path that EXISTS. The verb answers where the
        # artifact would be even when nothing has built it, but the glob
        # this replaces returned empty in that case, and every caller
        # reads empty as "not in this checkout" and falls back to the
        # registry. Handing back a path to a missing file instead would
        # turn that into a confusing compile failure.
        local p
        p=$( cd "$dir" 2>/dev/null && "$cj" artifact-path 2>/dev/null ) || return 0
        [[ -n "$p" && -f "$p" ]] && printf '%s\n' "$p"
        return 0
    else
        ls -t "$dir"/build/archive/"$name"-*.cja 2>/dev/null | head -1
    fi
}

OLLA_HOME="${OLLA_HOME:-$HOME/.olla}"
LOOPS="${1:-0}"

# --- codec version: single source of truth is cajeta.json's dependencies ------
CODEC_VER="$(sed -n 's/.*"dev\.cajeta\.codec"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    cajeta.json | head -1)"
if [ -z "$CODEC_VER" ]; then
    echo "run-tests.sh: could not read dev.cajeta.codec version from cajeta.json" >&2
    exit 1
fi
CODEC_CJA="$OLLA_HOME/dev.cajeta.codec/$CODEC_VER/dev.cajeta.codec-$CODEC_VER.cja"
if [ ! -f "$CODEC_CJA" ]; then
    echo "run-tests.sh: codec archive not found: $CODEC_CJA" >&2
    echo "  (resolve it first — e.g. \`$CAJETA_BIN build\` — or fix the dep pin)" >&2
    exit 1
fi

echo "==> codec $CODEC_VER: $CODEC_CJA"

# --- extract-bridge ----------------------------------------------------------
# Re-extract every run: the archive is the source of truth and a stale tree
# silently links an old backend.
NATIVE_DIR="$PWD/.cajeta-native"
rm -rf "$NATIVE_DIR"
"$CAJETA_BIN" archive extract "$CODEC_CJA" -C "$NATIVE_DIR" >/dev/null

if [ -d "$NATIVE_DIR/native" ]; then
    export CAJETA_NATIVE_PATH="$NATIVE_DIR/native"
    echo "==> CAJETA_NATIVE_PATH=$CAJETA_NATIVE_PATH"
    find "$NATIVE_DIR/native" -name '*.a' -printf '    %p (%s bytes)\n' 2>/dev/null || true
else
    # A pre-native codec (<= 0.6.0) has no native/ tree. Not fatal — the pure
    # cajeta DEFLATE fallback still builds — but say so loudly, because the
    # whole point of this script is the native path.
    echo "==> WARNING: no native/ tree in $CODEC_CJA — codec $CODEC_VER is" >&2
    echo "    pre-native (or the bake failed). Falling back to pure-cajeta" >&2
    echo "    DEFLATE; expect ~1 MB/s on gzip paths." >&2
fi

# --- build the library, then the suite against it ----------------------------
echo "==> building dev.cajeta.http"
"$CAJETA_BIN" build

ART="$(cajeta_artifact_path . dev.cajeta.http 2>/dev/null)"
if [ -z "$ART" ]; then
    echo "run-tests.sh: no build/archive/dev.cajeta.http-*.cja after build" >&2
    exit 1
fi
echo "==> library: $ART"

echo "==> compiling test suite"
mkdir -p build/test
"$CAJETA_BIN" "dev.cajeta.http.test.TestMain::main" test/src build/test \
    --emit=exe \
    --classpath="$ART,$CODEC_CJA" \
    -o build/test/http-tests

# The suite writes relative paths (downloadTo), so it must run from the repo
# root — which is where we already are.
echo "==> running suite"
./build/test/http-tests

if [ "$LOOPS" -gt 0 ] 2>/dev/null; then
    echo "==> looping ${LOOPS}x (a single green run proves nothing)"
    fail=0
    for i in $(seq 1 "$LOOPS"); do
        if ./build/test/http-tests >"build/test/loop-$i.log" 2>&1; then
            printf '.'
        else
            printf 'X'
            fail=$((fail + 1))
            echo "  <- run $i FAILED (build/test/loop-$i.log)"
        fi
    done
    echo
    echo "==> $((LOOPS - fail))/$LOOPS clean"
    [ "$fail" -eq 0 ] || exit 1
fi
