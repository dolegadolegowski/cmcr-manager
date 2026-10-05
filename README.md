# CMCR Manager

Natywna aplikacja okienkowa macOS (SwiftUI) do zdalnego zarządzania pracownią iMaców w sieci LAN przez ich konta administracyjne. Rozwija sposoby pracy z [cmcr-helpers](https://github.com/ws-qcnssp/cmcr-helpers): te same konta `imacNN@imacNN.local`, SSH z kluczem, folder ucznia `/Users/student/Public/cmcr` i lokalny `~/Public/cmcr`. Wszystko działa przez wbudowane w macOS `ssh`/`scp` — na iMacach nie trzeba niczego instalować.

## Co potrafi

| Dział | Funkcje |
|---|---|
| **Komputery** | Stan pracowni (online, zalogowany użytkownik, macOS, model, IP/MAC, czas pracy, dysk), odświeżanie co 2 min, sesja SSH w Terminalu (`cmcr-go`), Udostępnianie ekranu (VNC) |
| **Polecenia** | Skrypt bash na wielu iMacach naraz (`cmcr-exec`), opcjonalnie jako root, gotowe polecenia z README/notes.md, własne zapisane fragmenty |
| **Pliki** | Wgrywanie plików i folderów do wskazanego folderu (presety: folder cmcr ucznia, Biurko, Dokumenty, `/Users/Shared`, `/Applications`, dowolna ścieżka) z ustawieniem właściciela i uprawnień; zbieranie prac (`cmcr-pull`) do `~/Public/cmcr/<host>`; konwencja `all` + `<host>` (`cmcr-push`); podgląd i czyszczenie folderów |
| **Aplikacje** | Lista uruchomionych aplikacji zalogowanego użytkownika; uruchamianie (z argumentami), zamykanie i wymuszanie zamknięcia na jednym lub wszystkich iMacach; otwieranie URL/plików; lista zainstalowanych i odinstalowywanie |
| **Instalacja** | `.pkg`, `.dmg`, `.zip`, `.app` z tego Maca lub pobierane z URL bezpośrednio na iMacach; Homebrew (formuły i `--cask`), instalacja Homebrew i Oracle JDK; Unity Hub headless (edytor + moduły) i Android SDK (`sdkmanager`) — wg notes.md |
| **Aktualizacje** | `softwareupdate` (lista, pobieranie, instalacja, restart; na Apple Silicon z `--user/--stdinpass`), historia, `brew upgrade`, `mas upgrade` |
| **Podgląd ekranów** | Siatka miniatur ekranów zalogowanych użytkowników z automatycznym odświeżaniem i powiększeniem — tylko do odczytu, z ograniczeniami (niżej) |
| **Sesja i zasilanie** | Wiadomość (okno/powiadomienie), wylogowanie, uśpienie ekranu/komputera, restart, wyłączenie, Wake-on-LAN |
| **Zadania** | Historia operacji z wynikiem i pełnym wyjściem dla każdego iMaca, anulowanie; dziennik działań w `~/Library/Logs/CMCRManager/actions.log` |
| **Konfiguracja** | Lista komputerów (generator jak pętla w `cmcr-helpers.sh`, import/eksport), hasła w Pęku kluczy (wspólne lub per komputer), generowanie i rozsyłanie klucza SSH, ustawienia, przygotowanie iMaców |

### Podgląd ekranu – ograniczenia

- wyłącznie zrzuty ekranu — bez przejmowania myszy i klawiatury (pełne sterowanie tylko świadomie przez „Udostępnianie ekranu”, jeśli jest włączone na iMacu),
- domyślnie **tylko konta standardowe** — sesje kont administratorów są blokowane po stronie iMaca,
- opcjonalna lista dozwolonych kont (np. `student`),
- użytkownik dostaje powiadomienie o rozpoczęciu podglądu,
- ograniczona rozdzielczość i jakość JPEG oraz minimalny odstęp odświeżania,
- każda sesja podglądu jest zapisywana w dzienniku działań.

## Wymagania

**Komputer administratora:** macOS 13 lub nowszy, Swift (Xcode albo Command Line Tools: `xcode-select --install`).

**Każdy iMac (jednorazowo, przy komputerze):**
1. Ustawienia systemowe › Ogólne › Udostępnianie › **Logowanie zdalne** — włączone dla administratorów (konto `imacNN`). Do pobierania plików z chronionych folderów ucznia zaznacz „Zezwalaj zdalnym użytkownikom na pełny dostęp do dysku”.
2. Podgląd ekranu: Prywatność i ochrona › **Nagrywanie ekranu i dźwięku systemowego** › „+” › ⌘⇧G › `/usr/libexec/sshd-keygen-wrapper` › włącz. Bez tego zrzut pokaże tylko tapetę lub się nie uda (macOS nie pozwala nadać tego uprawnienia zdalnie bez MDM).
3. Opcjonalnie: **Udostępnianie ekranu** (VNC) i „Budź przy dostępie do sieci” (Wake-on-LAN).

Przy pierwszym połączeniu macOS zapyta, czy CMCR Manager może korzystać z sieci lokalnej — zezwól.

## Budowanie i uruchomienie

```bash
scripts/build-app.sh
```

```bash
open "build/CMCR Manager.app"
```

`scripts/build-app.sh --dmg` dodatkowo tworzy `build/CMCR-Manager.dmg` do przeniesienia na inny Mac. Numer wersji pochodzi z pliku `VERSION`. Skrypt sam wybiera zgodne SDK, gdy zainstalowane są tylko Command Line Tools (najnowsze SDK może wymagać Xcode do makr SwiftUI). W trakcie pracy nad kodem: `swift run CMCRManager`.

## Pierwsze kroki

1. **Konfiguracja › Komputery** — domyślnie lista `imac01…imac15` (`imacNN@imacNN.local`); popraw ją generatorem lub ręcznie.
2. **Konfiguracja › Dostęp i hasła** — zapisz hasło kont administracyjnych (Pęk kluczy). Jeśli komputery mają różne hasła, ustaw „własne” przy danym komputerze.
3. Zaznacz wszystkie komputery i kliknij **Roześlij klucz** (odpowiednik sekcji „Distribute your SSH key” z README). Kolejne połączenia logują się kluczem.
4. **Konfiguracja › Przygotowanie iMaców** — „Utwórz folder cmcr ucznia” (`/Users/student/Public/cmcr`, właściciel `student`, `chmod 777`).

Zaznaczenie komputerów na liście (środkowa kolumna) jest wspólne dla wszystkich działów; każdy przycisk akcji pokazuje, na ilu komputerach zadziała. Skróty: ⌘R odśwież stan, ⇧⌘A zaznacz wszystkie, ⇧⌘O zaznacz online, ⌘1…⌘0 działy.

## Odpowiedniki cmcr-helpers

| cmcr-helpers.sh | CMCR Manager | cmcrctl |
|---|---|---|
| `cmcr-exec "cmd" [nr]` | Polecenia | `cmcrctl exec "cmd" [all\|nr] [--root]` |
| `cmcr-go nr` | menu kontekstowe › Sesja SSH w Terminalu | `cmcrctl go nr` |
| `cmcr-push all\|nr` | Pliki › Konwencja cmcr-helpers | `cmcrctl push all\|nr [--root]` |
| `cmcr-pull all\|nr` | Pliki › Pobierz pliki | `cmcrctl pull all\|nr [--root]` |
| dystrybucja klucza (README) | Konfiguracja › Dostęp i hasła | — |
| Unity Hub / sdkmanager / Homebrew (notes.md) | Instalacja, Polecenia › Gotowe polecenia | `cmcrctl exec` |

`cmcrctl` (w `build/cmcrctl` i w pakiecie aplikacji: `Contents/Resources/bin/cmcrctl`) korzysta z tej samej konfiguracji i Pęku kluczy co aplikacja. Dodatkowo: `status`, `apps`, `screenshot`, `open-app`, `quit-app`, `render` (pokazuje dokładnie skrypt wykonywany zdalnie). Hasło można też podać zmienną `CMCR_PASSWORD`.

## Jak to działa i bezpieczeństwo

- Każda operacja to skrypt bash przesyłany w linii poleceń `ssh` w base64 (brak problemów z cudzysłowami) i wykonywany na koncie administracyjnym.
- Hasło administratora jest trzymane w Pęku kluczy i przekazywane wyłącznie przez szyfrowany kanał SSH (pierwsza linia stdin) do pomocnika `SUDO_ASKPASS` w prywatnym katalogu tymczasowym (usuwanym po zakończeniu). Nigdy nie trafia do argumentów procesów ani na dysk iMaca. Błędne hasło kosztuje tylko jedną nieudaną próbę sudo.
- Działania w sesji ucznia (uruchamianie aplikacji, wiadomości, zrzuty) wykonywane są przez `launchctl asuser` w sesji aktualnie zalogowanego użytkownika.
- Pliki są pakowane do jednego archiwum `tar` (zachowuje pakiety `.app`, dowiązania i uprawnienia), wysyłane `scp` do `/tmp` i rozpakowywane na miejscu.
- W skryptach dostępne są: `asroot`, `as_console_user`, `with_askpass`, `$CONSOLE_USER`, `$CONSOLE_UID`, `$CMCR_ADMIN_USER`, `$CMCR_TMP`.
- Konfiguracja: `~/Library/Application Support/CMCRManager/` (`hosts.json`, `settings.json`; katalog można zmienić zmienną `CMCR_CONFIG_DIR`).

## Uaktualnienia aplikacji

CMCR Manager sam sprawdza w [GitHub Releases](https://github.com/dolegadolegowski/cmcr-manager/releases), czy jest nowsza wersja: kilkanaście sekund po uruchomieniu i potem raz dziennie. Gdy jest, na dole paska bocznego pojawia się **„Dostępna nowa wersja X”** — kliknięcie pokazuje opis zmian i przyciski **Zainstaluj i uruchom ponownie**, **Przypomnij później** (24 h) oraz **Pomiń tę wersję**. Ręcznie: menu **CMCR Manager › Sprawdź uaktualnienia…**. Ustawienia: **Konfiguracja › Ustawienia › Uaktualnienia CMCR Manager** (sprawdzanie automatyczne — domyślnie włączone; pobieranie w tle — włączone; **Instaluj automatycznie** — domyślnie wyłączone, instaluje sprawdzone uaktualnienie przy zamykaniu aplikacji; wersje testowe).

Bez Twojej zgody nic nie jest instalowane (chyba że włączysz „Instaluj automatycznie”). Przed instalacją aplikacja sprawdza:

1. podpis cyfrowy **Ed25519** manifestu `cmcr-update.json` kluczem publicznym wbudowanym w aplikację (`Sources/CMCRCore/UpdateKeys.swift`) — przed odczytaniem czegokolwiek z manifestu; manifest wiąże wersję, tag, nazwę i rozmiar pliku oraz sumę SHA-256, więc starego wydania nie da się podsunąć jako nowego,
2. rozmiar i sumę **SHA-256** pobranego archiwum,
3. identyfikator, wersję, architekturę i **podpis kodu** rozpakowanej aplikacji.

Instalator działa po zamknięciu aplikacji: jeszcze raz sprawdza sumę, przygotowuje nową wersję obok starej, uruchamia ją testowo (`--cmcr-self-test`), zamienia pakiety atomowo i uruchamia aplikację ponownie. Jeśli nowa wersja nie wystartuje w ciągu 45 s albo zakończy działanie, zanim się w pełni uruchomi, **poprzednia wersja zostaje przywrócona** i aplikacja pokazuje powód (pytanie Pęku kluczy o zapisane hasło nie jest limitowane — instalator czeka na Twoją odpowiedź). Gdy aplikacja leży w folderze, do którego nie masz prawa zapisu (np. `/Applications` należący do administratora), macOS jednorazowo poprosi o hasło administratora. Aplikacji uruchomionej z obrazu DMG lub z Pobranych (App Translocation) nie da się uaktualnić — przenieś ją do folderu Aplikacje. Jeśli macOS zablokuje podmianę pakietu, aplikacja zgłosi to i dalej działa w starej wersji — wtedy włącz CMCR Manager w Ustawieniach systemowych › Prywatność i ochrona › **Zarządzanie aplikacjami** i spróbuj ponownie. Dziennik: `~/Library/Logs/CMCRManager/update.log`.

Z terminala: `cmcrctl app-update` (sprawdza), `cmcrctl app-update install [--relaunch]` (pobiera, weryfikuje i instaluje; aplikacja musi być zamknięta), opcje `--app ŚCIEŻKA`, `--beta`.

> Wersja 1.0.0 nie ma wbudowanych uaktualnień — wersję 1.1.0 trzeba zainstalować ręcznie (DMG z GitHuba; przy pierwszym uruchomieniu: Ustawienia systemowe › Prywatność i ochrona › „Otwórz mimo to”). Kolejne wersje instalują się już same.

## Publikowanie wersji (opiekun projektu)

Jednorazowo:

```bash
swift scripts/update-signing.swift keygen        # klucz prywatny → Pęk kluczy, wypisuje klucz PUBLICZNY
```

Wypisany klucz publiczny wpisz w `Sources/CMCRCore/UpdateKeys.swift` w miejsce `PLACEHOLDER_…` i zatwierdź. Dopóki jest tam PLACEHOLDER, aplikacja odrzuca każde uaktualnienie. **Zrób kopię zapasową klucza prywatnego** (`security find-generic-password -s pl.cmcr.manager.update-signing -a ed25519 -w | pbcopy` → menedżer haseł) — bez niego zainstalowane kopie nie przyjmą kolejnych wersji. Zamiast Pęku kluczy można użyć pliku: `keygen --file ~/.config/cmcr-manager/update-signing.key` (chmod 600; narzędzie odmawia zapisu klucza w repozytorium git i użycia pliku czytelnego dla innych). Nigdy nie dodawaj klucza do repozytorium — `.gitignore` blokuje `*.key`, `*.pem`, `*.p12`, `hosts.json`, `settings.json`.

Każde wydanie:

```bash
echo 1.2.0 > VERSION && git commit -am "Wersja 1.2.0" && git push
scripts/release.sh --dry-run                     # próba: buduje, pakuje i podpisuje w dist/1.2.0, nic nie publikuje
scripts/release.sh --notes-file zmiany.md        # tag v1.2.0 + wydanie na GitHubie (gh)
```

Opis zmian z `--notes-file` (po polsku, Markdown) trafia do podpisanego manifestu i to on jest pokazywany w aplikacji; bez niego aplikacja pokaże automatyczny, angielski opis wygenerowany przez GitHuba.

`release.sh` przerywa pracę, gdy: drzewo git nie jest czyste lub różni się od `origin/main`, wersja nie jest nowsza od ostatniego tagu, w śledzonych plikach jest coś, co wygląda na sekret (klucze prywatne, tokeny GitHuba, `hosts.json`, `settings.json`, `askpass.sh`, sam klucz podpisu; dodatkowo `gitleaks`, jeśli jest zainstalowany), klucz podpisu nie pasuje do `UpdateKeys.swift`, aplikacja nie przechodzi testu uruchomienia albo podpis kodu nie przetrwał spakowania. Domyślnie buduje wersję uniwersalną (Apple Silicon + Intel; `--arm64-only` tylko Apple Silicon). Pliki wydania: `CMCR-Manager-X.Y.Z.zip` (uaktualnienie), `cmcr-update.json` + `.sig` (podpisany manifest), `CMCR-Manager-X.Y.Z.dmg`, `cmcrctl-X.Y.Z-macos.zip`, `SHA256SUMS.txt`. W ustawieniach repozytorium warto włączyć *Immutable releases*.

### Podpis kodu i pytania Pęku kluczy

Bez konta Apple Developer aplikacja jest podpisywana ad-hoc. Taki podpis zmienia się przy każdej kompilacji, więc po każdym uaktualnieniu macOS zapyta jeszcze raz, czy CMCR Manager może użyć zapisanego hasła administratora („Zawsze pozwalaj”). Żeby tego uniknąć, utwórz raz stałą tożsamość podpisu (certyfikat samopodpisany, bez zmiany ustawień zaufania systemu):

```bash
scripts/make-signing-identity.sh --export ~/cmcr-podpis.p12    # kopia zapasowa poza repozytorium
```

`scripts/build-app.sh` i `release.sh` użyją jej automatycznie (albo wskaż ją zmienną `CMCR_SIGN_IDENTITY`). Wtedy wymaganie podpisu aplikacji brzmi `identifier "pl.cmcr.manager" and certificate root = H"…"` i jest takie samo dla każdej kompilacji: sprawdzone na osobnym pęku kluczy — kompilacja podpisana ad-hoc po przebudowaniu traci dostęp do zapisanego hasła, podpisana tym certyfikatem go zachowuje. Po przejściu z podpisu ad-hoc macOS zapyta jeszcze jeden raz. Wszystkie wydania podpisuj tym samym certyfikatem (na innym Macu zaimportuj kopię `.p12`). Gatekeeper nadal traktuje aplikację jak nienotaryzowaną — dotyczy to tylko pierwszej ręcznej instalacji, bo uaktualnienia pobierane przez aplikację nie dostają atrybutu kwarantanny.

Opcjonalne CI (`.github/workflows/ci.yml`) buduje projekt i uruchamia testy jednostkowe; nie ma dostępu do żadnych kluczy — wydania podpisuje się lokalnie.

## Struktura projektu

```
Sources/CMCRCore     – SSH/scp, skrypty zdalne, parsowanie, Pęk kluczy, Wake-on-LAN (wspólne)
Sources/CMCRManager  – aplikacja SwiftUI
Sources/cmcrctl      – narzędzie wiersza poleceń
scripts/             – budowanie pakietu .app i ikony, wydania (release.sh, update-signing.swift, make-signing-identity.sh)
```
