# Self-update of CMCR Manager (sourced by Tests/e2e/run.sh): signed manifest → download → verification →
# bundle swap with rollback, through `cmcrctl app-update`, against a fake GitHub on 127.0.0.1 and throw-away
# app bundles under $WORK. Never touches GitHub, /Applications or the real app; relaunches go to a fake `open`.

section "Uaktualnienia aplikacji (fałszywy GitHub, pakiety testowe)"
U="$WORK/self-update"
UPD_SRC="$ROOT/Tests/e2e/updater"
UPD_APP="$U/apps/CMCR Manager.app"
UPD_SERVER=""
mkdir -p "$U/keys" "$U/apps" "$U/build" "$U/www/files" "$U/state" "$U/tools"

upd_run() {
  if [ "$(id -u)" = 0 ]; then echo "  (pominięto: testy uaktualnień nie mogą działać jako root)"; return; fi
  case "$UPD_APP" in "$WORK"/*) ;; *) echo "  (pominięto: pakiet testowy poza $WORK)"; return ;; esac

  # The maintainer tool, compiled once; keys only in $U (never the Keychain or the signing key from the environment).
  swiftc "$ROOT/scripts/update-signing.swift" -o "$U/tools/update-signing" 2>"$U/tools/build.log" \
    || { fail "update-signing: kompilacja" "$(cat "$U/tools/build.log")"; return; }
  upd_tool() { env -u CMCR_UPDATE_SIGNING_KEY CMCR_UPDATE_SIGNING_KEY_FILE="$U/keys/test.key" "$U/tools/update-signing" "$@"; }
  UPD_KEY="$(upd_tool keygen --file "$U/keys/test.key" 2>/dev/null)"
  UPD_OTHER_KEY="$(env -u CMCR_UPDATE_SIGNING_KEY CMCR_UPDATE_SIGNING_KEY_FILE="$U/keys/other.key" \
    "$U/tools/update-signing" keygen --file "$U/keys/other.key" 2>/dev/null)"
  [ ${#UPD_KEY} = 44 ] && [ "$(stat -f %Lp "$U/keys/test.key")" = 600 ] \
    && pass "update-signing: klucz testowy (plik 0600 poza repozytorium)" || { fail "update-signing: keygen" "$UPD_KEY"; return; }

  upd_bundle() {  # version app confirm(0|1)
    local v=$1 app=$2
    local defs=(-DVERSION="\"$v\"" -DLAUNCHLOG="\"$U/launches.log\"")
    [ "$3" = 1 ] && defs+=(-DCONFIRM="\"$U/state/pl.cmcr.manager.update-confirm\"")
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
    clang -O1 "${defs[@]}" -o "$app/Contents/MacOS/CMCRManager" "$UPD_SRC/dummy-app.c" || return 1
    cp "$CTL" "$app/Contents/Resources/bin/cmcrctl"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>pl.cmcr.e2etest</string>
  <key>CFBundleExecutable</key><string>CMCRManager</string>
  <key>CFBundleName</key><string>CMCR Manager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$v</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
    codesign --force --sign - "$app/Contents/Resources/bin/cmcrctl" 2>/dev/null
    codesign --force --sign - "$app" 2>/dev/null
  }
  upd_release() {  # version confirm(0|1) → www/files/v<version>/{zip, cmcr-update.json, .sig}
    local v=$1 d="$U/www/files/v$1"
    upd_bundle "$v" "$U/build/v$v/CMCR Manager.app" "$2" || return 1
    mkdir -p "$d"
    ditto -c -k --sequesterRsrc --keepParent "$U/build/v$v/CMCR Manager.app" "$d/CMCR-Manager-$v.zip"
    printf '## Co nowego w %s\n- Poprawka **ważna**\n' "$v" > "$U/build/v$v/notes.md"
    upd_tool manifest --app "$U/build/v$v/CMCR Manager.app" --zip "$d/CMCR-Manager-$v.zip" --tag "v$v" \
      --notes-file "$U/build/v$v/notes.md" --out "$d/cmcr-update.json" 2>/dev/null &&
    upd_tool sign "$d/cmcr-update.json" > "$d/cmcr-update.json.sig"
  }
  upd_bundle 1.0.0 "$UPD_APP" 1 && upd_release 1.0.1 1 && upd_release 1.0.2 0 && upd_release 1.1.0-beta.1 1 \
    && python3 "$UPD_SRC/fixtures.py" "$U" >/dev/null \
    || { fail "przygotowanie wydań testowych"; return; }
  out="$(upd_tool verify "$U/www/files/v1.0.1/cmcr-update.json" "$U/www/files/v1.0.1/cmcr-update.json.sig" --public-key "$UPD_KEY" 2>&1)"
  expect "update-signing: manifest podpisany i zweryfikowany" "$out" "Podpis prawidłowy"
  expect "update-signing: manifest z wersją, sumą i architekturą" "$(cat "$U/www/files/v1.0.1/cmcr-update.json")" \
    '"version" : "1.0.1"' '"tag" : "v1.0.1"' '"sha256" : "' '"architectures"'

  # Relaunches of the helper go to this fake `open` (the helper runs `bash -c`, which reads BASH_ENV).
  cat > "$U/helper-fakes.sh" <<EOF
open() { printf 'open %s\n' "\$*" >> "$U/launches.log"; "\$1/Contents/MacOS/CMCRManager" & }
EOF
  if [ "$(BASH_ENV="$U/helper-fakes.sh" bash -c 'type -t open')" != function ]; then
    fail "atrapa open nie jest aktywna – pominięto testy instalacji"; return
  fi

  python3 "$UPD_SRC/fake_github.py" "$U" "$U/port" 2>"$U/server.log" &
  UPD_SERVER=$!
  for _ in $(seq 1 50); do [ -s "$U/port" ] && break; sleep 0.1; done
  [ -s "$U/port" ] || { fail "fałszywy GitHub nie wystartował" "$(cat "$U/server.log")"; return; }
  BASE="http://127.0.0.1:$(cat "$U/port")"

  upd() {  # mode cmcrctl-app-update-args… (UPD_TRUST overrides the trusted key)
    local mode=$1; shift
    env CMCR_UPDATE_REPO=test/cmcr CMCR_UPDATE_TEST_PUBLIC_KEY="${UPD_TRUST:-$UPD_KEY}" CMCR_UPDATE_API_BASE="$BASE/$mode" \
      CMCR_UPDATE_WEB_BASE="$BASE/web" CMCR_UPDATE_BUNDLE_ID=pl.cmcr.e2etest CMCR_UPDATE_STATE_DIR="$U/state" \
      BASH_ENV="$U/helper-fakes.sh" "$CTL" app-update "$@" --app "$UPD_APP" 2>&1
  }
  upd_version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$UPD_APP/Contents/Info.plist" 2>&1; }
  upd_leftovers() { ls -A "$U/apps" | grep -c '^\.' ; }

  # ---- check
  out="$(upd api-ok check)"; code=$?
  expect "check: dostępna nowa wersja z opisem zmian" "$out" "Dostępna nowa wersja 1.0.1 (zainstalowana: 1.0.0)" "Zmiany v1.0.1"
  expect_code "check: kod 0" "$code" 0 "$out"
  out="$(upd api-ok check --beta)"
  expect "check --beta: wersja testowa" "$out" "Dostępna nowa wersja 1.1.0-beta.1"
  out="$(upd api-403 check)"
  expect "check: limit API GitHuba → pobranie manifestu bez API" "$out" "Dostępna nowa wersja 1.0.1" "Co nowego w 1.0.1"
  out="$(upd api-none check)"
  expect "check: brak wydań → aktualna" "$out" "jest aktualny"
  out="$(upd api-forged check)"; code=$?
  expect "check: zmieniony manifest odrzucony (Ed25519)" "$out" "Podpis cyfrowy uaktualnienia jest nieprawidłowy"
  expect_code "check: zmieniony manifest – kod 1" "$code" 1 "$out"
  out="$(UPD_TRUST="$UPD_OTHER_KEY" upd api-ok check)"
  expect "check: podpis innym kluczem odrzucony" "$out" "Podpis cyfrowy uaktualnienia jest nieprawidłowy"
  out="$(upd api-relabel check)"
  expect "check: stare wydanie pod nowym tagiem odrzucone" "$out" "Niezgodna wersja" "v9.9.9"
  out="$(upd api-digest check)"
  expect "check: suma SHA-256 z GitHuba niezgodna z manifestem" "$out" "Suma kontrolna SHA-256"
  out="$(upd api-nomanifest check)"
  expect "check: wydanie bez podpisanego manifestu pominięte" "$out" "nie zawiera podpisanego manifestu"
  out="$(env -u CMCR_UPDATE_TEST_PUBLIC_KEY CMCR_UPDATE_REPO=test/cmcr CMCR_UPDATE_API_BASE="$BASE/api-ok" \
    CMCR_UPDATE_WEB_BASE="$BASE/web" CMCR_UPDATE_BUNDLE_ID=pl.cmcr.e2etest "$CTL" app-update check --app "$UPD_APP" 2>&1)"; code=$?
  if [ "$code" = 1 ] && { contains "" "$out" "nie są skonfigurowane" || contains "" "$out" "Podpis cyfrowy"; }; then
    pass "check: wbudowany klucz (PLACEHOLDER) nie przyjmuje obcego podpisu"
  else fail "check: wbudowany klucz przyjął obcy podpis" "$out"; fi

  # ---- install: refusals leave the installed app untouched
  out="$(upd api-tampered install)"; code=$?
  expect "install: podmienione archiwum odrzucone (SHA-256)" "$out" "Suma kontrolna SHA-256"
  out="$(upd api-big install)"
  expect "install: archiwum większe niż w manifeście przerwane" "$out" "większy niż zapowiedziany"
  "$UPD_APP/Contents/MacOS/CMCRManager" --e2e-sleep &
  local sleeper=$!
  sleep 0.3
  out="$(upd api-ok install)"
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null
  expect "install: odmowa, gdy aplikacja jest uruchomiona" "$out" "jest uruchomiony"
  chmod 555 "$U/apps"
  out="$(upd api-ok install)"; code=$?
  chmod 755 "$U/apps"
  expect "install: folder bez prawa zapisu – czytelna odmowa" "$out" "Brak uprawnień do zapisu" "sudo cmcrctl app-update install"
  [ "$(upd_version)" = 1.0.0 ] && [ "$(upd_leftovers)" = 0 ] \
    && pass "install: po odmowach aplikacja nietknięta (1.0.0)" || fail "install: aplikacja zmieniona mimo odmowy" "$(upd_version); $(ls -A "$U/apps")"

  # ---- install: download → verify → atomic swap
  : > "$U/launches.log"
  out="$(upd api-ok install)"; code=$?
  expect "install: pobrano, zweryfikowano, zainstalowano" "$out" "Zweryfikowano: podpis Ed25519" "Zainstalowano CMCR Manager 1.0.1"
  expect_code "install: kod 0" "$code" 0 "$out"
  [ "$(upd_version)" = 1.0.1 ] && codesign --verify --deep --strict "$UPD_APP" 2>/dev/null && [ "$(upd_leftovers)" = 0 ] \
    && pass "install: pakiet 1.0.1 na miejscu, podpis kodu poprawny, bez kopii roboczych" \
    || fail "install: stan po instalacji" "$(upd_version); $(ls -A "$U/apps")"
  [ ! -s "$U/launches.log" ] && pass "install: bez --relaunch aplikacja nie jest uruchamiana" || fail "install: nieoczekiwane uruchomienie" "$(cat "$U/launches.log")"
  out="$(upd api-ok check)"
  expect "check po instalacji: aktualna" "$out" "CMCR Manager 1.0.1 jest aktualny"

  # ---- rollback: 1.0.2 never confirms its start
  : > "$U/launches.log"
  out="$(upd api-bad install --relaunch --confirm-timeout 2)"; code=$?
  expect_code "rollback: kod 2" "$code" 2 "$out"
  expect "rollback: komunikat z powodem" "$out" "przywrócono wersję 1.0.1" "nie potwierdziła uruchomienia w ciągu 2 s"
  [ "$(upd_version)" = 1.0.1 ] && codesign --verify --deep --strict "$UPD_APP" 2>/dev/null && [ "$(upd_leftovers)" = 0 ] \
    && pass "rollback: przywrócono 1.0.1 (podpis poprawny, bez kopii roboczych)" || fail "rollback: stan" "$(upd_version); $(ls -A "$U/apps")"
  expect "rollback: nowa wersja uruchomiona, potem poprzednia" "$(cat "$U/launches.log")" "open $UPD_APP" "launched 1.0.2" "launched 1.0.1"

  # ---- relaunch with confirmation
  : > "$U/launches.log"
  out="$(upd api-ok install --beta --relaunch --confirm-timeout 10)"; code=$?
  expect_code "relaunch: kod 0" "$code" 0 "$out"
  [ "$(upd_version)" = 1.1.0-beta.1 ] && [ "$(upd_leftovers)" = 0 ] \
    && pass "relaunch: zainstalowano 1.1.0-beta.1, start potwierdzony" || fail "relaunch: stan" "$(upd_version); $(ls -A "$U/apps")"
  expect "relaunch: uruchomiono nową wersję" "$(cat "$U/launches.log")" "launched 1.1.0-beta.1"

  # ---- atomic swap primitive and maintainer tooling
  mkdir -p "$U/swap/a.app" "$U/swap/b.app"; echo A > "$U/swap/a.app/x"; echo B > "$U/swap/b.app/x"
  "$CTL" __swap-bundles "$U/swap/a.app" "$U/swap/b.app"
  [ "$(cat "$U/swap/a.app/x")$(cat "$U/swap/b.app/x")" = BA ] && pass "__swap-bundles: atomowa zamiana katalogów" || fail "__swap-bundles"
  out="$(upd_tool verify "$U/www/files/v1.0.1/cmcr-update.json" "$U/www/files/v1.0.1/cmcr-update.json.sig" \
    --keys-from "$ROOT/Sources/CMCRCore/UpdateKeys.swift" 2>&1)"; code=$?
  expect_code "update-signing: klucze z UpdateKeys.swift nie przyjmują klucza testowego" "$code" 1 "$out"
  out="$(env -u CMCR_UPDATE_SIGNING_KEY "$U/tools/update-signing" keygen --file "$ROOT/Tests/e2e/updater/e2e-test.key" 2>&1)"; code=$?
  if [ "$code" != 0 ] && [ ! -e "$ROOT/Tests/e2e/updater/e2e-test.key" ]; then pass "update-signing: odmowa zapisu klucza w repozytorium"
  else rm -f "$ROOT/Tests/e2e/updater/e2e-test.key"; fail "update-signing: klucz zapisany w repozytorium" "$out"; fi
  cp "$U/keys/test.key" "$U/keys/loose.key"; chmod 644 "$U/keys/loose.key"
  out="$(env -u CMCR_UPDATE_SIGNING_KEY CMCR_UPDATE_SIGNING_KEY_FILE="$U/keys/loose.key" "$U/tools/update-signing" public-key 2>&1)"
  expect "update-signing: odmowa użycia klucza czytelnego dla innych" "$out" "chmod 600"
  printf 'leaked: %s\n' "$(cat "$U/keys/test.key")" > "$U/leaked.txt"
  out="$(printf '%s\0%s\0' "$UPD_SRC/fixtures.py" "$U/leaked.txt" | upd_tool leak-check 2>&1)"; code=$?
  expect "update-signing leak-check: wykrywa klucz prywatny w pliku" "$out" "KLUCZ PRYWATNY" "leaked.txt"
  out="$(printf '%s\0' "$UPD_SRC/fixtures.py" | upd_tool leak-check 2>&1)"; code=$?
  expect_code "update-signing leak-check: czyste pliki" "$code" 0 "$out"
  out="$(bash -n "$ROOT/scripts/release.sh" && bash -n "$ROOT/scripts/make-signing-identity.sh" && bash -n "$ROOT/scripts/build-app.sh" && echo ok 2>&1)"
  expect "skrypty wydania: składnia" "$out" "ok"
}
upd_run
[ -n "$UPD_SERVER" ] && { kill "$UPD_SERVER"; wait "$UPD_SERVER"; } 2>/dev/null
unset -f upd_run upd_tool upd_bundle upd_release upd upd_version upd_leftovers 2>/dev/null
