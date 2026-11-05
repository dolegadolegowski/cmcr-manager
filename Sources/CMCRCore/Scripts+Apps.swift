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
        OUT="$CMCR_TMP/apps.out"; : > "$OUT"
        cmcr_inv_app() { # LOCATION PATH
          local loc="$1" a="$2" kind=app bid ver size rc="" sys="" real
          case "$a" in *"$CMCR_T"*|*$'\n'*|*$'\r'*) return 0 ;; esac
          if [ -L "$a" ]; then
            # Into the system (Safari): listed where the app really is. Elsewhere: listed as the link, not removable –
            # the uninstaller refuses links, so the list must not offer it.
            real="$(cmcr_realdir "$a")"
            [ -n "$real" ] || return 0
            case "$real" in /System/*) a="$real"; loc=system ;; *) loc=link ;; esac
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
          printf 'CMCR:APP\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(cmcr_clean "$loc")" "$kind" "$a" "$(cmcr_clean "$bid")" \
            "$(cmcr_clean "$ver")" "$size" "$rc" >> "$OUT"
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
        awk -F'\t' '!seen[$4]++' "$OUT"
        if [ "$WITH_PKGS" = 1 ]; then
          awk -F'\t' '{printf "CMCR:PKG\t%s\t%s\t%s\t%s\n", $1, $3, $4, $2}' "$CMCR_RLIST"
        fi
        printf 'CMCR:END\t%s\n' "$(awk -F'\t' '!seen[$4]++' "$OUT" | wc -l | tr -d ' ')"
        exit 0
        """#)
    }

    /// Removes applications as root, or with `dryRun` only says what would be removed (nothing changes). `targets`
    /// are paths (see the allowed places above) or bare names (`Blender`: every allowed place that has Blender.app).
    ///
    /// Per app: the bundle (moved aside first – the same permission as deleting it, which macOS refuses without Full
    /// Disk Access – so an app that cannot go is never quit for nothing), its running processes (every user: TERM, then
    /// KILL after 5 s – found again after the move, also translocated copies), its launch daemons and agents: those
    /// whose Program/ProgramArguments[0] lies inside the bundle, the helper the bundle names in SMPrivilegedExecutables
    /// (with its file in /Library/PrivilegedHelperTools), a daemon that lists the bundle id in AssociatedBundleIdentifiers
    /// and, in an account's ~/Library/LaunchAgents, an agent labelled with the bundle id (at least three components).
    /// An app in a user's ~/Applications touches only that user's agents – never the system-wide
    /// /Library/LaunchDaemons and /Library/LaunchAgents, and never anything on a label alone there. The jobs are booted
    /// out (and started again if the removal fails) and removed, and the receipts of the packages that
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
        # Processes running from the bundle (every user): "pid user" per line. ps lists precomposed names (cmcr_ps),
        # the path on disk may be decomposed (AUDIT REV-09), so the paths are converted the same way. The bundle may
        # also run translocated (Gatekeeper: .../AppTranslocation/<uuid>/d/<Name>.app/Contents/...), and after the
        # move aside it runs from the new path (4th argument).
        cmcr_app_procs() { # PATH PHYSICAL [BUNDLE-NAME.app for translocated copies] [MOVED-PATH]
          local a b m t
          a="$(printf '%s' "$1" | iconv -c -f UTF-8-MAC -t UTF-8)"; b="$(printf '%s' "$2" | iconv -c -f UTF-8-MAC -t UTF-8)"
          m="$(printf '%s' "${4:-$2}" | iconv -c -f UTF-8-MAC -t UTF-8)"
          t=""; [ -n "${3:-}" ] && t="/$(printf '%s' "$3" | iconv -c -f UTF-8-MAC -t UTF-8)/Contents/"
          cmcr_ps -axww -o pid=,user=,comm= 2>/dev/null | A="${a:-$1}/" B="${b:-$2}/" C="/System/Volumes/Data${b:-$2}/" \
            D="${m:-${4:-$2}}/" T="$t" awk '
            { l = $0; sub(/^ *[0-9]+ +[^ ]+ +/, "", l) }
            index(l, ENVIRON["A"]) == 1 || index(l, ENVIRON["B"]) == 1 || index(l, ENVIRON["C"]) == 1 || index(l, ENVIRON["D"]) == 1 \
              || (ENVIRON["T"] != "" && index(l, "/AppTranslocation/") > 0 && index(l, ENVIRON["T"]) > 0) { print $1, $2 }'
          # A translocated copy that ps shows under another name: Launch Services knows it by bundle id and path.
          if [ -n "${CMCR_LS_BID:-}" ] && [ -n "$t" ] && command -v lsappinfo >/dev/null 2>&1; then
            lsappinfo list 2>/dev/null | BID="$CMCR_LS_BID" N="/$3" awk '
              function flush() { if (pid != "" && bid == ENVIRON["BID"] && index(path, "/AppTranslocation/") > 0 \
                  && length(path) >= length(ENVIRON["N"]) && substr(path, length(path) - length(ENVIRON["N"]) + 1) == ENVIRON["N"]) print pid }
              /^ *[0-9]+\) / { flush(); pid = ""; bid = ""; path = "" }
              /^ *bundleID="/ { bid = $0; sub(/^ *bundleID="/, "", bid); sub(/".*/, "", bid) }
              /^ *bundle path="/ { path = $0; sub(/^ *bundle path="/, "", path); sub(/".*/, "", path) }
              /^ *pid = / { pid = $3 }
              END { flush() }' | while IFS= read -r p; do
                case "$p" in ""|*[!0-9]*) continue ;; esac
                printf '%s %s\n' "$p" "$(cmcr_ps -o user= -p "$p" 2>/dev/null | tr -d ' ')"
              done
          fi
        }
        # A bundle id usable for matching launchd labels: at least three dot-separated components, no odd characters
        # (the id comes from the app's own Info.plist – a student controls it for an app in ~/Applications).
        cmcr_bid_ok() {
          case "$1" in ""|.*|*.|*..*|*[!A-Za-z0-9._-]*) return 1 ;; *.*.*) return 0 ;; esac
          return 1
        }
        # Another copy of an app with this bundle id (outside ITEM) in /Applications or an allowed ~/Applications: its
        # services must stay.
        cmcr_bid_elsewhere() { # BUNDLE-ID ITEM
          local d a u
          for d in "$CMCR_APPS" "$CMCR_APPS"/*/ ; do
            for a in "${d%/}"/*.app; do
              [ -d "$a" ] && [ "$a" != "$2" ] && [ "$(cmcr_plist "$a/Contents/Info.plist" CFBundleIdentifier)" = "$1" ] && return 0
            done
          done
          while IFS= read -r u; do
            for a in "$CMCR_USERS/$u/Applications"/*.app "$CMCR_USERS/$u/Applications"/*/*.app; do
              [ -d "$a" ] && [ "$a" != "$2" ] && [ "$(cmcr_plist "$a/Contents/Info.plist" CFBundleIdentifier)" = "$1" ] && return 0
            done
          done < <(cmcr_app_users)
          return 1
        }
        # PROGRAM lies inside the bundle being removed (absolute, no „..”).
        cmcr_inside() { # PROGRAM ITEM PHYSICAL
          case "$1" in /*) ;; *) return 1 ;; esac
          case "$1" in */../*|*/./*|*/..|*/.) return 1 ;; esac
          case "$1" in "$2"/*|"$3"/*) return 0 ;; esac
          return 1
        }
        # Launch daemons and agents of the app: "kind<TAB>plist<TAB>label<TAB>program<TAB>why". Kind: daemon, agent,
        # uagent:USER. Why: inside (Program/ProgramArguments[0] lies in the bundle), smjob (the helper the bundle
        # declares in SMPrivilegedExecutables: exact label, program /Library/PrivilegedHelperTools/<label>), assoc
        # (AssociatedBundleIdentifiers names the bundle id), label (an agent of an account: label = bundle id or
        # bundle id + "."). An app in a user's ~/Applications – its bundle id is the student's to choose – touches only
        # that user's ~/Library/LaunchAgents; the system-wide /Library/LaunchDaemons and /Library/LaunchAgents are
        # never matched by label alone. Program "-" means none.
        cmcr_launchd_find() { # PATH PHYSICAL BUNDLE-ID LOCATION OWNER BUNDLE
          local item="$1" phys="$2" bid="$3" loc="$4" owner="$5" bundle="$6" kind dir f label prog why u sm="" idok=0 other=0
          cmcr_bid_ok "$bid" && idok=1
          [ $idok = 1 ] && cmcr_bid_elsewhere "$bid" "$item" && other=1
          case "$loc" in
            apps|utilities|folder) sm="$(plutil -extract SMPrivilegedExecutables xml1 -o - "$bundle/Contents/Info.plist" 2>/dev/null \
                                      | sed -n 's/^[[:space:]]*<key>\(.*\)<\/key>[[:space:]]*$/\1/p')" ;;
          esac
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
              prog="$(cmcr_plist "$f" Program)"; [ -n "$prog" ] || prog="$(cmcr_plist "$f" ProgramArguments.0)"
              case "$label" in ""|com.apple.*|com.openssh.*|pl.cmcr.*) continue ;; esac
              why=""
              if cmcr_inside "$prog" "$item" "$phys"; then why=inside
              elif [ $other = 0 ]; then
                case "$prog" in *.app/*) continue ;; esac     # it belongs to another bundle
                case "$kind" in
                  uagent:*) if [ $idok = 1 ]; then case "$label" in "$bid"|"$bid".*) why=label ;; esac; fi ;;
                esac
                if [ -z "$why" ] && [ $idok = 1 ]; then
                  case "$kind" in
                    daemon|agent) cmcr_plist_lists "$f" AssociatedBundleIdentifiers "$bid" && why=assoc ;;
                  esac
                fi
                if [ -z "$why" ] && [ "$kind" = daemon ] && [ "$prog" = "$CMCR_FS/Library/PrivilegedHelperTools/$label" ] \
                   && printf '%s\n' "$sm" | grep -qxF -- "$label"; then why=smjob; fi
              fi
              # A system-wide service named only after the bundle id is not removed – but the report says it stays.
              if [ -z "$why" ] && [ $idok = 1 ] && [ $other = 0 ]; then
                case "$kind" in daemon|agent) case "$label" in "$bid"|"$bid".*) why=kept ;; esac ;; esac
              fi
              [ -n "$why" ] || continue
              printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$f" "$(cmcr_clean "$label")" "$(cmcr_clean "${prog:--}")" "$why"
            done
          done
        }
        # A launch agent in an account's ~/Library/LaunchAgents may be stopped and started again only in THAT account's
        # GUI domain, and only when the file really is the account's own agent of this app: a regular file (no link)
        # owned by the account, whose Label is the bundle id (or starts with "bundle id.") AND whose
        # Program/ProgramArguments[0] lies inside the bundle. The account's folder is the student's to fill, so
        # neither a plist of another vendor nor a program elsewhere may make root act on it. Prints the uid.
        cmcr_uagent_ok() { # USER PLIST ITEM PHYSICAL BUNDLE-ID
          local u="$1" f="$2" ou label prog
          case "$u" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
          ou="$(id -u "$u" 2>/dev/null)"
          case "$ou" in ""|0|*[!0-9]*) return 1 ;; esac
          [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -f %u "$f" 2>/dev/null)" = "$ou" ] || return 1
          cmcr_bid_ok "$5" || return 1
          label="$(cmcr_plist "$f" Label)"
          case "$label" in "$5"|"$5".*) ;; *) return 1 ;; esac
          prog="$(cmcr_plist "$f" Program)"; [ -n "$prog" ] || prog="$(cmcr_plist "$f" ProgramArguments.0)"
          cmcr_inside "$prog" "$3" "$4" || return 1
          printf '%s\n' "$ou"
        }
        # Does the array (or string) KEY of the plist contain exactly this string?
        cmcr_plist_lists() { # PLIST KEY STRING
          plutil -extract "$2" xml1 -o - "$1" 2>/dev/null | sed 's/^[[:space:]]*//' | grep -qxF -- "<string>$3</string>"
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
          local APP="$1" ITEM KIND=app DIR NAME LOC="" OWNER="" PARENT ROOTP B BID VER TITLE AUTH KB PROCS PIDS USERS_RUNNING ou dom who
          local LD PF RS OURS SYS u chk r loc others f rel rest GONE err ok i TNAME dom
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
            case "$(cmcr_realdir "$ITEM")" in
              /System/*) cmcr_rec refused "$KIND" "$ITEM" "to tylko dowiązanie do „$(readlink "$ITEM")” (tak macOS umieszcza w folderze Aplikacje np. Safari) – nie odinstalowuję; aplikacji systemowych nie można odinstalować" ;;
              *) cmcr_rec refused "$KIND" "$ITEM" "to dowiązanie do „$(readlink "$ITEM")” – CMCR nie usuwa dowiązań ani niczego przez nie; usuń aplikację w miejscu, na które wskazuje, albo samo dowiązanie przy komputerze" ;;
            esac
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

          TNAME=""; CMCR_LS_BID=""
          if [ $KIND = app ]; then TNAME="$NAME"; CMCR_LS_BID="$BID"; fi
          PROCS="$(cmcr_app_procs "$ITEM" "$PARENT/$NAME" "$TNAME")"
          PIDS="$(printf '%s\n' "$PROCS" | awk 'NF {print $1}' | paste -sd' ' -)"
          USERS_RUNNING="$(printf '%s\n' "$PROCS" | awk 'NF && !s[$2]++ {printf "%s%s", (n++ ? ", " : ""), $2}')"
          LD="$CMCR_TMP/launchd.$SEQ"; cmcr_launchd_find "$ITEM" "$PARENT/$NAME" "$BID" "$LOC" "$OWNER" "$B" > "$LD.all"
          awk -F'\t' '$5 != "kept"' "$LD.all" > "$LD"
          if cmcr_bid_ok "$BID" && cmcr_bid_elsewhere "$BID" "$ITEM"; then
            cmcr_rec note copies "$ITEM" "Na komputerze jest inna kopia aplikacji o tym samym identyfikatorze – usługi rozpoznawane tylko po identyfikatorze zostają."
          fi
          while IFS="$CMCR_T" read -r kind f label prog why; do
            [ -n "$f" ] || continue
            case "$kind" in daemon) what=daemon ;; *) what=agent ;; esac
            cmcr_rec kept "$what" "$f" "etykieta $label pasuje do identyfikatora aplikacji, ale usług z /Library CMCR nie usuwa po samej etykiecie (tylko gdy ich program leży w aplikacji albo pochodzą z jej pakietu) – jeśli należą do tej aplikacji, usuń je ręcznie"
          done < <(awk -F'\t' '$5 == "kept"' "$LD.all")
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
                  awk -F'\t' '$5 == "smjob" {print $4}' "$LD" | grep -qxF -- "$f" && continue
                  printf '%s\t%s\n' "$r" "$f"
                done >> "$PF"
          done
          # Files another package also installed stay (checked against every package not from Apple, and pkgutil's own
          # lookup for packages installed to /).
          if [ "$PKGFILES" = 1 ] && [ -s "$PF" ]; then
            : > "$PF.others"
            awk -F'\t' '{print $1}' "$CMCR_RLIST" | while IFS= read -r i; do
              grep -qxF -- "$i" "$PF.receipts" && continue
              loc="$(I="$i" awk -F'\t' '$1 == ENVIRON["I"] {print $2; exit}' "$CMCR_RLIST")"
              pkgutil --files "$i" 2>/dev/null | L="$loc" awk '{ p = "/" ENVIRON["L"] "/" $0; gsub(/\/\.\//, "/", p); gsub(/\/+/, "/", p); print p }'
            done > "$PF.others"
          fi

          # With the package's files its other launchd jobs go too – booted out first (step 2), then removed (step 5) –
          # and are planned as services, not as plain files. Not Apple's, CMCR's, and not files another package owns.
          if [ "$PKGFILES" = 1 ] && [ -s "$PF" ]; then
            : > "$PF.keep"
            while IFS="$CMCR_T" read -r r f; do
              kind=""; chk=""
              case "$f" in
                "$CMCR_FS"/Library/LaunchDaemons/*.plist) kind=daemon; chk="$CMCR_FS/Library/LaunchDaemons" ;;
                "$CMCR_FS"/Library/LaunchAgents/*.plist) kind=agent; chk="$CMCR_FS/Library/LaunchAgents" ;;
              esac
              if [ -n "$kind" ] && [ "$(dirname "$f")" = "$chk" ] \
                 && [ -f "$f" ] && [ ! -L "$f" ] && cmcr_pkg_safe "$f" file && ! grep -qxF -- "$f" "$PF.others" \
                 && ! awk -F'\t' '{print $2}' "$LD" | grep -qxF -- "$f" \
                 && ! pkgutil --file-info "$f" 2>/dev/null | R="$r" awk '/^pkgid: / && $2 != ENVIRON["R"] {f = 1} END {exit !f}'; then
                label="$(cmcr_plist "$f" Label)"
                prog="$(cmcr_plist "$f" Program)"; [ -n "$prog" ] || prog="$(cmcr_plist "$f" ProgramArguments.0)"
                case "$label" in ""|com.apple.*|com.openssh.*|pl.cmcr.*) ;; *)
                  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$f" "$(cmcr_clean "$label")" "$(cmcr_clean "${prog:--}")" pkg >> "$LD"
                  continue ;;
                esac
              fi
              printf '%s\t%s\n' "$r" "$f" >> "$PF.keep"
            done < "$PF"
            mv -f "$PF.keep" "$PF"
          fi

          # The plan.
          if [ -n "$PIDS" ] && [ "$DRY" = 1 ]; then cmcr_rec running process "$ITEM" "$USERS_RUNNING" "$PIDS"; fi
          [ "$DRY" = 1 ] && cmcr_rec plan "$KIND" "$ITEM" "${KB:-}"
          PLAN_KB=$((PLAN_KB + ${KB:-0}))
          while IFS="$CMCR_T" read -r kind f label prog why; do
            [ -n "$f" ] || continue
            case "$kind" in daemon) what=daemon ;; agent) what=agent ;; *) what=uagent ;; esac
            if [ "$DRY" = 1 ]; then
              case "$kind" in
                uagent:*) dom="$(cmcr_uagent_ok "${kind#uagent:}" "$f" "$ITEM" "$PARENT/$NAME" "$BID")" && dom="gui/$dom" || dom="bez zatrzymywania usługi"
                          cmcr_rec plan "$what" "$f" "$label ($dom)" "$why" ;;
                *) cmcr_rec plan "$what" "$f" "$label" "$why" ;;
              esac
            fi
            # A helper in PrivilegedHelperTools goes only when the bundle itself names it (SMPrivilegedExecutables).
            if [ "$why" = smjob ] && [ "$kind" = daemon ] && [ "$prog" = "$CMCR_FS/Library/PrivilegedHelperTools/$label" ] \
               && [ -f "$prog" ] && [ ! -L "$prog" ] && [ "$DRY" = 1 ]; then cmcr_rec plan helper "$prog" "$label" "$why"; fi
          done < "$LD"
          : > "$PF.go"
          if [ -s "$PF" ]; then
            if [ "$PKGFILES" = 1 ]; then
              while IFS="$CMCR_T" read -r r f; do
                if ! cmcr_pkg_safe "$f" file; then cmcr_rec kept pkgfile "$f" "chroniony folder systemu lub CMCR – zostaje"; continue; fi
                if grep -qxF -- "$f" "$PF.others" || pkgutil --file-info "$f" 2>/dev/null | R="$r" awk '/^pkgid: / && $2 != ENVIRON["R"] {f = 1} END {exit !f}'; then
                  cmcr_rec kept pkgfile "$f" "należy też do innego pakietu – zostaje"; continue
                fi
                printf '%s\n' "$f" >> "$PF.go"
                [ "$DRY" = 1 ] && cmcr_rec plan pkgfile "$f" "$r"
              done < "$PF"
            else
              cmcr_rec kept pkgfiles "$(awk -F'\t' 'NR == 1 {print $2}' "$PF")" "$(wc -l < "$PF" | tr -d ' ')" "$(awk -F'\t' 'NR <= 3 {print $2}' "$PF" | paste -sd'|' -)"
            fi
          fi
          if [ "$DRY" = 1 ] && [ -s "$PF.go" ]; then
            cmcr_rec note pkgdirs "" "Foldery pakietu, które po usunięciu tych plików zostaną puste, też zostaną usunięte (poza folderami standardowymi macOS)."
          fi
          while IFS= read -r r; do [ -n "$r" ] && [ "$DRY" = 1 ] && cmcr_rec plan receipt "$r" ""; done < "$PF.receipts"
          [ "$DRY" = 1 ] && return 0

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
          # The processes again, now: something may have started since the plan, and the bundle runs from its new place.
          PROCS="$(cmcr_app_procs "$ITEM" "$PARENT/$NAME" "$TNAME" "$PARENT/${GONE#./}/$NAME")"
          PIDS="$(printf '%s\n' "$PROCS" | awk 'NF && !s[$1]++ {print $1}' | paste -sd' ' -)"
          USERS_RUNNING="$(printf '%s\n' "$PROCS" | awk 'NF && !s[$2]++ {printf "%s%s", (n++ ? ", " : ""), $2}')"
          # 2. Its launchd jobs stopped, so nothing restarts it. The jobs that were loaded are noted: should the removal
          # fail, they are started again.
          : > "$LD.booted"
          while IFS="$CMCR_T" read -r kind f label prog why; do
            [ -n "$f" ] || continue
            case "$kind" in
              daemon)
                if launchctl print "system/$label" >/dev/null 2>&1 </dev/null; then printf 'system\t%s\n' "$f" >> "$LD.booted"; fi
                launchctl bootout system "$f" >/dev/null 2>&1 ;;
              uagent:*)
                # Only the owner's own domain, only a verified agent of this app (see cmcr_uagent_ok); with no GUI session
                # of the owner nothing is loaded, so nothing is stopped.
                ou="$(cmcr_uagent_ok "${kind#uagent:}" "$f" "$ITEM" "$PARENT/$NAME" "$BID")" || continue
                cmcr_gui_sessions | awk '{print $1}' | grep -qx -- "$ou" || continue
                if launchctl print "gui/$ou/$label" >/dev/null 2>&1 </dev/null; then printf 'gui/%s\t%s\t%s\n' "$ou" "$f" "${kind#uagent:}" >> "$LD.booted"; fi
                launchctl bootout "gui/$ou" "$f" >/dev/null 2>&1 </dev/null ;;
              *) for u in $(cmcr_gui_sessions | awk '{print $1}'); do
                   if launchctl print "gui/$u/$label" >/dev/null 2>&1 </dev/null; then printf 'gui/%s\t%s\n' "$u" "$f" >> "$LD.booted"; fi
                   launchctl bootout "gui/$u" "$f" >/dev/null 2>&1
                 done ;;
            esac
          done < "$LD"
          # 3. Its processes quit (every user), then killed.
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
          # A flag „uchg” set by the account on a file of its bundle would stop rm: cleared first (the failure path
          # below is only a rollback, harmless thanks to cmcr_uagent_ok).
          chflags -R nouchg -- "./$GONE" 2>/dev/null
          if rm -rf -- "./$GONE" 2>"$CMCR_TMP/rm.err" && [ ! -e "./$GONE" ]; then
            cd /
            cmcr_rec removed "$KIND" "$ITEM" "${KB:-}"
            DONE_KB=$((DONE_KB + ${KB:-0}))
          else
            err="$(head -n 1 "$CMCR_TMP/rm.err")"
            # Back in place, so the list still shows it and the next attempt finds it.
            if [ ! -e "./$NAME" ] && [ -e "./$GONE/$NAME" ]; then /bin/mv -- "./$GONE/$NAME" "./$NAME" 2>/dev/null && rmdir -- "./$GONE" 2>/dev/null; fi
            # ... and its services started again: the app stays as it was (the processes that were quit stay quit).
            if [ -e "./$NAME" ] && [ -s "$LD.booted" ]; then
              while IFS="$CMCR_T" read -r dom f who; do
                [ -n "$f" ] && [ -f "$f" ] || continue
                if [ -n "$who" ]; then
                  # An account's agent: checked again now, started only in its owner's own domain.
                  ou="$(cmcr_uagent_ok "$who" "$f" "$ITEM" "$PARENT/$NAME" "$BID")" && [ "$dom" = "gui/$ou" ] || continue
                fi
                launchctl bootstrap "$dom" "$f" >/dev/null 2>&1 </dev/null
              done < "$LD.booted"
              cmcr_rec note launchd "$ITEM" "Zatrzymane usługi aplikacji uruchomiono ponownie – aplikacja zostaje na miejscu."
            fi
            cd /
            cmcr_rec failed "$KIND" "$ITEM" "${err:-nie udało się usunąć} $FDA"
            return 0
          fi
          # 5. Launch daemons, agents and their helpers.
          while IFS="$CMCR_T" read -r kind f label prog why; do
            [ -n "$f" ] || continue
            case "$kind" in daemon) what=daemon ;; agent) what=agent ;; *) what=uagent ;; esac
            if err="$(cmcr_rm_in "$(dirname "$f")" "$(basename "$f")")"; then cmcr_rec removed "$what" "$f" "$label"
            else cmcr_rec failed "$what" "$f" "$err"; fi
            if [ "$why" = smjob ] && [ "$kind" = daemon ] && [ "$prog" = "$CMCR_FS/Library/PrivilegedHelperTools/$label" ] \
               && [ -f "$prog" ] && [ ! -L "$prog" ]; then
              if err="$(cmcr_rm_in "$(dirname "$prog")" "$(basename "$prog")")"; then cmcr_rec removed helper "$prog" "$label"
              else cmcr_rec failed helper "$prog" "$err"; fi
            fi
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
