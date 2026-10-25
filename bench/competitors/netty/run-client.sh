#!/usr/bin/env bash
# run-client.sh get <url> <total> <conns> <keepalive>
# java.net.http.HttpClient (HTTP_1_1). JVM flags: -server -XX:+UseParallelGC -Xms256m.
# keepalive=0: the JDK client's pool cannot be switched off per client, so the JVM gets
# -Djdk.httpclient.allowRestrictedHeaders=connection and every request carries "Connection: close";
# the server answers with "connection: close" and closes, and the JDK client never returns such a
# connection to its pool. -Djdk.httpclient.keepalive.timeout=0 is added as a belt-and-braces.
# Verified by the accepted-connection count (TcpPassiveOpens in /proc/net/snmp) around a run:
# `get .../plaintext 2000 16 0` -> +2002 accepts (one fresh connection per request); the same run with
# keepalive=1 -> +16 (one per worker). Server-side TIME_WAIT on the port also grows by ~2000 vs 0.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_HOME="${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}"
[[ $# -eq 5 && "$1" == get ]] || { echo "usage: run-client.sh get <url> <total> <conns> <keepalive>" >&2; exit 2; }
[[ -f "$HERE/build/classpath.txt" ]] || { echo "run-client.sh: run build.sh first" >&2; exit 1; }
props=()
if [[ "$5" == 0 ]]; then
  props=(-Djdk.httpclient.allowRestrictedHeaders=connection -Djdk.httpclient.keepalive.timeout=0)
fi
exec "$JAVA_HOME/bin/java" -server -XX:+UseParallelGC -Xms256m "${props[@]}" -cp "$HERE/build/classes" Client "$@"
