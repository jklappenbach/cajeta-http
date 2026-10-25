#!/usr/bin/env bash
# Build the uvicorn stack: its own venv at .venv from requirements.txt (exact == pins). Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=/usr/bin/python3
VENV="$DIR/.venv"
STAMP="$VENV/.requirements.sha256"
want="$(sha256sum "$DIR/requirements.txt" | cut -d' ' -f1)"

if [[ -x "$VENV/bin/python" && -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]]; then
  echo "uvicorn: venv up to date ($VENV)" >&2
else
  echo "uvicorn: creating venv at $VENV with $PY" >&2
  rm -rf "$VENV"
  "$PY" -m venv "$VENV"
  "$VENV/bin/python" -m pip install --disable-pip-version-check -q --no-input \
    -r "$DIR/requirements.txt" >&2
  echo "$want" > "$STAMP"
fi
# Verify the installed set is consistent and the fast extras import.
"$VENV/bin/python" -m pip check --disable-pip-version-check >&2
"$VENV/bin/python" -c 'import uvicorn, uvloop, httptools, websockets, httpx' >&2
"$VENV/bin/python" -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' "$DIR/app.py" "$DIR/client.py"
echo "uvicorn: build ok" >&2
