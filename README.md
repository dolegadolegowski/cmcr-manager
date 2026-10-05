# CMCR Manager

Natywna aplikacja okienkowa macOS (SwiftUI) do zdalnego zarządzania pracownią iMaców w sieci LAN przez ich konta administracyjne. Rozwija sposoby pracy z [cmcr-helpers](https://github.com/ws-qcnssp/cmcr-helpers): te same konta `imacNN@imacNN.local`, SSH z kluczem, folder ucznia `/Users/student/Public/cmcr` i lokalny `~/Public/cmcr`. Wszystko działa przez wbudowane w macOS `ssh`/`scp` — na iMacach nie trzeba niczego instalować.

## Co potrafi

| Dział | Funkcje |
|---|---|
| **Komputery** | Stan pracowni (online, zalogowany użytkownik, macOS, model, IP/MAC, czas pracy, dysk), odświeżanie co 2 min, sesja SSH w Terminalu (`cmcr-go`), Udostępnianie ekranu (VNC) |
| **Polecenia** | Skrypt bash na wielu iMacach naraz (`cmcr-exec`), opcjonalnie jako root, gotowe polecenia z README/notes.md, własne zapisane fragmenty |
| **Pliki** | Wysyłanie plików i folderów na iMaki – folder docelowy wybiera się w okienku jak w Finderze (ulubione: folder cmcr ucznia, Biurko, Dokumenty, Pobrane, `/Users/Shared`, Programy, Biurko zalogowanego użytkownika, katalog administratora; ostatnio używane; nowy folder), ścieżka działa na wszystkich zaznaczonych komputerach (`{student}`, `{console}`, `~`), a okienko sprawdza, na których z nich folder już jest; właściciel i uprawnienia dobierane automatycznie; **Zbierz prace** do `~/Public/cmcr/zebrane/<data godzina>/<host>` (nic nie jest nadpisywane, opcjonalnie z wyczyszczeniem u ucznia tylko tych plików, które zostały zebrane i od tej pory się nie zmieniły); konwencja `all` + `<host>` (`cmcr-push`/`cmcr-pull`); czyszczenie folderów |
| **Przeglądarka plików** | Przeglądanie jednego iMaca jak w Finderze (ikony, sortowanie, szukanie, ukryte pliki, tryb administratora): pobieranie zaznaczonych elementów, wysyłanie przeciągnięciem z Findera, nowy folder, zmiana nazwy, usuwanie z potwierdzeniem; kliknięcie innego komputera na liście pokazuje ten sam folder na nim |
| **Aplikacje** | Lista uruchomionych aplikacji zalogowanego użytkownika; uruchamianie (z argumentami), zamykanie i wymuszanie zamknięcia na jednym lub wszystkich iMacach; otwieranie URL/plików; lista zainstalowanych i odinstalowywanie |
| **Instalacja** | `.pkg`, `.dmg`, `.zip`, `.app` z tego Maca lub pobierane z URL (`https://`) bezpośrednio na iMacach, ze sprawdzeniem podpisu i notaryzacji Apple; Homebrew (formuły i `--cask`), instalacja Homebrew i Oracle JDK; Unity Hub headless (edytor + moduły) i Android SDK (`sdkmanager`) — wg notes.md |
| **Aktualizacje** | `softwareupdate` (lista, pobieranie, instalacja, restart; na Apple Silicon z `--user/--stdinpass`), historia, `brew upgrade`, `mas upgrade` |
| **Podgląd ekranów** | Ekrany zalogowanych uczniów na żywo, z nazwą użytkownika i aplikacją na pierwszym planie; układ dopasowany do okna lub stała liczba kolumn, powiększanie (spacja, strzałki); osobne okno **Ściana ekranów** (⇧⌘E, także na pełnym ekranie drugiego monitora) i okna pojedynczych komputerów; z kafelka: wiadomość, uśpienie ekranu, Udostępnianie ekranu (VNC) — tylko do odczytu, z ograniczeniami (niżej) |
| **Zajęcia** | „Rozpocznij zajęcia” i „Zakończ zajęcia” jednym kliknięciem (budzenie, materiały, aplikacje, powitanie / zbieranie prac, porządki, wylogowanie, uśpienie), tryb uwagi (blokada ekranów z komunikatem), pytania do uczniów z odpowiedziami |
| **Sesja i zasilanie** | Wiadomość (okno/powiadomienie, szablony), wylogowanie, uśpienie ekranu/komputera, restart i wyłączenie (także z opóźnieniem i ostrzeżeniem), Wake-on-LAN, harmonogram zasilania (`pmset repeat`) |
| **Zadania** | Operacje w toku i historia (także z poprzednich uruchomień) z wynikiem, kodem wyjścia, czasem i wyjściem każdego iMaca (do 300 kB, przy dłuższym – jego końcówka); „Powtórz na nieudanych”, „Zaznacz nieudane”, grupowanie identycznych wyników, eksport do pliku; dziennik działań w `~/Library/Logs/CMCRManager/actions.log`, historia w `<konfiguracja>/history/` (JSONL + wyjście każdego zadania, 90 dni) |
| **Konfiguracja** | Lista komputerów (generator jak pętla w `cmcr-helpers.sh`, import/eksport), hasła w Pęku kluczy (wspólne lub per komputer), generowanie i rozsyłanie klucza SSH, ustawienia, przygotowanie iMaców |

### Podgląd ekranu – ograniczenia

- wyłącznie zrzuty ekranu — bez przejmowania myszy i klawiatury (pełne sterowanie tylko świadomie przez „Udostępnianie ekranu”, jeśli jest włączone na iMacu),
- domyślnie **tylko konta standardowe** — sesje kont administratorów są blokowane po stronie iMaca,
- opcjonalna lista dozwolonych kont (np. `student`),
- użytkownik widzi przez kilka sekund komunikat „Administrator rozpoczął podgląd Twojego ekranu” w rogu ekranu (własne okienko, niezależne od ustawień powiadomień i trybu skupienia) — raz na sesję podglądu i ponownie, gdy przy komputerze zaloguje się ktoś inny; dopóki iMac nie potwierdzi, że komunikat jest na ekranie, obraz nie jest pobierany (podgląd pokazuje „Nie udało się powiadomić ucznia” i ponawia próbę),
- każdy komputer ma jedno stałe połączenie podglądu: najwyżej jedno `sudo` na sesję (żadnego, gdy przy ekranie jest zalogowane konto administracyjne), niezmienione ekrany nie są przesyłane ponownie, a podgląd zatrzymuje się, gdy okno jest ukryte,
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

1. W aplikacji (Konfiguracja › Przygotowanie iMaców) kliknij **Zapisz skrypt do pliku…** (albo `cmcrctl setup-script [opcje] > cmcr-imac-setup.sh`). Plik zawiera klucz publiczny aplikacji i wybrane opcje; jeden plik pasuje do wszystkich iMaców — konto administratora i nazwa są wykrywane na miejscu.
2. Skopiuj plik na iMaca, zaloguj się na konto administratora `imacNN`, otwórz Terminal i wpisz:

   ```bash
   sudo bash ~/Downloads/cmcr-imac-setup.sh --guided
   ```

   `--guided` przy krokach ręcznych otwiera właściwe panele Ustawień i czeka na Enter. Podgląd bez zmian: `bash cmcr-imac-setup.sh --dry-run` (lub `--verify`). Uruchomienie przez `bash` działa także dla plików z AirDrop i internetu (Gatekeeper ich nie blokuje).

### Co zostaje do zrobienia ręcznie przy każdym iMacu

macOS chroni te uprawnienia (baza TCC jest pod ochroną SIP) — nie da się ich nadać skryptem ani zdalnie, tylko przy komputerze albo profilem MDM:

1. **Pełny dostęp do dysku dla sesji zdalnych:** Ustawienia systemowe › Ogólne › Udostępnianie › ⓘ przy „Zdalne logowanie” › „Daj użytkownikom zdalnym pełny dostęp do dysku”. Potrzebny do pobierania prac z Biurka i Dokumentów ucznia, czyszczenia folderów oraz podmiany i usuwania aplikacji.
2. **Nagrywanie ekranu** dla podglądu: Ustawienia systemowe › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego › „+” › ⌘⇧G › `/usr/libexec/sshd-keygen-wrapper` › włącz. Bez tego podgląd pokazuje tylko tapetę. Jeśli mimo to widać tylko tapetę (nowsze macOS przypisują sesję SSH do `sshd-session`), dodaj tak samo `/usr/libexec/sshd-session`. macOS 26.1–26.2 może nie pokazywać dodanego narzędzia na liście — uprawnienie i tak działa. Od macOS 15 system co jakiś czas (zwykle raz w miesiącu, na niektórych Macach przy każdym nowym połączeniu) pyta osobę przy komputerze, czy „sshd-session” może dalej mieć dostęp do ekranu z pominięciem systemowego wyboru okien; okno widać też w podglądzie. Podgląd działa dalej po zezwoleniu (po angielsku „Allow For One Month”), po odmowie pokazuje tylko tapetę.
3. Jeśli połączenie VNC pokazuje czarny ekran: wyłącz i włącz „Udostępnianie ekranu” w Ustawieniach.
4. Z włączonym **FileVault** iMac po restarcie czeka na odblokowanie przy ekranie i do tego czasu jest niedostępny przez SSH. Restart z aplikacji (od razu, zaplanowany „za N min” i po aktualizacjach z restartem) uzbraja wcześniej jednorazowe odblokowanie (`fdesetup authrestart`), jeśli zapisane hasło należy do konta z dostępem do FileVault; raport zadania mówi, czy się udało. Uzbrojonego odblokowania nie da się cofnąć — po anulowaniu zaplanowanego restartu działa przy najbliższym restarcie.

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

1. **Konfiguracja › Komputery** — domyślnie lista `imac01…imac15` (`imacNN@imacNN.local`); popraw ją przyciskiem **Utwórz listę…** (generator) lub ręcznie w tabeli. Kolumnę **Port** (gdy iMac nie używa portu 22) pokazuje prawe kliknięcie nagłówka tabeli.
2. **Potwierdź klucze komputerów** — przy pierwszym połączeniu aplikacja pokazuje odcisk klucza SSH każdego iMaca (okno „Potwierdź klucze komputerów”, potem także **Konfiguracja › Przygotowanie iMaców › Szybkie naprawy › Sprawdź klucz komputera…**; z terminala `cmcrctl trust all`). Dopóki klucz nie jest zaufany, aplikacja w ogóle nie łączy się z tym komputerem — zob. [bezpieczeństwo](#jak-to-działa-i-bezpieczeństwo).
3. **Konfiguracja › Dostęp i hasła** — zapisz hasło kont administracyjnych (Pęk kluczy). Jeśli komputery mają różne hasła, ustaw „własne” przy danym komputerze.
4. Zaznacz wszystkie komputery i kliknij **Roześlij klucz** (odpowiednik sekcji „Distribute your SSH key” z README). Kolejne połączenia logują się kluczem.
5. **Konfiguracja › Przygotowanie iMaców** — sprawdź gotowość iMaców i kliknij **Skonfiguruj zaznaczone…** (folder ucznia `/Users/student/Public/cmcr`, klucz, Wake-on-LAN i inne — zob. wyżej).

Pola wyboru na liście komputerów (środkowa kolumna) wyznaczają cel operacji we wszystkich działach; zaznaczenie jest zapamiętywane. Kliknięcie wiersza tylko go podświetla (menu kontekstowe działa na podświetlone wiersze) i nie zmienia zaznaczenia — dwuklik, Return lub spacja zaznacza albo odznacza podświetlone komputery. Lista ma wyszukiwarkę, filtr stanu (online, niedostępne, z zalogowanym użytkownikiem, wymagające uwagi) i **grupy** (np. rzędy ławek — tworzone z menu kontekstowego lub w Konfiguracji › Komputery). Opcja „Pomiń niedostępne” pomija komputery, które przy ostatnim sprawdzeniu były wyłączone (offline) — także w trakcie ponownego sprawdzania — zamiast czekać na limit czasu — trafiają do wyników jako pominięte, a „Powtórz na nieudanych” próbuje na nich ponownie bez pomijania. Po Wake-on-LAN, zapisaniu hasła i rozesłaniu klucza stan komputerów jest sprawdzany ponownie automatycznie. Niebezpieczne operacje (restart, wylogowanie, czyszczenie folderu, odinstalowanie…) pokazują listę komputerów z zalogowanymi użytkownikami i pozwalają ich pominąć; ich powtórzenie („Powtórz na nieudanych”, „Powtórz…” w Zadaniach) wymaga ponownego potwierdzenia w tym samym oknie. Pliki można upuścić na komputer na liście. Gdy trwają zadania (także odliczanie przed końcem zajęć), Mac administratora nie usypia się, zamknięcie okna nie przerywa pracy, a zakończenie aplikacji wymaga potwierdzenia. Skróty: ⌘R odśwież stan, ⇧⌘A zaznacz wszystkie, ⇧⌘O zaznacz online, ⌘1…⌘0 działy.

## Odpowiedniki cmcr-helpers

| cmcr-helpers.sh | CMCR Manager | cmcrctl |
|---|---|---|
| `cmcr-exec "cmd" [nr]` | Polecenia | `cmcrctl exec "cmd" all\|nr [--root]` |
| `cmcr-go nr` | menu kontekstowe › Sesja SSH w Terminalu | `cmcrctl go nr` |
| `cmcr-push all\|nr` | Pliki › Konwencja cmcr-helpers | `cmcrctl push all\|nr [--root]` |
| `cmcr-pull all\|nr` | Pliki › Konwencja cmcr-helpers › Pobierz | `cmcrctl pull all\|nr [--root]` |
| — | Pliki › Zbierz prace uczniów | `cmcrctl collect all\|nr [--from folder] [--to katalog] [--clean]` |
| — | Przeglądarka plików, wybór folderu | `cmcrctl ls`, `exists`, `mkdir`, `rename`, `rm`, `get` |
| dystrybucja klucza (README) | Konfiguracja › Dostęp i hasła | — |
| Unity Hub / sdkmanager / Homebrew (notes.md) | Instalacja, Polecenia › Gotowe polecenia | `cmcrctl exec` |

`cmcrctl` (w `build/cmcrctl` i w pakiecie aplikacji: `Contents/Resources/bin/cmcrctl`) korzysta z tej samej konfiguracji i Pęku kluczy co aplikacja. Pełna lista poleceń: `cmcrctl --help`. Poza odpowiednikami z tabeli: `status [--json]`, `apps`, `open-app`, `quit-app`, `open-url`, `kill`, `uninstall`, `brew`, `screenshot`, `screen-watch` (podgląd na żywo do folderu z klatkami), `ls`, `clean`, `updates list|install|history`, `message`, `logout`, `power restart|shutdown|sleep|display-sleep`, `wake`, `hosts list|add|set|remove|generate`, `password set|clear|status`, `trust [KOMP] [--dry-run]` (odciski kluczy SSH komputerów i zaufanie nowym), `install plik… KOMP [--allow-unsigned]` (`.pkg`/`.dmg`/`.zip`/`.app`), `install-url https://… KOMP [--sha256 SUMA] [--allow-unsigned]`, `render` (pokazuje dokładnie skrypt wykonywany zdalnie), `setup-script`, `setup` i `readiness` (jednorazowa konfiguracja iMaców) i `selftest` (sprawdza składnię wszystkich skryptów zdalnych).

- Komputery wskazuje się numerem z nazwy (`4` → imac04), listą (`1,3,7`), zakresem (`1-5`), pozycją na liście (`@2`), nazwą lub `all`. Numer, którego nie ma na liście, jest błędem – polecenie nigdy nie trafi do innego Maca.
- Bez listy komputerów polecenia, które tylko odczytują (`status`, `readiness`, `filevault`, `app-version`, `schedule show`), sprawdzają wszystkie. Polecenia, które coś zmieniają (`exec`, `open-app`, `quit-app`, `lock`, `unlock`, `ask`, `lesson`, `schedule set|clear`, `power-later`, `power-cancel`, `install`, `install-url`), działają wtedy na wszystkich tylko w terminalu (i wypisują, na których); w skryptach trzeba podać listę, np. `all`. Dzięki temu argument zgubiony przez powłokę – np. niezacytowane `#3`, które w skrypcie jest komentarzem – kończy się błędem, a nie poleceniem dla całej pracowni. Zmiana nazw komputerów (`rename KOMP`) zawsze wymaga listy.
- `cmcrctl POLECENIE --help` (lub `-h`) pokazuje pomoc tego polecenia i niczego nie wykonuje.
- `-j N` obsługuje N komputerów naraz (polecenia z listą komputerów poza `wake`, `hosts remove`, `lesson`, `rename`, `setup`, `readiness` i `ask`, które pyta wszystkie komputery naraz); wyniki i tak są wypisywane w kolejności listy (`--prefix` dodaje `[imac04]` przed każdym wierszem). `status` i `updates list` działają równolegle domyślnie.
- Restart, wyłączenie, wylogowanie, czyszczenie folderu, deinstalacja, usuwanie komputerów z listy i zastępowanie listy pytają o potwierdzenie – tak samo `power-later`, zakończenie zajęć, które wylogowuje, wyłącza, czyści foldery lub zamyka aplikacje (`lesson end`), zmiana nazw komputerów, usuwanie plików (`rm`) i `collect --clean`; w skryptach (bez terminala) trzeba dodać `--yes`.
- `hosts add` i `hosts generate` odrzucają adresy, konta i prefiksy ze spacją, znakiem sterującym, „@”, „-” na początku albo znakiem powłoki (cudzysłowy, `` ` ``, `$`, `\`, `;`, `&`, `|`, `<`, `>`, nawiasy); takie wpisy z zaimportowanej listy są oznaczane w Konfiguracji › Komputery; adres MAC można podać także w zapisie `arp -a` (`0:1b:…`).
- Kody wyjścia (wszystkich poleceń): 0 – sukces, 1 – błąd na co najmniej jednym komputerze, 2 – błędne użycie (także opcja, której polecenie nie używa, np. `exec … --host 4` albo `lock --mesage …`, lub nadmiarowy argument – wtedy nic nie jest wykonywane); `exec` zwraca kod zdalnego polecenia, `screen-watch` – także 3–6 (opis w `cmcrctl screen-watch --help`).
- `rename nr ścieżka nowa-nazwa` zmienia nazwę pliku, `rename KOMP [--name …]` (lub `rename-computer`) – nazwę komputera; inna liczba argumentów albo ścieżka niezaczynająca się od `/`, `~` lub `{student}` jest błędem, więc pomyłka przy zmianie nazwy pliku nigdy nie zmieni nazw komputerów.
- W terminalu znaki sterujące w wynikach z iMaców (np. sekwencje ESC w nazwach plików utworzonych przez ucznia) są pokazywane jako `^[`, `^M`…, a znaki odwracające kierunek tekstu jako `<U+202E>`…, więc nie mogą zmienić tytułu okna, wyczyścić ekranu, nadpisać wierszy ani odwrócić kolejności znaków w nazwie (`plik<U+202E>txt.exe`); wynik przekierowany do pliku lub potoku pozostaje dosłowny.
- Uszkodzony `hosts.json` nie jest nigdy nadpisywany: polecenia zmieniające listę komputerów kończą się błędem ze wskazaniem miejsca problemu.
- Hasło: `cmcrctl password set` (czyta ze standardowego wejścia, bez echa) lub zmienna `CMCR_PASSWORD`.

```sh
cmcrctl status                                  # stan wszystkich komputerów
cmcrctl exec "df -h /" 1-8 -j 8 --prefix        # polecenie na imac01…imac08 naraz
cmcrctl updates install all --restart --yes     # aktualizacje macOS z restartem
cmcrctl message "Przerwa" "Za 5 minut koniec zajęć" all
```

## Zajęcia, tryb uwagi i zasilanie

- **Rozpocznij zajęcia** – budzi komputery (Wake-on-LAN) i czeka, aż odpowiedzą, wysyła materiały z wybranego folderu do folderu cmcr lub na Biurko ucznia, uruchamia aplikacje i wyświetla powitanie. Postęp każdego kroku widać osobno dla każdego iMaca.
- **Zakończ zajęcia** – uprzedza uczniów i odlicza czas, zamyka aplikacje, zbiera prace do nowego folderu `~/Public/cmcr/zebrane/<data_godzina> <klasa>/<komputer>`, czyści folder cmcr (tylko razem ze zbieraniem prac i tylko na komputerach, z których prace zebrano) i Pobrane (pomijane, gdy zbieranie prac się nie udało), wylogowuje, usypia lub wyłącza. Ustawienia obu scenariuszy zapisują się w `classroom.json`.
- **Tryb uwagi** – zakrywa ekrany uczniów komunikatem. Najpierw używa narzędzia LockScreen z Apple Remote Desktop wbudowanego w macOS (`…/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app`, argumenty `-session <ID sesji z ioreg> -msg <tekst>`); jeśli się nie uruchomi, pokazuje okno na pełnym ekranie rysowane przez `osascript` (JavaScript for Automation) w sesji ucznia. Okno ukrywa Dock i menu i wyłącza przełączanie aplikacji, gdy macOS pozwoli mu przejąć klawiaturę (od macOS 14 nie zawsze od razu — wtedy dopiero po kliknięciu w komunikat; raport zadania ostrzega o tym: `CMCR:LOCKWARN:inactive`), ale nie jest zabezpieczeniem. Apple nie dokumentuje LockScreen — sprawdź go na jednym iMacu przed lekcją. Automatyczne odblokowanie po ustawionym czasie chroni przed utratą połączenia.
- **Zapytaj uczniów** – pytanie pojawia się jednocześnie na wszystkich zaznaczonych komputerach w oknie na ekranie ucznia (pole tekstowe albo do 3 przycisków); odpowiedzi zbierają się w tabeli i można je wyeksportować do CSV.
- **Harmonogram zasilania** – `pmset repeat` (jedno budzenie/włączanie i jedno usypianie/wyłączanie w wybrane dni), włączanie po zaniku zasilania (`autorestart`) i Wake-on-LAN (`womp`). **Wake-on-LAN budzi tylko z uśpienia** — wyłączone komputery włączy wyłącznie harmonogram. Na Macach z FileVault po włączeniu pojawia się ekran odblokowania dysku; przed restartem aplikacja uzbraja jednorazowe odblokowanie (`fdesetup authrestart`), a gdy się nie da — ostrzega.
- **Wake-on-LAN** wysyła pakiety na 255.255.255.255 i na adres rozgłoszeniowy każdego interfejsu (porty 9 i 7, kilka razy), preferuje adres MAC karty Ethernet i czeka, aż komputer odpowie.
- **Komputery** – kafelki zaznaczają pasujące komputery, kolumny tabeli można ukrywać, przestawiać i sortować, panel szczegółów pokazuje notatki, IP/MAC, FileVault i harmonogram. Ostatni znany stan zostaje zapisany między uruchomieniami (`status-cache.json`). Raport CSV (UTF-8, średnik – otwiera się w Excelu), porównanie wersji aplikacji na wszystkich iMacach i zmiana nazw komputerów (ComputerName, LocalHostName, HostName) z aktualizacją adresów `.local` na liście.

| Zadanie | cmcrctl |
|---|---|
| scenariusz zajęć z aplikacji | `cmcrctl lesson start\|end KOMP [--no-wait]` |
| tryb uwagi | `cmcrctl lock KOMP [--message "…"] [--minutes N]`, `cmcrctl unlock KOMP` |
| pytanie do uczniów | `cmcrctl ask "pytanie" KOMP [--buttons "Tak,Nie"]` |
| harmonogram zasilania | `cmcrctl schedule show [KOMP]`, `cmcrctl schedule set\|clear KOMP [--on MTWRF@07:45] [--off MTWRF@16:30]` |
| restart/wyłączenie za N min | `cmcrctl power-later restart\|shutdown\|sleep N KOMP [--warn "…"]`, `cmcrctl power-cancel KOMP` |
| nazwy komputerów (z listy; `--name` tylko dla jednego komputera) | `cmcrctl rename-computer KOMP [--name "…"] [--dry-run] [--update-list]` (lub `rename KOMP …`) |
| wersja aplikacji, FileVault, raport | `cmcrctl app-version "Nazwa" [KOMP]`, `cmcrctl filevault [KOMP]`, `cmcrctl report plik.csv` |

## Jak to działa i bezpieczeństwo

- Każda operacja to skrypt bash przesyłany w linii poleceń `ssh` w base64 (brak problemów z cudzysłowami) i wykonywany na koncie administracyjnym.
- Hasło administratora jest trzymane w Pęku kluczy i przekazywane wyłącznie przez szyfrowany kanał SSH (pierwsza linia stdin) do pomocnika `SUDO_ASKPASS` w prywatnym katalogu tymczasowym (usuwanym po zakończeniu). Nigdy nie trafia do argumentów procesów. Wyjątek dotyczy Homebrew i `mas` (`with_askpass`): Homebrew czyści zmienne środowiska, więc na czas działania polecenia hasło leży w pliku 0600 w prywatnym katalogu tymczasowym administratora i jest usuwane zaraz po nim. Błędne hasło kosztuje tylko jedną nieudaną próbę sudo.
- Działania w sesji ucznia (uruchamianie aplikacji, wiadomości, zrzuty) wykonywane są przez `launchctl asuser` w sesji aktualnie zalogowanego użytkownika (z jego `HOME`). „Zamknij” i „Wyloguj” wysyłają standardowe polecenie „Zakończ” / „Wyloguj” (Apple Event) – uczeń może zapisać pracę. Według dokumentacji polecenie „Zakończ” nie wymaga zgody na automatyzację; nie zostało to jeszcze sprawdzone na iMacach w pracowni. Jeśli macOS odrzuci polecenie, zadanie pokaże kod błędu (np. -1743) zamiast czekać. „Wymuś zamknięcie” i „Wyloguj natychmiast” kończą bez pytania.
- Pliki są pakowane do jednego archiwum `tar` (zachowuje pakiety `.app`, dowiązania i uprawnienia), wysyłane `scp` do `/tmp` i rozpakowywane na miejscu.
- Usuwanie i zmiana nazw w Przeglądarce plików (i czyszczenie po „Zbierz prace”) działa tylko w folderach kont (`/Users/…`), w `/tmp` i na dyskach zewnętrznych – po rozwinięciu dowiązań; chronione są katalogi domowe, `Library`, ukryte pliki w katalogu domowym i standardowe foldery (Biurko, Dokumenty…). `cmcrctl rm --dry-run` pokazuje, co zostałoby usunięte.
- Operacje na plikach (wysyłanie, czyszczenie folderu, „Zbierz prace” z czyszczeniem, usuwanie i zmiana nazw w Przeglądarce, przygotowanie folderu ucznia — także w skrypcie konfiguracyjnym) nie przechodzą przez dowiązania symboliczne utworzone przez użytkowników – np. przez folder `~/Public/cmcr`, który uczeń zamienił na dowiązanie do plików innego konta. Takie zadanie kończy się odmową z nazwą dowiązania; dozwolone są tylko dowiązania systemowe – należące do roota i leżące w folderze, którego zwykły użytkownik nie może zmieniać (np. `/tmp` czy `/Volumes/Macintosh HD`). Kopia dowiązania systemowego (twarde dowiązanie) podstawiona w folderze ucznia też jest odrzucana. Skrypt wchodzi do folderu krok po kroku i po każdym kroku sprawdza, czy to wciąż ten sam folder, więc podmiana folderu w trakcie kończy się odmową; dalej pracuje już wewnątrz sprawdzonego folderu. Właściciel i uprawnienia wysyłanych plików są ustawiane na ich kopii przed przeniesieniem na miejsce – nigdy rekurencyjnie na tym, co już było w folderze ucznia.
- Instalacja (`.pkg`, `.dmg`, `.zip`, `.app`) najpierw sprawdza podpis i notaryzację Apple (Gatekeeper: `spctl --assess`; gdy Gatekeeper jest wyłączony – `pkgutil --check-signature` / `codesign --verify` z wymogiem certyfikatu wydanego przez Apple). Instalatory bez ważnego podpisu są odrzucane, chyba że w dziale Instalacja › Bezpieczeństwo włączysz „Zezwalaj na instalatory bez podpisu Apple” (`cmcrctl install … --allow-unsigned`) – tylko dla zaufanych, np. szkolnych, instalatorów. Pobieranie z adresu działa wyłącznie przez `https://` (także po przekierowaniach), a `cmcrctl install-url … --sha256 SUMA` dodatkowo porównuje sumę kontrolną pobranego pliku.
- Przeglądanie Biurka, Dokumentów i Pobranych ucznia wymaga na iMacu: Ustawienia systemowe › Ogólne › Udostępnianie › Zdalne logowanie (ⓘ) › „Zezwalaj zdalnym użytkownikom na pełny dostęp do dysku”.
- W skryptach dostępne są: `asroot`, `as_console_user`, `with_askpass`, `$CONSOLE_USER`, `$CONSOLE_UID`, `$CMCR_ADMIN_USER`, `$CMCR_TMP`.
- Konfiguracja: `~/Library/Application Support/CMCRManager/` (`hosts.json`, `settings.json`; katalog można zmienić zmienną `CMCR_CONFIG_DIR`).
- **Klucze komputerów:** każde połączenie (`ssh`, `scp`, podgląd ekranu) ściśle sprawdza klucz SSH iMaca (`StrictHostKeyChecking=yes`) z listą zaufanych kluczy aplikacji (`<konfiguracja>/known_hosts` oraz klucze zapisane wcześniej w `~/.ssh/known_hosts`; z `UserKnownHostsFile` w dodatkowych opcjach SSH — wskazane pliki). Nazwy `.local` (Bonjour) nie są uwierzytelniane — dowolne urządzenie w sieci może podać się za wyłączonego iMaca. Dlatego z komputerem o nieznanym lub zmienionym kluczu aplikacja zrywa połączenie jeszcze przed logowaniem: hasło administratora, polecenia ani pliki nie są wysyłane, a zbieranie prac niczego od niego nie przyjmuje. Nowy klucz trzeba potwierdzić — okno pokazuje jego odcisk (SHA256), który można porównać przy iMacu (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`), i zapisuje dokładnie pokazany klucz. Zmieniony klucz (reinstalacja lub wymiana iMaca — albo podszywanie się) jest wyraźnie oznaczony i nigdy nie jest zaznaczony do zaufania z góry. Sesja w Terminalu (`cmcr-go`) sama pyta o nieznany klucz, z jego odciskiem.
- Połączenia: kolejne operacje na tym samym iMacu korzystają z jednego współdzielonego połączenia SSH (OpenSSH ControlMaster, gniazda w prywatnym katalogu `/tmp/cmcr-<uid>`, zamykane po 2 min bezczynności; można to wyłączyć w ustawieniach). Na jednym komputerze działa naraz najwyżej 6 sesji, a błędy sprzed uruchomienia polecenia (chwilowe odrzucenie połączenia, budzący się komputer) są ponawiane automatycznie. Ponawiane jest tylko połączenie, w którym skrypt nie zgłosił jeszcze startu na iMacu, więc polecenie nigdy nie wykona się dwa razy. Polecenie, które przekroczyło limit czasu już po starcie na iMacu, nie oznacza komputera jako wyłączonego.
- Stan komputerów odświeża się w tle co 2 min, gdy okno aplikacji jest widoczne. Wyłączony iMac jest w pełni sprawdzany coraz rzadziej (najrzadziej co 10 min), a pomiędzy tym sprawdzane jest tylko, czy odpowiada jego port SSH — włączony komputer pojawia się więc w kolejnym odświeżeniu.
- Zadania są odporne na utratę połączenia (uśpienie Maca nauczyciela, zamknięcie aplikacji, zerwane Wi‑Fi): polecenie na iMacu kończy pracę i sprząta po sobie. **Anuluj** zatrzymuje polecenie także na iMacu (rejestr zadań w `/tmp/cmcr-jobs`, procesy roota przez sudo).
- Uszkodzony `hosts.json` lub `settings.json` nie jest po cichu zastępowany wartościami domyślnymi: oryginał zostaje obok jako `*.bak`, a aplikacja wyświetla ostrzeżenie.

## Uaktualnienia aplikacji

CMCR Manager sam sprawdza w [GitHub Releases](https://github.com/dolegadolegowski/cmcr-manager/releases), czy jest nowsza wersja: kilkanaście sekund po uruchomieniu i potem raz dziennie. Gdy jest, na dole paska bocznego pojawia się **„Dostępna nowa wersja X”** — kliknięcie pokazuje opis zmian i przyciski **Zainstaluj i uruchom ponownie**, **Przypomnij później** (24 h) oraz **Pomiń tę wersję**. Ręcznie: menu **CMCR Manager › Sprawdź uaktualnienia…**. Ustawienia: **Konfiguracja › Ustawienia › Uaktualnienia CMCR Manager** albo okno **CMCR Manager › Ustawienia…** (⌘,) › Uaktualnienia (sprawdzanie automatyczne — domyślnie włączone; pobieranie w tle — włączone; **Instaluj automatycznie** — domyślnie wyłączone, instaluje sprawdzone uaktualnienie przy zamykaniu aplikacji; wersje testowe).

Bez Twojej zgody nic nie jest instalowane (chyba że włączysz „Instaluj automatycznie”). Przed instalacją aplikacja sprawdza:

1. podpis cyfrowy **Ed25519** manifestu `cmcr-update.json` kluczem publicznym wbudowanym w aplikację (`Sources/CMCRCore/UpdateKeys.swift`) — przed odczytaniem czegokolwiek z manifestu; manifest wiąże wersję, tag, nazwę i rozmiar pliku oraz sumę SHA-256, więc starego wydania nie da się podsunąć jako nowego,
2. rozmiar i sumę **SHA-256** pobranego archiwum,
3. identyfikator, wersję, architekturę i **podpis kodu** rozpakowanej aplikacji.

Gdy na iMacach trwają zadania (albo odliczanie przed końcem zajęć), okno uaktualnienia pyta jeden raz, czy je przerwać — także gdy zadania zaczęły się w trakcie pobierania — i dopiero wtedy uruchamia instalator; aplikacja zamyka się bez drugiego pytania. Instalator działa po zamknięciu aplikacji: jeszcze raz sprawdza sumę, przygotowuje nową wersję obok starej, uruchamia ją testowo (`--cmcr-self-test`), zamienia pakiety atomowo i uruchamia aplikację ponownie. Jeśli nowa wersja nie wystartuje w ciągu 45 s albo zakończy działanie, zanim się w pełni uruchomi, **poprzednia wersja zostaje przywrócona** i aplikacja pokazuje powód (pytanie Pęku kluczy o zapisane hasło nie jest limitowane — instalator czeka na Twoją odpowiedź). Gdy aplikacja leży w folderze, do którego nie masz prawa zapisu (np. `/Applications` należący do administratora), macOS jednorazowo poprosi o hasło administratora. Aplikacji uruchomionej z obrazu DMG lub z Pobranych (App Translocation) nie da się uaktualnić — przenieś ją do folderu Aplikacje. Jeśli macOS zablokuje podmianę pakietu, aplikacja zgłosi to i dalej działa w starej wersji — wtedy włącz CMCR Manager w Ustawieniach systemowych › Prywatność i ochrona › **Zarządzanie aplikacjami** i spróbuj ponownie. Dziennik: `~/Library/Logs/CMCRManager/update.log`.

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
