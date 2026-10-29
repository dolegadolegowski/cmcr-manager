# shellcheck shell=bash
# Review fixes of cmcrctl (AUDIT REV, group R3-cli): Ctrl-C while install or lesson start packs its files, the order of
# the classroom.json warning and the „Wykonać na wszystkich?” question in `lesson`, the exit code of `exec` after a
# broken connection, and renames whose new .local name another renamed Mac still has (a renumbering chain or a swap).
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT come from there). Own config folder, so later
# suites see the original configuration.

R3="$WORK/cfg-rev-r3"
mkdir -p "$R3"
cp "$WORK/config/settings.json" "$R3/"
cat > "$R3/hosts.json" <<EOF
[
 {"id":"b1111111-1111-1111-1111-111111111111","name":"imac01","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"b2222222-2222-2222-2222-222222222222","name":"imac02","address":"127.0.0.1","user":"$ME","port":$PORT},
 {"id":"b9999999-9999-9999-9999-999999999999","name":"imac09","address":"imac09.cmcr-e2e.invalid","user":"imac09","port":22}
]
EOF
r3() { CMCR_CONFIG_DIR="$R3" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" 2>&1; }
# r3_before NAME OUTPUT FIRST SECOND – both lines are there, FIRST above SECOND.
r3_before() {
  local a b
  a="$(printf '%s\n' "$2" | grep -nF -- "$3" | head -n 1 | cut -d: -f1)"
  b="$(printf '%s\n' "$2" | grep -nF -- "$4" | head -n 1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass "$1"; else fail "$1 („$3” przed „$4”)" "$2"; fi
}
# r3_close_masters – ends the shared ssh connections, so the next command opens its own.
r3_close_masters() {
  local mux
  for mux in "$CMCR_SSH_CONTROL_DIR"/*; do
    [ -S "$mux" ] && ssh -o ControlPath="$mux" -O exit cmcr-e2e >/dev/null 2>&1
  done
}

section "REV R3 cmcrctl – przygotowanie"
out="$(r3 list)"
expect "r3: lista komputerów" "$out" "imac01" "imac02" "imac09"

section "REV R3 cmcrctl – Ctrl-C w czasie pakowania plików (install, lesson start) (AUDIT REV-44)"
# A big folder: 8 clones of one 256 MB file (APFS clones take no extra disk space, but tar reads and writes every one).
r3_big() { # r3_big DIR
  mkdir -p "$1"
  dd if=/dev/zero of="$1/dane-0" bs=1048576 count=256 2>/dev/null
  local i
  for i in 1 2 3 4 5 6 7; do cp -c "$1/dane-0" "$1/dane-$i" 2>/dev/null || cp "$1/dane-0" "$1/dane-$i"; done
}
# r3_pack_interrupt FOLDER ARGS… – runs cmcrctl ARGS in its own process group and waits (at most 20 s) until its tar
# packs from $WORK/FOLDER (matched by name: cmcrctl may pass /private/tmp for /tmp). tar is then frozen (SIGSTOP – a
# fast disk must not finish it first), the group gets SIGINT, as Ctrl-C in a terminal sends it, and tar goes on half a
# second later. tar has a process group of its own, so the SIGINT does not reach it. (Frozen, it does not outlive a
# cmcrctl killed by SIGINT either: a stopped process whose process group is orphaned gets SIGHUP from the system – the
# archive written so far stays.) Sets R3_CODE, R3_OUT, R3_TAR (tar's pid) and R3_ARCHIVE (the archive tar writes).
r3_pack_interrupt() {
  local folder="$1" pid _
  shift
  R3_TAR=""
  R3_ARCHIVE=""
  set -m
  CMCR_CONFIG_DIR="$R3" CMCR_PASSWORD="$PASSWORD" "$CTL" "$@" > "$WORK/rev-r3-int.out" 2>&1 </dev/null &
  pid=$!
  set +m
  for _ in $(seq 1 400); do
    R3_TAR="$(pgrep -f -- "^/usr/bin/tar -cf .*cmcr-payload-.* -C .*/$(basename "$WORK")/$folder " | head -n 1)"
    [ -n "$R3_TAR" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if [ -n "$R3_TAR" ]; then
    kill -STOP "$R3_TAR"
    R3_ARCHIVE="$(ps -o args= -p "$R3_TAR" | sed -n 's|^/usr/bin/tar -cf \([^ ]*\) .*|\1|p')"
    kill -INT -- "-$pid"
    sleep 0.5
    kill -CONT "$R3_TAR" 2>/dev/null
  else
    kill -INT -- "-$pid" 2>/dev/null
  fi
  wait "$pid"
  R3_CODE=$?
  R3_OUT="$(cat "$WORK/rev-r3-int.out")"
}
# r3_pack_checks LABEL MESSAGE – after r3_pack_interrupt: cmcrctl ended with 130 and MESSAGE only after tar, and no
# archive is left.
r3_pack_checks() {
  local label="$1" message="$2"
  if [ -z "$R3_TAR" ]; then
    fail "$label: tar nie wystartował (lub skończył przed Ctrl-C)" "$R3_OUT"
    return
  fi
  expect_code "$label, Ctrl-C: kod 130" "$R3_CODE" 130 "$R3_OUT"
  expect "$label, Ctrl-C: przerwano pakowanie" "$R3_OUT" "▸ Przerywanie – zatrzymywanie pakowania plików" "$message"
  if kill -0 "$R3_TAR" 2>/dev/null; then
    fail "$label, Ctrl-C: tar działa dalej po zakończeniu cmcrctl" "$(ps -o pid,ppid,args= -p "$R3_TAR")"
    kill -KILL "$R3_TAR" 2>/dev/null
  else
    pass "$label, Ctrl-C: tar zatrzymany razem z cmcrctl"
  fi
  if [ -n "$R3_ARCHIVE" ] && [ -e "$R3_ARCHIVE" ]; then
    fail "$label, Ctrl-C: archiwum zostało w katalogu tymczasowym" "$(ls -la "$R3_ARCHIVE")"
  else
    pass "$label, Ctrl-C: archiwum usunięte"
  fi
  [ -n "$R3_ARCHIVE" ] && rm -f "$R3_ARCHIVE"
}
r3_big "$WORK/rev-r3-pack/rev-r3-big.app"
clear_fakelog
r3_pack_interrupt rev-r3-pack install "$WORK/rev-r3-pack/rev-r3-big.app" 1 --allow-unsigned
r3_pack_checks "install" "✘ Przerwano pakowanie plików. Na komputerach nic nie zostało zmienione."
expect_not "install, Ctrl-C: nic nie uruchomiono na komputerze" "$R3_OUT" "imac01:"
[ ! -e "$WORK/Applications/rev-r3-big.app" ] && pass "install, Ctrl-C: aplikacja nie zainstalowana" \
  || fail "install, Ctrl-C: aplikacja zainstalowana mimo przerwania" "$(ls -la "$WORK/Applications")"
rm -rf "$WORK/Applications/rev-r3-big.app"
mv "$WORK/rev-r3-pack/rev-r3-big.app" "$WORK/rev-r3-materials-big"
mkdir -p "$WORK/rev-r3-materials"
mv "$WORK/rev-r3-materials-big" "$WORK/rev-r3-materials/duze"
python3 - "$R3/classroom.json" "$WORK/rev-r3-materials" <<'PY'
import json, sys
json.dump({"start": {"wake": False, "sendMaterials": True, "materialsFolder": sys.argv[2], "openApps": False,
                     "greet": False}}, open(sys.argv[1], "w"))
PY
r3_pack_interrupt rev-r3-materials lesson start 1
r3_pack_checks "lesson start" "✘ Materiały: przerwano pakowanie plików. Nic nie zostało uruchomione."
expect_not "lesson start, Ctrl-C: nic nie uruchomiono na komputerze" "$R3_OUT" "== imac01"
[ ! -e "$WORK/remote/Public/cmcr/duze" ] && pass "lesson start, Ctrl-C: materiały nie wysłane" \
  || fail "lesson start, Ctrl-C: materiały wysłane mimo przerwania" "$(ls -la "$WORK/remote/Public/cmcr")"
rm -rf "$WORK/remote/Public/cmcr/duze" "$WORK/rev-r3-materials" "$WORK/rev-r3-pack" "$R3/classroom.json"

section "REV R3 cmcrctl – lesson: ostrzeżenie o uszkodzonym classroom.json przed pytaniem o wszystkie komputery (AUDIT REV-46)"
# At a terminal without a host list; no answer („nie”): the warning must come before the only question.
for kind in start end; do
  printf '{"schedule": {"powerOnEnabled": tr' > "$R3/classroom.json"
  out="$(CMCR_CONFIG_DIR="$R3" script -q /dev/null "$CTL" lesson "$kind" </dev/null 2>&1)"; code=$?
  expect "lesson $kind bez listy: pytanie o wszystkie komputery" "$out" "Wykonać na wszystkich?"
  r3_before "lesson $kind bez listy: ostrzeżenie przed pytaniem" "$out" "⚠ Plik ustawień zajęć (classroom.json) jest uszkodzony" \
    "Wykonać na wszystkich?"
  expect_code "lesson $kind bez listy, odpowiedź „nie”: kod 1" "$code" 1 "$out"
done
# As before: lock reads the file before the question too.
printf '{"schedule": {"powerOnEnabled": tr' > "$R3/classroom.json"
out="$(CMCR_CONFIG_DIR="$R3" script -q /dev/null "$CTL" lock </dev/null 2>&1)"
r3_before "lock bez listy: ostrzeżenie przed pytaniem" "$out" "⚠ Plik ustawień zajęć" "Wykonać na wszystkich?"
rm -f "$R3/classroom.json" "$R3"/classroom.json.*.bak

section "REV R3 cmcrctl – exec: zerwane połączenie to kod 1, nie 255 (AUDIT REV-51)"
r3_close_masters
rm -f "$WORK/rev-r3-exec.out" "$WORK/rev-r3-exec-done"
CMCR_CONFIG_DIR="$R3" "$CTL" exec "echo ruszyło-r3; sleep 4; touch '$WORK/rev-r3-exec-done'" 1 >"$WORK/rev-r3-exec.out" 2>&1 &
r3_pid=$!
for _ in $(seq 1 150); do grep -q "ruszyło-r3" "$WORK/rev-r3-exec.out" 2>/dev/null && break; sleep 0.1; done
r3_sock="$(find "$CMCR_SSH_CONTROL_DIR" -type s 2>/dev/null | head -n 1)"
if [ -n "$r3_sock" ]; then
  # The shared connection goes away under the running command (as when the network drops it).
  ssh -S "$r3_sock" -O exit cmcr-e2e >/dev/null 2>&1
  wait "$r3_pid"
  code=$?
  out="$(cat "$WORK/rev-r3-exec.out")"
  expect "exec, zerwane połączenie: błąd połączenia" "$out" "Połączenie zostało przerwane"
  expect_code "exec, zerwane połączenie: kod 1 (nie 255)" "$code" 1 "$out"
else
  kill "$r3_pid" 2>/dev/null
  wait "$r3_pid" 2>/dev/null
  fail "exec, zerwane połączenie: brak gniazda wspólnego połączenia" "$(ls -la "$CMCR_SSH_CONTROL_DIR" 2>&1)"
fi
# The command goes on on the Mac: let it end before the next suites count the test sshd's sessions.
for _ in $(seq 1 100); do [ -e "$WORK/rev-r3-exec-done" ] && break; sleep 0.1; done
out="$(r3 exec 'true' 9)"; code=$?
expect_code "exec, komputer nieosiągalny: kod 1 (nie 255)" "$code" 1 "$out"
# The command's own codes are still passed through – also its own 255 (e.g. another ssh inside it).
out="$(r3 exec 'echo "ssh: connect to host inny.local port 22: Operation timed out" >&2; exit 255' 1)"; code=$?
expect_code "exec, kod 255 samego polecenia: przekazany" "$code" 255 "$out"
out="$(r3 exec 'exit 7' 1,9)"; code=$?
expect_code "exec, kod polecenia i niedostępny komputer: kod polecenia" "$code" 7 "$out"

section "REV R3 cmcrctl – rename: nowa nazwa, którą ma jeszcze inny zmieniany komputer (AUDIT REV-52)"
RN="$WORK/cfg-rev-r3-rename"
mkdir -p "$RN"
cp "$WORK/config/settings.json" "$RN/"
# A swap (imac01 ↔ imac02 on the list), an upward renumbering (imac05 → imac06 → imac07) and a Mac that keeps its name.
cat > "$RN/hosts.json" <<EOF
[
 {"id":"c1111111-1111-1111-1111-111111111111","name":"imac02","address":"imac01.local","user":"$ME","port":$PORT},
 {"id":"c2222222-2222-2222-2222-222222222222","name":"imac01","address":"imac02.local","user":"$ME","port":$PORT},
 {"id":"c4444444-4444-4444-4444-444444444444","name":"imac04","address":"imac04.local","user":"$ME","port":$PORT},
 {"id":"c5555555-5555-5555-5555-555555555555","name":"imac06","address":"imac05.local","user":"$ME","port":$PORT},
 {"id":"c6666666-6666-6666-6666-666666666666","name":"imac07","address":"imac06.local","user":"$ME","port":$PORT},
 {"id":"c9999999-9999-9999-9999-999999999999","name":"imac09","address":"imac09.cmcr-e2e.invalid","user":"imac09","port":22}
]
EOF
rn() { CMCR_CONFIG_DIR="$RN" "$CTL" "$@" 2>&1; }
out="$(rn rename @1,@2 --dry-run)"; code=$?
expect_code "rename, zamiana nazw: kod 2" "$code" 2 "$out"
expect "rename, zamiana nazw: oba komputery wskazane" "$out" \
  "imac02: „imac02” → imac02.local – ten adres ma teraz imac01 (imac02.local)" \
  "imac01: „imac01” → imac01.local – ten adres ma teraz imac02 (imac01.local)" "nazwę tymczasową (--name)" \
  "nic nie zostało zmienione"
out="$(rn rename imac06,imac07 --dry-run)"; code=$?
expect_code "rename, przenumerowanie: kod 2" "$code" 2 "$out"
expect "rename, przenumerowanie: komputer, który zająłby zajęty adres" "$out" \
  "imac06: „imac06” → imac06.local – ten adres ma teraz imac07 (imac06.local)" "najpierw imac07, potem imac06"
expect "rename, przenumerowanie: drugi komputer bez błędu" "$out" "imac07: „imac07” → imac07.local"
# Only --dry-run here: the addresses are .local names, and no test may connect to one. The check runs before the
# dry-run ends, the same for a real rename.
# Two steps work: first the Mac that gives its address up, then – with the list updated (--update-list) – the other.
out="$(rn rename imac07 --dry-run)"; code=$?
expect_code "rename, pierwszy krok: kod 0" "$code" 0 "$out"
python3 - "$RN/hosts.json" <<'PY'
import json, sys
p = sys.argv[1]; hosts = json.load(open(p))
for h in hosts:
    if h["name"] == "imac07": h["address"] = "imac07.local"
json.dump(hosts, open(p, "w"))
PY
out="$(rn rename imac06 --dry-run)"; code=$?
expect_code "rename, drugi krok: kod 0" "$code" 0 "$out"
# Renamed Macs without a chain, and a Mac whose new name is its own current address.
out="$(rn rename 4,imac07 --dry-run)"; code=$?
expect_code "rename, dwa komputery bez łańcucha: kod 0" "$code" 0 "$out"
expect "rename, własny adres: bez błędu" "$out" "imac04: „imac04” → imac04.local"
