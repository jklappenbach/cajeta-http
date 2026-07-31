#!/usr/bin/env bash
# The full CI check chain: unit suite, then the self-checking tour, then the
# tour coverage gate. release.yml's `test-command` points here so the list
# lives in one place.
set -euo pipefail
cd "$(dirname "$0")/.."

./run-tests.sh

# The tour normally finishes in well under a minute; 300s is a wedge guard,
# not headroom. If it trips, suspect the runtime lost-wakeup defect (cajeta
# INDEX: runtime-lost-wakeup-under-load) rather than slowness.
timeout 300 ./samples/tour/run.sh

CAJETA="$(command -v cajeta)" ./scripts/check-library-tour-coverage.sh \
    src/main/cajeta samples/tour scripts/tour-coverage-ignore.txt
