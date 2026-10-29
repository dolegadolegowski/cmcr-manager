# Review fixes of the classroom and file browser (AUDIT REV-xx, group G4). Sourced by Tests/e2e/run.sh.
# „Wyślij pliki do tego folderu…” in the file browser uploads with Payload.make + Operations.push, as
# `cmcrctl _builder push` does; its question must describe what that upload does (AUDIT REV-31).

section "Wysyłanie do podfolderu: pliki zastąpione, foldery uzupełnione (AUDIT REV-31)"
G4="$WORK/rev-g4"
rm -rf "$G4"
mkdir -p "$G4/uczen/Prace/Projekt" "$G4/nauczyciel/Projekt"
echo "stara wersja" > "$G4/uczen/Prace/Projekt/wspolny.txt"
echo "praca ucznia" > "$G4/uczen/Prace/Projekt/moje.txt"
echo "stary plan" > "$G4/uczen/Prace/plan.txt"
echo "nowa wersja" > "$G4/nauczyciel/Projekt/wspolny.txt"
echo "nowy plan" > "$G4/nauczyciel/plan.txt"
out="$(ctl _builder push 1 "$G4/uczen/Prace" "" "" "$G4/nauczyciel/Projekt" "$G4/nauczyciel/plan.txt")"; code=$?
expect_code "podfolder: wysłano (kod 0)" "$code" 0 "$out"
[ "$(cat "$G4/uczen/Prace/plan.txt" 2>/dev/null)" = "nowy plan" ] \
  && pass "podfolder: plik o tej samej nazwie zastąpiony" || fail "podfolder: plik nie został zastąpiony" "$out"
[ "$(cat "$G4/uczen/Prace/Projekt/wspolny.txt" 2>/dev/null)" = "nowa wersja" ] \
  && pass "podfolder: plik w folderze o tej samej nazwie zastąpiony" || fail "podfolder: plik w folderze nie został zastąpiony" "$out"
[ "$(cat "$G4/uczen/Prace/Projekt/moje.txt" 2>/dev/null)" = "praca ucznia" ] \
  && pass "podfolder: folder o tej samej nazwie uzupełniony – praca ucznia została" \
  || fail "podfolder: folder o tej samej nazwie zastąpiony – praca ucznia usunięta" "$(ls -laR "$G4/uczen" 2>&1)"
rm -rf "$G4"
