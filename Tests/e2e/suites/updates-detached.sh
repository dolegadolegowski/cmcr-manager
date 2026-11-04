# shellcheck shell=bash
# macOS updates as a detached run on the iMac (Scripts+Updates.swift, Operations+Updates.swift): a lost connection does
# not stop softwareupdate and cmcrctl follows the same run again; a second install attaches to a running one; failures
# say what to do; only the newest macOS version is installed; after a restart the system version tells the outcome.
# Sourced by Tests/e2e/run.sh (helpers and $WORK $CTL $PASSWORD $ME $PORT $ROOT come from there).

SU="$WORK/softwareupdate"
SUD="$WORK/su-detached"
mkdir -p "$SUD"
su_reset() {
  rm -rf "$SU"
  rm -f "$WORK/softwareupdate.slow" "$WORK/softwareupdate.fail" "$WORK/softwareupdate.list" "$WORK/softwareupdate.list.rc" \
    "$WORK/log.show" "$WORK/boottime" "$WORK/sw_vers.version" "$WORK/sw_vers.build" "$WORK/su.restart_wait" \
    "$WORK/fake-volume-owner-unlisted"
  clear_fakelog
}
su_wait() { # su_wait SECONDS COMMAND… – polls until the command succeeds
  local i limit=$(($1 * 10)); shift
  for i in $(seq 1 "$limit"); do "$@" && return 0; sleep 0.1; done
  return 1
}
su_state() { sed -n "s/^$1=//p" "$SU/state" 2>/dev/null | head -n 1; }

section "Aktualizacje macOS – stan instalacji"
su_reset
out="$(ctl updates status 1)"; code=$?
expect_code "updates status bez żadnej instalacji: kod 0" "$code" 0 "$out"
expect "updates status bez żadnej instalacji: komunikat" "$out" "nie uruchamiano jeszcze instalacji aktualizacji"

section "Aktualizacje macOS – zerwane połączenie w trakcie pobierania"
su_reset
echo 8 > "$WORK/softwareupdate.slow"
CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 >"$SUD/drop.out" 2>&1 &
su_pid=$!
su_downloading() { grep -q "Downloading:" "$SUD/drop.out" 2>/dev/null; }
su_ended() { ! kill -0 "$su_pid" 2>/dev/null; }
if su_wait 20 su_downloading; then
  su_sock="$(find "$WORK/mux" -type s 2>/dev/null | head -n 1)"
  if [ -n "$su_sock" ]; then
    # The shared connection goes away under the download (keepalive on a saturated network, Wi‑Fi).
    ssh -S "$su_sock" -O exit cmcr-e2e >/dev/null 2>&1
    su_wait 60 su_ended || kill "$su_pid" 2>/dev/null
    wait "$su_pid"; code=$?
    out="$(cat "$SUD/drop.out")"
    expect_code "zerwane połączenie: instalacja dokończona i zgłoszona – kod 0" "$code" 0 "$out"
    expect "zerwane połączenie: ponowne połączenie i śledzenie tej samej instalacji" "$out" \
      "instalacja trwa na nim dalej" "Downloading: 100.00%" "Done."
    expect_not "zerwane połączenie: nie zgłoszone jako błąd połączenia" "$out" "Połączenie zostało przerwane – polecenie"
    [ "$(su_state phase)" = done ] && [ "$(su_state rc)" = 0 ] && pass "zerwane połączenie: stan na komputerze – zakończona, kod 0" \
      || fail "zerwane połączenie: stan na komputerze" "$(cat "$SU/state" 2>&1)"
    [ "$(grep -c "softwareupdate --install" "$WORK/fake.log")" = 1 ] \
      && pass "zerwane połączenie: softwareupdate uruchomiony raz" || fail "zerwane połączenie: liczba uruchomień" "$(fakelog)"
  else
    kill "$su_pid" 2>/dev/null; wait "$su_pid" 2>/dev/null
    fail "zerwane połączenie: brak gniazda wspólnego połączenia w $WORK/mux" "$(ls -la "$WORK/mux" 2>&1)"
  fi
