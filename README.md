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

**Każdy iMac:** jednorazowa konfiguracja skryptem — zob. [Konfiguracja iMaców (jednorazowo)](#konfiguracja-imaców-jednorazowo). Minimum, by aplikacja mogła się połączyć: Ustawienia systemowe › Ogólne › Udostępnianie › **Zdalne logowanie** włączone (albo skrypt uruchomiony lokalnie, który je włączy).

Przy pierwszym połączeniu macOS zapyta, czy CMCR Manager może korzystać z sieci lokalnej — zezwól.

## Konfiguracja iMaców (jednorazowo)

Skrypt [`setup/cmcr-imac-setup.sh`](setup/cmcr-imac-setup.sh) przygotowuje iMaca do pełnej współpracy z aplikacją. Uruchamia się go raz jako root — zdalnie z aplikacji albo lokalnie przy komputerze. Jest idempotentny (kolejne uruchomienia zmieniają tylko to, co trzeba), nie zadaje pytań, wypisuje raport po polsku i zapisuje znacznik `/Library/Application Support/CMCR/setup.json` (wersja skryptu, wynik, odciski kluczy — bez haseł) oraz dziennik `/Library/Logs/CMCR/cmcr-imac-setup.log`.

**Co robi domyślnie:**
- włącza **Zdalne logowanie** (SSH) i ogranicza je do administratorów,
- instaluje klucz SSH aplikacji na koncie administratora (`imacNN`) i poprawia uprawnienia `~/.ssh`,
- dodaje ustawienia sshd zamykające zawieszone połączenia (`/etc/ssh/sshd_config.d/050-cmcr-manager.conf`, sprawdzane `sshd -t`, przy błędzie przywracane),
- tworzy folder ucznia `/Users/student/Public/cmcr` (właściciel `student`, `777`, dziedziczone ACL dla ucznia i administratorów); jeśli uczeń jeszcze nigdy się nie zalogował i nie ma folderu domowego, skrypt pomija ten krok — zaloguj się raz na konto ucznia i uruchom go ponownie,
- włącza Wake-on-LAN (`pmset womp 1`),
- sprawdza zaporę („Blokuj wszystkie połączenia przychodzące” blokuje SSH), FileVault i uprawnienia prywatności sesji SSH.

**Opcjonalnie** (przełączniki w aplikacji lub opcje skryptu): Udostępnianie ekranu dla administratorów (`--enable-vnc`), nazwa komputera (`--hostname`; z aplikacji według adresu z listy, np. `imac07.local` → `imac07`, więc adres się nie zmienia; w zapisanym pliku — nazwa konta administratora), brak usypiania (`--no-sleep`), harmonogram włączania i wyłączania (`--power-schedule "MTWRF 07:30 17:00"`), Rosetta 2 (`--rosetta`), automatyczne aktualizacje (`--updates check|download|auto`), sudo bez hasła (`--sudo-nopasswd`, niezalecane), SSH wyłącznie z kluczem (`--ssh-key-only`). Pełna lista: `bash cmcr-imac-setup.sh --help`. Kody wyjścia: 0 — gotowe (mogą zostać kroki ręczne), 1 — nieudany krok, 2 — błędne opcje, 3 — brak uprawnień roota.

### Zdalnie z aplikacji (gdy SSH już działa)

1. **Konfiguracja › Dostęp i hasła** — zapisz hasło administratora (potrzebne do uruchomienia jako root).
2. **Konfiguracja › Przygotowanie iMaców** — tabela „Gotowość iMaców” pokazuje dla każdego iMaca: SSH i klucz, sudo, folder ucznia, Wake-on-LAN, Udostępnianie ekranu, Nagrywanie ekranu, Pełny dostęp do dysku, FileVault i wersję konfiguracji. Kliknięcie komórki pokazuje szczegóły i przycisk naprawy. Sprawdzenie niczego nie zmienia i nie wyświetla na iMacu żadnych okien zgody.
3. Zaznacz iMaki, kliknij **Skonfiguruj zaznaczone…**, wybierz opcje i potwierdź. Skrypt jest wysyłany przez SSH i uruchamiany jako root; raport każdego iMaca widać pod tabelą i w dziale Zadania. „Tylko sprawdź” pokazuje, co zostałoby zmienione.

Z terminala: `cmcrctl setup all --verify`, potem `cmcrctl setup all [opcje]`; stan pracowni: `cmcrctl readiness all`.

### Lokalnie przy iMacu (pendrive lub AirDrop — np. gdy SSH jeszcze nie działa)

1. W aplikacji kliknij **Zapisz skrypt konfiguracyjny…** (albo `cmcrctl setup-script [opcje] > cmcr-imac-setup.sh`). Plik zawiera klucz publiczny aplikacji i wybrane opcje; jeden plik pasuje do wszystkich iMaców — konto administratora i nazwa są wykrywane na miejscu.
2. Skopiuj plik na iMaca, zaloguj się na konto administratora `imacNN`, otwórz Terminal i wpisz:

   ```bash
   sudo bash ~/Downloads/cmcr-imac-setup.sh --guided
   ```

   `--guided` przy krokach ręcznych otwiera właściwe panele Ustawień i czeka na Enter. Podgląd bez zmian: `bash cmcr-imac-setup.sh --dry-run` (lub `--verify`). Uruchomienie przez `bash` działa także dla plików z AirDrop i internetu (Gatekeeper ich nie blokuje).

### Co zostaje do zrobienia ręcznie przy każdym iMacu

macOS chroni te uprawnienia (baza TCC jest pod ochroną SIP) — nie da się ich nadać skryptem ani zdalnie, tylko przy komputerze albo profilem MDM:

1. **Pełny dostęp do dysku dla sesji zdalnych:** Ustawienia systemowe › Ogólne › Udostępnianie › ⓘ przy „Zdalne logowanie” › „Daj użytkownikom zdalnym pełny dostęp do dysku”. Potrzebny do pobierania prac z Biurka i Dokumentów ucznia, czyszczenia folderów oraz podmiany i usuwania aplikacji.
2. **Nagrywanie ekranu** dla podglądu: Ustawienia systemowe › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego › „+” › ⌘⇧G › `/usr/libexec/sshd-keygen-wrapper` › włącz. Bez tego podgląd pokazuje tylko tapetę. macOS 26.1–26.2 może nie pokazywać dodanego narzędzia na liście — uprawnienie i tak działa.
3. Jeśli połączenie VNC pokazuje czarny ekran: wyłącz i włącz „Udostępnianie ekranu” w Ustawieniach.
4. Z włączonym **FileVault** iMac po restarcie czeka na odblokowanie przy ekranie i do tego czasu jest niedostępny przez SSH.

Tabela gotowości pokazuje, których iMaców dotyczą te kroki, a „Otwórz instrukcję” prowadzi przez nie krok po kroku.

Dla deweloperów: kopię skryptu wbudowaną w aplikację (`Sources/CMCRCore/SetupScriptTemplate.swift`) generuje `scripts/embed-setup.sh` — uruchom go po każdej zmianie `setup/cmcr-imac-setup.sh` (test jednostkowy pilnuje zgodności). Testy e2e (`Tests/e2e/suites/setup.sh`) uruchamiają skrypt zdalnie na atrapach poleceń systemowych, z plikami systemowymi przekierowanymi do katalogu testowego (`CMCR_SETUP_ROOT_PREFIX`).

## Budowanie i uruchomienie

```bash
scripts/build-app.sh
```

```bash
open "build/CMCR Manager.app"
```

`scripts/build-app.sh --dmg` dodatkowo tworzy `build/CMCR-Manager.dmg` do przeniesienia na inny Mac. Skrypt sam wybiera zgodne SDK, gdy zainstalowane są tylko Command Line Tools (najnowsze SDK może wymagać Xcode do makr SwiftUI). W trakcie pracy nad kodem: `swift run CMCRManager`.

## Pierwsze kroki

1. **Konfiguracja › Komputery** — domyślnie lista `imac01…imac15` (`imacNN@imacNN.local`); popraw ją generatorem lub ręcznie.
2. **Konfiguracja › Dostęp i hasła** — zapisz hasło kont administracyjnych (Pęk kluczy). Jeśli komputery mają różne hasła, ustaw „własne” przy danym komputerze.
3. Zaznacz wszystkie komputery i kliknij **Roześlij klucz** (odpowiednik sekcji „Distribute your SSH key” z README). Kolejne połączenia logują się kluczem.
4. **Konfiguracja › Przygotowanie iMaców** — sprawdź gotowość iMaców i kliknij **Skonfiguruj zaznaczone…** (folder ucznia `/Users/student/Public/cmcr`, klucz, Wake-on-LAN i inne — zob. wyżej).

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

`cmcrctl` (w `build/cmcrctl` i w pakiecie aplikacji: `Contents/Resources/bin/cmcrctl`) korzysta z tej samej konfiguracji i Pęku kluczy co aplikacja. Dodatkowo: `status`, `apps`, `screenshot`, `open-app`, `quit-app`, `render` (pokazuje dokładnie skrypt wykonywany zdalnie), `setup-script`, `setup` i `readiness` (jednorazowa konfiguracja iMaców). Hasło można też podać zmienną `CMCR_PASSWORD`.

## Jak to działa i bezpieczeństwo

- Każda operacja to skrypt bash przesyłany w linii poleceń `ssh` w base64 (brak problemów z cudzysłowami) i wykonywany na koncie administracyjnym.
- Hasło administratora jest trzymane w Pęku kluczy i przekazywane wyłącznie przez szyfrowany kanał SSH (pierwsza linia stdin) do pomocnika `SUDO_ASKPASS` w prywatnym katalogu tymczasowym (usuwanym po zakończeniu). Nigdy nie trafia do argumentów procesów ani na dysk iMaca. Błędne hasło kosztuje tylko jedną nieudaną próbę sudo.
- Działania w sesji ucznia (uruchamianie aplikacji, wiadomości, zrzuty) wykonywane są przez `launchctl asuser` w sesji aktualnie zalogowanego użytkownika.
- Pliki są pakowane do jednego archiwum `tar` (zachowuje pakiety `.app`, dowiązania i uprawnienia), wysyłane `scp` do `/tmp` i rozpakowywane na miejscu.
- W skryptach dostępne są: `asroot`, `as_console_user`, `with_askpass`, `$CONSOLE_USER`, `$CONSOLE_UID`, `$CMCR_ADMIN_USER`, `$CMCR_TMP`.
- Konfiguracja: `~/Library/Application Support/CMCRManager/` (`hosts.json`, `settings.json`; katalog można zmienić zmienną `CMCR_CONFIG_DIR`).

## Struktura projektu

```
Sources/CMCRCore     – SSH/scp, skrypty zdalne, parsowanie, Pęk kluczy, Wake-on-LAN (wspólne)
Sources/CMCRManager  – aplikacja SwiftUI
Sources/cmcrctl      – narzędzie wiersza poleceń
scripts/             – budowanie pakietu .app i ikony, osadzanie skryptu konfiguracyjnego
setup/               – jednorazowy skrypt konfiguracyjny iMaców (root)
```
