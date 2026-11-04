# cmcrctl unity latest|list|install: Unity editors through Unity Hub (headless) on the iMacs. Sourced by Tests/e2e/run.sh.
# No network: the Unity Release API answers from a file (CMCR_E2E_UNITY_RELEASES, honoured only in this harness), and
# Unity Hub is the fake from fakes.sh (_e2e_unity_hub), installed into $WORK/Applications (CMCR_APPS_DIR of the test sshd).

UNITY_HUB="$WORK/Applications/Unity Hub.app/Contents/MacOS/Unity Hub"
UNITY_ED="$WORK/Applications/Unity/Hub/Editor"
UNITY_ARCH=x86_64; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && UNITY_ARCH=arm64
# unity_release VERSION CHANGESET STREAM BYTES – one release as the API describes it (both architectures, android, ios).
unity_release() {
  local arch
  printf '{"version": "%s", "shortRevision": "%s", "releaseDate": "2026-11-03T16:15:27.205Z", "stream": "%s", "downloads": [' "$1" "$2" "$3"
  for arch in ARM64 X86_64; do
    [ "$arch" = X86_64 ] && printf ','
    printf '{"platform": "MAC_OS", "architecture": "%s", "downloadSize": {"value": %s, "unit": "BYTE"},' "$arch" "$4"
    printf ' "installedSize": {"value": %s, "unit": "BYTE"}, "modules": [' "$4"
    printf '{"id": "android", "downloadSize": {"value": 1000, "unit": "BYTE"}, "installedSize": {"value": 2000, "unit": "BYTE"},'
    printf ' "subModules": [{"id": "android-open-jdk-17.0.18+8", "downloadSize": {"value": 10, "unit": "BYTE"}, "installedSize": {"value": 20, "unit": "BYTE"}}]},'
    printf '{"id": "ios", "downloadSize": {"value": 1000, "unit": "BYTE"}, "installedSize": {"value": 2000, "unit": "BYTE"}}]}'
  done
  printf ']}'
}
{ printf '{"offset": 0, "limit": 10, "total": 4, "results": ['
  unity_release 6000.6.7f1 b22767f04f04 SUPPORTED 5000; printf ','
  unity_release 6000.6.8f1 237b6593792b SUPPORTED 5000; printf ','
  unity_release 6000.7.0b7 0625e1538ccf BETA 5000; printf ','
  # More than any disk: the free-space check must stop before Unity Hub is started.
  unity_release 6000.3.28f1 8f082d2fe476 LTS 4000000000000000000
  printf ']}'; } > "$WORK/unity-releases.json"
export CMCR_E2E_UNITY_RELEASES="$WORK/unity-releases.json"
un() { ctlpw unity "$@" </dev/null; }

section "Unity – cmcrctl unity (Unity Hub w trybie headless)"
clear_fakelog
out="$(un --help)"; code=$?
expect "unity --help: pomoc wszystkich form" "$out" "cmcrctl unity latest LINIA" "cmcrctl unity install WERSJA|LINIA KOMP" "-j N"
expect_code "unity --help: kod 0" "$code" 0 "$out"
out="$(un install 6000.6)"; code=$?
expect_code "unity install bez listy komputerów w skrypcie: kod 2" "$code" 2 "$out"
out="$(un install 6000.6 1 --modules andriod)"; code=$?
expect "unity install: nieznany moduł odrzucony przed połączeniem" "$out" "nie ma modułów: andriod"
expect_code "unity install: nieznany moduł – kod 2" "$code" 2 "$out"
out="$(un install '6000.6; id' 1)"; code=$?
expect_code "unity install: nieprawidłowa wersja – kod 2" "$code" 2 "$out"
out="$(un install 6000.6 1 --changeset 237b6593792b)"; code=$?
expect_code "unity install: --changeset z linią – kod 2" "$code" 2 "$out"
out="$(un latest 6000.6 1 --modules ios)"; code=$?
expect_code "unity latest: opcja instalacji odrzucona – kod 2" "$code" 2 "$out"
expect_not "unity: błędy użycia niczego nie uruchomiły na iMacu" "$(fakelog)" "unity-hub"

out="$(un latest 6000.6)"; code=$?
expect "unity latest: najnowsza wersja końcowa linii i jej changeset" "$out" "6000.6.8f1 237b6593792b" "Wydano: 2026-11-03 (SUPPORTED)"
expect_code "unity latest: kod 0" "$code" 0 "$out"
out="$(un latest 6000.7)"; code=$?
expect "unity latest: linia z samymi betami – czytelny błąd" "$out" "nie ma jeszcze wersji końcowej"
expect_code "unity latest: linia bez wersji końcowej – kod 1" "$code" 1 "$out"

rm -rf "$WORK/Applications/Unity Hub.app" "$WORK/Applications/Unity"
out="$(un install 6000.6 1 --modules android)"; code=$?
expect "unity install: brak Unity Hub na iMacu – wskazówka" "$out" "Brak Unity Hub" "unity-hub"
expect_code "unity install: brak Unity Hub – kod 1" "$code" 1 "$out"