else
  kill "$su_pid" 2>/dev/null; wait "$su_pid" 2>/dev/null
  fail "zerwane połączenie: pobieranie nie ruszyło" "$(cat "$SUD/drop.out")"
fi

section "Aktualizacje macOS – druga instalacja dołącza do trwającej"
su_reset
echo 8 > "$WORK/softwareupdate.slow"
CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 >"$SUD/first.out" 2>&1 &
su_pid=$!
su_first_running() { grep -q "Downloading:" "$SUD/first.out" 2>/dev/null; }
if su_wait 20 su_first_running; then
  out="$(ctlpw updates install 1)"; code=$?
  expect_code "druga instalacja: kod 0" "$code" 0 "$out"
  expect "druga instalacja: pokazuje trwającą zamiast uruchamiać drugą" "$out" "trwa już instalacja aktualizacji" "→ Safari99.1-99.1" "Done."
  wait "$su_pid"; code=$?
  expect_code "pierwsza instalacja: kod 0" "$code" 0 "$(cat "$SUD/first.out")"
  [ "$(grep -c "softwareupdate --install" "$WORK/fake.log")" = 1 ] \
    && pass "druga instalacja: softwareupdate uruchomiony raz" || fail "druga instalacja: liczba uruchomień" "$(fakelog)"
else
  kill "$su_pid" 2>/dev/null; wait "$su_pid" 2>/dev/null
  fail "druga instalacja: pierwsza nie ruszyła" "$(cat "$SUD/first.out")"
fi

section "Aktualizacje macOS – druga instalacja śledzi dołączoną po zerwanym połączeniu"
# The joining job follows the run it joined (its id comes with CMCR:SU-RUN), not the one it would have started. The
# first run downloads long enough for the second to join on a slow CI runner.
su_reset
echo 12 > "$WORK/softwareupdate.slow"
CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 >"$SUD/a.out" 2>&1 &
su_a=$!
su_a_running() { grep -q "Downloading:" "$SUD/a.out" 2>/dev/null; }
if su_wait 20 su_a_running; then
  CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 >"$SUD/b.out" 2>&1 &
  su_b=$!
  su_b_joined() { grep -q "trwa już" "$SUD/b.out" 2>/dev/null; }
  if su_wait 20 su_b_joined; then
    su_sock="$(find "$WORK/mux" -type s 2>/dev/null | head -n 1)"
    ssh -S "$su_sock" -O exit cmcr-e2e >/dev/null 2>&1
    wait "$su_b"; code=$?
    out="$(cat "$SUD/b.out")"
    expect_code "dołączona po zerwaniu: kod 0" "$code" 0 "$out"
    expect "dołączona po zerwaniu: śledzi dołączoną instalację do końca" "$out" "instalacja trwa na nim dalej" "Done."
    expect_not "dołączona po zerwaniu: bez szukania własnej instalacji" "$out" "Nie ma na komputerze śladu"
    expect_not "dołączona po zerwaniu: znacznik usunięty z wyniku" "$out" "CMCR:SU-RUN"
  else
    kill "$su_b" 2>/dev/null; wait "$su_b" 2>/dev/null
    fail "dołączona po zerwaniu: druga instalacja nie dołączyła" "$(cat "$SUD/b.out")"
  fi
  wait "$su_a"; code=$?
  expect_code "dołączona po zerwaniu: pierwsza – kod 0" "$code" 0 "$(cat "$SUD/a.out")"
else
  kill "$su_a" 2>/dev/null; wait "$su_a" 2>/dev/null
  fail "dołączona po zerwaniu: pierwsza nie ruszyła" "$(cat "$SUD/a.out")"
fi

