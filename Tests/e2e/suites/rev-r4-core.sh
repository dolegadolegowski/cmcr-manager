# shellcheck shell=bash
# Review fixes of the core (AUDIT REV, group R4-core): the remote wrapper reports how the script ended, so a command's
# own exit code 255 (also `exit -1`, with nothing on stderr) is told apart from a session whose shared connection died –
# also when the command wrote to stderr before the break.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folder, so later
# suites see the original configuration.

R4="$WORK/cfg-rev-r4"
mkdir -p "$R4"
cp "$WORK/config/settings.json" "$WORK/config/hosts.json" "$R4/"
r4() { CMCR_CONFIG_DIR="$R4" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# r4_close_masters – ends the shared ssh connections, so the next command opens its own.
r4_close_masters() {
  local mux
  for mux in "$CMCR_SSH_CONTROL_DIR"/*; do
    [ -S "$mux" ] && ssh -o ControlPath="$mux" -O exit cmcr-e2e >/dev/null 2>&1
  done
}
# r4_wait_for FILE NEEDLE – polls a growing file for up to 15 s.
r4_wait_for() {
  local i
  for i in $(seq 1 150); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}

section "REV R4 rdzeń – exec: własny kod 255 polecenia bez tekstu na stderr (AUDIT REV-53)"
out="$(r4 exec 'exit 255' 1)"; code=$?
expect_code "exec 'exit 255': kod 255 polecenia" "$code" 255 "$out"
expect_not "exec 'exit 255': to nie zerwane połączenie" "$out" "Połączenie zostało przerwane"
expect "exec 'exit 255': kod polecenia w komunikacie" "$out" "Polecenie zakończone kodem 255."
out="$(r4 exec 'echo wynik-r4; exit -1' 1)"; code=$?
expect_code "exec 'exit -1': kod 255 polecenia" "$code" 255 "$out"
expect "exec 'exit -1': wyjście polecenia" "$out" "wynik-r4"
expect_not "exec 'exit -1': to nie zerwane połączenie" "$out" "Połączenie zostało przerwane"
out="$(r4 exec 'exit 255' 1 --root)"; code=$?
expect_code "exec --root 'exit 255': kod 255 polecenia" "$code" 255 "$out"
out="$(r4 __run-job 'echo wynik-zadania; exit 255' 1)"
expect "zadanie 'exit 255': komputer online, kod polecenia" "$out" "wynik-zadania" "exit=255" "started=true" "reach=online"
# The end marker comes right after the command's last line, which may lack a newline: it is not shown either way.
out="$(r4 exec 'echo bez-nowej-linii-r4 | tr -d "\n" >&2; exit 3' 1)"; code=$?
expect_code "exec, stderr bez końca linii: kod 3" "$code" 3 "$out"
expect "exec, stderr bez końca linii: tekst polecenia zachowany" "$out" "bez-nowej-linii-r4"
expect_not "exec, stderr bez końca linii: brak znacznika końca" "$out" "CMCR:SESSION"
out="$(r4 __run-job 'printf "bez-nowej-linii-zadania" >&2; exit 4' 1)"
expect "zadanie, stderr bez końca linii: tekst i kod" "$out" "bez-nowej-linii-zadania" "exit=4" "reach=online"
expect_not "zadanie, stderr bez końca linii: brak znacznika końca" "$out" "CMCR:SESSION"
out="$(r4 exec 'echo zwykle-r4; echo blad-r4 >&2' 1)"; code=$?
expect_code "exec udany: kod 0" "$code" 0 "$out"
expect "exec udany: wyjście i błędy polecenia" "$out" "zwykle-r4" "blad-r4"
expect_not "exec udany: brak znaczników sesji" "$out" "CMCR:SESSION"
expect_not "actions.log: brak znaczników sesji" "$(cat "$R4/actions.log" 2>/dev/null)" "CMCR:SESSION"

section "REV R4 rdzeń – exec: zerwane połączenie po tekście na stderr to błąd połączenia (AUDIT REV-57)"
r4_close_masters
rm -f "$WORK/rev-r4-exec.out" "$WORK/rev-r4-exec-done"
CMCR_CONFIG_DIR="$R4" "$CTL" exec "echo postęp-r4 >&2; sleep 4; touch '$WORK/rev-r4-exec-done'" 1 >"$WORK/rev-r4-exec.out" 2>&1 &
r4_pid=$!
r4_wait_for "$WORK/rev-r4-exec.out" "postęp-r4"
r4_sock="$(find "$CMCR_SSH_CONTROL_DIR" -type s 2>/dev/null | head -n 1)"
if [ -n "$r4_sock" ]; then
  # The shared connection goes away under the running command (as when the network drops it).
  ssh -S "$r4_sock" -O exit cmcr-e2e >/dev/null 2>&1
  wait "$r4_pid"
  code=$?
  out="$(cat "$WORK/rev-r4-exec.out")"
  expect "exec, stderr i zerwane połączenie: błąd połączenia" "$out" "postęp-r4" "Połączenie zostało przerwane"
  expect_not "exec, stderr i zerwane połączenie: nie kod polecenia" "$out" "Polecenie zakończone kodem"
  expect_code "exec, stderr i zerwane połączenie: kod 1 (nie 255)" "$code" 1 "$out"
else
  kill "$r4_pid" 2>/dev/null
  wait "$r4_pid" 2>/dev/null
  fail "exec, stderr i zerwane połączenie: brak gniazda wspólnego połączenia" "$(ls -la "$CMCR_SSH_CONTROL_DIR" 2>&1)"
fi
# The command goes on on the Mac: let it end before the next suites count the test sshd's sessions.
for _ in $(seq 1 100); do [ -e "$WORK/rev-r4-exec-done" ] && break; sleep 0.1; done
[ -e "$WORK/rev-r4-exec-done" ] && pass "exec, stderr i zerwane połączenie: polecenie dokończone na komputerze" \
  || fail "exec, stderr i zerwane połączenie: polecenie nie dokończyło się" "$(cat "$WORK/rev-r4-exec.out")"

# The same for a job as the app runs it (__run-job prints the classification).
rm -f "$WORK/rev-r4-job.out" "$WORK/rev-r4-job-done"
CMCR_CONFIG_DIR="$R4" "$CTL" __run-job "echo postęp-zadania >&2; sleep 4; touch '$WORK/rev-r4-job-done'" 1 \
  >"$WORK/rev-r4-job.out" 2>&1 &
r4_pid=$!
r4_wait_for "$WORK/rev-r4-job.out" "postęp-zadania"
r4_sock="$(find "$CMCR_SSH_CONTROL_DIR" -type s 2>/dev/null | head -n 1)"
if [ -n "$r4_sock" ]; then
  ssh -S "$r4_sock" -O exit cmcr-e2e >/dev/null 2>&1
  wait "$r4_pid"
  out="$(cat "$WORK/rev-r4-job.out")"
  expect "zadanie, stderr i zerwane połączenie: błąd połączenia" "$out" "exit=255" "started=true" "reach=error"
else
  kill "$r4_pid" 2>/dev/null
  wait "$r4_pid" 2>/dev/null
  fail "zadanie, stderr i zerwane połączenie: brak gniazda wspólnego połączenia" "$(ls -la "$CMCR_SSH_CONTROL_DIR" 2>&1)"
fi
for _ in $(seq 1 100); do [ -e "$WORK/rev-r4-job-done" ] && break; sleep 0.1; done