mkdir -p "$(dirname "$UNITY_HUB")"
printf '#!/bin/bash\n_e2e_unity_hub "$@"\n' > "$UNITY_HUB"
chmod +x "$UNITY_HUB"
clear_fakelog
out="$(un install 6000.6 1 --modules android)"; code=$?
expect "unity install 6000.6: rozwiązana do 6000.6.8f1 przed instalacją" "$out" "Unity 6000.6.8f1 (changeset 237b6593792b, najnowsza w linii 6000.6"
expect "unity install: Hub dostał wersję, changeset, architekturę i moduły" "$(fakelog)" \
  "unity-hub install --version 6000.6.8f1 --changeset 237b6593792b --architecture $UNITY_ARCH -m android --childModules --errors"
expect "unity install: wynik sprawdzony na dysku" "$out" "✔ Unity 6000.6.8f1 ($UNITY_ARCH) w $UNITY_ED/6000.6.8f1, moduły: android"
expect_code "unity install: kod 0" "$code" 0 "$out"
[ -x "$UNITY_ED/6000.6.8f1/Unity.app/Contents/MacOS/Unity" ] && pass "unity install: edytor w folderze Unity Hub" \
  || fail "unity install: brak edytora" "$(ls -laR "$WORK/Applications/Unity" 2>&1)"

clear_fakelog
out="$(un install 6000.6 1 --modules android)"; code=$?
expect "unity install: zainstalowany edytor z modułami pominięty" "$out" "Unity 6000.6.8f1 jest już zainstalowany (moduły: android) – pominięto"
expect_not "unity install: pominięty – Hub nie instaluje ponownie" "$(fakelog)" "unity-hub install "
expect_code "unity install: pominięty – kod 0" "$code" 0 "$out"

clear_fakelog
out="$(un install 6000.6.8f1 1 --modules android,ios)"; code=$?
expect "unity install: tylko brakujący moduł" "$out" "brakujące moduły: ios" "✔ Unity 6000.6.8f1"
expect "unity install: install-modules tylko z brakującym modułem" "$(fakelog)" \
  "unity-hub install-modules --version 6000.6.8f1 -m ios --childModules --errors"
expect_not "unity install: zainstalowany moduł nie jest instalowany ponownie" "$(fakelog)" "-m android"
expect_code "unity install: dodanie modułu – kod 0" "$code" 0 "$out"

out="$(un list 1)"; code=$?
expect "unity list: zainstalowane edytory" "$out" "imac01:" "6000.6.8f1 (atrapa) installed at"
expect_code "unity list: kod 0" "$code" 0 "$out"

: > "$WORK/unity-hub.fail"
clear_fakelog
out="$(un install 6000.6.7f1 1 --changeset b22767f04f04)"; code=$?
rm -f "$WORK/unity-hub.fail"
expect "unity install: pełna wersja z --changeset bez pytania Unity Release API" "$out" "bez sprawdzania w Unity Release API"
expect "unity install: nieudana instalacja Hub – błąd z kodem" "$out" "Unity Hub zakończył pracę (kod 1), ale w $UNITY_ED/6000.6.7f1 nie ma edytora Unity 6000.6.7f1"
expect_code "unity install: nieudana instalacja – kod 1" "$code" 1 "$out"

: > "$WORK/unity-hub.rc1"
out="$(un install 6000.6.7f1 1)"; code=$?
rm -f "$WORK/unity-hub.rc1"
expect "unity install: kod 1 z Hub przy zainstalowanym edytorze to sukces z uwagą" "$out" "Uwaga: Unity Hub zakończył się kodem 1" "✔ Unity 6000.6.7f1"
expect_code "unity install: Hub kod 1, edytor jest – kod 0" "$code" 0 "$out"

: > "$WORK/unity-hub.nomodules"
out="$(un install 6000.6.7f1 1 --modules ios)"; code=$?
rm -f "$WORK/unity-hub.nomodules"
expect "unity install: moduł, którego Hub nie zainstalował – błąd" "$out" "nie zainstalowano modułów: ios"
expect_code "unity install: brak modułu po instalacji – kod 1" "$code" 1 "$out"

clear_fakelog
out="$(un install 6000.3 1)"; code=$?
expect "unity install: za mało miejsca na dysku – nic nie pobrano" "$out" "Za mało miejsca na dysku" "Nic nie zainstalowano"
expect_not "unity install: za mało miejsca – Hub nie uruchomiony do instalacji" "$(fakelog)" "unity-hub install "
expect_code "unity install: za mało miejsca – kod 1" "$code" 1 "$out"

clear_fakelog
chmod 555 "$UNITY_ED"
out="$(un install 6000.6.1f1 1 --changeset 7efac9f6c10e)"; code=$?
chmod 755 "$UNITY_ED"
expect "unity install: folder Unity Hub bez prawa zapisu – wskazówka" "$out" "nie może zapisywać w $UNITY_ED" "chown -R"
expect_not "unity install: bez prawa zapisu – Hub nie uruchomiony do instalacji" "$(fakelog)" "unity-hub install "
expect_code "unity install: folder bez prawa zapisu – kod 1" "$code" 1 "$out"

out="$(un install 6000.7 1)"; code=$?
expect "unity install: linia bez wersji końcowej – czytelny błąd" "$out" "nie ma jeszcze wersji końcowej"
expect_code "unity install: linia bez wersji końcowej – kod 1" "$code" 1 "$out"
unset CMCR_E2E_UNITY_RELEASES
