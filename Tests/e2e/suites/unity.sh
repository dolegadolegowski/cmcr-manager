# cmcrctl unity latest|list|install: Unity editors through Unity Hub (headless) on the iMacs. Sourced by Tests/e2e/run.sh.
# No network: the Unity Release API answers from a file (CMCR_E2E_UNITY_RELEASES, honoured only in this harness), and
# Unity Hub is the fake from fakes.sh (_e2e_unity_hub), installed into $WORK/Applications (CMCR_APPS_DIR of the test sshd).

UNITY_HUB="$WORK/Applications/Unity Hub.app/Contents/MacOS/Unity Hub"
UNITY_ED="$WORK/Applications/Unity/Hub/Editor"
UNITY_ARCH=x86_64; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && UNITY_ARCH=arm64
# unity_release VERSION CHANGESET STREAM BYTES – one release as the API describes it (both architectures; editor download
# and unpacked size BYTES each; android with OpenJDK under it, ios – the modules without size).
unity_release() {
  local arch
  printf '{"version": "%s", "shortRevision": "%s", "releaseDate": "2026-11-03T16:15:27.205Z", "stream": "%s", "downloads": [' "$1" "$2" "$3"
  for arch in ARM64 X86_64; do
    [ "$arch" = X86_64 ] && printf ','
    printf '{"platform": "MAC_OS", "architecture": "%s", "downloadSize": {"value": %s, "unit": "BYTE"},' "$arch" "$4"
    printf ' "installedSize": {"value": %s, "unit": "BYTE"}, "modules": [' "$4"
    printf '{"id": "android", "downloadSize": {"value": 0, "unit": "BYTE"}, "installedSize": {"value": 0, "unit": "BYTE"},'
    printf ' "subModules": [{"id": "android-open-jdk-17.0.18+8", "downloadSize": {"value": 0, "unit": "BYTE"}, "installedSize": {"value": 0, "unit": "BYTE"}}]},'
    printf '{"id": "ios", "downloadSize": {"value": 0, "unit": "BYTE"}, "installedSize": {"value": 0, "unit": "BYTE"}}]}'
  done
  printf ']}'
}
# The size check keeps 10% of the volume (at least 10 GB) free, which this Mac may not have: the releases installed
# here have no size (no check). 6000.5.9f1 needs 1 GB less than is free – it fits only without the reserve;
# 6000.3.28f1 needs more than any disk.
unity_free_kb="$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')"
{ printf '{"offset": 0, "limit": 10, "total": 5, "results": ['
  unity_release 6000.6.7f1 b22767f04f04 SUPPORTED 0; printf ','
  unity_release 6000.6.8f1 237b6593792b SUPPORTED 0; printf ','
  unity_release 6000.7.0b7 0625e1538ccf BETA 0; printf ','
  unity_release 6000.5.9f1 3ff58d469c8a SUPPORTED $(( (unity_free_kb - 1048576) * 512 )); printf ','
  unity_release 6000.3.28f1 8f082d2fe476 LTS 4000000000000000000
  printf ']}'; } > "$WORK/unity-releases.json"
export CMCR_E2E_UNITY_RELEASES="$WORK/unity-releases.json"
un() { ctlpw unity "$@" </dev/null; }
# unity_flag NAME… – control files of the fake Unity Hub (see fakes.sh); unity_flags_off removes them all.
unity_flag() { local f; for f in "$@"; do : > "$WORK/unity-hub.$f"; done; }
unity_flags_off() { rm -f "$WORK"/unity-hub.*; }
# unity_editor DIR [unsigned] – a Unity.app as Hub unpacks it (ad-hoc signed; "unsigned": only the binary).
unity_editor() {
  mkdir -p "$1/Unity.app/Contents/MacOS"
  if [ "${2:-}" = unsigned ]; then
    printf '#!/bin/sh\n' > "$1/Unity.app/Contents/MacOS/Unity"; chmod +x "$1/Unity.app/Contents/MacOS/Unity"; return
  fi
  cp /bin/sleep "$1/Unity.app/Contents/MacOS/Unity"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Unity</string><key>CFBundleIdentifier</key><string>com.unity3d.UnityEditor5.x</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n' \
    > "$1/Unity.app/Contents/Info.plist"
  codesign --force --sign - "$1/Unity.app" >/dev/null 2>&1
}

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
out="$(un list 1 5)"; code=$?
expect "unity list: nadmiarowy komputer odrzucony ze wskazówką" "$out" "Nadmiarowy argument „5”" "1,5"
expect_code "unity list: nadmiarowy argument – kod 2" "$code" 2 "$out"
expect_not "unity: błędy użycia niczego nie uruchomiły na iMacu" "$(fakelog)" "unity-hub"

