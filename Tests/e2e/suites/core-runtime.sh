# Core runtime: shared ssh connections, stopping remote jobs, surviving a lost connection, host keys.
# Sourced by Tests/e2e/run.sh (helpers: section, pass, fail, expect, expect_not, expect_code, ctl, ctlpw).

MUXDIR="${CMCR_SSH_CONTROL_DIR:-/tmp/cmcr-$(id -u)}"
mux_ssh() { /usr/bin/ssh -o ControlPath="$MUXDIR/%C" "$@" -p "$PORT" "$ME@127.0.0.1" 2>&1; }
logins() { grep -c "Accepted publickey" "$WORK/sshd.log"; }
set_setting() { # set_setting key json-value
  python3 - "$WORK/config/settings.json" "$1" "$2" <<'PY'
import json, sys
p, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
s = json.load(open(p)); s[k] = json.loads(v); json.dump(s, open(p, "w"))
PY
}
job_file_gone() { [ ! -e "/tmp/cmcr-jobs/$1" ] && [ ! -e "/tmp/cmcr-jobs-$(id -u)/$1" ]; }
job_id() { printf '%s\n' "$1" | sed -n 's/^CMCR:JOB://p' | head -1; }
no_process() { ! pgrep -u "$(id -u)" -f "^$1\$" >/dev/null 2>&1; }

section "Połączenia współdzielone (ControlMaster)"
mux_ssh -O exit >/dev/null
out="$(ctl exec 'echo mux-pierwsze' 1)"
expect "mux: polecenie wykonane" "$out" "mux-pierwsze"
expect "mux: połączenie główne działa po pierwszym poleceniu" "$(mux_ssh -O check)" "Master running"
sock="$(ls "$MUXDIR" 2>/dev/null | head -1)"
if [ -n "$sock" ] && [ -S "$MUXDIR/$sock" ]; then pass "mux: gniazdo w katalogu połączeń"; else fail "mux: brak gniazda" "$(ls -la "$MUXDIR" 2>&1)"; fi
perm="$(stat -f %Lp "$MUXDIR" 2>/dev/null)"
[ "$perm" = 700 ] && pass "mux: katalog gniazd dostępny tylko dla właściciela" || fail "mux: uprawnienia katalogu ($perm)"
n1="$(logins)"
out="$(ctl exec 'echo mux-drugie' 1)"
n2="$(logins)"
expect "mux: drugie polecenie" "$out" "mux-drugie"
[ "$n1" = "$n2" ] && pass "mux: drugie polecenie bez ponownego logowania" || fail "mux: nowe logowanie ($n1 → $n2)"

# 12 parallel sessions exceed sshd's MaxSessions (10) on one shared connection: none may fail or show noise.
pids=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  "$CTL" exec "sleep 1; echo rownolegle-$i" 1 > "$WORK/par-$i.log" 2>&1 &
  pids="$pids $!"
done
okpar=0
for p in $pids; do wait "$p" && okpar=$((okpar + 1)); done
allpar="$(cat "$WORK"/par-*.log)"
[ "$okpar" = 12 ] && pass "mux: 12 równoległych sesji zakończonych powodzeniem" || fail "mux: równoległe sesje ($okpar/12)" "$allpar"
expect_not "mux: brak komunikatów ssh o limicie sesji w wynikach" "$allpar" "mux_client"

# Retiring a shared connection (key or settings changed, "Zapomnij klucz hosta") must not break the
# sessions still running on it: they finish, and the next command logs in again.
mux_count() { pgrep -u "$(id -u)" -f "^ssh: $MUXDIR/.*\[mux\]" | wc -l | tr -d ' '; }
"$CTL" __run-job 'sleep 2; echo dlugie-ok' 1 > "$WORK/inflight.log" 2>&1 &
bgpid=$!
sleep 0.8
ctl __close-master 1 >/dev/null
expect_not "zamknięcie połączenia: nie przyjmuje nowych sesji" "$(mux_ssh -O check)" "Master running"
wait "$bgpid"; code=$?
expect "zamknięcie połączenia: trwające polecenie dokończone" "$(cat "$WORK/inflight.log")" "dlugie-ok" "exit=0"
expect_code "zamknięcie połączenia: kod 0 trwającego polecenia" "$code" 0 "$(cat "$WORK/inflight.log")"
n1="$(logins)"
out="$(ctl exec 'echo po-zamknieciu' 1)"
expect "zamknięcie połączenia: następne polecenie działa" "$out" "po-zamknieciu"
[ "$(logins)" -gt "$n1" ] && pass "zamknięcie połączenia: nowe połączenie główne" || fail "zamknięcie połączenia: brak nowego logowania"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(mux_count)" -le 1 ] && break; sleep 0.3; done
[ "$(mux_count)" -le 1 ] && pass "zamknięcie połączenia: stare połączenie zakończone po ostatniej sesji" \
  || fail "zamknięcie połączenia: stare połączenie nadal działa" "$(pgrep -lf '\[mux\]')"
