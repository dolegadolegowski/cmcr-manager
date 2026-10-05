import Foundation

/// Remote scripts for classroom routines, attention mode, energy schedule and computer names.
///
/// Process tags used with `pkill -f` are assembled at run time (`"cmcr-delayed""-power"`), so the literal
/// tag never appears in the script text. The remote wrapper carries the whole script in its own argv, and a
/// literal tag would make `pkill -f` kill the session that runs it.
public extension Scripts {

    /// ARD's screen locker shipped with every macOS (`-session <id> -msg <text>`).
    static let lockScreenPath = "/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app/Contents/MacOS/LockScreen"

    // MARK: - Attention mode (lock screens)

    /// Covers the screen of the logged-in user with a message. `.automatic` tries ARD's LockScreen first and
    /// falls back to a full-screen window drawn by osascript (JavaScript for Automation).
    static func lockScreen(message: String, mode: AttentionMode, autoUnlockMinutes: Int) -> RemoteScript {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Proszę patrzeć na tablicę" : message
        let overlay = Data(attentionOverlayJXA(message: text).utf8).base64EncodedString()
        return RemoteScript(#"""
        MSG=\#(shQuote(text))
        MODE=\#(shQuote(mode.rawValue))
        MINUTES=\#(max(0, min(240, autoUnlockMinutes)))
        LS=\#(shQuote(lockScreenPath))
        TAG="CMCR_ATT""ENTION"
        if [ -z "$CONSOLE_USER" ]; then echo "CMCR:LOCK:none"; echo "Nikt nie jest zalogowany – ekran logowania i tak jest zablokowany."; exit 0; fi
        pkill -x LockScreen >/dev/null 2>&1
        pkill -f "$TAG" >/dev/null 2>&1
        USED=""
        if [ "$MODE" != overlay ]; then
          SID=""
          if [ -x "$LS" ]; then
            SID="$(ioreg -n Root -d1 -k IOConsoleUsers 2>/dev/null | grep IOConsoleUsers | tr '}' '\n' \
              | grep '"kCGSSessionOnConsoleKey"=Yes' | grep -o '"kCGSSessionIDKey"=[0-9]*' | head -1 | cut -d= -f2)"
          fi
          if [ -n "$SID" ]; then
            ( trap '' HUP; launchctl asuser "$CONSOLE_UID" "$LS" -session "$SID" -msg "$MSG" ) </dev/null >/dev/null 2>&1 &
            sleep 2
            if pgrep -x LockScreen >/dev/null 2>&1; then USED=lockscreen; fi
          fi
          if [ -z "$USED" ]; then
            if [ "$MODE" = lockScreen ]; then
              echo "✘ Blokada systemowa (LockScreen) nie uruchomiła się na tym Macu – wybierz tryb „Komunikat na pełnym ekranie”." >&2; exit 1
            fi
            echo "⚠︎ LockScreen niedostępny – używam komunikatu na pełnym ekranie."
          fi
        fi
        OVERLAY_STATE=""
        if [ -z "$USED" ]; then
          S="$(echo \#(overlay) | base64 -D)"
          # The overlay reports once whether macOS let it take the keyboard (CMCR:OVERLAY:active|inactive).
          # The file is opened here, so the descriptor reaches the user's process through launchctl and sudo.
          OV="$CMCR_TMP/overlay.out"; : > "$OV"
          ( trap '' HUP; as_console_user /usr/bin/osascript -l JavaScript -e "$S" "$TAG" ) </dev/null >"$OV" 2>/dev/null &
          sleep 2
          if pgrep -f "$TAG" >/dev/null 2>&1; then USED=overlay; else
            echo "✘ Nie udało się wyświetlić komunikatu na ekranie użytkownika $CONSOLE_USER." >&2; exit 1
          fi
          i=0
          while [ $i -lt 50 ]; do
            OVERLAY_STATE="$(sed -n 's/^CMCR:OVERLAY://p' "$OV" 2>/dev/null | head -n 1)"
            [ -n "$OVERLAY_STATE" ] && break
            sleep 0.1; i=$((i + 1))
          done
        fi
        if [ "$MINUTES" -gt 0 ]; then
          ( trap '' HUP; exec /bin/bash --noprofile --norc -c 'sleep "$1"; pkill -x LockScreen; pkill -f "$2"' "$TAG-unlock" "$((MINUTES * 60))" "$TAG" ) </dev/null >/dev/null 2>&1 &
        fi
        # First CMCR:LOCK line: the app records the lock from it (the screen is covered either way).
        echo "CMCR:LOCK:$USED"
        if [ "$USED" = overlay ] && [ "$OVERLAY_STATE" != active ]; then
          echo "CMCR:LOCKWARN:inactive"
          if [ "$OVERLAY_STATE" = inactive ]; then
            echo "⚠︎ Komunikat zakrywa ekran, ale macOS nie oddał mu klawiatury – do pierwszego kliknięcia w komunikat uczeń może przełączać aplikacje (⌘⇥) i pisać w aplikacji pod spodem. Pełną blokadę daje tryb „Blokada systemowa (LockScreen)”, jeśli działa na tym Macu."
          else
            echo "⚠︎ Komunikat zakrywa ekran, ale nie udało się potwierdzić, że przejął klawiaturę – uczeń może przełączać aplikacje (⌘⇥). Pełną blokadę daje tryb „Blokada systemowa (LockScreen)”, jeśli działa na tym Macu."
          fi
        fi
        if [ "$USED" = lockscreen ]; then KIND="blokada systemowa"; else KIND="komunikat na pełnym ekranie"; fi
        if [ "$MINUTES" -gt 0 ]; then
          echo "✔ Ekran użytkownika $CONSOLE_USER zablokowany ($KIND, automatyczne odblokowanie za $MINUTES min)."
        else
          echo "✔ Ekran użytkownika $CONSOLE_USER zablokowany ($KIND)."
        fi
        """#, asRoot: true)
    }

    static func unlockScreen() -> RemoteScript {
        RemoteScript(#"""
        TAG="CMCR_ATT""ENTION"
        FOUND=0
        if pgrep -x LockScreen >/dev/null 2>&1; then pkill -x LockScreen; FOUND=1; fi
        if pgrep -f "$TAG" >/dev/null 2>&1; then pkill -f "$TAG"; FOUND=1; fi
        echo "CMCR:UNLOCKED"
        if [ $FOUND = 1 ]; then echo "✔ Ekran odblokowany."; else echo "Ekran nie był zablokowany."; fi
        """#, asRoot: true)
    }

    /// Full-screen message window on every display, run by `osascript -l JavaScript` in the user's session.
    /// Kiosk presentation options hide the Dock and menu bar and disable app switching and Force Quit – but
    /// macOS applies them only while the overlay is the ACTIVE application. Since macOS 14 activation is
    /// cooperative: a process started over SSH that asks before it has finished launching is often refused,
    /// and the student's app keeps the keyboard. So activation is requested from a timer once `app.run` is
    /// going (`activateIgnoringOtherApps`, which still forces it then; the newer `activate()` only asks),
    /// repeated whenever the overlay loses it, and the result is printed once on stdout:
    /// `CMCR:OVERLAY:active` or `CMCR:OVERLAY:inactive` (still not active after 4 s).
    /// `--dry-run` builds the windows without showing them (used to check the script on a Mac).
    static func attentionOverlayJXA(message: String) -> String {
        """
        ObjC.import('Cocoa');
        function say(s) {
          $.NSFileHandle.fileHandleWithStandardOutput.writeData($(s + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
        }
        function run(argv) {
          var msg = \(jsLiteral(message));
          var dry = argv.indexOf('--dry-run') >= 0;
          var app = $.NSApplication.sharedApplication;
          app.setActivationPolicy(0);
          var screens = $.NSScreen.screens;
          var windows = [];
          for (var i = 0; i < screens.count; i++) {
            var f = screens.objectAtIndex(i).frame;
            var w = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(f, 0, 2, false);
            w.setLevel(1000);
            w.setBackgroundColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(0.07, 0.10, 0.18, 1.0));
            w.setCollectionBehavior(1 | 16 | 64 | 256);
            var width = f.size.width, height = f.size.height;
            var label = $.NSTextField.wrappingLabelWithString(msg);
            label.setFont($.NSFont.boldSystemFontOfSize(Math.max(34, Math.round(height / 14))));
            label.setTextColor($.NSColor.whiteColor);
            label.setAlignment(2);
            label.setFrame({origin: {x: width * 0.08, y: height * 0.32}, size: {width: width * 0.84, height: height * 0.36}});
            w.contentView.addSubview(label);
            var note = $.NSTextField.labelWithString('Ekran zablokowany przez nauczyciela');
            note.setFont($.NSFont.systemFontOfSize(Math.max(15, Math.round(height / 48))));
            note.setTextColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(1.0, 1.0, 1.0, 0.6));
            note.setAlignment(2);
            note.setFrame({origin: {x: 0, y: height * 0.18}, size: {width: width, height: height * 0.06}});
            w.contentView.addSubview(note);
            windows.push(w);
          }
          if (dry) { return 'windows=' + windows.length; }
          for (var j = 0; j < windows.length; j++) { windows[j].makeKeyAndOrderFront(null); windows[j].orderFrontRegardless; }
          // Stored now, applied by macOS whenever the overlay is the active application.
          app.setPresentationOptions(2 | 8 | 32 | 64 | 128 | 256);
          var ticks = 0, reported = false;
          $.NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock(0.5, true, function (t) {
            ticks++;
            if (!app.isActive) {
              app.activateIgnoringOtherApps(true);
              for (var k = 0; k < windows.length; k++) { windows[k].orderFrontRegardless; }
            }
            if (!reported && (app.isActive || ticks >= 8)) {
              reported = true;
              say(app.isActive ? 'CMCR:OVERLAY:active' : 'CMCR:OVERLAY:inactive');
            }
          });
          app.run;
        }
        """
    }

    /// A JavaScript string literal (JSON plus the two line separators JSON leaves unescaped).
    internal static func jsLiteral(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// An AppleScript string literal.
    internal static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Two-way message ("Zapytaj uczniów")

    /// Shows a question in the user's session and waits for the answer. With `buttons` empty the dialog has a
    /// text field and a "Wyślij" button; otherwise the student picks one of up to three buttons.
    static func ask(title: String, prompt: String, buttons: [String], timeoutSeconds: Int) -> RemoteScript {
        let apple = askAppleScript(title: title, prompt: prompt, buttons: buttons, timeoutSeconds: timeoutSeconds)
        let b64 = Data(apple.utf8).base64EncodedString()
        return RemoteScript(#"""
        if [ -z "$CONSOLE_USER" ]; then echo "CMCR:NO_USER"; echo "Nikt nie jest zalogowany."; exit 0; fi
        echo "CMCR:USER:$CONSOLE_USER"
        OUT="$(echo \#(b64) | base64 -D | as_console_user /bin/sh -c 'S="$(cat)"; /usr/bin/osascript -e "$S"' 2>"$CMCR_TMP/err")"; RC=$?
        OUT="$(printf '%s\n' "$OUT" | grep '^CMCR:' | head -1)"
        if [ -n "$OUT" ]; then
          printf '%s\n' "$OUT"
        elif [ $RC -ne 0 ]; then
          echo "✘ Nie udało się wyświetlić pytania: $(head -c 300 "$CMCR_TMP/err" 2>/dev/null)" >&2; exit 1
        else
          echo "CMCR:TIMEOUT"
        fi
        """#)
    }

    /// The dialog behind `ask`; prints `CMCR:ANSWER:<button>[<tab><text>]`, `CMCR:TIMEOUT` or `CMCR:CANCELLED`.
    internal static func askAppleScript(title: String, prompt: String, buttons: [String], timeoutSeconds: Int) -> String {
        let names = Array(buttons.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3))
        let timeout = max(10, min(3600, timeoutSeconds))
        let list = (names.isEmpty ? ["Wyślij"] : names).map(appleScriptLiteral).joined(separator: ", ")
        let field = names.isEmpty ? " default answer \"\"" : ""
        let answer = names.isEmpty ? "(button returned of r) & tab & (text returned of r)" : "(button returned of r)"
        return """
        activate
        try
          set r to display dialog \(appleScriptLiteral(prompt))\(field) with title \(appleScriptLiteral(title)) buttons {\(list)} default button 1 giving up after \(timeout) with icon note
        on error number -128
          return "CMCR:CANCELLED"
        end try
        if gave up of r then return "CMCR:TIMEOUT"
        return "CMCR:ANSWER:" & \(answer)
        """
    }

    // MARK: - Delayed power actions

    /// Restart/shutdown/sleep after `minutes`, optionally warning the user first. Cancel with
    /// `cancelDelayedPower()`.
    ///
    /// A restart arms the FileVault unlock right away (`cmcr_arm_authrestart`): the detached timer no longer
    /// has the password, and keeping it in a root process for up to the whole delay is not an option.
    static func delayedPower(_ action: PowerAction, minutes: Int, warning: String?) -> RemoteScript {
        let verb: String
        switch action {
        case .restart: verb = "restart"
        case .shutdown: verb = "shutdown"
        case .sleep, .displaySleep: verb = "sleep"
        }
        let secs = max(0, minutes) * 60
        var warn = ""
        if let warning, !warning.isEmpty {
            let apple = "activate\ndisplay dialog \(appleScriptLiteral(warning)) with title \"Komunikat od nauczyciela\" buttons {\"OK\"} default button \"OK\" with icon caution giving up after \(max(60, secs))"
            warn = #"""
            if [ -n "$CONSOLE_USER" ]; then
              echo \#(Data(apple.utf8).base64EncodedString()) | base64 -D | as_console_user /bin/sh -c 'S="$(cat)"; /usr/bin/osascript -e "$S" </dev/null >/dev/null 2>&1 &' \
                && echo "Ostrzeżenie wyświetlone użytkownikowi $CONSOLE_USER."
            fi
            """#
        }
        var arm = ""
        if action == .restart {
            arm = #"""
            \#(fileVaultArmFunction)
            if cmcr_arm_authrestart "przy zaplanowanym restarcie" && [ "$(fdesetup isactive 2>/dev/null)" = "true" ]; then
              echo "  Odblokowanie pozostaje uzbrojone do najbliższego restartu – także gdy anulujesz zaplanowany restart."
            fi
            """#
        }
        return RemoteScript(#"""
        TAG="cmcr-delayed""-power"
        pkill -f "$TAG" >/dev/null 2>&1
        \#(arm)
        \#(warn)
        ( trap '' HUP; exec /bin/bash --noprofile --norc -c 'sleep "$1"; case "$2" in restart) shutdown -r now ;; shutdown) shutdown -h now ;; sleep) pmset sleepnow ;; esac' "$TAG" \#(secs) \#(verb) ) </dev/null >/dev/null 2>&1 &
        echo "✔ \#(action.label): za \#(max(0, minutes)) min (ok. $(date -v+\#(secs)S +%H:%M)). Można to anulować przyciskiem „Anuluj zaplanowane”."
        """#, asRoot: true)
    }

    static func cancelDelayedPower() -> RemoteScript {
        RemoteScript(#"""
        TAG="cmcr-delayed""-power"
        if pgrep -f "$TAG" >/dev/null 2>&1; then
          RESTART_PENDING=0
          pgrep -f "$TAG [0-9]+ restart" >/dev/null 2>&1 && RESTART_PENDING=1
          pkill -f "$TAG" && echo "✔ Anulowano zaplanowane wyłączenie, restart lub uśpienie."
          if [ $RESTART_PENDING = 1 ] && [ "$(fdesetup isactive 2>/dev/null)" = "true" ]; then
            echo "⚠︎ FileVault: jeśli przy planowaniu restartu uzbrojono jednorazowe odblokowanie dysku (fdesetup authrestart), zostaje ono uzbrojone do najbliższego restartu – macOS nie pozwala go cofnąć. Przy tym restarcie iMac uruchomi się bez pytania o hasło FileVault (okno logowania zostaje)."
          fi
        else
          echo "Nic nie było zaplanowane."
        fi
        killall shutdown >/dev/null 2>&1 && echo "✔ Anulowano też wyłączenie zaplanowane poleceniem shutdown."
        exit 0
        """#, asRoot: true)
    }

    /// FileVault state; a restart of a FileVault Mac stops at the unlock screen until someone logs in.
    static func fileVaultStatus() -> RemoteScript {
        RemoteScript(#"""
        if [ "$(fdesetup isactive 2>/dev/null)" = true ]; then echo "fv=on"; else echo "fv=off"; fi
        if [ "$(fdesetup supportsauthrestart 2>/dev/null)" = true ]; then echo "authrestart=yes"; else echo "authrestart=no"; fi
        """#)
    }

    // MARK: - Energy schedule

    /// `pmset repeat …` plus the optional power policy (restart after power loss, wake for network access).
    static func applyEnergySchedule(_ schedule: EnergySchedule, autoRestart: Bool, wakeOnLAN: Bool) -> RemoteScript {
        guard let args = schedule.pmsetArguments else {
            return RemoteScript("echo \(shQuote("✘ " + (schedule.validationError ?? "Niepoprawny harmonogram."))) >&2; exit 2")
        }
        return RemoteScript(#"""
        pmset \#(args.map(shQuote).joined(separator: " ")) || { echo "✘ pmset nie przyjął harmonogramu." >&2; exit 1; }
        echo \#(shQuote("✔ Harmonogram: " + schedule.summary))
        \#(autoRestart ? "pmset -a autorestart 1 && echo '✔ Włączanie po zaniku zasilania: tak'" : ":")
        \#(wakeOnLAN ? "pmset -a womp 1 && echo '✔ Budzenie przez sieć (Wake-on-LAN): tak'" : ":")
        echo "CMCR:SCHED"; pmset -g sched 2>&1
        echo "CMCR:POLICY"; pmset -g 2>/dev/null | awk '$1=="autorestart"||$1=="womp"||$1=="sleep"||$1=="displaysleep"{print $1"="$2}'
        """#, asRoot: true)
    }

    static func cancelEnergySchedule() -> RemoteScript {
        RemoteScript(#"""
        pmset repeat cancel || { echo "✘ Nie udało się usunąć harmonogramu." >&2; exit 1; }
        echo "✔ Harmonogram zasilania usunięty."
        echo "CMCR:SCHED"; pmset -g sched 2>&1
        """#, asRoot: true)
    }

    static func energyScheduleStatus() -> RemoteScript {
        RemoteScript(#"""
        echo "CMCR:SCHED"; pmset -g sched 2>&1
        echo "CMCR:POLICY"; pmset -g 2>/dev/null | awk '$1=="autorestart"||$1=="womp"||$1=="sleep"||$1=="displaysleep"{print $1"="$2}'
        exit 0
        """#)
    }

    // MARK: - Computer names

    static func computerNames() -> RemoteScript {
        RemoteScript(#"""
        echo "cn=$(scutil --get ComputerName 2>/dev/null)"
        echo "lhn=$(scutil --get LocalHostName 2>/dev/null)"
        echo "hn=$(scutil --get HostName 2>/dev/null)"
        exit 0
        """#)
    }

    /// Sets ComputerName, LocalHostName (Bonjour, `<name>.local`) and HostName.
    static func renameComputer(computerName: String, localHostName: String) -> RemoteScript {
        RemoteScript(#"""
        CN=\#(shQuote(computerName)); LHN=\#(shQuote(localHostName))
        case "$LHN" in
          ""|-*|*[!A-Za-z0-9-]*) echo "✘ Niepoprawna nazwa sieciowa „${LHN}” – dozwolone są litery bez polskich znaków, cyfry i „-”." >&2; exit 2 ;;
        esac
        [ ${#LHN} -le 63 ] || { echo "✘ Nazwa sieciowa może mieć najwyżej 63 znaki." >&2; exit 2; }
        [ -n "$CN" ] || CN="$LHN"
        OLD_CN="$(scutil --get ComputerName 2>/dev/null)"; OLD_LHN="$(scutil --get LocalHostName 2>/dev/null)"
        scutil --set ComputerName "$CN" && scutil --set LocalHostName "$LHN" && scutil --set HostName "$LHN" \
          || { echo "✘ Nie udało się zmienić nazwy (scutil)." >&2; exit 1; }
        dscacheutil -flushcache >/dev/null 2>&1
        killall -HUP mDNSResponder >/dev/null 2>&1
        echo "✔ Nazwa komputera: ${OLD_CN:-?} → $CN"
        echo "✔ Adres w sieci: ${OLD_LHN:-?}.local → $LHN.local"
        echo "CMCR:LHN:$LHN"
        """#, asRoot: true)
    }

    // MARK: - Applications

    /// Versions of an application (by bundle name) in the Applications folders.
    static func appVersion(_ name: String) -> RemoteScript {
        var base = name.trimmingCharacters(in: .whitespaces)
        if base.lowercased().hasSuffix(".app") { base = String(base.dropLast(4)) }
        return RemoteScript(#"""
        NAME=\#(shQuote(base))
        FOUND=0
        for D in "${CMCR_APPS_DIR:-/Applications}" /System/Applications ${CONSOLE_USER:+"/Users/$CONSOLE_USER/Applications"}; do
          [ -d "$D" ] || continue
          while IFS= read -r A; do
            [ -n "$A" ] || continue
            V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$A/Contents/Info.plist" 2>/dev/null)"
            B="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$A/Contents/Info.plist" 2>/dev/null)"
            printf 'CMCR:APP:%s\t%s\t%s\n' "$A" "$V" "$B"; FOUND=1
          done <<CMCR_EOF
        $(find "$D" -maxdepth 5 \( -iname "$NAME.app" -print -prune \) -o \( -name '*.app' -prune \) 2>/dev/null)
        CMCR_EOF
        done
        [ $FOUND = 1 ] || echo "Brak aplikacji „${NAME}” na tym komputerze."
        exit 0
        """#)
    }

    /// Quits (SIGTERM) every application of the logged-in user started from an Applications folder, including
    /// the apps macOS 13+ runs from the system cryptex (Safari).
    static func quitAllApps() -> RemoteScript {
        RemoteScript(#"""
        if [ -z "$CONSOLE_USER" ]; then echo "Nikt nie jest zalogowany – nie ma czego zamykać."; exit 0; fi
        PIDS="$(ps -axww -o pid=,user=,comm= | awk -v u="$CONSOLE_USER" '$2 == u {
          p = $0; sub(/^ *[0-9]+ +[^ ]+ +/, "", p)
          if (p ~ /^(\/Applications\/|\/System\/Applications\/|\/System\/Volumes\/Preboot\/Cryptexes\/App\/System\/Applications\/|\/System\/Cryptexes\/App\/System\/Applications\/|\/Users\/[^\/]+\/Applications\/)/ && p ~ /\.app\/Contents\/MacOS\/[^\/]+$/ && p !~ /\.app\/.*\.app\//) print $1
        }')"
        if [ -z "$PIDS" ]; then echo "Brak otwartych aplikacji."; exit 0; fi
        asroot kill -TERM $PIDS && echo "✔ Zamknięto aplikacje użytkownika $CONSOLE_USER (PID: $(echo $PIDS))."
        """#)
    }

    /// Cheap reachability probe used while waiting for a Mac to wake up.
    static func ping() -> RemoteScript {
        RemoteScript("echo \"online $(hostname -s 2>/dev/null)\"")
    }
}