out="$(un latest 6000.6)"; code=$?
expect "unity latest: najnowsza wersja końcowa linii i jej changeset" "$out" "6000.6.8f1 237b6593792b" "Wydano: 2026-11-03 (SUPPORTED)"
expect_code "unity latest: kod 0" "$code" 0 "$out"
out="$(un latest 6000.7)"; code=$?
expect "unity latest: linia z samymi betami – czytelny błąd" "$out" "nie ma jeszcze wersji końcowej"
expect_code "unity latest: linia bez wersji końcowej – kod 1" "$code" 1 "$out"

rm -rf "$WORK/Applications/Unity Hub.app" "$WORK/Applications/Unity"
unity_flags_off
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
[ -f "$UNITY_ED/6000.6.8f1/.cmcr-installed" ] && pass "unity install: znacznik ukończonej instalacji zapisany" \
  || fail "unity install: brak znacznika" "$(ls -la "$UNITY_ED/6000.6.8f1" 2>&1)"

clear_fakelog
out="$(un install 6000.6 1 --modules android)"; code=$?
expect "unity install: kompletny edytor z modułami pominięty" "$out" "Unity 6000.6.8f1 jest już zainstalowany (moduły: android) – pominięto"
expect_not "unity install: pominięty – Hub nie instaluje ponownie" "$(fakelog)" "unity-hub install "
expect_code "unity install: pominięty – kod 0" "$code" 0 "$out"

clear_fakelog
out="$(un install 6000.6.8f1 1 --modules android,ios)"; code=$?
expect "unity install: tylko brakujący moduł" "$out" "brakuje: ios" "✔ Unity 6000.6.8f1"
expect "unity install: install-modules tylko z brakującym modułem" "$(fakelog)" \
  "unity-hub install-modules --version 6000.6.8f1 -m ios --childModules --errors"
expect_not "unity install: zainstalowany moduł nie jest instalowany ponownie" "$(fakelog)" "-m android"
expect_code "unity install: dodanie modułu – kod 0" "$code" 0 "$out"

out="$(un list 1)"; code=$?
expect "unity list: zainstalowane edytory" "$out" "imac01:" "6000.6.8f1 (atrapa) installed at"
expect_code "unity list: kod 0" "$code" 0 "$out"

section "Unity – kompletność modułów, przerwane instalacje, Hub z błędem"
# Modules without the ones under them (--childModules stopped half-way) and Hub's code 1: not a success, and the next
# run installs the missing parts instead of skipping the Mac.
unity_flag nochildren rc1
out="$(un install 6000.6.7f1 1 --modules android)"; code=$?
unity_flags_off
expect "unity install: brak modułów podrzędnych mimo „android” w modules.json – błąd" "$out" \
  "brakuje: android-open-jdk-17.0.18+8 android-sdk-ndk-tools"
expect_not "unity install: niekompletny moduł nie jest sukcesem" "$out" "✔ Unity 6000.6.7f1"
expect_code "unity install: niekompletny moduł – kod 1" "$code" 1 "$out"
clear_fakelog
out="$(un install 6000.6.7f1 1 --modules android)"; code=$?
expect "unity install: następne uruchomienie doinstalowuje brakujące części" "$(fakelog)" \
  "unity-hub install-modules --version 6000.6.7f1 -m android-open-jdk-17.0.18+8 -m android-sdk-ndk-tools --childModules --errors"