section "Aktualizacje macOS – przerwanie dołączonej instalacji zatrzymuje ją na komputerze"
su_reset
echo 12 > "$WORK/softwareupdate.slow"
CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 >"$SUD/a.out" 2>&1 &
su_a=$!
if su_wait 20 su_a_running; then
  CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 >"$SUD/b.out" 2>&1 &
  su_b=$!
  if su_wait 20 su_b_joined; then
    kill -INT "$su_b"
    wait "$su_b"; code=$?
    expect_code "przerwanie dołączonej: kod 130" "$code" 130 "$(cat "$SUD/b.out")"
    su_a_ended() { ! kill -0 "$su_a" 2>/dev/null; }
    su_wait 10 su_a_ended
    run_pid="$(awk '{print $2}' "$SU/runner" 2>/dev/null)"
    if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then fail "przerwanie dołączonej: instalacja nadal działa na komputerze" "$(ps -p "$run_pid")"
    else pass "przerwanie dołączonej: instalacja zatrzymana na komputerze"; fi
    out="$(ctl updates status 1)"
    expect "przerwanie dołączonej: stan instalacji – przerwano" "$out" "Instalację przerwano."
  else
    kill "$su_b" 2>/dev/null; wait "$su_b" 2>/dev/null
    fail "przerwanie dołączonej: druga instalacja nie dołączyła" "$(cat "$SUD/b.out")"
  fi
  wait "$su_a" 2>/dev/null
  expect_not "przerwanie dołączonej: pierwsza nie dokończyła instalacji" "$(cat "$SUD/a.out")" "Done."
  # The first job explains the stop it did not ask for, instead of a bare „kod 143”.
  if grep -qE "Instalację przerwano|Instalacja została przerwana" "$SUD/a.out"; then
    pass "przerwanie dołączonej: pierwsza wyjaśnia, że instalację przerwano"
  else fail "przerwanie dołączonej: pierwsza bez wyjaśnienia" "$(cat "$SUD/a.out")"; fi
else
  kill "$su_a" 2>/dev/null; wait "$su_a" 2>/dev/null
  fail "przerwanie dołączonej: pierwsza nie ruszyła" "$(cat "$SUD/a.out")"
fi

section "Aktualizacje macOS – instalacja nie dołącza do samego pobierania"
su_reset
echo 10 > "$WORK/softwareupdate.slow"
CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 --download >"$SUD/dl.out" 2>&1 &
su_a=$!
su_dl_running() { grep -q "Downloading:" "$SUD/dl.out" 2>/dev/null; }
if su_wait 20 su_dl_running; then
  out="$(ctlpw _builder install-updates 1 --restart)"; code=$?
  expect_code "instalacja w trakcie pobierania: odmowa – kod 7" "$code" 7 "$out"
  expect "instalacja w trakcie pobierania: co trwa i co zrobić" "$out" "trwa już pobieranie aktualizacji (bez instalacji)" \
    "niczego nie zainstalowano"
  expect_not "instalacja w trakcie pobierania: bez etykiet jak zainstalowanych" "$out" "→ Safari"
  wait "$su_a"; code=$?
  out="$(cat "$SUD/dl.out")"
  expect_code "samo pobieranie: kod 0" "$code" 0 "$out"
  expect "samo pobieranie: etykiety jako pobrane (↓), nie zainstalowane (→)" "$out" "↓ Safari99.1-99.1"
  expect_not "samo pobieranie: bez „→ etykieta”" "$out" "→ Safari99.1-99.1"
  expect_not "instalacja w trakcie pobierania: nic nie zainstalowano" "$(fakelog)" "softwareupdate --install"
else
  kill "$su_a" 2>/dev/null; wait "$su_a" 2>/dev/null
  fail "samo pobieranie nie ruszyło" "$(cat "$SUD/dl.out")"
fi

