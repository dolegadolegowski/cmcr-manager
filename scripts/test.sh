#!/bin/bash
# Runs the unit tests (Swift Testing) and the end-to-end suite.
#   scripts/test.sh          – everything
#   scripts/test.sh --unit   – unit tests only
# CMCR_TEST_TIMEOUT=<seconds> (default 720) limits the unit tests: a hung test is reported and killed (status 124).
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

# Watchdog: a hung test must cost minutes, not the whole CI job. After CMCR_TEST_TIMEOUT seconds (default 720 = 12 min)
# the tests that started and have not finished, and what the test processes are doing, are printed, and the tests
# are killed (exit status 124). Plain bash 3.2: no timeout(1), no coproc, no wait -n.
LIMIT="${CMCR_TEST_TIMEOUT:-720}"
LOG="$UNIT_HOME/swift-test.log"

descendants() { # pids of all children, grandchildren, … of $1
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

report_hang() { # $1: pid of the test job
  echo "::error::swift test przekroczył ${LIMIT} s – przerywam (prawdopodobnie zawieszony test)"
  if [ -s "$LOG" ]; then
    echo "--- testy rozpoczęte i nieukończone (według wyjścia swift test) ---"
    awk '
      /◇ Test .* started\.$/ { n = $0; sub(/^.*◇ Test /, "", n); sub(/ started\.$/, "", n); open[n] = 1 }
      /(✔|✘) Test .* (passed|failed)/ { n = $0; sub(/^.*(✔|✘) Test /, "", n); sub(/ (passed|failed) after.*$/, "", n); delete open[n] }
      END { for (n in open) print "  " n }
    ' "$LOG" | sort | head -50
  fi
  echo "--- procesy testów ---"
  local pids pid
  pids="$(descendants "$1" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  [ -n "$pids" ] && ps -o pid=,ppid=,stat=,etime=,command= -p $(echo $pids | tr ' ' ',') 2>/dev/null | cut -c1-200
  for pid in $pids; do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
      *swiftpm-testing-helper*|*xctest*)
        echo "--- stos wątków $pid (sample, 3 s) ---"
        sample "$pid" 3 2>/dev/null | grep -E "^ +[0-9]+ Thread_|Tests\)|Tests\.|\+ +[0-9]+ [^ ]+ +\(in (Foundation|CoreFoundation)\)" | head -40 || true ;;
    esac
  done
}

kill_tree() { # $1: pid – the parent first, so that nothing it would do after its children are gone happens
  local pid kids
  kids="$(descendants "$1")"
  kill -KILL "$1" 2>/dev/null
  for pid in $kids; do kill -CONT "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; done
  return 0
}

run_swift_test() {
  # With a terminal the output stays as it is; without one (CI) it is also kept for the report above.
  if [ -t 1 ]; then
    CMCR_CONFIG_DIR="$UNIT_HOME/config" CMCR_KEYCHAIN_SERVICE="pl.cmcr.manager.unit-tests" \
      CMCR_PASSWORD="unit-test-password" CMCR_UPDATE_STATE_DIR="$UNIT_HOME/update" CMCR_SSH_CONTROL_DIR="$UNIT_HOME/mux" \
      swift test ${EXTRA[@]+"${EXTRA[@]}"}
  else
    CMCR_CONFIG_DIR="$UNIT_HOME/config" CMCR_KEYCHAIN_SERVICE="pl.cmcr.manager.unit-tests" \
      CMCR_PASSWORD="unit-test-password" CMCR_UPDATE_STATE_DIR="$UNIT_HOME/update" CMCR_SSH_CONTROL_DIR="$UNIT_HOME/mux" \
      swift test ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | tee "$LOG"
  fi
}

run_swift_test &
TEST_JOB=$!
( sleep "$LIMIT"; touch "$UNIT_HOME/timed-out"; report_hang "$TEST_JOB"; kill_tree "$TEST_JOB" ) &
WATCHDOG=$!
set +e
wait "$TEST_JOB"
STATUS=$?
set -e
# Quiet the watchdog (and its sleep) once the tests are over.
kill_tree "$WATCHDOG"
wait "$WATCHDOG" 2>/dev/null || true
if [ -e "$UNIT_HOME/timed-out" ]; then exit 124; fi
if [ "$STATUS" -ne 0 ]; then exit "$STATUS"; fi
if [ "${1:-}" != "--unit" ]; then
  CMCR_E2E_NOBUILD=0 Tests/e2e/run.sh
fi