expect_not "unity install: niekompletny moduł nie jest pomijany" "$out" "pominięto"
expect "unity install: po doinstalowaniu – sukces" "$out" "✔ Unity 6000.6.7f1"
expect_code "unity install: po doinstalowaniu – kod 0" "$code" 0 "$out"
# A file the Android SDK action needs is gone although modules.json says the module is there.
rm -f "$UNITY_ED/6000.6.7f1/PlaybackEngines/AndroidPlayer/OpenJDK/bin/java"
clear_fakelog
out="$(un install 6000.6.7f1 1 --modules android)"; code=$?
expect "unity install: brak OpenJDK na dysku – moduł doinstalowany" "$(fakelog)" \
  "unity-hub install-modules --version 6000.6.7f1 -m android-open-jdk-17.0.18+8 --childModules --errors"
expect_code "unity install: brak pliku OpenJDK – kod 0 po doinstalowaniu" "$code" 0 "$out"

unity_flag fail
clear_fakelog
out="$(un install 6000.6.6f1 1 --changeset d20c9ac777da)"; code=$?
unity_flags_off
expect "unity install: pełna wersja z --changeset bez pytania Unity Release API" "$out" "bez sprawdzania w Unity Release API"
expect "unity install: nieudana instalacja Hub – błąd z kodem" "$out" "Unity Hub zakończył pracę (kod 1), ale w $UNITY_ED/6000.6.6f1 nie ma edytora Unity 6000.6.6f1"
expect_code "unity install: nieudana instalacja – kod 1" "$code" 1 "$out"

unity_flag rc1
out="$(un install 6000.6.6f1 1 --changeset d20c9ac777da)"; code=$?
unity_flags_off
expect "unity install: kod 1 z Hub przy kompletnym, podpisanym edytorze to sukces z uwagą" "$out" \
  "Uwaga: Unity Hub zakończył się kodem 1" "✔ Unity 6000.6.6f1"
expect_code "unity install: Hub kod 1, edytor kompletny – kod 0" "$code" 0 "$out"

unity_flag broken
out="$(un install 6000.6.5f1 1 --changeset 3ff58d469c8a)"; code=$?
unity_flags_off
expect "unity install: kod 1 z Hub i uszkodzony Unity.app – błąd" "$out" "podpis Unity.app się nie zgadza"
expect_code "unity install: uszkodzony edytor – kod 1" "$code" 1 "$out"
[ ! -f "$UNITY_ED/6000.6.5f1/.cmcr-installed" ] && pass "unity install: uszkodzony edytor bez znacznika" \
  || fail "unity install: znacznik mimo uszkodzonego edytora"
# The next run does not take the binary left behind for a finished install.
clear_fakelog
out="$(un install 6000.6.5f1 1 --changeset 3ff58d469c8a)"; code=$?
expect "unity install: przerwana instalacja – ostrzeżenie i instalacja od nowa" "$out" "niepełna instalacja Unity 6000.6.5f1" "usuń ten folder"
expect "unity install: przerwana instalacja – Hub instaluje edytor ponownie" "$(fakelog)" "unity-hub install --version 6000.6.5f1"
expect_code "unity install: przerwana instalacja – kod 0 po ponownej instalacji" "$code" 0 "$out"

# An editor installed some other way (no marker): skipped only with Hub's modules.json and a valid signature.
unity_editor "$UNITY_ED/6000.6.4f1"
echo '[{"id": "ios", "parent": "", "selected": false}]' > "$UNITY_ED/6000.6.4f1/modules.json"
clear_fakelog
out="$(un install 6000.6.4f1 1 --changeset 12bfff696524)"; code=$?
expect "unity install: edytor spoza CMCR z modules.json i podpisem – pominięty" "$out" "Unity 6000.6.4f1 jest już zainstalowany – pominięto"
expect_not "unity install: edytor spoza CMCR – Hub nie instaluje ponownie" "$(fakelog)" "unity-hub install "
[ -f "$UNITY_ED/6000.6.4f1/.cmcr-installed" ] && pass "unity install: edytor spoza CMCR – znacznik po sprawdzeniu" \
  || fail "unity install: edytor spoza CMCR – brak znacznika"
