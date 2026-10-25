# Sourced by the stack scripts: pins the Node toolchain (nvm is not loaded in non-interactive shells).
NODE_BIN_DIR="${NODE_BIN_DIR:-/home/julian/.nvm/versions/node/v22.22.3/bin}"
NODE="$NODE_BIN_DIR/node"
export PATH="$NODE_BIN_DIR:$PATH"
if [[ ! -x "$NODE" ]]; then
  echo "node-http: node not found at $NODE" >&2
  exit 2
fi
