# shellcheck shell=bash
# Review findings of the CMCRCore package, group G1 (REV-xx): checks through the real ssh transport and cmcrctl.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT $ROOT come from there).

section "Zerwane wspólne połączenie zadania, które ruszyło (AUDIT REV-02)"
# With connection sharing (the default) a session ends with code 255 and nothing on stderr when its shared connection
# dies (Wi‑Fi reset, keepalive timeout): it was reported as the command's own exit code 255 on an online Mac, while
# the job keeps running on the iMac.
RG1="$WORK/rev-g1"
mkdir -p "$RG1"
rm -f "$RG1/job.out" "$RG1/dokonczone"
"$CTL" __run-job "echo ruszyło; sleep 4; touch '$RG1/dokonczone'" 1 >"$RG1/job.out" 2>&1 &
rg1_pid=$!
rg1_wait() { # rg1_wait SECONDS COMMAND… – polls until the command succeeds
  local i limit=$(($1 * 10)); shift
  for i in $(seq 1 "$limit"); do "$@" && return 0; sleep 0.1; done
  return 1
}
rg1_running() { grep -q "ruszyło" "$RG1/job.out" 2>/dev/null; }
rg1_ended() { ! kill -0 "$rg1_pid" 2>/dev/null; }
if rg1_wait 15 rg1_running; then
  rg1_sock="$(find "$WORK/mux" -type s 2>/dev/null | head -n 1)"
  if [ -n "$rg1_sock" ]; then
    # The shared connection goes away under the running session (as when the network drops it).
    ssh -S "$rg1_sock" -O exit cmcr-e2e >/dev/null 2>&1
    rg1_wait 15 rg1_ended || kill "$rg1_pid" 2>/dev/null
    wait "$rg1_pid" 2>/dev/null
    out="$(cat "$RG1/job.out")"
    expect "zerwane połączenie po starcie: zgłoszone jako błąd połączenia, nie „kod 255” na komputerze online" "$out" \
      "exit=255" "started=true" "reach=error"
    rg1_wait 15 test -e "$RG1/dokonczone" \
      && pass "zerwane połączenie po starcie: polecenie dokończone na komputerze" \
      || fail "zerwane połączenie po starcie: polecenie nie dokończyło się na komputerze" "$(cat "$RG1/job.out")"
  else
    kill "$rg1_pid" 2>/dev/null; wait "$rg1_pid" 2>/dev/null
    fail "zerwane połączenie po starcie: brak gniazda wspólnego połączenia w $WORK/mux" "$(ls -la "$WORK/mux" 2>&1)"
  fi
else
  kill "$rg1_pid" 2>/dev/null; wait "$rg1_pid" 2>/dev/null
  fail "zerwane połączenie po starcie: zadanie nie ruszyło" "$(cat "$RG1/job.out")"
fi
