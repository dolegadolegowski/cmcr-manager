#!/bin/bash
# Publikuje wersję CMCR Manager w GitHub Releases z podpisanym manifestem automatycznych uaktualnień.
#
#   scripts/release.sh [X.Y.Z] [--notes-file zmiany.md] [--draft] [--arm64-only] [--dry-run]
#
# Wersja pochodzi z pliku VERSION (podany argument musi się z nim zgadzać – najpierw zatwierdź nowy VERSION).
# --dry-run buduje, pakuje i podpisuje wszystko w dist/X.Y.Z, ale niczego nie publikuje (bez gh, bez tagu).
#
# Wymaga: klucza prywatnego Ed25519 (swift scripts/update-signing.swift keygen; Pęk kluczy albo plik 0600
# poza repozytorium), jego klucza publicznego w Sources/CMCRCore/UpdateKeys.swift, czystego drzewa git
# zgodnego z origin/main oraz zalogowanego gh (gh auth login).
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES_FILE="" DRY=0 UNIVERSAL=1 WANTED=""
DRAFT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) NOTES_FILE=$2; shift 2 ;;
    --draft) DRAFT=(--draft); shift ;;
    --dry-run) DRY=1; shift ;;
    --arm64-only) UNIVERSAL=0; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Nieznana opcja: $1" >&2; exit 64 ;;
    *) WANTED=$1; shift ;;
  esac
done
VERSION=$(tr -d '[:space:]' < VERSION)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "✘ Nieprawidłowa wersja w pliku VERSION: $VERSION" >&2; exit 64; }
TAG="v$VERSION"; APP="build/CMCR Manager.app"; DIST="dist/$VERSION"; ZIP="CMCR-Manager-$VERSION.zip"
KEYS_SRC="Sources/CMCRCore/UpdateKeys.swift"
step() { printf '\n• %s\n' "$*"; }
die() { printf '✘ %s\n' "$*" >&2; exit 1; }
warn() { printf '⚠︎ %s\n' "$*" >&2; }

[ -z "$WANTED" ] || [ "${WANTED#v}" = "$VERSION" ] || die "Plik VERSION zawiera $VERSION, a podano $WANTED – zmień VERSION i zatwierdź go."

# The maintainer tool is compiled once (a `swift script.swift` run takes several seconds each time).
TOOLS=$(mktemp -d)
trap 'rm -rf "$TOOLS"' EXIT
swiftc -O scripts/update-signing.swift -o "$TOOLS/update-signing" 2>/dev/null \
  || { swiftc -O scripts/update-signing.swift -o "$TOOLS/update-signing"; die "Nie można skompilować scripts/update-signing.swift"; }
signing() { "$TOOLS/update-signing" "$@"; }

step "Kontrole wstępne ($TAG)"
[ -z "$(git status --porcelain)" ] || die "Masz niezatwierdzone lub nieśledzone pliki – zatwierdź je albo dodaj do .gitignore."
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || die "Brak pliku $NOTES_FILE"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "Tag $TAG już istnieje."
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || warn "Wydanie nie z gałęzi main."
if [ $DRY = 0 ]; then
  command -v gh >/dev/null || die "Brak gh (brew install gh)."
  gh auth status >/dev/null 2>&1 || die "Zaloguj się: gh auth login"
  git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "Tag $TAG istnieje już na GitHubie."
  git fetch -q origin main && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "HEAD różni się od origin/main – wypchnij zmiany (git push) przed wydaniem."
fi
LAST=$(git -c versionsort.suffix=- tag -l 'v[0-9]*' --sort=-v:refname | head -n 1 || true)
if [ -n "$LAST" ]; then signing is-newer "$VERSION" "$LAST" || die "Wersja $VERSION nie jest nowsza niż $LAST."; fi

step "Szukanie sekretów w śledzonych plikach"
if git ls-files | grep -v '^\.claude/' | grep -E '(^|/)(hosts|settings)\.json$|\.(key|pem|p12|p8|keychain|keychain-db)$|(^|/)askpass\.sh$|(^|/)\.env'; then
  die "Śledzone są pliki, które nie mogą trafić do publicznego repozytorium (powyżej)."
fi
if git grep -nIE -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -e '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}' \
     -e 'github_pat_[A-Za-z0-9_]{40,}' -e 'CMCR_(PASSWORD|UPDATE_SIGNING_KEY)=[^$[:space:]"]{8,}' -- . ':!scripts/release.sh'; then
  die "Znaleziono coś, co wygląda na sekret (powyżej) – usuń to z historii i unieważnij."