expect_not "znacznik startu usunięty z wyniku" "$out$(cat "$WORK/inflight.log")" "CMCR:SESSION-STARTED"

set_setting reuseConnections false
mux_ssh -O exit >/dev/null
out="$(ctl exec 'echo bez-mux' 1)"
expect "mux wyłączony: polecenie wykonane" "$out" "bez-mux"
expect_not "mux wyłączony: brak połączenia głównego" "$(mux_ssh -O check)" "Master running"
set_setting reuseConnections true

section "Zadania zdalne (rejestr, przekaźnik wyjścia)"
out="$(ctl __run-job 'echo wyjscie; echo blad >&2; echo "tmp=$CMCR_TMP"; exit 3' 1)"; code=$?
expect "zadanie: wyjście i błędy przekazane" "$out" "wyjscie" "blad" "exit=3"
expect_code "zadanie: kod wyjścia przekazany" "$code" 3 "$out"
jid="$(job_id "$out")"; jtmp="$(printf '%s\n' "$out" | sed -n 's/^tmp=//p')"
if [ -n "$jid" ] && job_file_gone "$jid"; then pass "zadanie: wpis w rejestrze usunięty po zakończeniu"; else fail "zadanie: rejestr ($jid)" "$(ls -la /tmp/cmcr-jobs 2>&1)"; fi
[ -n "$jtmp" ] && [ ! -d "$jtmp" ] && pass "zadanie: katalog tymczasowy usunięty" || fail "zadanie: katalog tymczasowy ($jtmp)"
out="$(ctl exec 'yes | head -1; echo potok-ok' 1)$(ctl __run-job 'yes | head -1; echo potok-ok' 1)"
expect "potoki: zwykłe zachowanie SIGPIPE w poleceniach" "$out" "potok-ok"
expect_not "potoki: brak komunikatów Broken pipe" "$out" "Broken pipe"
out="$(ctl __run-job '/bin/cat /bin/ls' 1 --stdout "$WORK/binary.out")"
if cmp -s /bin/ls "$WORK/binary.out"; then pass "zadanie: dane binarne przez przekaźnik bez zmian"; else fail "zadanie: dane binarne różne" "$out"; fi
clear_fakelog
out="$(ctlpw __run-job 'echo "root-zadanie $(id -un)"; : > "$CMCR_TMP/plik-roota"' 1 --root)"; code=$?
expect "zadanie root: ciało wykonane" "$out" "root-zadanie"
expect_code "zadanie root: kod 0" "$code" 0 "$out"
expect "zadanie root: pliki oddane administratorowi przed sprzątaniem" "$(fakelog)" "chown -hR $(id -u)"
sudos="$(grep -c '^sudo ' "$WORK/fake.log" 2>/dev/null)"
[ "$sudos" = 1 ] && pass "zadanie root: jedno uwierzytelnienie sudo" || fail "zadanie root: liczba wywołań sudo ($sudos)" "$(fakelog)"

section "Anulowanie zatrzymuje polecenie na komputerze"
rm -f "$WORK/cancel-1" "$WORK/cancel-2" "$WORK/cancel-3"
out1="$(ctl __run-job "echo start; echo \"tmp=\$CMCR_TMP\"; sleep 6.3; echo koniec > '$WORK/cancel-1'" 1 --cancel-after 1.5)"
expect "anuluj: zadanie przerwane i zatrzymane zdalnie" "$out1" "start" "Zatrzymano polecenie na komputerze" "cancelled=true"
no_process "sleep 6.3" && pass "anuluj: proces na komputerze zakończony" || fail "anuluj: proces nadal działa" "$(pgrep -lf 'sleep 6.3')"
jid="$(job_id "$out1")"; jtmp="$(printf '%s\n' "$out1" | sed -n 's/^tmp=//p')"
job_file_gone "$jid" && pass "anuluj: wpis w rejestrze usunięty" || fail "anuluj: wpis w rejestrze pozostał"
[ -n "$jtmp" ] && [ ! -d "$jtmp" ] && pass "anuluj: katalog tymczasowy usunięty" || fail "anuluj: katalog tymczasowy ($jtmp)"
out2="$(ctlpw __run-job "echo start-root; sleep 6.4; echo koniec > '$WORK/cancel-2'" 1 --root --cancel-after 1.5)"
expect "anuluj (root): zadanie zatrzymane zdalnie" "$out2" "start-root" "Zatrzymano polecenie na komputerze"
no_process "sleep 6.4" && pass "anuluj (root): proces na komputerze zakończony" || fail "anuluj (root): proces nadal działa"
out3="$(ctl __run-job "sleep 6.6; echo koniec > '$WORK/cancel-3'" 1 --timeout 1.5)"
expect "limit czasu: polecenie zatrzymane zdalnie" "$out3" "Przekroczono limit czasu" "Zatrzymano polecenie na komputerze" "timedOut=true"
# The Mac answered (the script ran there): a slow command must not mark it offline, or later actions skip it.
expect "limit czasu po starcie: komputer nadal online" "$out3" "started=true" "reach=online"
out5="$("$CTL" __run-job "echo x" 99 --timeout 20 2>&1)"
expect "brak połączenia: komputer niedostępny" "$out5" "started=false" "reach=offline"
no_process "sleep 6.6" && pass "limit czasu: proces na komputerze zakończony" || fail "limit czasu: proces nadal działa"
out4="$(ctl __run-job "echo szybkie" 1 --cancel-after 3)"
expect_not "anuluj po zakończeniu: brak próby zatrzymania" "$out4" "Zatrzymano"
sleep 5
[ ! -e "$WORK/cancel-1" ] && [ ! -e "$WORK/cancel-2" ] && [ ! -e "$WORK/cancel-3" ] \
  && pass "anuluj: przerwane polecenia nie dokończyły pracy" || fail "anuluj: polecenie dokończyło pracę" "$(ls "$WORK"/cancel-* 2>&1)"

