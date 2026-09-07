#!/usr/bin/env bash
# Build a native sbe-tool binary from upstream SBE.
#
# Usage: scripts/build.sh [REF]
#
# Environment:
#   UPSTREAM_REPO  upstream git URL (default: aeron-io/simple-binary-encoding)
#   UPSTREAM_REF   ref to build when no positional REF is given (default: latest release tag)
#   UPSTREAM_COMMIT, UPSTREAM_VERSION
#                  when both are set, skip resolution and build exactly that commit
#                  under that version (used by CI to pin what the resolve job chose)
#   TARGET         platform label for the asset name (default: <os>-<arch>)
#   BUILD_DIR      scratch directory (default: ./build)
#   DIST_DIR       output directory (default: ./dist)
#
# Requires java (GraalVM), native-image, git and the native-image system deps.
#
# Pipeline:
#   1. fetch the upstream revision and run ./gradlew :sbe-all:jar
#   2. run sbe-all.jar on the JVM under the native-image tracing agent over a
#      corpus (every built-in target language, IR output and IR input, a
#      validation failure) to collect reflection and resource config; the
#      JVM outputs double as the reference for step 4
#   3. native-image with the collected config merged over config/native-image
#   4. run the same corpus with the native binary and diff against step 2
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/aeron-io/simple-binary-encoding.git}"
BUILD_DIR="${BUILD_DIR:-$root/build}"
DIST_DIR="${DIST_DIR:-$root/dist}"
export UPSTREAM_REPO

command -v native-image >/dev/null || { echo "native-image not on PATH" >&2; exit 1; }
command -v java >/dev/null || { echo "java not on PATH" >&2; exit 1; }

if [[ -n "${UPSTREAM_COMMIT:-}" && -n "${UPSTREAM_VERSION:-}" ]]; then
  echo "==> using pinned upstream revision"
  upstream_ref="${1:-${UPSTREAM_REF:-$UPSTREAM_COMMIT}}"
  upstream_commit="$UPSTREAM_COMMIT"
  upstream_version="$UPSTREAM_VERSION"
else
  echo "==> resolving upstream ref"
  eval "$("$here/resolve-upstream.sh" "${1:-${UPSTREAM_REF:-}}" | sed 's/^/upstream_/')"
fi
echo "    ref=$upstream_ref commit=$upstream_commit version=$upstream_version"

if [[ -z "${TARGET:-}" ]]; then
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in aarch64|arm64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; esac
  TARGET="${os}-${arch}"
fi

src="$BUILD_DIR/sbe"
work="$BUILD_DIR/native"
rm -rf "$src" "$work"
mkdir -p "$src" "$work" "$DIST_DIR"

echo "==> fetching $UPSTREAM_REPO @ $upstream_commit"
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 "$UPSTREAM_REPO" "$upstream_commit"
git -C "$src" checkout -q FETCH_HEAD

echo "==> building sbe-all.jar"
(cd "$src" && ./gradlew --no-daemon --console=plain -q :sbe-all:jar)
jar="$(find "$src/sbe-all/build/libs" -maxdepth 1 -name 'sbe-all-*.jar' \
  ! -name '*-sources.jar' ! -name '*-javadoc.jar' | head -n 1)"
[[ -n "$jar" ]] || { echo "sbe-all jar not found" >&2; exit 1; }
cp "$jar" "$work/sbe-all.jar"

# ---------------------------------------------------------------------------
# Corpus shared by the tracing-agent run and the native smoke test.
# ---------------------------------------------------------------------------
xsd="$src/sbe-tool/src/main/resources/fpl/sbe.xsd"
samples="$src/sbe-samples/src/main/resources"
tests="$src/sbe-tool/src/test/resources"
schemas=(
  "$samples/example-schema.xml"
  "$tests/json-printer-test-schema.xml"
  "$tests/composite-elements-schema.xml"
  "$tests/field-order-check-schema.xml"
)
languages=(Java C cpp golang rust)
# Agrona reaches jdk.internal.misc.Unsafe; the JVM and the native image both need this opened.
add_opens=(--add-opens java.base/jdk.internal.misc=ALL-UNNAMED)

bad_schema="$work/invalid-schema.xml"
printf '<?xml version="1.0"?><sbe:messageSchema xmlns:sbe="http://fixprotocol.io/2016/sbe" package="x" id="1" version="0"><bogus/></sbe:messageSchema>\n' > "$bad_schema"

