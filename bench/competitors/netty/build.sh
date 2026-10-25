#!/usr/bin/env bash
# Builds the Netty competitor: verifies every pinned jar (path + sha256 from pins.tsv), then javac's
# src/*.java into build/classes and writes build/classpath.txt for the run-*.sh scripts.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPETITORS="${CAJETA_COMPETITORS:-$HERE/../../../../cajeta/bench/competitors}"
COMPETITORS="$(cd "$COMPETITORS" && pwd)"
PINS="$COMPETITORS/pins.tsv"
JARS="$COMPETITORS/third_party/java"
JAVA_HOME="${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}"
JAVAC="$JAVA_HOME/bin/javac"

[[ -f "$PINS" ]] || { echo "build.sh: missing $PINS" >&2; exit 1; }
[[ -x "$JAVAC" ]] || { echo "build.sh: missing javac at $JAVAC" >&2; exit 1; }

mkdir -p "$HERE/build"
cp_entries=()
while IFS= read -r item; do
  [[ -z "$item" || "$item" == \#* ]] && continue
  line="$(awk -F'\t' -v k="$item" '$1==k && $3=="jar" {print; exit}' "$PINS")"
  [[ -n "$line" ]] || { echo "build.sh: $item not pinned in $PINS" >&2; exit 1; }
  rel="$(cut -f4 <<<"$line")"; want="$(cut -f6 <<<"$line")"
  jar="$JARS/$rel"
  [[ -f "$jar" ]] || { echo "build.sh: missing jar $jar" >&2; exit 1; }
  got="$(sha256sum "$jar" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || { echo "build.sh: sha256 mismatch for $jar: $got != $want" >&2; exit 1; }
  echo "build.sh: ok $item $(cut -f5 <<<"$line")" >&2
  cp_entries+=("$jar")
done < "$HERE/classpath"

CP="$(IFS=:; echo "${cp_entries[*]}")"
rm -rf "$HERE/build/classes"
mkdir -p "$HERE/build/classes"
echo "build.sh: javac $("$JAVAC" -version 2>&1)" >&2
"$JAVAC" --release 25 -nowarn -Xlint:-options -d "$HERE/build/classes" -cp "$CP" "$HERE"/src/*.java
printf '%s\n' "$CP" > "$HERE/build/classpath.txt"
echo "build.sh: done -> $HERE/build/classes" >&2
