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
| **Zadania** | Operacje w toku i historia (także z poprzednich uruchomień) z wynikiem, kodem wyjścia, czasem i wyjściem każdego iMaca (do 300 kB, przy dłuższym – jego końcówka); „Powtórz na nieudanych”, „Zaznacz nieudane”, grupowanie identycznych wyników, eksport do pliku; dziennik działań w `~/Library/Logs/CMCRManager/actions.log`, historia w `<konfiguracja>/history/` (JSONL + wyjście każdego zadania, 90 dni) |
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

`scripts/build-app.sh --dmg` dodatkowo tworzy `build/CMCR-Manager.dmg` do przeniesienia na inny Mac. Numer wersji pochodzi z pliku `VERSION`. Skrypt sam wybiera zgodne SDK, gdy zainstalowane są tylko Command Line Tools (najnowsze SDK może wymagać Xcode do makr SwiftUI). W trakcie pracy nad kodem: `swift run CMCRManager`.

## Pierwsze kroki

1. **Konfiguracja › Komputery** — domyślnie lista `imac01…imac15` (`imacNN@imacNN.local`); popraw ją generatorem lub ręcznie.
2. **Konfiguracja › Dostęp i hasła** — zapisz hasło kont administracyjnych (Pęk kluczy). Jeśli komputery mają różne hasła, ustaw „własne” przy danym komputerze.
3. Zaznacz wszystkie komputery i kliknij **Roześlij klucz** (odpowiednik sekcji „Distribute your SSH key” z README). Kolejne połączenia logują się kluczem.
4. **Konfiguracja › Przygotowanie iMaców** — sprawdź gotowość iMaców i kliknij **Skonfiguruj zaznaczone…** (folder ucznia `/Users/student/Public/cmcr`, klucz, Wake-on-LAN i inne — zob. wyżej).

Pola wyboru na liście komputerów (środkowa kolumna) wyznaczają cel operacji we wszystkich działach; zaznaczenie jest zapamiętywane. Kliknięcie wiersza tylko go podświetla (menu kontekstowe działa na podświetlone wiersze) i nie zmienia zaznaczenia — dwuklik, Return lub spacja zaznacza albo odznacza podświetlone komputery. Lista ma wyszukiwarkę, filtr stanu (online, niedostępne, z zalogowanym użytkownikiem, wymagające uwagi) i **grupy** (np. rzędy ławek — tworzone z menu kontekstowego lub w Konfiguracji › Komputery). Opcja „Pomiń niedostępne” pomija komputery, które przy ostatnim sprawdzeniu były wyłączone (offline) — także w trakcie ponownego sprawdzania — zamiast czekać na limit czasu — trafiają do wyników jako pominięte, a „Powtórz na nieudanych” próbuje na nich ponownie bez pomijania. Po Wake-on-LAN, zapisaniu hasła i rozesłaniu klucza stan komputerów jest sprawdzany ponownie automatycznie. Niebezpieczne operacje (restart, wylogowanie, czyszczenie folderu, odinstalowanie…) pokazują listę komputerów z zalogowanymi użytkownikami i pozwalają ich pominąć; ich powtórzenie („Powtórz na nieudanych”, „Powtórz…” w Zadaniach) wymaga ponownego potwierdzenia w tym samym oknie. Pliki można upuścić na komputer na liście. Gdy trwają zadania, Mac administratora nie usypia się, a zamknięcie okna nie przerywa pracy. Skróty: ⌘R odśwież stan, ⇧⌘A zaznacz wszystkie, ⇧⌘O zaznacz online, ⌘1…⌘0 działy.

## Odpowiedniki cmcr-helpers