# run_corpus <launcher...> -- <trailer...> -- <out-dir>
# Runs every corpus case as: <launcher> -D... <trailer> <inputs>.
# JVM:    launcher = java <jvm flags>, trailer = -jar sbe-all.jar
# native: launcher = ./sbe-tool,       trailer = (empty)
run_corpus() {
  local -a launcher=() trailer=()
  while [[ "$1" != "--" ]]; do launcher+=("$1"); shift; done
  shift
  while [[ "$1" != "--" ]]; do trailer+=("$1"); shift; done
  shift
  local out="$1"
  mkdir -p "$out"
  local lang
  for lang in "${languages[@]}"; do
    "${launcher[@]}" \
      -Dsbe.output.dir="$out/$lang" \
      -Dsbe.target.language="$lang" \
      -Dsbe.xinclude.aware=true \
      -Dsbe.validation.xsd="$xsd" \
      -Dsbe.validation.stop.on.error=true \
      -Dsbe.generate.precedence.checks=true \
      "${trailer[@]}" "${schemas[@]}" > "$out/$lang.log" 2>&1 || { cat "$out/$lang.log" >&2; echo "corpus: $lang failed" >&2; return 1; }
  done
  "${launcher[@]}" \
    -Dsbe.output.dir="$out/ir" -Dsbe.generate.ir=true -Dsbe.target.language=Java -Dsbe.xinclude.aware=true \
    "${trailer[@]}" "$samples/example-schema.xml" > "$out/ir.log" 2>&1 || { cat "$out/ir.log" >&2; echo "corpus: ir failed" >&2; return 1; }
  "${launcher[@]}" \
    -Dsbe.output.dir="$out/from-ir" -Dsbe.target.language=cpp \
    "${trailer[@]}" "$out/ir/example-schema.sbeir" > "$out/from-ir.log" 2>&1 || { cat "$out/from-ir.log" >&2; echo "corpus: from-ir failed" >&2; return 1; }
  # Validation failure path: must exit non-zero and print the XSD error message.
  if "${launcher[@]}" -Dsbe.output.dir="$out/invalid" -Dsbe.validation.xsd="$xsd" "${trailer[@]}" "$bad_schema" > "$out/invalid.log" 2>&1; then
    echo "corpus: invalid schema unexpectedly accepted" >&2; return 1
  fi
  grep -q 'cvc-complex-type' "$out/invalid.log" || { cat "$out/invalid.log" >&2; echo "corpus: invalid schema did not report an XSD error" >&2; return 1; }
}

echo "==> collecting native-image config with the tracing agent"
cfg="$work/native-image-config"
mkdir -p "$cfg"
cp "$root"/config/native-image/*.json "$cfg/"
run_corpus java "${add_opens[@]}" \
  "-agentlib:native-image-agent=config-merge-dir=$cfg" \
  -- -jar "$work/sbe-all.jar" -- "$work/reference"

echo "==> running native-image"
(cd "$work" && native-image \
  --no-fallback \
  -jar sbe-all.jar \
  -H:IncludeResources=".*\.xsd$" \
  -H:IncludeResources="golang/templates/.*" \
  -H:Name=sbe-tool \
  -H:ConfigurationFileDirectories="$cfg" \
  --initialize-at-build-time \
  --initialize-at-run-time=org.agrona.BufferUtil \
  "${add_opens[@]}")

echo "==> smoke testing the native binary against the JVM reference output"
run_corpus "$work/sbe-tool" -- -- "$work/native-out"
for d in "${languages[@]}" ir from-ir; do
  diff -r "$work/reference/$d" "$work/native-out/$d" > /dev/null \
    || { echo "native output for '$d' differs from the JVM reference" >&2; exit 1; }
done
echo "    native output matches JVM output for: ${languages[*]} ir from-ir"

asset="sbe-tool-${upstream_version}-${TARGET}"
cp "$work/sbe-tool" "$DIST_DIR/$asset"
chmod +x "$DIST_DIR/$asset"
(cd "$DIST_DIR" && sha256sum "$asset" > "$asset.sha256")
printf '%s\n' "$upstream_version" > "$DIST_DIR/VERSION"
printf '%s\n' "$upstream_commit" > "$DIST_DIR/COMMIT"

echo "==> done"
ls -l "$DIST_DIR"
