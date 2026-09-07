#!/usr/bin/env bash
# Install the build toolchain on a Debian/Ubuntu host:
# native-image system deps, SDKMAN! and GraalVM CE 21.0.2.
#
# Usage: sudo -E scripts/install-toolchain.sh   (or run as root)
# Afterwards: source "$HOME/.sdkman/bin/sdkman-init.sh"
set -euo pipefail

GRAALVM_ID="${GRAALVM_ID:-21.0.2-graalce}"

sudo_cmd=()
if [[ "$(id -u)" -ne 0 ]]; then sudo_cmd=(sudo); fi

"${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
"${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential zlib1g-dev curl zip unzip

if [[ ! -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
  curl -s "https://get.sdkman.io?rcupdate=false" | bash
fi

set +u
# shellcheck disable=SC1091
source "$HOME/.sdkman/bin/sdkman-init.sh"
set -u

sdk install java "$GRAALVM_ID" < /dev/null || true
sdk use java "$GRAALVM_ID"

java -version
native-image --version