| cmcr-helpers.sh | CMCR Manager | cmcrctl |
|---|---|---|
| `cmcr-exec "cmd" [nr]` | Polecenia | `cmcrctl exec "cmd" all\|nr [--root]` |
| `cmcr-go nr` | menu kontekstowe › Sesja SSH w Terminalu | `cmcrctl go nr` |
| `cmcr-push all\|nr` | Pliki › Konwencja cmcr-helpers | `cmcrctl push all\|nr [--root]` |
| `cmcr-pull all\|nr` | Pliki › Pobierz pliki | `cmcrctl pull all\|nr [--root]` |
| dystrybucja klucza (README) | Konfiguracja › Dostęp i hasła | — |
| Unity Hub / sdkmanager / Homebrew (notes.md) | Instalacja, Polecenia › Gotowe polecenia | `cmcrctl exec` |

`cmcrctl` (w `build/cmcrctl` i w pakiecie aplikacji: `Contents/Resources/bin/cmcrctl`) korzysta z tej samej konfiguracji i Pęku kluczy co aplikacja. Pełna lista poleceń: `cmcrctl --help`. Poza odpowiednikami z tabeli: `status [--json]`, `apps`, `open-app`, `quit-app`, `open-url`, `kill`, `uninstall`, `brew`, `screenshot`, `ls`, `clean`, `updates list|install|history`, `message`, `logout`, `power restart|shutdown|sleep|display-sleep`, `wake`, `hosts list|add|set|remove|generate`, `password set|clear|status`, `install plik… [all|nr]` (`.pkg`/`.dmg`/`.zip`/`.app`), `install-url URL [all|nr]`, `render` (pokazuje dokładnie skrypt wykonywany zdalnie), `setup-script`, `setup` i `readiness` (jednorazowa konfiguracja iMaców) i `selftest` (sprawdza składnię wszystkich skryptów zdalnych).

- Komputery wskazuje się numerem z nazwy (`4` → imac04), listą (`1,3,7`), zakresem (`1-5`), pozycją na liście (`@2`), nazwą lub `all`. Numer, którego nie ma na liście, jest błędem – polecenie nigdy nie trafi do innego Maca.
- Bez listy komputerów `status` sprawdza wszystkie. `exec`, `open-app` i `quit-app` działają wtedy na wszystkich tylko w terminalu (i wypisują, na których); w skryptach trzeba podać listę, np. `all`. Dzięki temu argument zgubiony przez powłokę – np. niezacytowane `#3`, które w skrypcie jest komentarzem – kończy się błędem, a nie poleceniem dla całej pracowni.
- `-j N` obsługuje N komputerów naraz (polecenia z listą komputerów poza `wake` i `hosts remove`); wyniki i tak są wypisywane w kolejności listy (`--prefix` dodaje `[imac04]` przed każdym wierszem). `status` i `updates list` działają równolegle domyślnie.
- Restart, wyłączenie, wylogowanie, czyszczenie folderu, deinstalacja, usuwanie komputerów z listy i zastępowanie listy pytają o potwierdzenie; w skryptach (bez terminala) trzeba dodać `--yes`.
- `hosts add` i `hosts generate` odrzucają adresy, konta i prefiksy ze spacją, znakiem sterującym, „@” lub „-” na początku; adres MAC można podać także w zapisie `arp -a` (`0:1b:…`).
- Kody wyjścia: 0 – sukces, 1 – błąd na co najmniej jednym komputerze, 2 – błędne użycie (także opcja, której polecenie nie używa, np. `exec … --host 4`, albo nadmiarowy argument – wtedy nic nie jest wykonywane); `exec` zwraca kod zdalnego polecenia.
- Uszkodzony `hosts.json` nie jest nigdy nadpisywany: polecenia zmieniające listę komputerów kończą się błędem ze wskazaniem miejsca problemu.
- Hasło: `cmcrctl password set` (czyta ze standardowego wejścia, bez echa) lub zmienna `CMCR_PASSWORD`.

```sh
cmcrctl status                                  # stan wszystkich komputerów
cmcrctl exec "df -h /" 1-8 -j 8 --prefix        # polecenie na imac01…imac08 naraz
cmcrctl updates install all --restart --yes     # aktualizacje macOS z restartem
cmcrctl message "Przerwa" "Za 5 minut koniec zajęć" all
```

## Jak to działa i bezpieczeństwo

