import Foundation

/// Exit codes of the remote file browser scripts (stderr also carries a `CMCR:<CODE>` marker line).
public enum BrowseCode {
    public static let notFound: Int32 = 61
    public static let notDirectory: Int32 = 62
    public static let accessDenied: Int32 = 63
    /// macOS privacy protection (TCC) blocked the folder: remote users need "Full Disk Access".
    public static let privacyDenied: Int32 = 64
    public static let refused: Int32 = 65
    public static let exists: Int32 = 66
}

/// Remote side of the file browser: listing, new folder, rename, delete and download.
public extension Scripts {

    /// Shell helpers shared by the browser scripts.
    ///
    /// - `cmcr_resolve PATH` – resolves `{console}` and a leading `~` (administrator's home) into `$CMCR_PATH`;
    ///   fails with exit code 3 when `{console}` is used while nobody is logged in.
    /// - `cmcr_guard_item PATH` – canonicalises the parent folder (symlinks resolved) into `$CMCR_REAL` and refuses
    ///   anything outside account folders, /tmp and external volumes, as well as Library, dot-files directly in a
    ///   home folder and the standard folders (Desktop, Documents…) themselves.
    internal static let browseLibrary = #"""
    cmcr_admin_home() {
      if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        local h
        h="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
        if [ -n "$h" ]; then printf '%s' "$h"; return; fi
      fi
      printf '%s' "$HOME"
    }
    cmcr_resolve() {
      CMCR_PATH="$1"
      case "$CMCR_PATH" in *'{console}'*)
        if [ -z "$CONSOLE_USER" ]; then
          echo "CMCR:NO_CONSOLE" >&2
          echo "Nikt nie jest zalogowany – folder zalogowanego użytkownika jest niedostępny." >&2
          return 3
        fi
        CMCR_PATH="${CMCR_PATH//\{console\}/$CONSOLE_USER}" ;;
      esac
      case "$CMCR_PATH" in "~"|"~/"*) CMCR_PATH="$(cmcr_admin_home)${CMCR_PATH#\~}" ;; esac
      while [ "${CMCR_PATH%/}" != "$CMCR_PATH" ]; do CMCR_PATH="${CMCR_PATH%/}"; done
      [ -n "$CMCR_PATH" ] || CMCR_PATH="/"
      case "$CMCR_PATH" in
        /*) ;;
        *) echo "CMCR:REFUSED" >&2; echo "Odmowa: ścieżka musi zaczynać się od / (podano: $CMCR_PATH)" >&2; return 65 ;;
      esac
    }
    cmcr_refuse() { echo "CMCR:REFUSED" >&2; echo "Odmowa: $1" >&2; return 65; }
    cmcr_privacy() {
      echo "CMCR:PRIVACY" >&2
      echo "macOS blokuje dostęp do $1 (ochrona prywatności) – włącz pełny dostęp do dysku dla Zdalnego logowania." >&2
      exit 64
    }
    cmcr_guard_item() {
      local p="$1" base parent real sub
      base="${p##*/}"; parent="${p%/*}"; [ -n "$parent" ] || parent="/"
      case "$base" in ""|.|..) cmcr_refuse "niepoprawna ścieżka: $p"; return ;; esac
      real="$(cd "$parent" 2>/dev/null && pwd -P)" || {
        echo "CMCR:NOT_FOUND" >&2; echo "Folder nie istnieje: $parent" >&2; return 61
      }
      [ "$real" = "/" ] && real=""
      CMCR_REAL="$real/$base"
      case "$CMCR_REAL" in
        /Users/*/?*|/private/tmp/?*|/Volumes/*/?*) ;;
        *) cmcr_refuse "usuwać i zmieniać nazwy można tylko w folderach kont (/Users/…), w /tmp i na dyskach zewnętrznych – $CMCR_REAL"; return ;;
      esac
      case "$CMCR_REAL" in /Users/*)
        sub="${CMCR_REAL#/Users/*/}"
        case "$sub" in
          Library|Library/*|.*) cmcr_refuse "folder chroniony (Library lub plik ukryty w katalogu domowym) – $CMCR_REAL"; return ;;
          Desktop|Documents|Downloads|Movies|Music|Pictures|Public|Applications|Sites)
            cmcr_refuse "nie można usunąć ani przemianować standardowego folderu konta – $CMCR_REAL"; return ;;
        esac ;;
      esac
      return 0
    }
    """#

    private static func browseScript(_ body: String, asRoot: Bool) -> RemoteScript {
        RemoteScript(browseLibrary + "\n" + body, asRoot: asRoot)
    }

    private static func shArray(_ values: [String]) -> String {
        "(" + values.map(shQuote).joined(separator: " ") + ")"
    }

    /// Lists one remote folder as a NUL-separated record stream (see `Parsers.remoteListing`).
    ///
    /// Names travel verbatim (spaces, newlines, any Unicode), the metadata of all entries comes from a single
    /// `stat` call, so even large folders cost only a few processes.
    static func listDirectory(_ path: String, asRoot: Bool, limit: Int = 5000) -> RemoteScript {
        browseScript(#"""
        cmcr_resolve \#(shQuote(path)) || exit $?
        DIR="$CMCR_PATH"
        if [ ! -e "$DIR" ]; then echo "CMCR:NOT_FOUND" >&2; echo "Folder nie istnieje: $DIR" >&2; exit 61; fi
        if [ ! -d "$DIR" ]; then echo "CMCR:NOT_DIR" >&2; echo "To nie jest folder: $DIR" >&2; exit 62; fi
        if ! cd "$DIR" 2>"$CMCR_TMP/cd.err"; then
          grep -q "Operation not permitted" "$CMCR_TMP/cd.err" && cmcr_privacy "$DIR"
          echo "CMCR:DENIED" >&2; echo "Brak dostępu do folderu: $DIR" >&2; exit 63
        fi
        N=0
        while IFS= read -r -d '' f; do P[N]="$f"; N=$((N + 1)); done < <(find . -mindepth 1 -maxdepth 1 -print0 2>"$CMCR_TMP/find.err")
        if [ "$N" -eq 0 ] && [ -s "$CMCR_TMP/find.err" ]; then
          grep -q "Operation not permitted" "$CMCR_TMP/find.err" && cmcr_privacy "$DIR"
          echo "CMCR:DENIED" >&2; echo "Brak dostępu do folderu: $DIR" >&2; exit 63
        fi
        TOTAL=$N
        LIMIT=\#(max(1, limit))
        if [ "$N" -gt "$LIMIT" ]; then P=("${P[@]:0:$LIMIT}"); N=$LIMIT; fi
        A=(. "${P[@]}")
        FMT=$'%HT\t%z\t%m\t%Su\t%Sg\t%Lp\t%Sf'
        K=0
        while IFS=$'\t' read -r a b c d e g h; do
          T[K]="$a"; S[K]="$b"; MT[K]="$c"; O[K]="$d"; G[K]="$e"; MO[K]="$g"; FL[K]="$h"; K=$((K + 1))
        done < <(stat -f "$FMT" "${A[@]}" 2>/dev/null)
        if [ "$K" -ne "${#A[@]}" ]; then
          # An entry vanished between find and stat: one stat per entry keeps names and metadata paired.
          B=(); K=0
          for f in "${A[@]}"; do
            line="$(stat -f "$FMT" "$f" 2>/dev/null)" || continue
            IFS=$'\t' read -r a b c d e g h <<< "$line"
            B[K]="$f"; T[K]="$a"; S[K]="$b"; MT[K]="$c"; O[K]="$d"; G[K]="$e"; MO[K]="$g"; FL[K]="$h"; K=$((K + 1))
          done
          A=("${B[@]}")
        fi
        W=0; [ -w . ] && W=1
        printf 'CMCR-LISTING\0%s\0' 1
        printf 'PATH\0%s\0' "$DIR"
        printf 'REAL\0%s\0' "$(pwd -P)"
        printf 'WRITABLE\0%s\0' "$W"
        printf 'USER\0%s\0' "$CMCR_ADMIN_USER"
        printf 'EUID\0%s\0' "$EUID"
        printf 'CONSOLE\0%s\0' "$CONSOLE_USER"
        printf 'HOME\0%s\0' "$(cmcr_admin_home)"
        printf 'TOTAL\0%s\0' "$TOTAL"
        i=0
        while [ "$i" -lt "${#A[@]}" ]; do
          f="${A[$i]}"
          if [ "$f" = . ]; then
            printf 'SELF\0%s\0%s\0%s\0' "${O[$i]}" "${G[$i]}" "${MO[$i]}"
          else
            target=""; isdir=0
            [ -d "$f" ] && isdir=1
            [ "${T[$i]}" = "Symbolic Link" ] && target="$(readlink "$f")"
            printf 'ENTRY\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "${T[$i]}" "${S[$i]}" "${MT[$i]}" \
              "${O[$i]}" "${G[$i]}" "${MO[$i]}" "${FL[$i]}" "$isdir" "${f#./}" "$target"
          fi
          i=$((i + 1))
        done
        printf 'END\0'
        """#, asRoot: asRoot)
    }

    /// Creates a folder. As root the new folder gets the owner of the folder it is created in, so a folder made
    /// in a student's Desktop belongs to the student. `intermediate` behaves like `mkdir -p`.
    static func makeDirectory(_ path: String, asRoot: Bool, intermediate: Bool = false) -> RemoteScript {
        browseScript(#"""
        cmcr_resolve \#(shQuote(path)) || exit $?
        NEW="$CMCR_PATH"
        NAME="${NEW##*/}"
        case "$NAME" in ""|.|..) cmcr_refuse "niepoprawna nazwa folderu: $NEW"; exit $? ;; esac
        if [ -e "$NEW" ] || [ -L "$NEW" ]; then
          if [ \#(intermediate ? 1 : 0) = 1 ] && [ -d "$NEW" ]; then echo "Folder już istnieje: $NEW"; exit 0; fi
          echo "CMCR:EXISTS" >&2; echo "Element o tej nazwie już istnieje: $NEW" >&2; exit 66
        fi
        TOP="$NEW"; PARENT="${TOP%/*}"; [ -n "$PARENT" ] || PARENT="/"
        if [ \#(intermediate ? 1 : 0) = 1 ]; then
          while [ ! -e "$PARENT" ]; do TOP="$PARENT"; PARENT="${TOP%/*}"; [ -n "$PARENT" ] || PARENT="/"; done
          mkdir -p "$NEW" || { echo "✘ Nie można utworzyć folderu $NEW" >&2; exit 1; }
        else
          if [ ! -d "$PARENT" ]; then echo "CMCR:NOT_FOUND" >&2; echo "Folder nie istnieje: $PARENT" >&2; exit 61; fi
          mkdir "$NEW" || { echo "✘ Nie można utworzyć folderu $NEW" >&2; exit 1; }
        fi
        if [ \#(asRoot ? 1 : 0) = 1 ]; then
          OWN="$(stat -f '%Su:%Sg' "$PARENT" 2>/dev/null)"
          [ -n "$OWN" ] && chown -R "$OWN" "$TOP"
        fi
        echo "✔ Utworzono folder $NEW"
        """#, asRoot: asRoot)
    }

    /// Renames an item inside its folder (no overwriting, same safety rules as deleting).
    static func renameItem(_ path: String, to newName: String, asRoot: Bool) -> RemoteScript {
        browseScript(#"""
        NEWNAME=\#(shQuote(newName))
        case "$NEWNAME" in ""|.|..|*/*) cmcr_refuse "niepoprawna nowa nazwa: $NEWNAME"; exit $? ;; esac
        cmcr_resolve \#(shQuote(path)) || exit $?
        cmcr_guard_item "$CMCR_PATH" || exit $?
        SRC="$CMCR_REAL"
        if [ ! -e "$SRC" ] && [ ! -L "$SRC" ]; then echo "CMCR:NOT_FOUND" >&2; echo "Nie znaleziono: $SRC" >&2; exit 61; fi
        DST="${SRC%/*}/$NEWNAME"
        if { [ -e "$DST" ] || [ -L "$DST" ]; } && ! [ "$SRC" -ef "$DST" ]; then
          echo "CMCR:EXISTS" >&2; echo "Element o nazwie „$NEWNAME” już istnieje." >&2; exit 66
        fi
        mv -n "$SRC" "$DST" || { echo "✘ Nie udało się zmienić nazwy $SRC" >&2; exit 1; }
        echo "✔ Zmieniono nazwę: ${SRC##*/} → $NEWNAME"
        """#, asRoot: asRoot)
    }

    /// Permanently deletes items (files, folders, links – never the target of a link).
    /// `dryRun` only reports what the safety rules would allow.
    static func deleteItems(_ paths: [String], asRoot: Bool, dryRun: Bool = false) -> RemoteScript {
        browseScript(#"""
        ITEMS=\#(shArray(paths))
        RC=0
        for it in "${ITEMS[@]}"; do
          cmcr_resolve "$it" || { RC=$?; continue; }
          cmcr_guard_item "$CMCR_PATH" || { RC=$?; continue; }
          if [ ! -e "$CMCR_REAL" ] && [ ! -L "$CMCR_REAL" ]; then echo "Brak (już usunięto?): $CMCR_REAL"; continue; fi
          if [ \#(dryRun ? 1 : 0) = 1 ]; then echo "Zostałoby usunięte: $CMCR_REAL"; continue; fi
          if rm -rf "$CMCR_REAL"; then echo "✔ Usunięto $CMCR_REAL"; else echo "✘ Nie udało się usunąć $CMCR_REAL" >&2; RC=1; fi
        done
        exit $RC
        """#, asRoot: asRoot)
    }

    /// Streams the selected items of one folder as a tar archive to stdout (download transport).
    static func archiveItems(in folder: String, names: [String], asRoot: Bool) -> RemoteScript {
        browseScript(#"""
        cmcr_resolve \#(shQuote(folder)) || exit $?
        DIR="$CMCR_PATH"
        [ -d "$DIR" ] || { echo "CMCR:NOT_FOUND" >&2; echo "Folder nie istnieje: $DIR" >&2; exit 61; }
        cd "$DIR" 2>/dev/null || { echo "CMCR:DENIED" >&2; echo "Brak dostępu do folderu: $DIR" >&2; exit 63; }
        NAMES=\#(shArray(names))
        ARGS=()
        for n in "${NAMES[@]}"; do
          case "$n" in ""|.|..|*/*) echo "Pominięto niepoprawną nazwę: $n" >&2; continue ;; esac
          if [ -e "./$n" ] || [ -L "./$n" ]; then ARGS[${#ARGS[@]}]="./$n"; else echo "Nie znaleziono: $n" >&2; fi
        done
        [ "${#ARGS[@]}" -gt 0 ] || { echo "CMCR:NOT_FOUND" >&2; echo "Nie znaleziono wybranych elementów." >&2; exit 61; }
        COPYFILE_DISABLE=1 tar -cf - "${ARGS[@]}"
        """#, asRoot: asRoot)
    }
}
