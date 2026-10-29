# shellcheck shell=bash
# Review fixes of the core (AUDIT REV, group R5-core): the wrapper's end marker travels on stderr, and sshd sends it
# ahead of the stdout it still holds (one stderr packet after each stdout packet, up to a window of about 2 MB of
# stdout). A connection that broke off after the marker, before the end of the output, ended with ssh's 255, which the
# marker's code replaced: `exec` returned 0 without a word and a job ended „OK” with its output cut off. ssh's 255 is
# now a broken session unless the marker says 255 as well – the command's own 255 (AUDIT REV-60).
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folders, so later
# suites see the original configuration.

R5="$WORK/cfg-rev-r5"
mkdir -p "$R5"
cp "$WORK/config/settings.json" "$WORK/config/hosts.json" "$R5/"
# r5_close_masters – ends the shared ssh connections, so the next command opens its own.
r5_close_masters() {
  local mux
  for mux in "$CMCR_SSH_CONTROL_DIR"/*; do
    [ -S "$mux" ] && ssh -o ControlPath="$mux" -O exit cmcr-e2e >/dev/null 2>&1
  done
}
# r5_wait_for FILE NEEDLE – polls a growing file for up to 15 s.
r5_wait_for() {
  local i
  for i in $(seq 1 150); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
# r5_wait_file FILE – waits up to 15 s for a file (the remote command's end, before the next check or suite).
r5_wait_file() {
  local i
  for i in $(seq 1 150); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}
# r5_count FILE – how many payload bytes ("x") the file holds.
r5_count() { tr -cd x <"$1" 2>/dev/null | wc -c | tr -d ' '; }

section "REV R5 rdzeń – linia znacznika końca od polecenia, potem zerwane połączenie: błąd połączenia (AUDIT REV-60)"
# The command's own stderr holds a line like the wrapper's end marker (tar quoting a student's file name, a log being
# shown), and then the shared connection goes away under the running command (as when the network drops it).
r5_close_masters
rm -f "$WORK/rev-r5-exec.out" "$WORK/rev-r5-exec-done"
CMCR_CONFIG_DIR="$R5" "$CTL" exec "echo 'CMCR:SESSION-ENDED 0' >&2; echo postęp-r5 >&2; sleep 3; touch '$WORK/rev-r5-exec-done'" 1 \
  >"$WORK/rev-r5-exec.out" 2>&1 &
r5_pid=$!
r5_wait_for "$WORK/rev-r5-exec.out" "postęp-r5"
r5_sock="$(find "$CMCR_SSH_CONTROL_DIR" -type s 2>/dev/null | head -n 1)"
if [ -n "$r5_sock" ]; then
  ssh -S "$r5_sock" -O exit cmcr-e2e >/dev/null 2>&1
  wait "$r5_pid"
  code=$?
  out="$(cat "$WORK/rev-r5-exec.out")"
  expect "exec, znacznik od polecenia i zerwane połączenie: błąd połączenia" "$out" "postęp-r5" "Połączenie zostało przerwane"
  expect_not "exec, znacznik od polecenia i zerwane połączenie: nie kod polecenia" "$out" "Polecenie zakończone kodem"
  expect_code "exec, znacznik od polecenia i zerwane połączenie: kod 1 (nie 0)" "$code" 1 "$out"
else
  kill "$r5_pid" 2>/dev/null
  wait "$r5_pid" 2>/dev/null
  fail "exec, znacznik od polecenia i zerwane połączenie: brak gniazda wspólnego połączenia" "$(ls -la "$CMCR_SSH_CONTROL_DIR" 2>&1)"
fi
# The command goes on on the Mac: let it end before the next checks count the test sshd's sessions.
r5_wait_file "$WORK/rev-r5-exec-done" || fail "exec, znacznik od polecenia: polecenie nie dokończyło się" "$(cat "$WORK/rev-r5-exec.out")"

# The same for a job as the app runs it (__run-job prints the classification).
rm -f "$WORK/rev-r5-job.out" "$WORK/rev-r5-job-done"
CMCR_CONFIG_DIR="$R5" "$CTL" __run-job "echo 'CMCR:SESSION-ENDED 0' >&2; echo postęp-zadania-r5 >&2; sleep 3; touch '$WORK/rev-r5-job-done'" 1 \
  >"$WORK/rev-r5-job.out" 2>&1 &
r5_pid=$!
r5_wait_for "$WORK/rev-r5-job.out" "postęp-zadania-r5"
r5_sock="$(find "$CMCR_SSH_CONTROL_DIR" -type s 2>/dev/null | head -n 1)"
if [ -n "$r5_sock" ]; then
  ssh -S "$r5_sock" -O exit cmcr-e2e >/dev/null 2>&1
  wait "$r5_pid"
  out="$(cat "$WORK/rev-r5-job.out")"
  expect "zadanie, znacznik od polecenia i zerwane połączenie: błąd połączenia" "$out" "exit=255" "started=true" "reach=error"
else
  kill "$r5_pid" 2>/dev/null
  wait "$r5_pid" 2>/dev/null
  fail "zadanie, znacznik od polecenia i zerwane połączenie: brak gniazda wspólnego połączenia" "$(ls -la "$CMCR_SSH_CONTROL_DIR" 2>&1)"
fi
r5_wait_file "$WORK/rev-r5-job-done" || fail "zadanie, znacznik od polecenia: polecenie nie dokończyło się" "$(cat "$WORK/rev-r5-job.out")"

section "REV R5 rdzeń – wolne łącze zerwane po znaczniku końca, przed końcem wyjścia: błąd połączenia (AUDIT REV-60)"
# ssh reaches the test sshd through a ProxyCommand that passes sshd's data on at 1 MB/s (the link is the bottleneck, so
# sshd holds the command's stdout and the end marker overtakes it). With $WORK/rev-r5-proxy.cut (a byte count) it then
# closes the link once it has passed that many bytes; it writes how many it passed to $WORK/rev-r5-proxy.count.
R5P="$WORK/cfg-rev-r5-proxy"
mkdir -p "$R5P"
cp "$WORK/config/hosts.json" "$R5P/"
cat > "$WORK/rev-r5-proxy.py" <<'PY'
import os, select, socket, sys, time
host, port, rate, control = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
try:
    with open(control + ".cut") as f: cut = int(f.read())
except OSError:
    cut = 1 << 62
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
s.connect((host, port))
fin, fout = sys.stdin.fileno(), sys.stdout.fileno()
passed, start, reading = 0, time.monotonic(), True
def note():
    with open(control + ".count", "w") as f: f.write(str(passed))
while passed < cut:
    allowed = min(65536, int(rate * (time.monotonic() - start)) - passed, cut - passed)
    ready = select.select(([fin] if reading else []) + ([s] if allowed > 0 else []), [], [], 0.01)[0]
    if fin in ready:
        data = os.read(fin, 65536)
        if data: s.sendall(data)
        else: reading = False; s.shutdown(socket.SHUT_WR)
    if s in ready:
        data = s.recv(allowed)
        if not data: break
        view = memoryview(data)
        while view: view = view[os.write(fout, view):]
        passed += len(data)
        note()
note()
s.close()
PY
python3 - "$WORK/config/settings.json" "$R5P/settings.json" "$WORK" "$(command -v python3)" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
w, py = sys.argv[3], sys.argv[4]
s["extraSSHOptions"] = f"ProxyCommand={py} {w}/rev-r5-proxy.py %h %p 1000000 {w}/rev-r5-proxy\nUserKnownHostsFile={w}/known_hosts"
# One connection per command, so each run gets its own proxy and byte count.
s["reuseConnections"] = False
json.dump(s, open(sys.argv[2], "w"))
PY
r5p() { CMCR_CONFIG_DIR="$R5P" "$CTL" "$@"; }
r5_size=4000000
r5_cmd="head -c $r5_size /dev/zero | tr '\\0' x; touch '$WORK/rev-r5-proxy.done'"
rm -f "$WORK/rev-r5-proxy.cut" "$WORK/rev-r5-proxy.count" "$WORK/rev-r5-proxy.done"
r5p exec "$r5_cmd" 1 >"$WORK/rev-r5-full.out" 2>"$WORK/rev-r5-full.err"; code=$?
r5_total="$(cat "$WORK/rev-r5-proxy.count" 2>/dev/null)"
expect_code "wolne łącze bez zerwania: kod 0" "$code" 0 "$(cat "$WORK/rev-r5-full.err")"
expect_code "wolne łącze bez zerwania: całe wyjście" "$(r5_count "$WORK/rev-r5-full.out")" "$r5_size" "$(cat "$WORK/rev-r5-full.err")"
if [ -n "$r5_total" ] && [ "$r5_total" -gt "$r5_size" ]; then
  # The link drops 128 KiB before the end of what the undisturbed run received: after the end marker, before the end of
  # the output.
  echo $((r5_total - 131072)) > "$WORK/rev-r5-proxy.cut"
  rm -f "$WORK/rev-r5-proxy.done"
  r5p exec "$r5_cmd" 1 >"$WORK/rev-r5-cut.out" 2>"$WORK/rev-r5-cut.err"; code=$?
  err="$(cat "$WORK/rev-r5-cut.err")"
  got="$(r5_count "$WORK/rev-r5-cut.out")"
  [ "$got" -lt "$r5_size" ] && pass "exec, zerwane łącze: wyjście ucięte ($got z $r5_size B)" \
    || fail "exec, zerwane łącze: łącze nie zostało zerwane przed końcem wyjścia ($got B)" "$err"
  expect "exec, zerwane łącze po znaczniku końca: błąd połączenia" "$err" "Połączenie zostało przerwane"
  expect_not "exec, zerwane łącze po znaczniku końca: nie kod polecenia" "$err" "Polecenie zakończone kodem"
  expect_code "exec, zerwane łącze po znaczniku końca: kod 1 (nie 0)" "$code" 1 "$err"
  r5_wait_file "$WORK/rev-r5-proxy.done"

  # A job as the app runs it, with its output in memory and in a file (the app's path for large output).
  rm -f "$WORK/rev-r5-proxy.done"
  r5p __run-job "$r5_cmd" 1 >"$WORK/rev-r5-job-cut.out" 2>&1
  expect "zadanie, zerwane łącze po znaczniku końca: błąd połączenia" "$(grep -ao "CMCR:RESULT.*" "$WORK/rev-r5-job-cut.out")" \
    "exit=255" "started=true" "reach=error"
  r5_wait_file "$WORK/rev-r5-proxy.done"
  rm -f "$WORK/rev-r5-proxy.done" "$WORK/rev-r5-job-cut.file"
  r5p __run-job "$r5_cmd" 1 --stdout "$WORK/rev-r5-job-cut.file" >"$WORK/rev-r5-job-cut.out" 2>&1
  got="$(r5_count "$WORK/rev-r5-job-cut.file")"
  expect "zadanie z wyjściem w pliku, zerwane łącze: błąd połączenia, nie „OK”" "$(cat "$WORK/rev-r5-job-cut.out")" \
    "exit=255" "started=true" "reach=error"
  [ "$got" -lt "$r5_size" ] && pass "zadanie z wyjściem w pliku, zerwane łącze: plik ucięty ($got z $r5_size B)" \
    || fail "zadanie z wyjściem w pliku: łącze nie zostało zerwane przed końcem wyjścia ($got B)"
  r5_wait_file "$WORK/rev-r5-proxy.done"
else
  fail "wolne łącze: pośrednik nie policzył przesłanych bajtów (${r5_total:-brak})" "$(cat "$WORK/rev-r5-full.err")"
fi
rm -f "$WORK/rev-r5-proxy.cut"
