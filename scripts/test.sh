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
# The app's model tests (Tests/CMCRManagerTests) get a configuration folder, Keychain service, password and
# update cache of their own; without them they are skipped, so they never touch the user's real ones.
UNIT_HOME="$(mktemp -d /tmp/cmcr-unit.XXXXXX)"
trap 'rm -rf "$UNIT_HOME"' EXIT
CMCR_CONFIG_DIR="$UNIT_HOME/config" CMCR_KEYCHAIN_SERVICE="pl.cmcr.manager.unit-tests" \
  CMCR_PASSWORD="unit-test-password" CMCR_UPDATE_STATE_DIR="$UNIT_HOME/update" CMCR_SSH_CONTROL_DIR="$UNIT_HOME/mux" \
  swift test ${EXTRA[@]+"${EXTRA[@]}"}
if [ "${1:-}" != "--unit" ]; then
  CMCR_E2E_NOBUILD=0 Tests/e2e/run.sh
fi
