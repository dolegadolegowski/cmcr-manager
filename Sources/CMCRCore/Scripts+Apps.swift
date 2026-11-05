import Foundation

// Installed applications: the inventory („Zainstalowane aplikacje”, `cmcrctl apps installed`) and uninstalling
// (`cmcrctl uninstall`, „Odinstaluj…”). Both print tab-separated records that `AppInventory.parse` and
// `UninstallReport` read; the people see `UninstallReport`'s Polish lines, never the records.
//
// Where apps may be removed from: $CMCR_APPS (/Applications) and one folder below it (Utilities, vendor folders such
// as /Applications/Blender), the student's (and the logged-in user's) ~/Applications and one folder below it, and
// whole Unity editor versions in /Applications/Unity/Hub/Editor. Never: anything under /System, links (Safari in
// /Applications leads into the system cryptex), items with the SIP flag, Apple's apps (com.apple.*, Apple's own
// signature), CMCR's own components (pl.cmcr.*), anything inside another app bundle.
//
// Test hooks (the e2e fakes set them; real sudo resets the environment, so root on an iMac always gets the defaults):
// CMCR_APPS_DIR (/Applications), CMCR_USERS_DIR (/Users) and CMCR_FS_PREFIX (prefix of /Library, /usr/local and /opt
// for launchd items and package files).
extension Scripts {
    static let appsLibrary = #"""
    CMCR_APPS="${CMCR_APPS_DIR:-/Applications}"
    CMCR_USERS="${CMCR_USERS_DIR:-/Users}"
    CMCR_FS="${CMCR_FS_PREFIX:-}"
    CMCR_T="$(printf '\t')"
    # One field of a record: tabs and line breaks would split it.
    cmcr_clean() { local s="$1"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; printf '%s' "$s"; }
    # One value of a plist, or nothing. Only a successful plutil counts: for a missing key the plutil of macOS 15 prints
    # „Could not extract value…” on stdout (later versions on stderr), which must not become a version or a bundle id.
    cmcr_plist() { local v; v="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)" || return 0; printf '%s' "$v"; }
    # The version people see: CFBundleShortVersionString, else CFBundleVersion; a blank value does not count.
    cmcr_app_version() {
      local k v
      for k in CFBundleShortVersionString CFBundleVersion; do
        v="$(cmcr_plist "$1" "$k" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
      done
      return 0
    }
    # Accounts whose ~/Applications count as allowed: the student account from the settings and the logged-in user.
    cmcr_app_users() {
      local u seen=" "
      for u in "$STUDENT" "$CONSOLE_USER"; do
        [ -n "$u" ] || continue
        case "$u" in .*|*[!A-Za-z0-9._-]*) continue ;; esac
        case "$seen" in *" $u "*) continue ;; esac
        seen="$seen$u "
        [ -d "$CMCR_USERS/$u" ] && printf '%s\n' "$u"
      done
    }
    # Size in KB: Spotlight's figure (instant), otherwise du – only until CMCR_SIZE_DEADLINE (SECONDS), so a Mac
    # without Spotlight still answers within the list's time limit.
    cmcr_bundle_size() {
      local b
      b="$(mdls -raw -name kMDItemPhysicalSize "$1" 2>/dev/null)"
      case "$b" in ''|*[!0-9]*) ;; *) echo $((b / 1024)); return 0 ;; esac
      [ "$SECONDS" -lt "${CMCR_SIZE_DEADLINE:-0}" ] || return 0
      du -sk "$1" 2>/dev/null | awk '{print $1}'
    }
    # Receipts of packages not from Apple (pkgutil): $CMCR_RLIST "id<TAB>location<TAB>version<TAB>install-time" and
    # $CMCR_RIDX "id<TAB>absolute path<TAB>path in the receipt" of every application the package installed (not
    # inside another bundle). `pkgutil --file-info` finds only packages installed to /, not those installed to a folder
    # (location: Applications), so the index is built here.
    cmcr_receipt_index() {
      local id info loc ver t
      CMCR_RLIST="$CMCR_TMP/receipts.list"; CMCR_RIDX="$CMCR_TMP/receipts.idx"
      : > "$CMCR_RLIST"; : > "$CMCR_RIDX"
      pkgutil --pkgs 2>/dev/null | grep -v '^com\.apple\.' > "$CMCR_TMP/receipts.ids"
      while IFS= read -r id; do
        case "$id" in ''|*/*|*"$CMCR_T"*|*$'\r'*) continue ;; esac
        info="$(pkgutil --pkg-info "$id" 2>/dev/null)"
        loc="$(printf '%s\n' "$info" | sed -n 's/^location: *//p' | head -n 1)"
        ver="$(printf '%s\n' "$info" | sed -n 's/^version: *//p' | head -n 1)"
        t="$(printf '%s\n' "$info" | sed -n 's/^install-time: *//p' | head -n 1)"
        printf '%s\t%s\t%s\t%s\n' "$id" "$(cmcr_clean "$loc")" "$(cmcr_clean "$ver")" "$t" >> "$CMCR_RLIST"
        pkgutil --files "$id" 2>/dev/null | I="$id" L="$loc" awk '
          /\.app$/ && !/\.app\// && !/\t/ {
            p = "/" ENVIRON["L"] "/" $0; gsub(/\/\.\//, "/", p); gsub(/\/+/, "/", p); sub(/\/\.$/, "", p)
            print ENVIRON["I"] "\t" p "\t" $0 }' >> "$CMCR_RIDX"
      done < "$CMCR_TMP/receipts.ids"
    }
    # cmcr_app_receipts PATH PHYSICAL [system] – ids of the receipts that installed this app (comma-separated). With
    # "system" (an app in /Applications) also packages that install the app alone into another folder and move it into
    # place under the same name (Microsoft AutoUpdate installs into a cache folder).
    cmcr_app_receipts() {
      [ -s "${CMCR_RIDX:-}" ] || return 0
      P1="$1" P2="${2:-$1}" S="${3:-}" awk -F'\t' '
        BEGIN { n = ENVIRON["P1"]; sub(/.*\//, "", n) }
        { b = $2; sub(/.*\//, "", b) }
        $2 == ENVIRON["P1"] || $2 == ENVIRON["P2"] || (ENVIRON["S"] == "system" && b == n && $3 !~ /\// && $2 !~ /^\/(Applications|Users)\//) {
          if (!seen[$1]++) o = o (o == "" ? "" : ",") $1 }
        END { print o }' "$CMCR_RIDX"
    }
    cmcr_mdm_enrolled() {
      profiles status -type enrollment 2>/dev/null | awk -F': *' '/^MDM enrollment:/ {print ($2 ~ /^Yes/ ? "yes" : "no"); exit}'
    }
    """#

    /// Applications on the Mac as `CMCR:APP` records – location, kind, path, bundle id, version, size (KB),
    /// receipts – plus `CMCR:MDM` (enrolled in MDM) and, with `receipts`, the packages not from Apple (`CMCR:PKG`).
    /// Read-only, without root: /Applications (and one folder below it), Unity editors, ~/Applications of the student
    /// account and of the logged-in user, and /System/Applications (listed, never removable). A link is listed where
    /// the app really is: /Applications/Safari.app leads into the system cryptex since macOS 13.
    public static func appInventory(studentUser: String, receipts: Bool = false) -> RemoteScript {
        RemoteScript(#"""
        STUDENT=\#(shQuote(studentUser)); WITH_PKGS=\#(receipts ? 1 : 0)
        \#(appsLibrary)
        CMCR_SIZE_DEADLINE=$((SECONDS + 20))
        cmcr_receipt_index
        OUT="$CMCR_TMP/apps.out"; : > "$OUT"; : > "$OUT.links"
        cmcr_inv_app() { # LOCATION PATH
          local loc="$1" a="$2" kind=app bid ver size rc="" sys="" dest
          case "$a" in *"$CMCR_T"*|*$'\n'*|*$'\r'*) return 0 ;; esac
          # A link is listed where the app really is: under /System as a system app, anywhere else as a link, which
          # the uninstaller refuses as well (only the real place of an app counts, where it is listed on its own).
          if [ -L "$a" ]; then
            a="$(cmcr_realdir "$a")"
            [ -n "$a" ] || return 0
            case "$a" in /System/*) loc=system ;; *) loc=link ;; esac
          fi
          case "$loc" in system) kind=system ;; unity) kind=unity ;; esac
          bid="$(cmcr_plist "$a/Contents/Info.plist" CFBundleIdentifier)"
          ver="$(cmcr_app_version "$a/Contents/Info.plist")"
          if [ $kind = app ]; then
            case "$(stat -f %Sf "$a" 2>/dev/null)" in *restricted*) kind=system ;; esac
          fi
          if [ $kind = app ]; then
            case "$bid" in com.apple.*) kind=apple ;; pl.cmcr.*) kind=cmcr ;; esac
          fi
          if [ $kind = app ] && [ -d "$a/Contents/_MASReceipt" ]; then kind=appstore; fi
          if [ $kind = unity ]; then
            ver="$(basename "$(dirname "$a")")"
            size=""
          else
            size="$(cmcr_bundle_size "$a")"
          fi
          case "$loc" in apps|utilities|folder) sys=system ;; esac
          [ $kind = system ] || rc="$(cmcr_app_receipts "$a" "$a" "$sys")"
          dest="$OUT"; [ "$loc" = link ] && dest="$OUT.links"
          printf 'CMCR:APP\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(cmcr_clean "$loc")" "$kind" "$a" "$(cmcr_clean "$bid")" \
            "$(cmcr_clean "$ver")" "$size" "$rc" >> "$dest"
        }
        cmcr_inv_dir() { # LOCATION FOLDER
          local a
          for a in "$2"/*.app; do
            if [ -e "$a" ] || [ -L "$a" ]; then cmcr_inv_app "$1" "$a"; fi
          done
        }
        # FOLDER and every folder directly in it that is not itself an app (vendor folders such as /Applications/Blender).
        cmcr_inv_tree() { # LOCATION FOLDER SUBFOLDER-LOCATION
          local f
          cmcr_inv_dir "$1" "$2"
          for f in "$2"/*/; do
            f="${f%/}"
            case "$f" in *.app) continue ;; esac
            [ -L "$f" ] && continue
            if [ "$f" = "$CMCR_APPS/Utilities" ]; then cmcr_inv_dir utilities "$f"; else cmcr_inv_dir "$3" "$f"; fi
          done
        }
        cmcr_inv_tree apps "$CMCR_APPS" folder
        for e in "$CMCR_APPS"/Unity/Hub/Editor/*/Unity.app; do
          [ -d "$e" ] && [ ! -L "$e" ] && cmcr_inv_app unity "$e"
        done
        while IFS= read -r u; do
          h="$CMCR_USERS/$u/Applications"
          [ -d "$h" ] && [ ! -L "$h" ] && cmcr_inv_tree "user:$u" "$h" "user:$u"
        done < <(cmcr_app_users)
        cmcr_inv_dir system /System/Applications
        cmcr_inv_dir system /System/Applications/Utilities
        printf 'CMCR:MDM\t%s\n' "$(M="$(cmcr_mdm_enrolled)"; echo "${M:-unknown}")"
        # The real place of an app wins over a link to it.
        cat "$OUT" "$OUT.links" | awk -F'\t' '!seen[$4]++'
        if [ "$WITH_PKGS" = 1 ]; then
          awk -F'\t' '{printf "CMCR:PKG\t%s\t%s\t%s\t%s\n", $1, $3, $4, $2}' "$CMCR_RLIST"
        fi
        printf 'CMCR:END\t%s\n' "$(cat "$OUT" "$OUT.links" | awk -F'\t' '!seen[$4]++' | wc -l | tr -d ' ')"
        exit 0
        """#)
    }

    /// Removes applications as root, or with `dryRun` only says what would be removed (nothing changes). `targets`
    /// are paths (see the allowed places above) or bare names (`Blender`: every allowed place that has Blender.app).
    ///
    /// Per app: the bundle (moved aside first – the same permission as deleting it, which macOS refuses without Full
    /// Disk Access – so an app that cannot go is never quit for nothing), its running processes (every user: TERM, then
    /// KILL after 5 s), its launch daemons and agents (Program inside the bundle, or Label = bundle id / bundle id + "."):
    /// booted out and removed, with their helper in /Library/PrivilegedHelperTools, and the receipts of the packages that
    /// installed it (`pkgutil --forget`) unless the package also installed another app that stays. The package's other
    /// files stay unless `packageFiles`; then those under /Library, /usr/local and /opt that no other package owns go too
    /// (never anything Apple's or CMCR's, never kernel or system extensions), with the folders they leave empty. A whole
    /// Unity editor version (the editor with its modules) is removed the way Unity Hub does it: by its folder.
    ///
    /// Exit code: 0, 1 when something could not be removed, 2 when an app was refused (protected, not allowed).
    public static func uninstallApps(_ targets: [String], studentUser: String, dryRun: Bool = false,
                                     packageFiles: Bool = false) -> RemoteScript {
        let list = targets.map(shQuote).joined(separator: " ")
        return RemoteScript(#"""
        STUDENT=\#(shQuote(studentUser)); DRY=\#(dryRun ? 1 : 0); PKGFILES=\#(packageFiles ? 1 : 0)
        TARGETS=(\#(list))
        \#(appsLibrary)
        N_DONE=0; N_KEPT=0; N_FAIL=0; N_PLAN=0; N_REFUSED=0; PLAN_KB=0; DONE_KB=0; MDM_NOTED=0; SEQ=0
        FDA="macOS chroni aplikacje: włącz „Daj użytkownikom zdalnym pełny dostęp do dysku” (Ustawienia systemowe › Ogólne › Udostępnianie › ⓘ przy „Zdalne logowanie”)."
        cmcr_rec() { # VERB WHAT PATH DETAIL [EXTRA…]
          local out="CMCR:UN" a
          for a in "$@"; do out="$out$CMCR_T$(cmcr_clean "$a")"; done
          printf '%s\n' "$out"
          case "$1" in
            removed|forgot) N_DONE=$((N_DONE + 1)) ;;
            plan) N_PLAN=$((N_PLAN + 1)) ;;
            kept) N_KEPT=$((N_KEPT + 1)) ;;
            refused) N_REFUSED=$((N_REFUSED + 1)) ;;
            failed) N_FAIL=$((N_FAIL + 1)) ;;
          esac
        }
        MDM="$(cmcr_mdm_enrolled)"
        cmcr_receipt_index
        # Processes of the app (every user): "pid user" per line – those running from the bundle, and copies macOS runs
        # from a random folder (App Translocation of a quarantined app) when that copy has the app's bundle id. ps lists
        # precomposed names (cmcr_ps), the path on disk may be decomposed (AUDIT REV-09), so the paths are converted.
        cmcr_app_procs() { # PATH PHYSICAL BUNDLE-ID BUNDLE-NAME (no bundle id: no translocated copies)
          local a b n pid user root
          a="$(printf '%s' "$1" | iconv -c -f UTF-8-MAC -t UTF-8)"; b="$(printf '%s' "$2" | iconv -c -f UTF-8-MAC -t UTF-8)"
          n="$(printf '%s' "$4" | iconv -c -f UTF-8-MAC -t UTF-8)"
          cmcr_ps -axww -o pid=,user=,comm= 2>/dev/null \
            | A="${a:-$1}/" B="${b:-$2}/" C="/System/Volumes/Data${b:-$2}/" N="/${n:-$4}/Contents/" T="${3:+1}" awk '
              { l = $0; sub(/^ *[0-9]+ +[^ ]+ +/, "", l) }
              index(l, ENVIRON["A"]) == 1 || index(l, ENVIRON["B"]) == 1 || index(l, ENVIRON["C"]) == 1 { print $1, $2, "-"; next }
              ENVIRON["T"] == 1 && index(l, "/AppTranslocation/") > 0 && (i = index(l, ENVIRON["N"])) > 0 {
                print $1, $2, substr(l, 1, i + length(ENVIRON["N"]) - 11) }' \
            | while read -r pid user root; do
                if [ "$root" = - ]; then printf '%s %s\n' "$pid" "$user"; continue; fi
                [ "$(cmcr_plist "$root/Contents/Info.plist" CFBundleIdentifier)" = "$3" ] && printf '%s %s\n' "$pid" "$user"
              done
        }
        # Another app with this bundle id in an allowed folder (a copy that stays still needs the services named after it).
        cmcr_same_bid() { # BUNDLE-ID BUNDLE PHYSICAL
          local a u
          {
            for a in "$CMCR_APPS"/*.app "$CMCR_APPS"/*/*.app "$CMCR_APPS"/Unity/Hub/Editor/*/Unity.app; do printf '%s\n' "$a"; done
            while IFS= read -r u; do
              for a in "$CMCR_USERS/$u/Applications"/*.app "$CMCR_USERS/$u/Applications"/*/*.app; do printf '%s\n' "$a"; done
            done < <(cmcr_app_users)
          } | while IFS= read -r a; do
            [ -d "$a" ] && [ ! -L "$a" ] || continue
            case "$a" in "$2"|*.app/*.app) continue ;; esac
            [ "$(cmcr_realdir "$a")" = "$3" ] && continue
            if [ "$(cmcr_plist "$a/Contents/Info.plist" CFBundleIdentifier)" = "$1" ]; then printf '%s\n' "$a"; break; fi
          done
        }
        # Launch daemons and agents of the app: "kind<TAB>plist<TAB>label<TAB>program<TAB>how" (kind: daemon, agent,
        # uagent:USER). how: prog – its program lies inside the bundle; label – a user's agent whose label is the bundle id
        # or starts with „bundle id.”; sys – such a label in /Library, which is only reported, never removed: any app can
        # copy a bundle id (a student's game with the id „com” or „com.jamf” must not take MDM or antivirus services with
        # it). An app in a user's ~/Applications is that user's to name, so only that user's ~/Library/LaunchAgents are
        # searched for it. Labels count only with LABELS=1 (see cmcr_un_path), and never for a program inside another
        # app that is still there.
        cmcr_launchd_find() { # PATH PHYSICAL BUNDLE-ID LOCATION OWNER LABELS
          local item="$1" phys="$2" bid="$3" loc="$4" owner="$5" labels="$6" kind dir f label prog how other u
          {
            case "$loc" in
              user:*) printf 'uagent:%s\t%s\n' "$owner" "$CMCR_USERS/$owner/Library/LaunchAgents" ;;
              *)
                printf 'daemon\t%s\n' "$CMCR_FS/Library/LaunchDaemons"
                printf 'agent\t%s\n' "$CMCR_FS/Library/LaunchAgents"
                while IFS= read -r u; do printf 'uagent:%s\t%s\n' "$u" "$CMCR_USERS/$u/Library/LaunchAgents"; done < <(cmcr_app_users) ;;
            esac
          } | while IFS="$CMCR_T" read -r kind dir; do
            [ -d "$dir" ] && [ ! -L "$dir" ] || continue
            for f in "$dir"/*.plist; do
              [ -f "$f" ] && [ ! -L "$f" ] || continue
              label="$(cmcr_plist "$f" Label)"
              case "$label" in com.apple.*|com.openssh.*|pl.cmcr.*) continue ;; esac
              prog="$(cmcr_plist "$f" Program)"; [ -n "$prog" ] || prog="$(cmcr_plist "$f" ProgramArguments.0)"
              how=""
              case "$prog" in "$item"/*|"$phys"/*) how=prog ;; esac
              if [ -z "$how" ] && [ "$labels" = 1 ] && [ -n "$label" ]; then
                case "$label" in "$bid"|"$bid".*) how=label ;; esac
                case "$prog" in *.app/*) other="${prog%%.app/*}.app"; [ -d "$other" ] && how="" ;; esac
                case "$how:$kind" in label:daemon|label:agent) how=sys ;; esac
              fi
              [ -n "$how" ] || continue
              printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$f" "$(cmcr_clean "$label")" "$(cmcr_clean "$prog")" "$how"
            done
          done
        }
        # Package files that may go (with "file") and folders that may go once empty (with "dir").
        cmcr_pkg_safe() { # PATH file|dir
          local p="$1" rest
          case "$p" in *$'\n'*|*/../*|*/./*|*/.|*/..) return 1 ;; esac
          case "$p" in */com.apple.*|*/pl.cmcr.*|*/CMCR|*/CMCR/*|*.app/*|*.kext|*.kext/*|*.systemextension|*.systemextension/*) return 1 ;; esac
          case "$p" in
            "$CMCR_FS"/Library/*) rest="${p#"$CMCR_FS"/Library/}" ;;
            "$CMCR_FS"/usr/local/*) rest="${p#"$CMCR_FS"/usr/local/}" ;;
            "$CMCR_FS"/opt/*) rest="opt/${p#"$CMCR_FS"/opt/}" ;;
            *) return 1 ;;
          esac
          case "$rest" in
            Apple/*|Keychains/*|Security/*|Extensions/*|SystemExtensions/*|Developer/*|"Managed Preferences"/*|Preferences/*|Receipts/*) return 1 ;;
          esac
          [ "$2" = dir ] || return 0
          # A folder only at least two levels down (/Library/Application Support/Firma) and never one of the standard ones.
          case "$rest" in */*) ;; *) return 1 ;; esac
          case "$rest" in
            "Application Support"|Audio/*|"Internet Plug-Ins"/*|Caches/*|Printers/*|ColorSync/*|"Image Capture"/*|CoreMediaIO/*|Video/*) return 1 ;;
            share/man|share/man/*|share/doc|share/info|share/locale|share/locale/*|lib/pkgconfig|Homebrew|Homebrew/*|Cellar|Cellar/*) return 1 ;;
          esac
          return 0
        }
        # Removes NAME from FOLDER, entering the folder one component at a time (cmcr_walk): a link a user planted in
        # the path cannot send root's rm somewhere else.
        cmcr_rm_in() { # FOLDER NAME [dir]
          local rc
          cmcr_walk "$1" || { echo "nie można bezpiecznie wejść do $1"; return 1; }
          if [ "${3:-}" = dir ]; then rmdir -- "./$2" 2>&1; rc=$?; else rm -f -- "./$2" 2>&1; rc=$?; fi
          cd /
          return $rc
        }

        cmcr_un_target() {
          local t="$1" n d u found=0
          local -a dirs
          case "$t" in
            "") return 0 ;;
            *$'\n'*|*$'\r'*|*"$CMCR_T"*) cmcr_rec refused app "$t" "nazwa zawiera znak nowej linii lub tabulator"; return 0 ;;
          esac
          case "$t" in /*) cmcr_un_path "$t"; return 0 ;; esac
          n="${t%.app}"
          case "$n" in ""|.*|*/*) cmcr_rec refused app "$t" "podaj nazwę aplikacji (np. Blender) albo pełną ścieżkę do niej"; return 0 ;; esac
          dirs=("$CMCR_APPS" "$CMCR_APPS/Utilities")
          while IFS= read -r u; do dirs+=("$CMCR_USERS/$u/Applications"); done < <(cmcr_app_users)
          for d in "${dirs[@]}"; do
            if [ -e "$d/$n.app" ] || [ -L "$d/$n.app" ]; then found=1; cmcr_un_path "$d/$n.app"; fi
          done
          for d in "$CMCR_APPS"/*/"$n.app"; do
            case "$d" in "$CMCR_APPS/Utilities/$n.app"|*.app/*) continue ;; esac
            if [ -e "$d" ] || [ -L "$d" ]; then found=1; cmcr_un_path "$d"; fi
          done
          [ $found = 1 ] || cmcr_rec missing app "$n.app" "nie ma takiej aplikacji w folderach Aplikacje"
        }

        cmcr_un_path() {
          local APP="$1" ITEM KIND=app DIR NAME LOC="" OWNER="" PARENT ROOTP B BID VER TITLE AUTH KB PROCS PIDS USERS_RUNNING
          local LD PF RS OURS SYS LABELS PBID SW u chk r loc others other f rel rest GONE err ok i d doms kind what label prog how
          SEQ=$((SEQ + 1))
          while [ "${APP%/}" != "$APP" ]; do APP="${APP%/}"; done
          case "$APP/" in */../*|*/./*|*//*) cmcr_rec refused app "$APP" "niepoprawna ścieżka (.., . lub //)"; return 0 ;; esac
          case "$APP" in
            /System/*) cmcr_rec refused app "$APP" "aplikacje systemowe macOS (/System) chroni System Integrity Protection – nie można ich odinstalować"; return 0 ;;
            "$CMCR_APPS"/Unity/Hub/Editor/*/Unity.app) ITEM="${APP%/Unity.app}"; KIND=unity ;;
            "$CMCR_APPS"/Unity/Hub/Editor/*) ITEM="$APP"; KIND=unity ;;
            *.app/*) cmcr_rec refused app "$APP" "leży wewnątrz innej aplikacji – usuń całą aplikację"; return 0 ;;
            *) ITEM="$APP" ;;
          esac
          DIR="$(dirname "$ITEM")"; NAME="$(basename "$ITEM")"
          if [ $KIND = unity ]; then
            if [ "$DIR" != "$CMCR_APPS/Unity/Hub/Editor" ]; then
              cmcr_rec refused unity "$APP" "z edytorów Unity usuwa się całe wersje: $CMCR_APPS/Unity/Hub/Editor/<wersja>"; return 0
            fi
            LOC=unity
          else
            case "$NAME" in *.app) ;; *) cmcr_rec refused app "$APP" "to nie jest aplikacja (.app)"; return 0 ;; esac
            case "$DIR" in
              "$CMCR_APPS") LOC=apps ;;
              "$CMCR_APPS"/*/*) ;;
              "$CMCR_APPS/Utilities") LOC=utilities ;;
              "$CMCR_APPS"/*) LOC=folder ;;
            esac
            if [ -z "$LOC" ]; then
              while IFS= read -r u; do
                case "$DIR" in
                  "$CMCR_USERS/$u/Applications") LOC="user:$u"; OWNER="$u" ;;
                  "$CMCR_USERS/$u/Applications"/*/*) ;;
                  "$CMCR_USERS/$u/Applications"/*) LOC="user:$u"; OWNER="$u" ;;
                esac
              done < <(cmcr_app_users)
            fi
            if [ -z "$LOC" ]; then
              cmcr_rec refused app "$APP" "Odinstalowywać można tylko aplikacje z $CMCR_APPS (i jednego folderu w nim, np. Utilities) oraz z folderu Aplikacje ucznia ($CMCR_USERS/<konto>/Applications)"
              return 0
            fi
          fi
          if [ ! -e "$ITEM" ] && [ ! -L "$ITEM" ]; then cmcr_rec missing "$KIND" "$ITEM" "nic do usunięcia"; return 0; fi
          if [ -L "$ITEM" ]; then
            cmcr_rec refused "$KIND" "$ITEM" "to tylko dowiązanie do „$(readlink "$ITEM")” (tak macOS umieszcza w folderze Aplikacje np. Safari) – nie odinstalowuję; aplikacji systemowych nie można odinstalować"
            return 0
          fi
          [ -d "$ITEM" ] || { cmcr_rec refused "$KIND" "$ITEM" "to nie jest pakiet aplikacji (folder .app)"; return 0; }
          # No link anywhere on the way: a student who owns ~/Applications (or the account that owns /Applications/Unity)
          # could otherwise point it at a system folder.
          case "$LOC" in
            unity) for chk in "$CMCR_APPS/Unity" "$CMCR_APPS/Unity/Hub" "$CMCR_APPS/Unity/Hub/Editor"; do
                     [ -L "$chk" ] && { cmcr_rec refused unity "$ITEM" "$chk to dowiązanie – nie usuwam niczego przez dowiązania"; return 0; }
                   done
                   ROOTP="$(cmcr_realdir "$CMCR_APPS/Unity/Hub/Editor")" ;;
            user:*) for chk in "$CMCR_USERS/$OWNER" "$CMCR_USERS/$OWNER/Applications" "$DIR"; do
                      [ -L "$chk" ] && { cmcr_rec refused app "$ITEM" "$chk to dowiązanie – nie usuwam niczego przez dowiązania"; return 0; }
                    done
                    ROOTP="$(cmcr_realdir "$CMCR_USERS/$OWNER/Applications")" ;;
            *) [ -L "$DIR" ] && { cmcr_rec refused app "$ITEM" "$DIR to dowiązanie – nie usuwam niczego przez dowiązania"; return 0; }
               ROOTP="$(cmcr_realdir "$CMCR_APPS")" ;;
          esac
          PARENT="$(cmcr_realdir "$DIR")"
          case "$PARENT/" in
            "$ROOTP"/*) ;;
            *) cmcr_rec refused "$KIND" "$ITEM" "Odmowa: $ITEM wskazuje poza dozwolony folder (${PARENT:-?})"; return 0 ;;
          esac
          case "$(stat -f %Sf "$ITEM" 2>/dev/null)" in
            *restricted*) cmcr_rec refused "$KIND" "$ITEM" "jest chroniona przez macOS (System Integrity Protection) – aplikacji systemowych nie można odinstalować"; return 0 ;;
          esac
          B="$ITEM"; [ $KIND = unity ] && B="$ITEM/Unity.app"
          BID="$(cmcr_plist "$B/Contents/Info.plist" CFBundleIdentifier)"
          VER="$(cmcr_app_version "$B/Contents/Info.plist")"
          TITLE="${NAME%.app}"
          if [ $KIND = unity ]; then VER="$NAME"; TITLE="Unity $NAME"; fi
          case "$BID" in
            com.apple.*) cmcr_rec refused "$KIND" "$ITEM" "to aplikacja Apple ($BID) – CMCR nie odinstalowuje aplikacji Apple ani systemowych; w razie potrzeby usuń ją przy komputerze lub przez MDM"; return 0 ;;
            pl.cmcr.*) cmcr_rec refused "$KIND" "$ITEM" "to składnik CMCR ($BID) – nie odinstalowuję go zdalnie"; return 0 ;;
          esac
          AUTH="$(codesign -dvv "$B" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
          case "$AUTH" in
            "Software Signing"|"macOS Software Signing"|"Apple Code Signing Certification Authority")
              cmcr_rec refused "$KIND" "$ITEM" "podpisana przez Apple jako część systemu ($AUTH) – nie odinstalowuję"; return 0 ;;
          esac
          KB="$(du -sk "$ITEM" 2>/dev/null | awk '{print $1}')"
          cmcr_rec target "$KIND" "$ITEM" "$TITLE" "$VER" "$BID" "${KB:-}" "$LOC"

          # What the teacher should know before removing it.
          if [ -d "$B/Contents/_MASReceipt" ]; then
            cmcr_rec note appstore "$ITEM" "Aplikacja z App Store – zakup zostaje na koncie Apple ID. Jeśli szkoła przydziela ją przez MDM (Apple School Manager), MDM może ją zainstalować ponownie – wtedy usuń najpierw przydział w MDM."
          fi
          if [ "$MDM" = yes ] && [ $MDM_NOTED = 0 ]; then
            MDM_NOTED=1
            cmcr_rec note mdm "" "Komputer jest zarządzany przez MDM – aplikacje instalowane przez MDM mogą wrócić przy najbliższej synchronizacji; takie usuwaj w konsoli MDM."
          fi
          case "$LOC:$DIR" in
            folder:*|user:*:"$CMCR_USERS/$OWNER/Applications"/*)
              for u in "$DIR"/*[Uu]ninstall*.app; do
                [ -d "$u" ] && [ "$u" != "$ITEM" ] && cmcr_rec note vendor "$u" "W folderze jest deinstalator producenta ($(basename "$u")) – usuwa też pliki poza aplikacją; jeśli to możliwe, uruchom go przy komputerze."
              done ;;
          esac
          case "$BID" in
            com.adobe.*) cmcr_rec note vendor "$ITEM" "Programy Adobe usuwaj przez Creative Cloud – samo usunięcie aplikacji zostawia usługi i licencję Adobe." ;;
            com.unity3d.unityhub)
              if ls "$CMCR_APPS/Unity/Hub/Editor" 2>/dev/null | grep -q .; then
                cmcr_rec note unity "$CMCR_APPS/Unity/Hub/Editor" "Edytory Unity zostają – usuń je osobno (na liście: Unity <wersja>)."
              fi ;;
          esac
          if [ $KIND = unity ]; then
            cmcr_rec note unity "$ITEM" "Wersję edytora zainstalowaną przez Unity Hub usuwa się razem z modułami (np. Android) – cały folder, tak jak robi to Hub (Hub nie ma polecenia odinstalowania bez okna). Uruchomiony Unity Hub może ją pokazywać do ponownego otwarcia."
          fi

          # Translocated copies are recognised by the bundle id, not for Unity (every editor version has the same one).
          PBID="$BID"; [ $KIND = unity ] && PBID=""
          PROCS="$(cmcr_app_procs "$ITEM" "$PARENT/$NAME" "$PBID" "$(basename "$B")")"
          PIDS="$(printf '%s\n' "$PROCS" | awk 'NF {print $1}' | paste -sd' ' -)"
          USERS_RUNNING="$(printf '%s\n' "$PROCS" | awk 'NF && !s[$2]++ {printf "%s%s", (n++ ? ", " : ""), $2}')"
          # Labels count only for a bundle id of at least three parts (com.firma.program) that no other copy on this Mac
          # has: „com” or „com.google” would match other vendors' services, and a copy that stays still needs them.
          LABELS=0
          case "$BID" in *.*.*) LABELS=1 ;; esac
          case "$BID" in .*|*.|*..*) LABELS=0 ;; esac
          if [ $LABELS = 1 ]; then
            other="$(cmcr_same_bid "$BID" "$B" "$(cmcr_realdir "$B")")"
            if [ -n "$other" ]; then
              LABELS=0
              cmcr_rec note copies "$other" "Na komputerze jest inna kopia aplikacji o tym samym identyfikatorze ($other) – usługi rozpoznawane tylko po identyfikatorze zostają."
            fi
          fi
          LD="$CMCR_TMP/launchd.$SEQ"
          cmcr_launchd_find "$ITEM" "$PARENT/$NAME" "$BID" "$LOC" "$OWNER" "$LABELS" > "$LD.all"
          awk -F'\t' '$5 != "sys"' "$LD.all" > "$LD"
          awk -F'\t' '$5 == "sys"' "$LD.all" > "$LD.kept"
          # bash 3.2 cannot parse a case pattern inside $( ): the scope is set first.
          SYS=""; case "$LOC" in apps|utilities|folder) SYS=system ;; esac
          RS="$(cmcr_app_receipts "$ITEM" "$PARENT/$NAME" "$SYS")"
          [ $KIND = unity ] && RS=""
          PF="$CMCR_TMP/pkgfiles.$SEQ"; : > "$PF"        # package files outside the bundle: "receipt<TAB>path"
          : > "$PF.receipts"                              # receipts to forget
          for r in $(printf '%s' "$RS" | tr ',' ' '); do
            loc="$(R="$r" awk -F'\t' '$1 == ENVIRON["R"] {print $2; exit}' "$CMCR_RLIST")"
            OURS="$(R="$r" P1="$ITEM" P2="$PARENT/$NAME" N="$NAME" S="$SYS" awk -F'\t' '
              { b = $2; sub(/.*\//, "", b) }
              $1 == ENVIRON["R"] && ($2 == ENVIRON["P1"] || $2 == ENVIRON["P2"] || (ENVIRON["S"] == "system" && b == ENVIRON["N"] && $3 !~ /\// && $2 !~ /^\/(Applications|Users)\//)) {print $3}' "$CMCR_RIDX")"
            others="$(R="$r" O="$OURS" awk -F'\t' 'BEGIN { n = split(ENVIRON["O"], o, "\n"); for (i = 1; i <= n; i++) ours[o[i]] = 1 }
              $1 == ENVIRON["R"] && !($3 in ours) {print $2}' "$CMCR_RIDX" | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done)"
            if [ -n "$others" ]; then
              cmcr_rec kept receipt "$r" "pakiet zainstalował też inne aplikacje, które zostają: $(printf '%s\n' "$others" | head -n 3 | paste -sd, -)"
              continue
            fi
            printf '%s\n' "$r" >> "$PF.receipts"
            # The package's files outside the bundle (and outside the launchd items found above).
            pkgutil --files "$r" --only-files 2>/dev/null | O="$OURS" L="$loc" awk '
              BEGIN { n = split(ENVIRON["O"], o, "\n") }
              { for (i = 1; i <= n; i++) if (o[i] != "" && ($0 == o[i] || index($0, o[i] "/") == 1)) next
                p = "/" ENVIRON["L"] "/" $0; gsub(/\/\.\//, "/", p); gsub(/\/+/, "/", p); print p }' \
              | while IFS= read -r f; do
                  { [ -e "$f" ] || [ -L "$f" ]; } && [ ! -d "$f" ] || continue
                  awk -F'\t' '{print $2}' "$LD" | grep -qxF -- "$f" && continue
                  printf '%s\t%s\n' "$r" "$f"
                done >> "$PF"
          done
          # Files another package also installed stay (checked against every package not from Apple, and pkgutil's own
          # lookup for packages installed to /).
          : > "$PF.others"
          if [ "$PKGFILES" = 1 ] && [ -s "$PF" ]; then
            awk -F'\t' '{print $1}' "$CMCR_RLIST" | while IFS= read -r i; do
              grep -qxF -- "$i" "$PF.receipts" && continue
              loc="$(I="$i" awk -F'\t' '$1 == ENVIRON["I"] {print $2; exit}' "$CMCR_RLIST")"
              pkgutil --files "$i" 2>/dev/null | L="$loc" awk '{ p = "/" ENVIRON["L"] "/" $0; gsub(/\/\.\//, "/", p); gsub(/\/+/, "/", p); print p }'
            done > "$PF.others"
          fi
          # With packageFiles: which package files go. A launch daemon or agent of the package is a launchd item: it is
          # stopped before its plist goes (a root daemon would otherwise keep running from a deleted program).
          : > "$PF.go"
          if [ "$PKGFILES" = 1 ] && [ -s "$PF" ]; then
            while IFS="$CMCR_T" read -r r f; do
              if ! cmcr_pkg_safe "$f" file; then cmcr_rec kept pkgfile "$f" "chroniony folder systemu lub CMCR – zostaje"; continue; fi
              if grep -qxF -- "$f" "$PF.others" || pkgutil --file-info "$f" 2>/dev/null | R="$r" awk '/^pkgid: / && $2 != ENVIRON["R"] {f = 1} END {exit !f}'; then
                cmcr_rec kept pkgfile "$f" "należy też do innego pakietu – zostaje"; continue
              fi
              kind=""
              case "$f" in
                "$CMCR_FS"/Library/LaunchDaemons/*.plist) kind=daemon ;;
                "$CMCR_FS"/Library/LaunchAgents/*.plist) kind=agent ;;
              esac
              if [ -n "$kind" ]; then
                label="$(cmcr_plist "$f" Label)"
                case "$label" in
                  com.apple.*|com.openssh.*|pl.cmcr.*) cmcr_rec kept pkgfile "$f" "usługa systemu lub CMCR – zostaje"; continue ;;
                esac
                prog="$(cmcr_plist "$f" Program)"; [ -n "$prog" ] || prog="$(cmcr_plist "$f" ProgramArguments.0)"
                printf '%s\t%s\t%s\t%s\tpkg\n' "$kind" "$f" "$(cmcr_clean "$label")" "$(cmcr_clean "$prog")" >> "$LD"
                continue
              fi
              printf '%s\n' "$f" >> "$PF.go"
            done < "$PF"
          fi

          # The plan. System-wide services that go are named in a warning of their own.
          if [ "$DRY" = 1 ]; then
            [ -n "$PIDS" ] && cmcr_rec running process "$ITEM" "$USERS_RUNNING" "$PIDS"
            cmcr_rec plan "$KIND" "$ITEM" "${KB:-}"
            SW=""
            while IFS="$CMCR_T" read -r kind f label prog how; do
              [ -n "$f" ] || continue
              case "$kind" in daemon) what=daemon ;; agent) what=agent ;; *) what=uagent ;; esac
              cmcr_rec plan "$what" "$f" "$label" "$how"
              case "$kind" in daemon|agent) SW="$SW${SW:+, }${label:-$(basename "$f")}" ;; esac
            done < "$LD"
            if [ -n "$SW" ]; then
              cmcr_rec note systemwide "" "Uwaga: zostaną usunięte usługi działające dla całego komputera: $SW. Program każdej z nich leży w tej aplikacji albo pochodzi z jej pakietu – sprawdź je przed potwierdzeniem."
            fi
          fi
          PLAN_KB=$((PLAN_KB + ${KB:-0}))
          while IFS="$CMCR_T" read -r kind f label prog how; do
            [ -n "$f" ] || continue
            awk -F'\t' '{print $2}' "$LD" | grep -qxF -- "$f" && continue
            case "$kind" in daemon) what=daemon ;; *) what=agent ;; esac
            cmcr_rec kept "$what" "$f" "etykieta $label pasuje do identyfikatora aplikacji, ale usługi z /Library CMCR usuwa tylko wtedy, gdy ich program leży w aplikacji albo pochodzą z jej pakietu (z opcją plików pakietu) – jeśli należy do tej aplikacji, usuń ją ręcznie"
          done < "$LD.kept"
          if [ -s "$PF" ] && [ "$PKGFILES" != 1 ]; then
            cmcr_rec kept pkgfiles "$(awk -F'\t' 'NR == 1 {print $2}' "$PF")" "$(wc -l < "$PF" | tr -d ' ')" "$(awk -F'\t' 'NR <= 3 {print $2}' "$PF" | paste -sd'|' -)"
          fi
          if [ "$DRY" = 1 ]; then
            while IFS= read -r f; do [ -n "$f" ] && cmcr_rec plan pkgfile "$f" ""; done < "$PF.go"
            if [ -s "$PF.go" ]; then
              cmcr_rec note pkgdirs "" "Foldery pakietu, które po usunięciu tych plików zostaną puste, też zostaną usunięte (poza folderami standardowymi macOS)."
            fi
            while IFS= read -r r; do [ -n "$r" ] && cmcr_rec plan receipt "$r" ""; done < "$PF.receipts"
            return 0
          fi

          # 1. Moved aside within its folder: an app macOS protects stays where it is and keeps running.
          if ! cmcr_walk "$PARENT"; then
            cmcr_rec failed "$KIND" "$ITEM" "nie można bezpiecznie wejść do $PARENT – aplikacji nie zamknięto"; return 0
          fi
          err=""
          GONE="$(mktemp -d "./.cmcr-uninstall.XXXXXX" 2>"$CMCR_TMP/rm.err")" && /bin/mv -- "./$NAME" "$GONE/" 2>"$CMCR_TMP/rm.err" || {
            err="$(head -n 1 "$CMCR_TMP/rm.err")"
            [ -n "$GONE" ] && rmdir -- "$GONE" 2>/dev/null
            cd /
            cmcr_rec failed "$KIND" "$ITEM" "${err:-brak uprawnień} – aplikacji nie zamknięto. $FDA"
            return 0
          }
          # 2. Its launchd jobs stopped, so nothing restarts it. Those that were running are noted: if the bundle cannot
          # be deleted after all and goes back, they are started again.
          : > "$LD.booted"
          while IFS="$CMCR_T" read -r kind f label prog how; do
            [ -n "$f" ] || continue
            case "$kind" in
              daemon) doms=system ;;
              uagent:*) u="$(id -u "${kind#uagent:}" 2>/dev/null)"; doms="${u:+gui/$u}" ;;
              *) doms="$(cmcr_gui_sessions | awk '{printf "gui/%s ", $1}')" ;;
            esac
            for d in $doms; do
              if [ -n "$label" ] && launchctl print "$d/$label" >/dev/null 2>&1; then printf '%s\t%s\n' "$d" "$f" >> "$LD.booted"; fi
              launchctl bootout "$d" "$f" >/dev/null 2>&1
            done
          done < "$LD"
          # 3. Its processes quit (every user), then killed – looked up again now: an app started since the plan has no
          # way back to the bundle any more.
          PROCS="$(cmcr_app_procs "$ITEM" "$PARENT/$NAME" "$PBID" "$(basename "$B")")"
          PIDS="$(printf '%s\n' "$PROCS" | awk 'NF {print $1}' | paste -sd' ' -)"
          USERS_RUNNING="$(printf '%s\n' "$PROCS" | awk 'NF && !s[$2]++ {printf "%s%s", (n++ ? ", " : ""), $2}')"
          if [ -n "$PIDS" ]; then
            kill -TERM $PIDS 2>/dev/null
            for i in 1 2 3 4 5 6 7 8 9 10; do
              ok=1; for u in $PIDS; do kill -0 "$u" 2>/dev/null && ok=0; done
              [ $ok = 1 ] && break
              sleep 0.5
            done
            [ $ok = 1 ] || kill -KILL $PIDS 2>/dev/null
            cmcr_rec quit process "$ITEM" "$USERS_RUNNING" "$PIDS"
          fi
          # 4. Removed.
          if rm -rf -- "./$GONE" 2>"$CMCR_TMP/rm.err" && [ ! -e "./$GONE" ]; then
            cd /
            cmcr_rec removed "$KIND" "$ITEM" "${KB:-}"
            DONE_KB=$((DONE_KB + ${KB:-0}))
          else
            err="$(head -n 1 "$CMCR_TMP/rm.err")"
            # Back in place, so the list still shows it and the next attempt finds it – with its services running again.
            if [ ! -e "./$NAME" ] && [ -e "./$GONE/$NAME" ]; then /bin/mv -- "./$GONE/$NAME" "./$NAME" 2>/dev/null && rmdir -- "./$GONE" 2>/dev/null; fi
            cd /
            cmcr_rec failed "$KIND" "$ITEM" "${err:-nie udało się usunąć} $FDA"
            if [ -s "$LD.booted" ]; then
              while IFS="$CMCR_T" read -r d f; do launchctl bootstrap "$d" "$f" >/dev/null 2>&1; done < "$LD.booted"
              cmcr_rec note restarted "" "Usługi aplikacji zatrzymane przed usuwaniem zostały uruchomione ponownie."
            fi
            return 0
          fi
          # 5. Launch daemons and agents. A helper in /Library/PrivilegedHelperTools goes only as a file of the app's
          # package (with packageFiles), never because of a label.
          while IFS="$CMCR_T" read -r kind f label prog how; do
            [ -n "$f" ] || continue
            case "$kind" in daemon) what=daemon ;; agent) what=agent ;; *) what=uagent ;; esac
            if err="$(cmcr_rm_in "$(dirname "$f")" "$(basename "$f")")"; then cmcr_rec removed "$what" "$f" "$label"
            else cmcr_rec failed "$what" "$f" "$err"; fi
          done < "$LD"
          # 6. Package files (only with packageFiles), then the package folders they left empty, deepest first.
          while IFS= read -r f; do
            [ -n "$f" ] || continue
            if err="$(cmcr_rm_in "$(dirname "$f")" "$(basename "$f")")"; then cmcr_rec removed pkgfile "$f" ""
            else cmcr_rec failed pkgfile "$f" "$err"; fi
          done < "$PF.go"
          if [ -s "$PF.go" ]; then
            while IFS= read -r r; do
              loc="$(R="$r" awk -F'\t' '$1 == ENVIRON["R"] {print $2; exit}' "$CMCR_RLIST")"
              pkgutil --files "$r" --only-dirs 2>/dev/null | L="$loc" awk '{ p = "/" ENVIRON["L"] "/" $0; gsub(/\/\.\//, "/", p); gsub(/\/+/, "/", p); print length(p) "\t" p }'
            done < "$PF.receipts" | sort -rn | cut -f2- | awk '!s[$0]++' > "$PF.dirs"
            while IFS= read -r f; do
              [ -d "$f" ] && [ ! -L "$f" ] || continue
              cmcr_pkg_safe "$f" dir || continue
              grep -qxF -- "$f" "$PF.others" 2>/dev/null && continue
              [ -z "$(ls -A "$f" 2>/dev/null | grep -vx '.DS_Store')" ] || continue
              rm -f -- "$f/.DS_Store" 2>/dev/null
              cmcr_rm_in "$(dirname "$f")" "$(basename "$f")" dir >/dev/null && cmcr_rec removed pkgdir "$f" ""
            done < "$PF.dirs"
          fi
          # 7. Receipts.
          while IFS= read -r r; do
            [ -n "$r" ] || continue
            if err="$(pkgutil --forget "$r" 2>&1 >/dev/null)"; then cmcr_rec forgot receipt "$r" ""
            else cmcr_rec failed receipt "$r" "pkgutil --forget: $(printf '%s' "$err" | head -n 1)"; fi
          done < "$PF.receipts"
          # 8. A vendor folder the app leaves empty.
          case "$LOC:$DIR" in
            folder:*|user:*:"$CMCR_USERS/$OWNER/Applications"/*)
              if [ -d "$DIR" ] && [ ! -L "$DIR" ] && [ -z "$(ls -A "$DIR" 2>/dev/null | grep -vx '.DS_Store')" ]; then
                rm -f -- "$DIR/.DS_Store" 2>/dev/null
                cmcr_rm_in "$(dirname "$DIR")" "$(basename "$DIR")" dir >/dev/null && cmcr_rec removed folder "$DIR" ""
              fi ;;
          esac
          return 0
        }

        for T0 in "${TARGETS[@]}"; do cmcr_un_target "$T0"; done
        cmcr_rec done summary "" "$N_DONE $N_KEPT $N_FAIL $N_PLAN $N_REFUSED $DRY $PLAN_KB $DONE_KB"
        [ $N_FAIL -gt 0 ] && exit 1
        [ $N_REFUSED -gt 0 ] && exit 2
        exit 0
        """#, asRoot: true)
    }

    /// One application (`uninstallApps`), as `cmcrctl _builder uninstall` and the older callers use it.
    public static func uninstallApp(_ path: String, studentUser: String = "", dryRun: Bool = false,
                                    packageFiles: Bool = false) -> RemoteScript {
        uninstallApps([path], studentUser: studentUser, dryRun: dryRun, packageFiles: packageFiles)
    }
}
