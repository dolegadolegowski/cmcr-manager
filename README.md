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
| **Zajęcia** | „Rozpocznij zajęcia” i „Zakończ zajęcia” jednym kliknięciem (budzenie, materiały, aplikacje, powitanie / zbieranie prac, porządki, wylogowanie, uśpienie), tryb uwagi (blokada ekranów z komunikatem), pytania do uczniów z odpowiedziami |
| **Sesja i zasilanie** | Wiadomość (okno/powiadomienie, szablony), wylogowanie, uśpienie ekranu/komputera, restart i wyłączenie (także z opóźnieniem i ostrzeżeniem), Wake-on-LAN, harmonogram zasilania (`pmset repeat`) |
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

`scripts/build-app.sh --dmg` dodatkowo tworzy `build/CMCR-Manager.dmg` do przeniesienia na inny Mac. Skrypt sam wybiera zgodne SDK, gdy zainstalowane są tylko Command Line Tools (najnowsze SDK może wymagać Xcode do makr SwiftUI). W trakcie pracy nad kodem: `swift run CMCRManager`.

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

## Zajęcia, tryb uwagi i zasilanie

- **Rozpocznij zajęcia** – budzi komputery (Wake-on-LAN) i czeka, aż odpowiedzą, wysyła materiały z wybranego folderu do folderu cmcr lub na Biurko ucznia, uruchamia aplikacje i wyświetla powitanie. Postęp każdego kroku widać osobno dla każdego iMaca.
- **Zakończ zajęcia** – uprzedza uczniów i odlicza czas, zamyka aplikacje, zbiera prace do nowego folderu `~/Public/cmcr/zebrane/<data_godzina> <klasa>/<komputer>`, czyści folder cmcr (tylko razem ze zbieraniem prac i tylko na komputerach, z których prace zebrano) i Pobrane (pomijane, gdy zbieranie prac się nie udało), wylogowuje, usypia lub wyłącza. Ustawienia obu scenariuszy zapisują się w `classroom.json`.
- **Tryb uwagi** – zakrywa ekrany uczniów komunikatem. Najpierw używa narzędzia LockScreen z Apple Remote Desktop wbudowanego w macOS (`…/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app`, argumenty `-session <ID sesji z ioreg> -msg <tekst>`); jeśli się nie uruchomi, pokazuje okno na pełnym ekranie rysowane przez `osascript` (JavaScript for Automation) w sesji ucznia. Okno ukrywa Dock i menu i wyłącza przełączanie aplikacji, ale nie jest zabezpieczeniem. Apple nie dokumentuje LockScreen — sprawdź go na jednym iMacu przed lekcją. Automatyczne odblokowanie po ustawionym czasie chroni przed utratą połączenia.
- **Zapytaj uczniów** – pytanie pojawia się jednocześnie na wszystkich zaznaczonych komputerach w oknie na ekranie ucznia (pole tekstowe albo do 3 przycisków); odpowiedzi zbierają się w tabeli i można je wyeksportować do CSV.
- **Harmonogram zasilania** – `pmset repeat` (jedno budzenie/włączanie i jedno usypianie/wyłączanie w wybrane dni), włączanie po zaniku zasilania (`autorestart`) i Wake-on-LAN (`womp`). **Wake-on-LAN budzi tylko z uśpienia** — wyłączone komputery włączy wyłącznie harmonogram. Na Macach z FileVault po restarcie lub włączeniu pojawia się ekran odblokowania dysku; aplikacja ostrzega o tym przed restartem.
- **Wake-on-LAN** wysyła pakiety na 255.255.255.255 i na adres rozgłoszeniowy każdego interfejsu (porty 9 i 7, kilka razy), preferuje adres MAC karty Ethernet i czeka, aż komputer odpowie.
- **Komputery** – kafelki zaznaczają pasujące komputery, kolumny tabeli można ukrywać, przestawiać i sortować, panel szczegółów pokazuje notatki, IP/MAC, FileVault i harmonogram. Ostatni znany stan zostaje zapisany między uruchomieniami (`status-cache.json`). Raport CSV (UTF-8, średnik – otwiera się w Excelu), porównanie wersji aplikacji na wszystkich iMacach i zmiana nazw komputerów (ComputerName, LocalHostName, HostName) z aktualizacją adresów `.local` na liście.

| Zadanie | cmcrctl |
|---|---|
| scenariusz zajęć z aplikacji | `cmcrctl lesson start\|end [all\|nr] [--no-wait]` |
| tryb uwagi | `cmcrctl lock [all\|nr] [--message "…"] [--minutes N]`, `cmcrctl unlock` |
| pytanie do uczniów | `cmcrctl ask "pytanie" [all\|nr] [--buttons "Tak,Nie"]` |
| harmonogram zasilania | `cmcrctl schedule show\|set\|clear [all\|nr] [--on MTWRF@07:45] [--off MTWRF@16:30]` |
| restart/wyłączenie za N min | `cmcrctl power-later restart\|shutdown\|sleep N [all\|nr] [--warn "…"]`, `cmcrctl power-cancel` |
| nazwy komputerów (z listy; `--name` tylko dla jednego komputera) | `cmcrctl rename [all\|nr] [--name "…"] [--dry-run] [--update-list]` |
| wersja aplikacji, FileVault, raport | `cmcrctl app-version "Nazwa"`, `cmcrctl filevault`, `cmcrctl report plik.csv` |

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
scripts/             – budowanie pakietu .app i ikony
```
