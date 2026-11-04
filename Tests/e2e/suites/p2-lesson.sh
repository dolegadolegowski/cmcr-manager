# End of lesson without anybody at the screen (AUDIT DOD-08). Sourced by Tests/e2e/run.sh.
section "Zakończ zajęcia: zamykanie aplikacji, gdy nikt nie jest zalogowany (AUDIT DOD-08)"
pl_backup="$(cat "$WORK/config/classroom.json" 2>/dev/null)"
python3 - "$WORK/config/classroom.json" <<'PY'
import json, sys, os
p = sys.argv[1]
cfg = json.load(open(p)) if os.path.exists(p) else {}
cfg.setdefault("end", {})
cfg["end"].update({"warn": False, "collect": False, "quitApps": True, "quitAllApps": False, "apps": "Kalkulator Test",
                   "cleanShared": False, "cleanDownloads": False, "logout": False, "power": "none"})
json.dump(cfg, open(p, "w"), ensure_ascii=False)
PY
touch "$WORK/fake-no-console"
out="$(ctlpw lesson end 1 --no-wait --yes)"; code=$?
rm -f "$WORK/fake-no-console"
expect_code "zamykanie bez ucznia: kod 0" "$code" 0 "$out"
expect "zamykanie bez ucznia: krok pominięty" "$out" "nikt nie jest zalogowany"
expect_not "zamykanie bez ucznia: bez fałszywego „zamknięto”" "$out" "zamknięto:"
if [ -n "$pl_backup" ]; then printf '%s' "$pl_backup" > "$WORK/config/classroom.json"; else rm -f "$WORK/config/classroom.json"; fi
