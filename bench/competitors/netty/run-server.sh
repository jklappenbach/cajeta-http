#!/usr/bin/env bash
# run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]
# JVM flags: -server -XX:+UseParallelGC -Xms256m (throughput GC, pre-sized heap; --enable-native-access
# only silences the JDK warning when netty loads its epoll .so; everything else is the
# JVM / Netty default: worker threads = 2 x cores, epoll transport when available, adaptive allocator).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_HOME="${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}"
[[ $# -ge 2 ]] || { echo "usage: run-server.sh <h1|h2c|tls> <port> [<cert.pem> <key.pem>]" >&2; exit 2; }
[[ -f "$HERE/build/classpath.txt" ]] || { echo "run-server.sh: run build.sh first" >&2; exit 1; }
CP="$HERE/build/classes:$(cat "$HERE/build/classpath.txt")"
exec "$JAVA_HOME/bin/java" -server -XX:+UseParallelGC -Xms256m --enable-native-access=ALL-UNNAMED -cp "$CP" Main "$@"
