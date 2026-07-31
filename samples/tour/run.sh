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
OLLA_HOME="${OLLA_HOME:-$HOME/.olla}"

# 1. The library .cja. The version lives in cajeta.json and only the build
#    knows it, so build when missing/stale and GLOB the produced archive —
#    a version pin hardcoded here is exactly how the tour silently broke on
#    the 0.1.1 -> 0.1.2 bump.
newest="$(ls -t "${REPO_ROOT}"/build/archive/dev.cajeta.http-*.cja 2>/dev/null | head -1 || true)"
if [[ -z "${newest}" ]] \
   || [[ -n "$(find "${REPO_ROOT}/src/main/cajeta" -name '*.cajeta' -newer "${newest}" -print -quit)" ]]; then
    echo ">> building the library"
    ( cd "${REPO_ROOT}" && "${CAJETA_BIN}" build )
    newest="$(ls -t "${REPO_ROOT}"/build/archive/dev.cajeta.http-*.cja | head -1)"
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