fi
git ls-files -z | signing leak-check || die "Klucz prywatny podpisu trafił do repozytorium."
# Only the history that gets published (HEAD); a false positive can be allowed with a `gitleaks:allow` comment.
if command -v gitleaks >/dev/null; then
  gitleaks git --no-banner --redact --log-opts=HEAD . || die "gitleaks zgłosił wyciek (szczegóły: gitleaks git -v --log-opts=HEAD .)"
fi

step "Klucz podpisu i repozytorium"
PUB=$(signing public-key) || die "Brak klucza prywatnego (swift scripts/update-signing.swift keygen)."
if ! grep -qF "\"$PUB\"" "$KEYS_SRC"; then
  [ $DRY = 1 ] || die "Klucz publiczny $PUB nie jest wpisany w $KEYS_SRC – zainstalowane kopie odrzuciłyby to wydanie."
  warn "(próba) Klucz publiczny $PUB nie jest wpisany w $KEYS_SRC – prawdziwe wydanie zostałoby przerwane."
fi
REPO=$(sed -n 's/.*static let repository = "\(.*\)".*/\1/p' "$KEYS_SRC")
[[ "$REPO" == */* && "$REPO" != OWNER/* ]] || die "Ustaw UpdateKeys.repository w $KEYS_SRC."
if [ $DRY = 0 ]; then
  ORIGIN=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  [ "$ORIGIN" = "$REPO" ] || die "UpdateKeys.repository = $REPO, a origin to $ORIGIN."
fi

step "Budowanie $VERSION"
VERSION="$VERSION" BUILD_NUMBER="$(git rev-list --count HEAD)" UNIVERSAL=$UNIVERSAL scripts/build-app.sh --dmg
SELFTEST=$("$APP/Contents/MacOS/CMCRManager" --cmcr-self-test | tail -n 1)
[ "$SELFTEST" = "$VERSION" ] || die "Test uruchomienia zwrócił '$SELFTEST' zamiast $VERSION."
codesign --verify --deep --strict "$APP" || die "Podpis kodu pakietu jest nieprawidłowy."
if codesign -dr - "$APP" 2>&1 | grep -q 'designated => cdhash'; then
  warn "Podpis ad-hoc: po uaktualnieniu macOS ponownie zapyta o dostęp do hasła w Pęku kluczy."
  warn "Stała tożsamość podpisu: scripts/make-signing-identity.sh (README › Podpis kodu)."
fi

step "Pakowanie"
rm -rf "$DIST"; mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP"
cp build/CMCR-Manager.dmg "$DIST/CMCR-Manager-$VERSION.dmg"
ditto -c -k build/cmcrctl "$DIST/cmcrctl-$VERSION-macos.zip"
CHECK=$(mktemp -d); ditto -x -k "$DIST/$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/CMCR Manager.app" || die "Podpis kodu nie przetrwał spakowania."
rm -rf "$CHECK"

step "Manifest i podpis Ed25519"
NOTES_ARGS=(); [ -n "$NOTES_FILE" ] && NOTES_ARGS=(--notes-file "$NOTES_FILE")
signing manifest --app "$APP" --zip "$DIST/$ZIP" --tag "$TAG" ${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"} --out "$DIST/cmcr-update.json"
signing sign "$DIST/cmcr-update.json" > "$DIST/cmcr-update.json.sig"
if [ $DRY = 1 ]; then
  signing verify "$DIST/cmcr-update.json" "$DIST/cmcr-update.json.sig" --public-key "$PUB"
else
  signing verify "$DIST/cmcr-update.json" "$DIST/cmcr-update.json.sig" --keys-from "$KEYS_SRC"
fi
(cd "$DIST" && shasum -a 256 -- * > SHA256SUMS.txt)
ls -l "$DIST"
if [ $DRY = 1 ]; then step "Próba zakończona – nic nie opublikowano. Pliki: $DIST"; exit 0; fi

step "Publikacja $TAG"
git tag -a "$TAG" -m "CMCR Manager $VERSION"
git push origin "$TAG"
GH_NOTES=(--generate-notes); [ -n "$NOTES_FILE" ] && GH_NOTES=(--notes-file "$NOTES_FILE")
PRE=(); [[ "$VERSION" == *-* ]] && PRE=(--prerelease)
gh release create "$TAG" "$DIST"/* --verify-tag --title "CMCR Manager $VERSION" \
  "${GH_NOTES[@]}" ${PRE[@]+"${PRE[@]}"} ${DRAFT[@]+"${DRAFT[@]}"}
echo "✔ Opublikowano: $(gh release view "$TAG" --json url -q .url)"