- Każda operacja to skrypt bash przesyłany w linii poleceń `ssh` w base64 (brak problemów z cudzysłowami) i wykonywany na koncie administracyjnym.
- Hasło administratora jest trzymane w Pęku kluczy i przekazywane wyłącznie przez szyfrowany kanał SSH (pierwsza linia stdin) do pomocnika `SUDO_ASKPASS` w prywatnym katalogu tymczasowym (usuwanym po zakończeniu). Nigdy nie trafia do argumentów procesów. Wyjątek dotyczy Homebrew i `mas` (`with_askpass`): Homebrew czyści zmienne środowiska, więc na czas działania polecenia hasło leży w pliku 0600 w prywatnym katalogu tymczasowym administratora i jest usuwane zaraz po nim. Błędne hasło kosztuje tylko jedną nieudaną próbę sudo.
- Działania w sesji ucznia (uruchamianie aplikacji, wiadomości, zrzuty) wykonywane są przez `launchctl asuser` w sesji aktualnie zalogowanego użytkownika (z jego `HOME`). „Zamknij” i „Wyloguj” wysyłają standardowe polecenie „Zakończ” / „Wyloguj” (Apple Event) – uczeń może zapisać pracę. Według dokumentacji polecenie „Zakończ” nie wymaga zgody na automatyzację; nie zostało to jeszcze sprawdzone na iMacach w pracowni. Jeśli macOS odrzuci polecenie, zadanie pokaże kod błędu (np. -1743) zamiast czekać. „Wymuś zamknięcie” i „Wyloguj natychmiast” kończą bez pytania.
- Pliki są pakowane do jednego archiwum `tar` (zachowuje pakiety `.app`, dowiązania i uprawnienia), wysyłane `scp` do `/tmp` i rozpakowywane na miejscu.
- W skryptach dostępne są: `asroot`, `as_console_user`, `with_askpass`, `$CONSOLE_USER`, `$CONSOLE_UID`, `$CMCR_ADMIN_USER`, `$CMCR_TMP`.
- Konfiguracja: `~/Library/Application Support/CMCRManager/` (`hosts.json`, `settings.json`; katalog można zmienić zmienną `CMCR_CONFIG_DIR`).
- Połączenia: kolejne operacje na tym samym iMacu korzystają z jednego współdzielonego połączenia SSH (OpenSSH ControlMaster, gniazda w prywatnym katalogu `/tmp/cmcr-<uid>`, zamykane po 2 min bezczynności; można to wyłączyć w ustawieniach). Na jednym komputerze działa naraz najwyżej 6 sesji, a błędy sprzed uruchomienia polecenia (chwilowe odrzucenie połączenia, budzący się komputer) są ponawiane automatycznie. Ponawiane jest tylko połączenie, w którym skrypt nie zgłosił jeszcze startu na iMacu, więc polecenie nigdy nie wykona się dwa razy.
- Stan komputerów odświeża się w tle co 2 min, gdy okno aplikacji jest widoczne. Wyłączony iMac jest w pełni sprawdzany coraz rzadziej (najrzadziej co 10 min), a pomiędzy tym sprawdzane jest tylko, czy odpowiada jego port SSH — włączony komputer pojawia się więc w kolejnym odświeżeniu.
- Zadania są odporne na utratę połączenia (uśpienie Maca nauczyciela, zamknięcie aplikacji, zerwane Wi‑Fi): polecenie na iMacu kończy pracę i sprząta po sobie. **Anuluj** zatrzymuje polecenie także na iMacu (rejestr zadań w `/tmp/cmcr-jobs`, procesy roota przez sudo).
- Uszkodzony `hosts.json` lub `settings.json` nie jest po cichu zastępowany wartościami domyślnymi: oryginał zostaje obok jako `*.bak`, a aplikacja wyświetla ostrzeżenie.

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
scripts/             – budowanie pakietu .app i ikony, osadzanie skryptu konfiguracyjnego, wydania (release.sh, update-signing.swift, make-signing-identity.sh)
setup/               – jednorazowy skrypt konfiguracyjny iMaców (root)
```
