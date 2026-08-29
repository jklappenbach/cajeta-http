#!/usr/bin/env bash
# Build + run the cajeta-http tour.
#
#   ./run.sh            # build the library if needed, compile the tour, run it
#   RUN=0 ./run.sh      # compile only
#
# The tour is an ordinary cajeta program compiled against the library's
# .cja via --classpath (the toolchain's test/sample dependency flow until
# local path-dependencies land in the build tool). Exit code = number of
# failed self-checks (0 = tour passed).
#
# Knobs (environment):
#   CAJETA_BIN=<path>   compiler binary (default: `cajeta` on PATH)
#   OLLA_HOME=<path>    dependency store root (default: ~/.olla)

set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd -- "${SCRIPT_DIR}/../.." &> /dev/null && pwd )"

CAJETA_BIN="${CAJETA_BIN:-cajeta}"

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

# 1. The library .cja. The version lives in cajeta.json and only the build
#    knows it, so build when missing/stale and GLOB the produced archive —
#    a version pin hardcoded here is exactly how the tour silently broke on
#    the 0.1.1 -> 0.1.2 bump.
newest="$(cajeta_artifact_path "${REPO_ROOT}" dev.cajeta.http 2>/dev/null || true)"
if [[ -z "${newest}" ]] \
   || [[ -n "$(find "${REPO_ROOT}/src/main/cajeta" -name '*.cajeta' -newer "${newest}" -print -quit)" ]]; then
    echo ">> building the library"
    ( cd "${REPO_ROOT}" && "${CAJETA_BIN}" build )
    newest="$(cajeta_artifact_path "${REPO_ROOT}" dev.cajeta.http)"
fi
LIB_CJA="${newest}"
echo ">> library: ${LIB_CJA##*/}"

# 2. dev.cajeta.codec — the version is single-sourced from cajeta.json's
#    dependencies block (mirrors run-tests.sh; a second pin here would drift).
CODEC_VER="$(sed -n 's/.*"dev\.cajeta\.codec"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${REPO_ROOT}/cajeta.json" | head -1)"
if [[ -z "${CODEC_VER}" ]]; then
    echo "run.sh: could not read dev.cajeta.codec version from cajeta.json" >&2
    exit 1
fi
CODEC_CJA="${CODEC_CJA:-${OLLA_HOME}/dev.cajeta.codec/${CODEC_VER}/dev.cajeta.codec-${CODEC_VER}.cja}"
if [[ ! -f "${CODEC_CJA}" ]]; then
    echo "run.sh: codec archive not found: ${CODEC_CJA}" >&2
    echo "  (resolve it first — e.g. \`${CAJETA_BIN} build\` — or fix the dep pin)" >&2
    exit 1
fi
echo ">> codec ${CODEC_VER}: ${CODEC_CJA##*/}"

# 3. extract-bridge (same as run-tests.sh): the codec .cja bakes the native
#    zlib archives, but the toolchain doesn't yet auto-extract natives from a
#    classpath .cja — explode native/ and point the linker at it.
NATIVE_DIR="${SCRIPT_DIR}/build/.cajeta-native"
rm -rf "${NATIVE_DIR}"
mkdir -p "${SCRIPT_DIR}/build"
"${CAJETA_BIN}" archive extract "${CODEC_CJA}" -C "${NATIVE_DIR}" >/dev/null
if [[ -d "${NATIVE_DIR}/native" ]]; then
    export CAJETA_NATIVE_PATH="${NATIVE_DIR}/native"
fi

# 4. The tour binary, compiled against the .cja.
OUT="${SCRIPT_DIR}/build/http-tour"
"${CAJETA_BIN}" "tour.http.HttpTour::main" \
    "${SCRIPT_DIR}/src" "${SCRIPT_DIR}/build" \
    --emit=exe --classpath="${LIB_CJA},${CODEC_CJA}" -o "${OUT}"

# 5. Run it (RUN=0 skips).
if [[ "${RUN:-1}" != "0" ]]; then
    exec "${OUT}"
fi
