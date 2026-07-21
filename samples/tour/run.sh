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

set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd -- "${SCRIPT_DIR}/../.." &> /dev/null && pwd )"

CAJETA_BIN="${CAJETA_BIN:-cajeta}"
LIB_CJA="${REPO_ROOT}/build/archive/dev.cajeta.http-0.1.1.cja"
# dev.cajeta.codec (http:1.6a content-coding) — the library's olla
# dependency, needed on every downstream classpath alongside the .cja.
CODEC_CJA="${CODEC_CJA:-${HOME}/.olla/dev.cajeta.codec/0.6.0/dev.cajeta.codec-0.6.0.cja}"
OUT="${SCRIPT_DIR}/build/http-tour"

# 1. The library .cja — build it when missing or older than any source.
if [[ ! -f "${LIB_CJA}" ]] \
   || [[ -n "$(find "${REPO_ROOT}/src/main/cajeta" -name '*.cajeta' -newer "${LIB_CJA}" -print -quit)" ]]; then
    echo ">> building the library (${LIB_CJA##*/})"
    ( cd "${REPO_ROOT}" && "${CAJETA_BIN}" build )
fi

# 2. The tour binary, compiled against the .cja.
mkdir -p "${SCRIPT_DIR}/build"
"${CAJETA_BIN}" "tour.http.HttpTour::main" \
    "${SCRIPT_DIR}/src" "${SCRIPT_DIR}/build" \
    --emit=exe --classpath="${LIB_CJA},${CODEC_CJA}" -o "${OUT}"

# 3. Run it (RUN=0 skips).
if [[ "${RUN:-1}" != "0" ]]; then
    exec "${OUT}"
fi