section "Aktualizacje macOS – przerwanie (Ctrl-C) zatrzymuje instalację na komputerze"
su_reset
echo 8 > "$WORK/softwareupdate.slow"
CMCR_PASSWORD="$PASSWORD" "$CTL" updates install 1 >"$SUD/int.out" 2>&1 &
su_pid=$!
su_int_running() { grep -q "Downloading:" "$SUD/int.out" 2>/dev/null; }
if su_wait 20 su_int_running; then
  kill -INT "$su_pid"
  wait "$su_pid"; code=$?
  expect_code "Ctrl-C: kod 130" "$code" 130 "$(cat "$SUD/int.out")"
  sleep 1
  run_pid="$(awk '{print $2}' "$SU/runner" 2>/dev/null)"
  if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then fail "Ctrl-C: instalacja nadal działa na komputerze" "$(ps -p "$run_pid")"
  else pass "Ctrl-C: instalacja zatrzymana na komputerze"; fi
  out="$(ctl updates status 1)"
  expect "Ctrl-C: stan instalacji – przerwana" "$out" "przerwana"
  expect_not "Ctrl-C: bez Done." "$out" "Done."
else
  kill "$su_pid" 2>/dev/null; wait "$su_pid" 2>/dev/null
  fail "Ctrl-C: instalacja nie ruszyła" "$(cat "$SUD/int.out")"
fi

section "Aktualizacje macOS – „Failed to queue update and restart”"
su_reset
echo "Failed to queue update and restart." > "$WORK/softwareupdate.fail"
echo "2026-11-04 18:37:38.1 E  softwareupdated[123:4567] Queue for post-logout failed: Error Domain=SUErrorDomain Code=6 (testowy)" > "$WORK/log.show"
out="$(ctlpw _builder install-updates 1 --major --restart)"; code=$?
expect_code "Failed to queue: kod 1" "$code" 1 "$out"
expect "Failed to queue: wyjaśnienie, przyczyna z dziennika i co zrobić" "$out" \
  "Failed to queue update and restart" "Przyczyna według dziennika systemu" "Queue for post-logout failed" \
  "macOS nie przyjął zlecenia instalacji z ponownym uruchomieniem"
# The script's own last line (cmcrctl adds its „✘ Polecenie zakończone kodem 1.” below it).
last="$(printf '%s\n' "$out" | grep -v -e '^ *$' -e '^✘ Polecenie zakończone' | tail -n 1)"
expect "Failed to queue: ostatni wiersz to błąd z poleceniem, co zrobić" "$last" "✘ Aktualizacja jest pobrana"

section "Aktualizacje macOS – tylko najnowsza wersja systemu"
su_reset
cur="$(sw_vers -productVersion)"; cur="${cur%%.*}"
cat > "$WORK/softwareupdate.list" <<LIST
Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: macOS Testowy $cur.9-A9
	Title: macOS Testowy, Version: $cur.9, Size: 1000000KiB, Recommended: YES, Action: restart,
* Label: macOS Testowy $cur.10-A10
	Title: macOS Testowy, Version: $cur.10, Size: 1000000KiB, Recommended: YES, Action: restart,
* Label: macOS Nowy 99.1-99A1
	Title: macOS Nowy, Version: 99.1, Size: 9000000KiB, Recommended: YES, Action: restart,
* Label: Safari99.1-99.1
	Title: Safari, Version: 99.1, Size: 123456KiB, Recommended: YES,
LIST
out="$(ctlpw _builder install-updates 1)"; code=$?
expect_code "najnowsza poprawka: kod 0" "$code" 0 "$out"
expect "najnowsza poprawka: instaluje $cur.10 i Safari" "$(fakelog)" "softwareupdate --install macOS Testowy $cur.10-A10 Safari99.1-99.1 --agree-to-license"
expect_not "najnowsza poprawka: bez wersji pośredniej" "$(fakelog)" "$cur.9-A9"
expect "najnowsza poprawka: wyjaśnia pominięcie" "$out" "↷ Pominięto wersję pośrednią: macOS Testowy $cur.9-A9 – od razu instaluję najnowszą: macOS Testowy $cur.10-A10."
clear_fakelog
out="$(ctlpw _builder install-updates 1 --major)"
expect "nowa wersja macOS: tylko ona z systemów" "$(fakelog)" "softwareupdate --install macOS Nowy 99.1-99A1 Safari99.1-99.1"
expect "nowa wersja macOS: poprawki obecnej pominięte" "$out" "Pominięto wersję pośrednią: macOS Testowy $cur.10-A10"
rm -f "$WORK/softwareupdate.list"

