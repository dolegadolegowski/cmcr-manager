#!/bin/bash
# Runs the unit tests (Swift Testing) and the end-to-end suite.
#   scripts/test.sh          – everything
#   scripts/test.sh --unit   – unit tests only
set -euo pipefail
cd "$(dirname "$0")/.."
EXTRA=()
# Command Line Tools ship the Testing macro plugin but SwiftPM does not find it on its own.
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if ! xcodebuild -version >/dev/null 2>&1 && [ -d "$PLUGINS" ]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
fi
swift test ${EXTRA[@]+"${EXTRA[@]}"}
if [ "${1:-}" != "--unit" ]; then
  CMCR_E2E_NOBUILD=0 Tests/e2e/run.sh
fi
