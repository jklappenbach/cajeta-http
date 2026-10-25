#!/usr/bin/env bash
# Prints key=value versions, measured from the installed JDK and the pinned jar names.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_HOME="${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}"
jv="$("$JAVA_HOME/bin/java" -version 2>&1 | sed -n '1s/.*version "\([^"]*\)".*/\1/p')"
nv="unknown"
if [[ -f "$HERE/build/classpath.txt" ]]; then
  nv="$(tr ':' '\n' < "$HERE/build/classpath.txt" | sed -n 's#.*/netty-codec-http-\([^/]*\)\.jar$#\1#p' | head -1)"
fi
[[ -n "$nv" ]] || nv="unknown"
echo "language=java"
echo "language_version=$jv"
echo "server=netty $nv"
echo "h2=netty-codec-http2 $nv"
echo "ws=netty-codec-http $nv"
echo "sse=netty $nv"
echo "tls=jsse $jv"
echo "client=java.net.http $jv"