section "Aktualizacje macOS – wynik po ponownym uruchomieniu"
su_reset
out="$(ctlpw _builder install-updates 1 --major --restart)"; code=$?
expect_code "z restartem: fałszywy softwareupdate nie restartuje – kod 6" "$code" 6 "$out"
# Followed again long after, the restart that did not come is reported at once, not after the whole wait again.
echo 60 > "$WORK/su.restart_wait"
sed -i '' "s/^finished=.*/finished=$(( $(date +%s) - 600 ))/" "$SU/state"
su_t0=$SECONDS
out="$(ctl updates status 1)"; code=$?
expect_code "stan po czasie: restart, który nie nastąpił – kod 1" "$code" 1 "$out"
expect "stan po czasie: od kiedy czeka" "$out" "nie uruchomił się ponownie od"
[ $((SECONDS - su_t0)) -lt 20 ] && pass "stan po czasie: bez ponownego czekania" \
  || fail "stan po czasie: czekał $((SECONDS - su_t0)) s" "$out"
rm -f "$WORK/su.restart_wait"
# The Mac "restarts" into the new system: another boot time and system version.
echo 1234567890 > "$WORK/boottime"
echo 99.1 > "$WORK/sw_vers.version"; echo 99A123 > "$WORK/sw_vers.build"
out="$(ctl updates status 1)"; code=$?
expect_code "po restarcie z nowym systemem: kod 0" "$code" 0 "$out"
expect "po restarcie z nowym systemem: wersje przed i po" "$out" "→ macOS Testowy 99.1-99A123" \
  "✔ Komputer uruchomił się ponownie z nowym systemem: macOS 99.1 (99A123)"
rm -f "$WORK/sw_vers.version" "$WORK/sw_vers.build"
out="$(ctl updates status 1)"; code=$?
expect_code "po restarcie bez zmiany systemu: kod 1" "$code" 1 "$out"
expect "po restarcie bez zmiany systemu: aktualizacja nie zainstalowana" "$out" "system się nie zmienił" "Zwykły restart nie instaluje"

if [ "$(uname -m)" = arm64 ]; then
  section "Aktualizacje macOS – Apple silicon bez właściciela woluminu"
  su_reset
  touch "$WORK/fake-no-volume-owner"
  out="$(ctlpw _builder install-updates 1 --major --restart)"; code=$?
  expect_code "bez Secure Token: kod 1" "$code" 1 "$out"
  expect "bez Secure Token: przerwane przed pobraniem, z poleceniem naprawy" "$out" "nie jest właścicielem woluminu" \
    "Nic nie pobrano" "sysadminctl -secureTokenOn"
  expect_not "bez Secure Token: softwareupdate --install nie uruchomiony" "$(fakelog)" "softwareupdate --install"
  rm -f "$WORK/fake-no-volume-owner"
  # An account without a Secure Token is not even listed among the volume's cryptographic users.
  su_reset
  touch "$WORK/fake-volume-owner-unlisted"
  out="$(ctlpw _builder install-updates 1 --major --restart)"; code=$?
  expect_code "konto spoza listy właścicieli: kod 1" "$code" 1 "$out"
  expect "konto spoza listy właścicieli: przerwane przed pobraniem" "$out" "nie jest właścicielem woluminu" "Nic nie pobrano"
  expect_not "konto spoza listy właścicieli: softwareupdate --install nie uruchomiony" "$(fakelog)" "softwareupdate --install"
  rm -f "$WORK/fake-volume-owner-unlisted"
fi
su_reset