# Only the binary, as an install stopped right after unpacking it.
unity_editor "$UNITY_ED/6000.6.3f1" unsigned
clear_fakelog
out="$(un install 6000.6.3f1 1 --changeset 45d8eee7de74)"; code=$?
expect "unity install: sam plik Unity bez znacznika i podpisu – instalacja od nowa" "$(fakelog)" "unity-hub install --version 6000.6.3f1"
expect_code "unity install: sam plik Unity – kod 0 po instalacji" "$code" 0 "$out"

unity_flag nomodules
out="$(un install 6000.6.6f1 1 --changeset d20c9ac777da --modules ios)"; code=$?
unity_flags_off
expect "unity install: moduł, którego Hub nie zainstalował – błąd" "$out" "brakuje: ios"
expect_code "unity install: brak modułu po instalacji – kod 1" "$code" 1 "$out"

section "Unity – miejsce na dysku i prawo zapisu"
clear_fakelog
out="$(un install 6000.3 1)"; code=$?
expect "unity install: za mało miejsca na dysku – nic nie pobrano" "$out" "Za mało miejsca na dysku" "Nic nie zainstalowano"
expect_not "unity install: za mało miejsca – Hub nie uruchomiony do instalacji" "$(fakelog)" "unity-hub install "
expect_code "unity install: za mało miejsca – kod 1" "$code" 1 "$out"
if [ "$unity_free_kb" -gt 2097152 ]; then
  clear_fakelog
  out="$(un install 6000.5 1)"; code=$?
  expect "unity install: zmieściłby się, ale bez zapasu 10% dysku – zatrzymany" "$out" "Za mało miejsca na dysku" "GB zapasu (10% dysku, co najmniej 10 GB)"
  expect_not "unity install: bez zapasu – Hub nie uruchomiony do instalacji" "$(fakelog)" "unity-hub install "
  expect_code "unity install: bez zapasu – kod 1" "$code" 1 "$out"
else
  echo "  (mniej niż 2 GB wolnego miejsca – test zapasu pominięty)"
fi

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

section "Unity – moduły i Android SDK dla zainstalowanego edytora (linia = najnowsza na komputerze)"
# Newest installed 6000.6 here: 6000.6.8f1 (with android). Unity's newest release does not matter.
clear_fakelog
out="$(ctlpw _builder android-sdk 1 6000.6 34)"; code=$?
expect "android-sdk 6000.6: najnowszy zainstalowany edytor linii" "$out" "→ Unity 6000.6.8f1 (najnowsza zainstalowana z linii 6000.6)"
expect "android-sdk: sdkmanager edytora z folderu Unity Hub" "$(fakelog)" \
  "sdkmanager --sdk_root=$UNITY_ED/6000.6.8f1/PlaybackEngines/AndroidPlayer/SDK platform-tools platforms;android-34"
expect_code "android-sdk: kod 0" "$code" 0 "$out"
# 6000.6.10f1 sorts after 6000.6.8f1 as a version, not as text.
unity_editor "$UNITY_ED/6000.6.10f1"
echo '[]' > "$UNITY_ED/6000.6.10f1/modules.json"
clear_fakelog
out="$(ctlpw _builder unity-modules 1 6000.6 ios)"; code=$?
expect "unity-modules 6000.6: 6000.6.10f1 nowszy niż 6000.6.8f1" "$out" "→ Unity 6000.6.10f1 (najnowsza zainstalowana z linii 6000.6)"
expect "unity-modules: install-modules dla tej wersji" "$(fakelog)" "unity-hub install-modules --version 6000.6.10f1 -m ios --childModules --errors"
expect_not "unity-modules: bez pytania Unity Release API (ani 6000.6.8f1 z API)" "$(fakelog)" "--version 6000.6.8f1"
out="$(ctlpw _builder unity-modules 1 6000.9 ios)"; code=$?
expect "unity-modules: linia bez zainstalowanego edytora – czytelny błąd" "$out" "nie ma edytora Unity z linii 6000.9"
expect_code "unity-modules: linia bez edytora – kod 2" "$code" 2 "$out"
unset CMCR_E2E_UNITY_RELEASES