section "Utrata połączenia nie przerywa zadania"
survive() { # survive label
  local m="$WORK/survive-$1" t="$WORK/survive-$1.tmp" log="$WORK/survive-$1.log" pid tmp
  rm -f "$m" "$t"
  "$CTL" __run-job "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do /bin/echo \"tick \$i\" || exit 9; echo \"err \$i\" >&2; sleep 0.25; done; echo \"\$CMCR_TMP\" > '$t'; echo gotowe > '$m'" 1 > "$log" 2>&1 &
  pid=$!
  sleep 1.2
  pkill -TERM -P "$pid" -x ssh
  wait "$pid"
  for _ in $(seq 1 40); do [ -f "$m" ] && break; sleep 0.2; done
  expect "rozłączenie ($1): lokalne ssh przerwane w trakcie" "$(cat "$log")" "tick 1"
  expect_not "rozłączenie ($1): lokalnie nie odebrano końca" "$(cat "$log")" "tick 12"
  if [ -f "$m" ]; then pass "rozłączenie ($1): zadanie dokończone na komputerze"; else fail "rozłączenie ($1): zadanie nie dokończone" "$(cat "$log")"; fi
  sleep 0.5
  tmp="$(cat "$t" 2>/dev/null)"
  [ -n "$tmp" ] && [ ! -d "$tmp" ] && pass "rozłączenie ($1): katalog tymczasowy usunięty" || fail "rozłączenie ($1): katalog tymczasowy ($tmp)"
}
survive mux
set_setting reuseConnections false
survive "bez mux"
set_setting reuseConnections true

section "Klucz hosta (zapomnij, zaufaj ponownie)"
out="$(ctl status 1)"
if ssh-keygen -F "[127.0.0.1]:$PORT" -f "$WORK/known_hosts" >/dev/null 2>&1; then pass "known_hosts: zaufany klucz zapisany"; else fail "known_hosts: brak wpisu" "$(cat "$WORK/known_hosts" 2>&1)"; fi
expect "known_hosts: połączenie współdzielone przed usunięciem" "$(mux_ssh -O check)" "Master running"
out="$(ctl __forget-host-key 1)"; code=$?
expect_code "zapomnij klucz: kod 0" "$code" 0 "$out"
if ssh-keygen -F "[127.0.0.1]:$PORT" -f "$WORK/known_hosts" >/dev/null 2>&1; then fail "zapomnij klucz: wpis pozostał" "$(cat "$WORK/known_hosts")"; else pass "zapomnij klucz: wpis usunięty z pliku UserKnownHostsFile"; fi
expect_not "zapomnij klucz: połączenie współdzielone zamknięte" "$(mux_ssh -O check)" "Master running"
out="$(ctl status 1)"; code=$?
expect "zapomnij klucz: bez zaufanego klucza połączenie odrzucone" "$out" "nie jest jeszcze zaufany" "cmcrctl trust imac01"
expect_code "zapomnij klucz: kod 1" "$code" 1 "$out"
expect_not "zapomnij klucz: klucz nie został przyjęty sam" "$(cat "$WORK/known_hosts" 2>/dev/null)" "[127.0.0.1]:$PORT"
out="$(ctl trust 1 --yes)"
expect "zaufaj: odcisk klucza i zapis" "$out" "nowy klucz" "SHA256:" "imac01: zaufano"
out="$(ctl status 1)"
expect "zaufaj: ponowne połączenie" "$out" "● imac01"
