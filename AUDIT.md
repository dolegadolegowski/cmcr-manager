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
| P1 | 32 | 32 | 0 | 0 | 0 |
| P2 | 246 | 242 | 4 | 0 | 0 |
| **Razem** | **289** | **285** | **4** | **0** | **0** |

P0 – awaria, utrata danych lub bezpieczeństwo; P1 – funkcja opisana w README nie działa; P2 – UX, drobne, teksty. Plik i linia wskazują stan sprzed poprawki (gałąź `main` @ `c7d00ec`). Szczegóły każdej pozycji są niżej, w sekcji „Szczegóły”.

## Jak powstała lista

Etap 1 przeprowadziło równolegle 11 agentów analizy, każdy dla jednego obszaru: działy z paska bocznego (Pracownia, Pliki i programy, Administracja), `cmcrctl`, współbieżność i cykl życia okien, polskie teksty oraz interfejs względem Apple HIG. Każdy prześledził funkcje z README ścieżką widok → model → CMCRCore → skrypt bash. Zgłoszenia każdego obszaru sprawdził potem niezależny, sceptyczny recenzent: potwierdził je w kodzie (często uruchamiając fragmenty skryptów lub `cmcrctl` w izolowanej konfiguracji), odrzucił albo zmienił priorytet. Usterki, które recenzenci zauważyli przy okazji, są oznaczone jako „zgłoszone przy weryfikacji” i sprawdzam je przy naprawie. Powtarzające się zgłoszenia różnych agentów są scalone w jedną pozycję („także: …”). Na koniec krytyk kompletności przeczytał README i listę prześledzonych funkcji i wskazał 4 słabo pokryte tematy; ich dodatkowe przeszukanie dało pozycje z obszaru „Dodatkowe przeszukanie” (DOD). Kilka pozycji dodałem sam (obszar „Własne”) po przejrzeniu zrzutów i opisu menu.

## Przegląd poprawek (pozycje REV-xx)

Poprawki z etapu 2 przeszły kolejne rundy niezależnego przeglądu, aż runda nie znalazła nowych usterek w kodzie. W każdej rundzie recenzenci, każdy dla jednego obszaru, czytali zmiany na gałęzi. Każde zgłoszenie sprawdzali potem sceptycy, którzy próbowali je obalić w kodzie, często z własnym buildem i testem e2e w osobnym worktree. Potwierdzone zgłoszenia mają numery REV-xx i obszar „Przegląd poprawek”. Ich plik i linia wskazują stan gałęzi w chwili przeglądu, a nie `main`.

- Runda 1 (po scaleniu poprawek etapu 2): 36 zgłoszeń, 35 potwierdzonych → REV-01…REV-34. Jedno zgłoszenie dołączono do istniejącej pozycji.
- Runda 2 (po poprawkach rundy 1): 10 potwierdzonych → REV-35…REV-42. Jedno zgłoszenie powtarzało REV-08, a jedno dotyczyło DOD-07, która czeka na decyzję właściciela.
- Runda 3 (po poprawkach rundy 2, z poprawkami symboli i opisem przeglądu interfejsu): 16 zgłoszeń, wszystkie P2.
  - 13 potwierdzili obaj sceptycy. W 3 sceptycy się podzielili; po sprawdzeniu w kodzie przyjęto je jako usterki.
  - 10 dotyczyło kodu i README → REV-44…REV-52 i UI-29.
  - 6 dotyczyło nieprawdziwych zdań w opisie przeglądu interfejsu (`docs/ui-review/README.md`), poprawionych przed zatwierdzeniem tego pliku. Dwa z nich ujawniły też usterki w kodzie (UI-30, UI-31).
- Runda 4 (po poprawkach rundy 3): 10 zgłoszeń, wszystkie P2; 9 potwierdzili obaj sceptycy, 1 sporne przyjęto. 6 dotyczyło kodu → REV-53…REV-58, 4 – opisu przeglądu interfejsu.
- Runda 5 (po poprawkach rundy 4): 8 zgłoszeń. Jedno P1 → REV-60: znacznik końca sesji z REV-53 pozwalał uznać ucięty wynik za sukces. Trzy dotyczyły zmiany nazw → REV-61…REV-63. Cztery dotyczyły opisu przeglądu interfejsu; jedno z nich ujawniło też usterkę w kodzie (UI-32).
- Runda 6 (po poprawkach rundy 5): 5 zgłoszeń. Jedno sceptycy odrzucili, 4 potwierdzili (P2) → REV-64…REV-66, UI-33.
- Runda 7 (po poprawkach rundy 6): 7 zgłoszeń, wszystkie P2. Dwa sceptycy odrzucili (zachowanie zgodne z README i testami; brak przegenerowanego AUDIT.md, co zrobiono przy zatwierdzaniu). 5 przyjęto → REV-67…REV-70, UI-34. Wątek naprawczy zgłosił przy okazji REV-71.
- Runda 8 (po poprawkach rundy 7): 6 zgłoszeń, wszystkie P2. Jedno odrzucone (AUDIT.md nieprzegenerowany w chwili przeglądu), 5 przyjętych → REV-72…REV-75 i jedno zdanie w opisie przeglądu interfejsu.
- Runda 9 (po poprawkach rundy 8; zakres: regresje z rundy 8 i usterki P0/P1 w całej gałęzi): 1 zgłoszenie, odrzucone przez obu sceptyków (REV-76, w tabeli odrzuconych). Brak nowych usterek – przegląd zakończony.
- REV-59: niestabilny test (wyścig o stan globalny), który ujawnił się po scaleniu rundy 4.
- REV-77: test z za ciasnym limitem czasu, który nie przeszedł na runnerze CI pull requesta.
- REV-43: błąd w testach e2e (kolejność grup), zgłoszony przez wątek naprawczy rundy 2.
- UI-26…UI-28 dopisano przy budowaniu słownika symboli i porównywaniu zrzutów „po”.

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
| [KON-06](#kon-06) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:915` | Ustawienie „Powiadamiaj o podglądzie” wyłącza komunikat dla ucznia, który README opisuje jako stały | naprawione (fdd24ba) |
| [PLI-02](#pli-02) | Pliki, przeglądarka | `Sources/CMCRCore/Operations.swift:17` | Archiwum wysyłanych plików w /tmp jest czytelne dla wszystkich (0644) i zostaje po przerwaniu | naprawione (32503a4) |
| [PLI-03](#pli-03) | Pliki, przeglądarka | `Sources/CMCRManager/AppModel.swift:740` | Konwencja cmcr-push oraz cmcrctl push/pull nie rozwijają {student} w folderze ucznia z ustawień | naprawione (797c6cb) |
| [PLI-12](#pli-12) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:81` | Usuwanie i pobieranie obejmuje zaznaczone elementy ukryte filtrem lub wyszukiwaniem | naprawione (3878c61) |
| [PLI-23](#pli-23) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserView.swift:66` | Kliknięcie innego komputera na liście nie przełącza Przeglądarki plików | naprawione (7924cac) |
| [PRZ-03](#prz-03) | Przygotowanie iMaców, uaktualnienia | `Sources/cmcrctl/SetupCommands.swift:47` | cmcrctl setup/readiness/setup-script po cichu pomijają nadmiarowe argumenty – konfiguracja może trafić na inny komputer | naprawione (f07b2af) |
| [PRZ-04](#prz-04) | Przygotowanie iMaców, uaktualnienia | `setup/cmcr-imac-setup.sh:546` | --ssh-key-only wyłącza logowanie hasłem, choć klucz aplikacji nie został zainstalowany (utrata dostępu) | naprawione (4382653) |
| [PRZ-17](#prz-17) | Przygotowanie iMaców, uaktualnienia | `Sources/cmcrctl/SetupCommands.swift:42` | cmcrctl setup-script po cichu ignoruje --verify/--dry-run – plik „do sprawdzenia” wprowadza zmiany jako root (zgłoszone przy weryfikacji) | naprawione (f07b2af) |
| [REV-11](#rev-11) | Przegląd poprawek | `Sources/CMCRManager/AppModel.swift:746` | Poprawka KOM-04 czyści zalogowanego ucznia na osiągalnych Macach: „Pomiń komputery z zalogowanym uczniem” już ich nie chroni | naprawione (0807d34) |
| [REV-18](#rev-18) | Przegląd poprawek | `Sources/CMCRManager/ClassroomModel.swift:608` | rename ponownie używa indeksu tablicy po zmianie, która może podmienić listę komputerów (scalanie z KON-04) | naprawione (13bd0ff) |
| [REV-32](#rev-32) | Przegląd poprawek | `Sources/cmcrctl/TrustCommand.swift:16` | Po poprawce CLI-02 `trust` z --yes nadal bez pytania rozszerza się na całą pracownię | naprawione (fbac161) |
| [REV-60](#rev-60) | Przegląd poprawek | `Sources/CMCRCore/SSH.swift:537` | Znacznik końca sesji wyprzedza stdout: sesja zerwana, gdy wynik jeszcze napływa, liczy się jako sukces z uciętym wynikiem | naprawione (ab4d7d2) |
| [UI-02](#ui-02) | Interfejs | `Sources/CMCRManager/DashboardView.swift:234` | Menu kontekstowe tabeli działu Komputery działa na jednym, przypadkowym komputerze | naprawione (fe7f85a) |
| [UI-03](#ui-03) | Interfejs | `Sources/CMCRManager/PowerView.swift:99` | „Wyloguj” wylogowuje wszystkie zaznaczone komputery bez arkusza potwierdzenia | naprawione (a1788d6) |
| [UI-04](#ui-04) | Interfejs | `Sources/CMCRManager/RemoteBrowserView.swift:376` | Potwierdzenie usunięcia/zastąpienia w Przeglądarce plików wymienia zaznaczone komputery zamiast przeglądanego | naprawione (fe7f85a) |
| [WSP-02](#wsp-02) | Współbieżność | `Sources/CMCRManager/ClassroomModel.swift:332` | „Przerwij” na partii ostrzeżenia nie przerywa „Zakończ zajęcia” | naprawione (b4be562) |
| [ZAD-01](#zad-01) | Zadania, polecenia | `Sources/CMCRManager/AppModel+Jobs.swift:136` | „Powtórz na nieudanych” używa starej kopii komputera (wspólne hasło, adres, port, usunięte iMaki) | naprawione (e55f3c2) |
| [ZAD-02](#zad-02) | Zadania, polecenia | `Sources/CMCRManager/AppModel+Jobs.swift:508` | „Przerwij zadania i zakończ” nie czeka na zatrzymanie na iMacach ani na zapis historii | naprawione (f4013cd) |
| [ZAJ-03](#zaj-03) | Zajęcia, podgląd | `Sources/CMCRCore/LessonRoutine.swift:237` | Niewysłane materiały raportowane jako „pominięto”, a zajęcia jako „Gotowe” | naprawione (df746f0) |
| [ZAJ-04](#zaj-04) | Zajęcia, podgląd | `Sources/CMCRCore/ScreenCapture.swift:383` | Ponowne zalogowanie na to samo konto nie wyświetla komunikatu o podglądzie | naprawione (fdd24ba) |
| [ZAJ-05](#zaj-05) | Zajęcia, podgląd | `Sources/CMCRCore/ScreenCapture.swift:623` | Komunikat o podglądzie uznany za wyświetlony przy zablokowanym/uśpionym ekranie | naprawione (fdd24ba) |

## P2 – UX i drobne

| ID | Obszar | Plik:linia | Usterka | Status |
|---|---|---|---|---|
| [APL-05](#apl-05) | Aplikacje, instalacja, aktualizacje | `README.md:170` | README: instalacja „wyłącznie przez https://”, a kod przyjmuje też file:// | naprawione (077b036) |
| [APL-06](#apl-06) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:278` | Zabijanie po PID jako root bez sprawdzenia, czyj to proces | naprawione (896bd79) |
| [APL-07](#apl-07) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:297` | Odinstalowanie zabija aplikację wszystkim użytkownikom, zanim sprawdzi, czy da się ją usunąć (Safari zawsze, inne bez Pełnego dostępu do dysku) | naprawione (91c88ac) |
| [APL-08](#apl-08) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:415` | Po „Anuluj” w trakcie instalacji z .dmg obraz zostaje zamontowany | naprawione (983d4ae) |
| [APL-09](#apl-09) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:564` | „Zainstaluj Homebrew” kończy się sukcesem, gdy pobranie instalatora się nie uda | naprawione (4b85810) |
| [APL-10](#apl-10) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRCore/Scripts.swift:638` | Instalacja aktualizacji ukrywa błąd softwareupdate --list i zgłasza „Brak aktualizacji” | naprawione (e1c5ab0) |
| [APL-12](#apl-12) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/InstallView.swift:96` | Adres instalatora i „Otwórz” nie są przycinane – spacja na początku daje błąd „tylko https://” | naprawione (d4754f9) |
| [APL-13](#apl-13) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/InstallView.swift:111` | Homebrew: przecinki w nazwach pakietów (jak w podpowiedzi) psują polecenie | naprawione (d4754f9) |
| [APL-14](#apl-14) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/InstallView.swift:185` | „Pokaż zainstalowane” (Unity) wypisuje też wszystkie dostępne wydania | naprawione (d4754f9) |
| [APL-15](#apl-15) | Aplikacje, instalacja, aktualizacje | `Sources/CMCRManager/UpdatesView.swift:131` | Po instalacji aktualizacji lista i plakietka nadal pokazują je jako dostępne | naprawione (d4754f9) |
| [APL-16](#apl-16) | Aplikacje, instalacja, aktualizacje | `Sources/cmcrctl/CLI.swift:452` | cmcrctl quit-app --force zabija aplikacje bez potwierdzenia (GUI pyta) | naprawione (c068ca5) |
| [APL-17](#apl-17) | Aplikacje, instalacja, aktualizacje | `Sources/cmcrctl/CLI.swift:540` | cmcrctl updates install nie pozwala na nową wersję macOS, a komunikat odsyła do przełącznika GUI | naprawione (a326b29) |
| [CLI-03](#cli-03) | cmcrctl | `Sources/cmcrctl/CLI.swift:119` | --help poleceń podstawowych pokazuje całą pomoc zamiast pomocy polecenia | naprawione (40c5b86) |
| [CLI-04](#cli-04) | cmcrctl | `Sources/cmcrctl/CLI.swift:474` | kill PID przyjmuje wiele komputerów – zabija przypadkowe procesy jako root | naprawione (6a3009a) |
| [CLI-05](#cli-05) | cmcrctl | `Sources/cmcrctl/CLI.swift:576` | cmcrctl logout zawsze wylogowuje natychmiast (bootout) | naprawione (efa60f7) |
| [CLI-06](#cli-06) | cmcrctl | `Sources/cmcrctl/ClassroomCommands.swift:196` | report używa ConfigStore.loadHosts() – inna lista i brak ostrzeżenia | naprawione (eba9ddb) |
| [CLI-07](#cli-07) | cmcrctl | `Sources/cmcrctl/ClassroomCommands.swift:206` | schedule set i ask nie biorą ustawień z classroom.json | naprawione (72c5a4d) |
| [CLI-08](#cli-08) | cmcrctl | `Sources/cmcrctl/ConfigCommands.swift:54` | Nieudany zapis hosts.json zgłaszany jako sukces (kod 0) | naprawione (b5d9416) |
| [CLI-09](#cli-09) | cmcrctl | `Sources/cmcrctl/ConfigCommands.swift:106` | hosts generate przyjmuje przecinek w prefiksie (hosts add go odrzuca) | naprawione (5b05936) |
| [CLI-10](#cli-10) | cmcrctl | `Sources/cmcrctl/ConfigCommands.swift:122` | hosts generate --replace nadpisuje uszkodzony hosts.json bez kopii .bak | naprawione (bff98d9) |
| [CLI-11](#cli-11) | cmcrctl | `Sources/cmcrctl/ScreenWatch.swift:24` | screen-watch: ukryta --notified-user pomija komunikat dla ucznia; brak wpisu w dzienniku | naprawione (90382b2) |
| [CLI-12](#cli-12) | cmcrctl | `Sources/cmcrctl/SelfUpdateCommand.swift:102` | app-update --beta podpowiada instalację bez --beta | naprawione (a3475a0) |
| [CLI-13](#cli-13) | cmcrctl | `Sources/cmcrctl/TrustCommand.swift:15` | trust odrzuca -j/--prefix, a nie ma go na liście wyjątków | naprawione (aeb43ea) |
| [CLI-14](#cli-14) | cmcrctl | `Sources/cmcrctl/TrustCommand.swift:65` | trust: zmieniony klucz zatwierdzany razem z nowymi (jedno pytanie/--yes) | naprawione (c0eb904) |
| [CLI-15](#cli-15) | cmcrctl | `Sources/cmcrctl/main.swift:22` | Polecenia modułów nie ostrzegają o uszkodzonym settings.json | naprawione (3515af9) |
| [CLI-16](#cli-16) | cmcrctl | `Sources/CMCRCore/Scripts+Classroom.swift:257` | Komunikat power-later odsyła do nieistniejącego przycisku „Anuluj zaplanowane” (zgłoszone przy weryfikacji) | naprawione (a8123fa) |
| [CLI-17](#cli-17) | cmcrctl | `Sources/cmcrctl/ScriptCommands.swift:33` | install bierze istniejący lokalnie plik lub folder o nazwie KOMP (np. „all”) za instalator (zgłoszone przy weryfikacji) | naprawione (a0aa5ef) |
| [CLI-18](#cli-18) | cmcrctl | `Sources/cmcrctl/SetupCommands.swift:42` | setup-script po cichu ignoruje --verify i --dry-run, więc wygenerowany plik wprowadza zmiany (zgłoszone przy weryfikacji) | naprawione (f07b2af) |
| [DOD-05](#dod-05) | Dodatkowe przeszukanie | `Sources/CMCRCore/SSH.swift:716` | Brak zgody macOS na sieć lokalną diagnozowany jako „wyłączony” dla całej pracowni | naprawione (66eb75e) |
| [DOD-06](#dod-06) | Dodatkowe przeszukanie | `Sources/CMCRCore/SSH.swift:734` | „Network is unreachable” (Mac nauczyciela bez sieci) pokazywany jako surowy angielski błąd ssh | naprawione (ca477c2) |
| [DOD-07](#dod-07) | Dodatkowe przeszukanie | `Sources/CMCRCore/Scripts+Classroom.swift:256` | Opóźnione wyłączenie/restart: ostrzeżenie i pominięcie zalogowanych tylko według stanu z chwili planowania | pominięte |
| [DOD-08](#dod-08) | Dodatkowe przeszukanie | `Sources/CMCRCore/Scripts+Classroom.swift:380` | „Zakończ zajęcia”: „Zamknij aplikacje” zgłasza „aplikacje zamknięte”, gdy nikt nie jest na konsoli | naprawione (80da493, 53196b3) |
| [DOD-09](#dod-09) | Dodatkowe przeszukanie | `Sources/CMCRCore/Scripts.swift:1026` | Uprzejme „Wyloguj” uznaje sukces, gdy tylko zmieni się właściciel konsoli | naprawione (977ae3f) |
| [DOD-10](#dod-10) | Dodatkowe przeszukanie | `Sources/CMCRManager/AppModel.swift:543` | Przy ProxyJump/ProxyCommand wynik nil sondy portu blokuje pełne sprawdzenie włączonego iMaca | naprawione (51ad629) |
| [DOD-11](#dod-11) | Dodatkowe przeszukanie | `Sources/CMCRManager/AppModel.swift:704` | Adres VNC sklejany bez kodowania – „#”, „/”, „?” w koncie kierują Udostępnianie ekranu do innego hosta niż ssh | naprawione (0d14b5c) |
| [DOD-12](#dod-12) | Dodatkowe przeszukanie | `Sources/CMCRManager/AppModel.swift:704` | „Steruj ekranem” po cichu nic nie robi dla adresu IPv6 (lub z „%”) – brak komunikatu (zgłoszone przy weryfikacji) | naprawione (0d14b5c) |
| [DOD-13](#dod-13) | Dodatkowe przeszukanie | `Sources/CMCRManager/RemoteBrowserComponents.swift:8` | Znaki bidi (U+202A–202E, U+2066–2069) w nazwach plików z iMaców nie są neutralizowane w GUI | naprawione (b58ee2e) |
| [KOM-02](#kom-02) | Komputery, zasilanie | `Sources/CMCRCore/Classroom.swift:432` | Uszkodzony classroom.json po cichu zastępowany wartościami domyślnymi | naprawione (0947713) |
| [KOM-03](#kom-03) | Komputery, zasilanie | `Sources/CMCRCore/Scripts+Classroom.swift:297` | Wyłączone przełączniki autorestart/Wake-on-LAN niczego nie wyłączają na iMacu | naprawione (48a551f) |
| [KOM-04](#kom-04) | Komputery, zasilanie | `Sources/CMCRManager/App.swift:562` | Nieaktualny zalogowany uczeń przy wyłączonych komputerach (lista, panel, potwierdzenia) | naprawione (6ec783a) |
| [KOM-05](#kom-05) | Komputery, zasilanie | `Sources/CMCRManager/AppModel+Jobs.swift:101` | ⇧⌘O „Zaznacz włączone” i kafelek „Włączone” w trakcie odświeżania kasują zaznaczenie | naprawione (28b9b05) |
| [KOM-06](#kom-06) | Komputery, zasilanie | `Sources/CMCRManager/ClassroomModel.swift:521` | Nieudany odczyt nazw/FileVault ignorowany – „sprawdzanie…” bez końca | naprawione (e02664e) |
| [KOM-07](#kom-07) | Komputery, zasilanie | `Sources/CMCRManager/ClassroomModel.swift:548` | Po zmianie nazwy z aktualizacją listy komputer traci zaufany klucz SSH | naprawione (dc66c55) |
| [KOM-08](#kom-08) | Komputery, zasilanie | `Sources/CMCRManager/DashboardView.swift:185` | Kliknięcie kafelka z liczbą 0 kasuje zaznaczenie komputerów | naprawione (28b9b05) |
| [KOM-09](#kom-09) | Komputery, zasilanie | `Sources/CMCRManager/DashboardView.swift:228` | Kliknięcie wiersza w tabeli „Komputery” zastępuje zaznaczenie (cele działań) | naprawione (c0a08b0) |
| [KOM-10](#kom-10) | Komputery, zasilanie | `Sources/CMCRManager/HostInspector.swift:138` | Panel szczegółów: „Harmonogram zasilania: nie sprawdzono”, choć stan zawiera harmonogram | naprawione (e02664e) |
| [KOM-11](#kom-11) | Komputery, zasilanie | `Sources/CMCRManager/HostInspector.swift:424` | Błędna odmiana „Sprawdzanie… (N pozostało)” | naprawione (e02664e) |
| [KOM-12](#kom-12) | Komputery, zasilanie | `Sources/CMCRManager/PowerView.swift:302` | Ostrzeżenie o FileVault przed restartem pomija automatyczne odblokowanie | naprawione (e02664e) |
| [KOM-13](#kom-13) | Komputery, zasilanie | `Sources/cmcrctl/CLI.swift:330` | cmcrctl status zapisuje MAC trasy domyślnej, cmcrctl wake nie preferuje Ethernetu ani nie czeka | naprawione (8a9ab17) |
| [KOM-14](#kom-14) | Komputery, zasilanie | `Sources/CMCRCore/Classroom.swift:563` | Eksport CSV nie neutralizuje formuł – dane kontrolowane przez ucznia wykonują się w arkuszu (zgłoszone przy weryfikacji) | naprawione (bb816ec) |
| [KOM-15](#kom-15) | Komputery, zasilanie | `Sources/CMCRManager/HostInspector.swift:282` | „Zmień nazwy komputerów” nie wykrywa kolizji z nazwami niezaznaczonych komputerów (zgłoszone przy weryfikacji) | naprawione (dc66c55) |
| [KON-07](#kon-07) | Konfiguracja | `Sources/CMCRCore/HostValidation.swift:27` | Poprawny adres MAC bez separatorów oznaczany jako błędny | naprawione (138cf29) |
| [KON-08](#kon-08) | Konfiguracja | `Sources/CMCRCore/Store.swift:18` | Pusta zmienna CMCR_CONFIG_DIR przenosi dziennik działań w inne miejsce | naprawione (564b738) |
| [KON-09](#kon-09) | Konfiguracja | `Sources/CMCRManager/ActivityViews.swift:334` | Baner „Nie zapisano hasła administratora” przy samych hasłach „własnych” | naprawione (a45dba1) |
| [KON-10](#kon-10) | Konfiguracja | `Sources/CMCRManager/App.swift:77` | Pozycje menu „Przejdź” i „Konfiguracja…” nic nie robią, gdy główne okno jest zamknięte | naprawione (7c11459) |
| [KON-11](#kon-11) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:73` | Widoczność kolumny Port nie jest zapamiętywana | naprawione (05d88af) |
| [KON-12](#kon-12) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:184` | Kolumna Hasło pokazuje „Własne” także, gdy własnego hasła nie ma w Pęku kluczy | naprawione (a45dba1) |
| [KON-13](#kon-13) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:382` | Błąd importu listy nie wskazuje miejsca problemu | naprawione (a45dba1) |
| [KON-14](#kon-14) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:399` | Generator listy w aplikacji nie sprawdza prefiksu i domeny (cmcrctl je odrzuca) | naprawione (05d88af) |
| [KON-15](#kon-15) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:511` | Własne hasła zastąpionych lub usuniętych wpisów zostają w Pęku kluczy | naprawione (a45dba1) |
| [KON-16](#kon-16) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:680` | „Utwórz (nowy) klucz” ignoruje klucz ustawiony w Ustawieniach › Połączenie | naprawione (8994a24) |
| [KON-17](#kon-17) | Konfiguracja | `Sources/CMCRManager/SetupView.swift:762` | „Roześlij klucz” jest aktywne bez pliku .pub i kończy się samym sygnałem dźwiękowym | naprawione (8994a24) |
| [PLI-06](#pli-06) | Pliki, przeglądarka | `Sources/CMCRCore/Operations+Browse.swift:91` | Nazwa komputera z „/” psuje „Zbierz prace” | naprawione (d2b2916) |
| [PLI-07](#pli-07) | Pliki, przeglądarka | `Sources/CMCRCore/SSH.swift:735` | Wysyłanie kończy się błędem, gdy pierwszy element ma nazwę zaczynającą się od „-” | naprawione (5978b7b) |
| [PLI-08](#pli-08) | Pliki, przeglądarka | `Sources/CMCRCore/Scripts.swift:805` | Nieudany chown przy wysyłaniu daje zadanie „Gotowe” | naprawione (a2d24cd) |
| [PLI-09](#pli-09) | Pliki, przeglądarka | `Sources/CMCRCore/Scripts.swift:935` | „Pokaż listę plików” nie rozwija ~ (folder w katalogu administratora) | naprawione (b16e6df) |
| [PLI-10](#pli-10) | Pliki, przeglądarka | `Sources/CMCRManager/FilesView.swift:80` | Tekst o {console}: „komputery … zostaną pominięte”, a zadania kończą się błędem | naprawione (94f8df5) |
| [PLI-11](#pli-11) | Pliki, przeglądarka | `Sources/CMCRManager/FilesView.swift:350` | Podpisy „&lt;nazwa komputera>” przy folderach konwencji, a folder nosi nazwę adresu | naprawione (94f8df5) |
| [PLI-13](#pli-13) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:103` | Przełączenie komputera po błędzie wczytywania przenosi ścieżkę poprzedniego iMaca | naprawione (18ff2c5) |
| [PLI-14](#pli-14) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:196` | Przełącznik „Jako administrator” wraca sam do włączonego | naprawione (18ff2c5) |
| [PLI-15](#pli-15) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:220` | Zmiany w Przeglądarce pomijane jako „niedostępny”, choć folder właśnie się wczytał | naprawione (18ff2c5) |
| [PLI-16](#pli-16) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:223` | Wspólny stan activity/notice/lastDownload przy równoległych zmianach w Przeglądarce | naprawione (18ff2c5) |
| [PLI-17](#pli-17) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserModel.swift:250` | Nazwy plików ucznia trafiają bez zmian do dziennika działań (fałszywe wpisy) | naprawione (b58ee2e) |
| [PLI-18](#pli-18) | Pliki, przeglądarka | `Sources/CMCRManager/RemoteBrowserView.swift:343` | „Wyślij pliki do tego folderu…” zastępuje istniejące pliki bez pytania | naprawione (18ff2c5) |
| [PLI-19](#pli-19) | Pliki, przeglądarka | `Sources/cmcrctl/Browse.swift:136` | Inne domyślne sudo w CLI: collect bez root dla prywatnych folderów, push z właścicielem administratora | naprawione (ced1c71) |
| [PLI-20](#pli-20) | Pliki, przeglądarka | `Sources/cmcrctl/CLI.swift:431` | cmcrctl ls ŚCIEŻKA KOMP i clean nie rozwijają {student}; clean kończy się kodem 0 bez czyszczenia | naprawione (934a05d) |
| [PLI-24](#pli-24) | Interfejs | `Sources/CMCRManager/RemoteBrowserView.swift:66` | Kliknięcie innego komputera na liście nie przełącza Przeglądarki plików (zgłoszone przy weryfikacji) | naprawione (7924cac) |
| [PRZ-02](#prz-02) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/Updater.swift:468` | „Przypomnij później” nie anuluje zleconej instalacji – po pobraniu aplikacja sama się zamyka i instaluje | naprawione (d4754f9) |
| [PRZ-05](#prz-05) | Przygotowanie iMaców, uaktualnienia | `README.md:34` | README podaje macOS 13, a aplikacja wymaga macOS 14 | naprawione (077b036) |
| [PRZ-06](#prz-06) | Przygotowanie iMaców, uaktualnienia | `README.md:52` | Kod wyjścia 4 skryptu konfiguracyjnego nieopisany w README | naprawione (077b036) |
| [PRZ-07](#prz-07) | Przygotowanie iMaców, uaktualnienia | `README.md:96` | README: „Skrypt sam wybiera zgodne SDK” – build-app.sh nie ma już tej logiki | naprawione (077b036) |
| [PRZ-08](#prz-08) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/Scripts+Setup.swift:425` | Gotowość: przy pierwszym sudo na koncie błędne hasło pokazuje się jako „błąd: WARNING: Improper use…” zamiast „złe hasło” | naprawione (1928153) |
| [PRZ-09](#prz-09) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/SelfUpdate.swift:764` | Instalator jako root dopisuje dziennik do ścieżki w katalogu użytkownika (podąża za dowiązaniem, TOCTOU) | naprawione (bd9c7cb) |
| [PRZ-10](#prz-10) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/SetupScript.swift:92` | cmcrctl: przy błędnych literach dni harmonogramu komunikat „wybierz co najmniej jeden dzień” | naprawione (5f96b5c) |
| [PRZ-11](#prz-11) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRCore/SetupScript.swift:384` | cmcrctl setup ignoruje zapisane opcje i po cichu cofa „Logowanie zdalne tylko kluczem” | naprawione (35d15b3) |
| [PRZ-12](#prz-12) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/ReadinessView.swift:23` | Ponowne sprawdzenie po naprawie jest pomijane, gdy dla iMaca trwa wcześniejsze sprawdzenie – tabela pokazuje stan sprzed naprawy | naprawione (231a108) |
| [PRZ-13](#prz-13) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/ReadinessView.swift:804` | Komórka gotowości proponuje naprawę, która nie może pomóc („brak konta” → Utwórz folder ucznia, „nie admin” → Hasło tego komputera…) | naprawione (231a108) |
| [PRZ-14](#prz-14) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/SetupOptionsSheet.swift:122` | Aplikacja pozwala uruchomić lub zapisać skrypt z niepoprawnym folderem ucznia (CLI to blokuje) | naprawione (231a108) |
| [PRZ-15](#prz-15) | Przygotowanie iMaców, uaktualnienia | `setup/cmcr-imac-setup.sh:475` | „Tylko sprawdź”/--dry-run twierdzi „Usunięto prawo zapisu…” i nie liczy tej zmiany | naprawione (9eb1ab5) |
| [PRZ-16](#prz-16) | Przygotowanie iMaców, uaktualnienia | `setup/cmcr-imac-setup.sh:717` | Nieudane pmset -a (WoL, uśpienie) i scutil --set są połykane – raport mówi „bez zmian”, kod 0 | naprawione (e3ce5a1) |
| [PRZ-18](#prz-18) | Przygotowanie iMaców, uaktualnienia | `Sources/CMCRManager/UpdateViews.swift:357` | „Sprawdź teraz” w oknie Ustawień (i „Sprawdź uaktualnienia…” bez widocznego głównego okna) pokazuje wynik w niewidocznym arkuszu (zgłoszone przy weryfikacji) | naprawione (d4754f9) |
| [REV-01](#rev-01) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:304` | KOM-07 naprawiono tylko w aplikacji: `cmcrctl rename --update-list` nadal gubi zaufany klucz komputera (hosta) | naprawione (3e0325d) |
| [REV-02](#rev-02) | Przegląd poprawek | `Sources/CMCRCore/SSH.swift:761` | ZAD-07: rozpoczęta sesja zerwana przez reset TCP jest zgłaszana jako kod wyjścia 255 samego polecenia | naprawione (e3caaf4) |
| [REV-03](#rev-03) | Przegląd poprawek | `Sources/CMCRCore/Classroom.swift:357` | Poprawka KOM-02 pomija zagnieżdżenia: zła wartość w start/end/schedule nadal po cichu resetuje cały scenariusz lub harmonogram | naprawione (6a8db4e) |
| [REV-04](#rev-04) | Przegląd poprawek | `Sources/CMCRCore/Store.swift:44` | Scalanie KON-04 zawodzi, gdy przy starcie aplikacji nie było hosts.json: pierwszy zapis nadal kasuje listę z cmcrctl | naprawione (3e0e5bd) |
| [REV-05](#rev-05) | Przegląd poprawek | `Sources/CMCRCore/Store.swift:103` | Zmieniony poza aplikacją hosts.json, który nie jest już poprawnym JSON-em, zostaje po cichu zastąpiony bez ostrzeżenia | naprawione (87aecaa) |
| [REV-06](#rev-06) | Przegląd poprawek | `Sources/CMCRCore/Scripts.swift:1292` | Szybka poprawka Udostępniania ekranu pisze „tylko administratorzy”, nie sprawdzając kont już obecnych na liście dostępu | naprawione (0f60f76) |
| [REV-07](#rev-07) | Przegląd poprawek | `Sources/CMCRCore/Scripts.swift:1156` | „Wyloguj” (z pytaniem o zapis) traktuje sesję administratora w tle jak sesję ucznia i zawsze kończy się błędem | naprawione (acb1df3) |
| [REV-08](#rev-08) | Przegląd poprawek | `Sources/CMCRCore/ScreenCapture.swift:398` | Sprawdzanie trybu uwagi wykrywa pozostały proces automatycznego odblokowania i blokuje podgląd po zdjęciu blokady | naprawione (4dd272d) |
| [REV-09](#rev-09) | Przegląd poprawek | `Sources/CMCRCore/Scripts.swift:341` | Odinstalowanie nadal nie wykrywa działających aplikacji, których nazwa jest zapisana na dysku w postaci rozłożonej (NFD) – APL-03 naprawione w połowie | naprawione (c54fb72) |
| [REV-10](#rev-10) | Przegląd poprawek | `Sources/CMCRCore/SetupScript.swift:489` | Komunikat błędu cmcrctl odsyła do opcji w aplikacji pod nazwą, której już tam nie ma | naprawione (49a436b) |
| [REV-12](#rev-12) | Przegląd poprawek | `Sources/CMCRManager/AppModel.swift:597` | Poprawka ZAD-10 gubi rzeczywisty błąd „Zbierz prace” i cmcr-pull: podsumowaniem staje się ostatni wiersz „ls -l” | naprawione (acce0a3) |
| [REV-13](#rev-13) | Przegląd poprawek | `Sources/CMCRManager/AppModel.swift:858` | Nowe alerty o błędach i powiadomienie o tunelu są tylko w oknie głównym: działania na Ścianie ekranów zawodzą po cichu | naprawione (4dd739e) |
| [REV-14](#rev-14) | Przegląd poprawek | `Sources/CMCRManager/ClassroomModel.swift:76` | ZAJ-13: komputery, na których kroki nie miały nic do zrobienia, są zgłaszane jako „pominięto” | naprawione (e74cbda) |
| [REV-15](#rev-15) | Przegląd poprawek | `Sources/CMCRManager/RemoteBrowserModel.swift:268` | Operacja na poprzednim Macu pokazuje postęp i wynik w Przeglądarce plików nowo wybranego Maca | naprawione (904b458) |
| [REV-16](#rev-16) | Przegląd poprawek | `Sources/CMCRManager/RemoteBrowserModel.swift:302` | Błąd gramatyczny: „Usuwanie/Pobieranie/Wysyłanie 3 elementy…” | naprawione (bd70255) |
| [REV-17](#rev-17) | Przegląd poprawek | `Sources/CMCRManager/AppModel+Jobs.swift:145` | Błąd odmiany w komunikacie po ponowieniu: „Pominięto 1 komputer usunięte z listy” | naprawione (2e1f8e1) |
| [REV-19](#rev-19) | Przegląd poprawek | `Sources/CMCRManager/RemoteBrowserModel.swift:337` | DOD-13 nie zabezpieczyło tytułu wysyłania: nazwy folderów z iMaca nadal odwracają tytuł zadania | naprawione (e079cb2) |
| [REV-20](#rev-20) | Przegląd poprawek | `Sources/CMCRManager/ClassroomModel.swift:491` | ZAJ-11: ponowione pytanie nadal pokazuje „pominięto – komputer niedostępny”, a Mac nie jest liczony jako oczekujący | naprawione (5d3c45d) |
| [REV-21](#rev-21) | Przegląd poprawek | `Sources/CMCRManager/HostInspector.swift:141` | Zastępcze źródło z KOM-10 pokazuje harmonogram jako surowy angielski tekst pmset, a pusty jako „nie sprawdzono” | naprawione (e3e40db) |
| [REV-22](#rev-22) | Przegląd poprawek | `Sources/CMCRManager/ConfigIssuesAlert.swift:44` | Nowy alert AppNotice jest tylko w oknie głównym, więc błędy ze Ściany ekranów, podglądów i okna Ustawień są ukryte | naprawione (4dd739e) |
| [REV-23](#rev-23) | Przegląd poprawek | `Sources/CMCRManager/App.swift:765` | Przejdź › dział wysuwa okno Ustawień zamiast otworzyć zamknięte okno główne (KON-10 nienaprawione w swoim scenariuszu) | naprawione (6e1b3df) |
| [REV-24](#rev-24) | Przegląd poprawek | `Sources/CMCRManager/App.swift:441` | Potwierdzenie „Usuń grupę” używa mianownika po „z”: „Grupa zniknie z 1 komputer / z 3 komputery” | naprawione (53b14f9) |
| [REV-25](#rev-25) | Przegląd poprawek | `Sources/CMCRManager/SetupView.swift:535` | Stopka generatora: „Przedrostek nazwy pusta wartość”, a pole, którego dotyczy, ma etykietę „Początek nazwy” | naprawione (ac814f8) |
| [REV-26](#rev-26) | Przegląd poprawek | `Sources/CMCRManager/PowerView.swift:393` | Podpowiedź FileVault przy każdym Macu w arkuszu ponownego uruchamiania przeczy nowemu ostrzeżeniu z KOM-12 | naprawione (48c9182) |
| [REV-27](#rev-27) | Przegląd poprawek | `Sources/CMCRManager/UpdatesView.swift:151` | Instalacja aktualizacji usuwa z widoku aktualizacje, których nie zainstalowano (nowa wersja macOS lub niezalecane) | naprawione (cd7a2e1) |
| [REV-28](#rev-28) | Przegląd poprawek | `Sources/CMCRManager/RemoteFolderPicker.swift:60` | WSP-07/UI-14 nienaprawione w wyborze folderu: błędna nazwa w „Nowy folder” nadal daje tylko sygnał dźwiękowy i przepada | naprawione (dbcf38d) |
| [REV-29](#rev-29) | Przegląd poprawek | `Sources/CMCRManager/ScreenTiles.swift:497` | Znacznik zaznaczenia zasłania pierwszy przycisk paska akcji (pokazywanego po najechaniu) na zaznaczonych kafelkach | naprawione (7ced267) |
| [REV-30](#rev-30) | Przegląd poprawek | `Sources/CMCRManager/RemoteBrowserView.swift:221` | Komunikat o nieprawidłowej nazwie ma link „Szczegóły” do nieistniejącego zadania i jest ukryty, gdy trwa inna zmiana | naprawione (dbcf38d) |
| [REV-31](#rev-31) | Przegląd poprawek | `Sources/CMCRManager/RemoteBrowserView.swift:350` | Potwierdzenie wysyłania do podfolderu mówi o zastąpieniu elementów o tych samych nazwach i usunięciu starych wersji, a foldery są scalane | naprawione (833a4f4) |
| [REV-33](#rev-33) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:281` | rename-computer --name nie wykrywa nazwy innego Maca z listy komputerów (KOM-15 poprawiono tylko w aplikacji) | naprawione (62d94d5) |
| [REV-34](#rev-34) | Przegląd poprawek | `Sources/cmcrctl/SetupCommands.swift:48` | readiness nadal po cichu akceptuje --no-key, --verify i --dry-run (niepełna poprawka PRZ-17) | naprawione (cbf8d79) |
| [REV-35](#rev-35) | Przegląd poprawek | `Sources/cmcrctl/Interrupt.swift:83` | Ctrl-C przy -j > 1 kończy program z wnętrza zadania, więc zbuforowane wyjście innych Maców, w tym wynik zatrzymania, nie jest wypisywane | naprawione (cdf30fe) |
| [REV-36](#rev-36) | Przegląd poprawek | `Sources/cmcrctl/CLI.swift:88` | Pomoc i README obiecują, że Ctrl-C zatrzymuje polecenie na iMakach, ale rm, install, push, collect, lesson, rename-computer, setup i ask nadal działają bez rejestracji | naprawione (e0209b0) |
| [REV-37](#rev-37) | Przegląd poprawek | `Sources/cmcrctl/main.swift:25` | Ostrzeżenie CLI-15 pojawia się przed wczytaniem classroom.json – uszkodzony plik po cichu daje wartości domyślne w schedule set, ask, lock i lesson | naprawione (c13a5e2) |
| [REV-38](#rev-38) | Przegląd poprawek | `Sources/cmcrctl/CLI.swift:678` | Podpowiedź logout proponuje --force przy każdym błędzie, także dla niedostępnego Maca, i pojawia się przed komunikatem o błędzie | naprawione (be764fe) |
| [REV-39](#rev-39) | Przegląd poprawek | `Sources/CMCRCore/Scripts.swift:862` | Sprawdzenie właściciela z PLI-08 odrzuca liczbowe UID, które chown przyjmuje – wysyłanie do folderów usuniętych kont teraz zawodzi | naprawione (47079e8) |
| [REV-40](#rev-40) | Przegląd poprawek | `setup/cmcr-imac-setup.sh:551` | Wyłączenie „SSH wyłącznie z kluczem” razem z keepalive zostawia logowanie hasłem wyłączone; krok jest tylko oznaczany „bez zmian” | naprawione (0f0dd15) |
| [REV-41](#rev-41) | Przegląd poprawek | `setup/cmcr-imac-setup.sh:752` | Odczyt kontrolny w pm_set porównuje napisy: --display-sleep z wiodącym zerem jest teraz zgłaszane jako błąd pmset (exit 1) | naprawione (685a4dc) |
| [REV-42](#rev-42) | Przegląd poprawek | `Sources/CMCRCore/Scripts+Setup.swift:166` | Tekst z TXT-08 „Zainstaluj klucz logowania” (niżej) wypisuje też cmcrctl readiness, gdzie niżej nic nie ma | naprawione (7a1bed5) |
| [REV-43](#rev-43) | Przegląd poprawek | `Tests/e2e/run.sh:252` | Pełny przebieg e2e nie przechodzi: wspólne połączenia SSH grupy rev-g6-cli przeżywają do grupy screens | naprawione (1461c95) |
| [REV-44](#rev-44) | Przegląd poprawek | `Sources/cmcrctl/ScriptCommands.swift:59` | Ctrl-C w trakcie pakowania w `install` (lub `lesson start` z materiałami) zostawia działający tar i wielogigabajtowe archiwum w $TMPDIR | naprawione (3ac2c94) |
| [REV-45](#rev-45) | Przegląd poprawek | `README.md:129` | README: polecenia tylko do odczytu kończą się od razu po Ctrl-C, ale `ls ŚCIEŻKA KOMP`, `updates history`, `setup --verify/--dry-run` i `rm --dry-run` to zadania | naprawione (1b0de00) |
| [REV-46](#rev-46) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:67` | lesson: ostrzeżenie o uszkodzonym classroom.json pojawia się dopiero po pytaniu „Wykonać na wszystkich?”, inaczej niż w lock/ask/schedule set | naprawione (c6cefc8) |
| [REV-47](#rev-47) | Przegląd poprawek | `Sources/cmcrctl/CLI.swift:693` | Podpowiedź logout --force nie ujmuje w cudzysłów nazwy komputera z „!” (lub „=” na początku), więc wklejona do zsh/bash nie działa | naprawione (66e742f) |
| [REV-48](#rev-48) | Przegląd poprawek | `Sources/CMCRCore/Scripts.swift:869` | Literówka w liczbowym właścicielu omija teraz sprawdzenie z PLI-08: pliki trafiają do uid bez konta, a wysyłanie kończy się kodem 0 | naprawione (3fb07fc) |
| [REV-49](#rev-49) | Przegląd poprawek | `setup/cmcr-imac-setup.sh:585` | Przy --ssh-key-only i nieudanej instalacji klucza raport mówi, że logowanie hasłem pozostaje włączone, choć jest już wyłączone | naprawione (82a214c) |
| [REV-50](#rev-50) | Przegląd poprawek | `setup/cmcr-imac-setup.sh:781` | --display-sleep 0/00 jest raportowane jako „uśpienie ekranu po 0 min”, choć 0 wyłącza usypianie ekranu | naprawione (15ab812) |
| [REV-51](#rev-51) | Przegląd poprawek | `README.md:178` | README: zerwane połączenie nie jest zgłaszane jako kod wyjścia, ale historia w aplikacji, eksporty i cmcrctl exec nadal podają kod 255 | naprawione (ed59d5a, 35aee45) |
| [REV-52](#rev-52) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:304` | cmcrctl rename (i arkusz w aplikacji) przyjmuje przenumerowanie lub zamianę na nazwę .local, którą ma jeszcze inny Mac z listy, wbrew nowej regule w README | naprawione (b12d083) |
| [REV-53](#rev-53) | Przegląd poprawek | `Sources/cmcrctl/Output.swift:184` | cmcrctl exec zwraca 1 zamiast własnego kodu polecenia 255, gdy polecenie nic nie wypisało na stderr (exit 255, exit -1) | naprawione (7008694) |
| [REV-54](#rev-54) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:353` | cmcrctl rename przy przesunięciu nazw w kółko (trzy komputery i więcej) radzi „najpierw X, potem Y” po okręgu – każdy pierwszy krok jest odrzucany | naprawione (ac724b1) |
| [REV-55](#rev-55) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:357` | Rada „zmień nazwy w dwóch krokach” pomija --update-list, więc drugi krok wykonany dosłownie jest odrzucany | naprawione (53309f2) |
| [REV-56](#rev-56) | Przegląd poprawek | `Sources/CMCRCore/CommandLineSupport.swift:26` | Cytowanie z REV-47 pomija „=” na początku, po którym stoi znak łączący – zsh nadal rozwija słowo jako ścieżkę polecenia | naprawione (0d0bddd) |
| [REV-57](#rev-57) | Przegląd poprawek | `README.md:129` | Zerwane połączenie po wpisie polecenia na stderr nadal jest zgłaszane jako „Polecenie zakończone kodem 255” (exec: kod 255), wbrew README | naprawione (7008694) |
| [REV-58](#rev-58) | Przegląd poprawek | `README.md:130` | README mówi, że cmcrctl rename sprawdza kolizje nazw „tak jak okno „Zmień nazwy komputerów””, ale oba sprawdzają inne nazwy | naprawione (4c309d3) |
| [REV-59](#rev-59) | Przegląd poprawek | `Tests/CMCRCoreTests/StoreTests.swift:128` | Test zapisu z błędem (KON-03) porównuje globalny lastSaveError, który równolegle zerują inne testy | naprawione (d35ee19) |
| [REV-61](#rev-61) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:316` | Rada przy przesunięciu nazw w kółko nie podaje kolejności pozostałych komputerów, a podsuwana kolejność jest odwrotna | naprawione (ea2d06d) |
| [REV-62](#rev-62) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:363` | Powtórzone nowe nazwy giną za radą o kolejności; wykonanie jej zostawia komputer z nazwą tymczasową | naprawione (605a0c6) |
| [REV-63](#rev-63) | Przegląd poprawek | `Sources/CMCRManager/HostInspector.swift:261` | Okno „Zmień nazwy komputerów” nadal radzi „najpierw tylko X, potem ten komputer”, co nie działa przy przenumerowaniu trzech i więcej komputerów | naprawione (cd58fea) |
| [REV-64](#rev-64) | Przegląd poprawek | `Sources/cmcrctl/ClassroomCommands.swift:354` | Rada o kolejności zmiany nazw prowadzi przez komputer, którego nazwa powtarza się albo jest zajęta – wykonanie jej zostawia komputer z nazwą tymczasową | naprawione (c3622f7) |
| [REV-65](#rev-65) | Przegląd poprawek | `Sources/CMCRCore/RenamePlan.swift:164` | Rada w oknie „Zmień nazwy komputerów” nie podaje nowych nazw w krokach, a okno po zamknięciu zapomina wpisane nazwy | naprawione (40e7e26) |
| [REV-66](#rev-66) | Przegląd poprawek | `README.md:179` | Ostrzeżenia o konfiguracji pokazuje tylko główne okno, choć README obiecuje komunikaty w oknie, w którym się pracuje | naprawione (1ba58a7) |
| [REV-67](#rev-67) | Przegląd poprawek | `Sources/CMCRManager/ConfigIssuesAlert.swift:134` | Problem z konfiguracją dodany, gdy ostrzeżenie jest już na ekranie, nie zostaje pokazany, a „OK” go usuwa | naprawione (4ba95e9) |
| [REV-68](#rev-68) | Przegląd poprawek | `Sources/CMCRManager/ConfigIssuesAlert.swift:121` | Ten sam tekst problemu z konfiguracją, który pojawi się ponownie, trafia do okna wybranego poprzednio, a nie do okna, w którym się pracuje | naprawione (4ba95e9) |
| [REV-69](#rev-69) | Przegląd poprawek | `Sources/CMCRCore/RenamePlan.swift:100` | Rada w oknie zmiany nazw podaje kolejność, której pierwszy krok samo okno odrzuca, gdy nazwa z listy zmienianego komputera różni się od jego obecnej nazwy .local | naprawione (7e6ae29, 3b2fefa) |
| [REV-70](#rev-70) | Przegląd poprawek | `README.md:106` | README: limit czasu przy sprawdzaniu stanu nie zawsze zachowuje ostatnio zalogowanego ucznia | naprawione (53fb6bc) |
| [REV-71](#rev-71) | Przegląd poprawek | `Sources/CMCRManager/HostInspector.swift:318` | Okno „Zmień nazwy komputerów” pozwala dać innemu komputerowi adres zaznaczonego komputera, którego nazwa się nie zmienia | naprawione (26ca4c7) |
| [REV-72](#rev-72) | Przegląd poprawek | `Sources/CMCRManager/ConfigIssuesAlert.swift:218` | Ostrzeżenie o konfiguracji znika po zminimalizowaniu jego okna i wraca dopiero później, w innym oknie | naprawione (7c35a9e) |
| [REV-73](#rev-73) | Przegląd poprawek | `Sources/CMCRManager/HostInspector.swift:262` | Okno zmiany nazw wskazuje zły komputer i opisuje nieistniejący konflikt Bonjour, gdy nową nazwę ma inny komputer tylko jako nazwę na liście | naprawione (d2e8652) |
| [REV-74](#rev-74) | Przegląd poprawek | `README.md:106` | Nieudane działanie na komputerze, który przestał odpowiadać, oznacza go jako niedostępny, ale zostawia ostatnio zalogowanego ucznia | naprawione (d4cad13) |
| [REV-75](#rev-75) | Przegląd poprawek | `README.md:180` | Błąd zapisu classroom.json w aplikacji nie jest zgłaszany, a cmcrctl status przy błędzie zapisu adresu MAC kończy się kodem 0 – wbrew README | naprawione (0b945d8, 88d2c7b) |
| [REV-77](#rev-77) | Przegląd poprawek | `Tests/CMCRCoreTests/P2CoreTests.swift:553` | Test przerwania przed znacznikiem startu ma zbyt ciasny limit czasu i nie przechodzi na runnerze CI | naprawione (8e0e9af) |
| [TXT-01](#txt-01) | Teksty | `Sources/CMCRManager/MainToolbar.swift:59` | Podpowiedź „Ściana ekranów” obiecuje tylko zaznaczone komputery, a okno domyślnie pokazuje wszystkie | naprawione (8c553df) |
| [TXT-02](#txt-02) | Teksty | `README.md:106` | README: filtr i skrót opisane jako „online”, w UI to „Włączone” | naprawione (077b036) |
| [TXT-03](#txt-03) | Teksty | `README.md:114` | README: „Pliki › Konwencja cmcr-helpers” – takiej pozycji nie ma | naprawione (077b036) |
| [TXT-04](#txt-04) | Teksty | `README.md:177` | README: „Anuluj” zatrzymuje polecenie – przycisk to „Przerwij”; stan „Przerwano” vs wynik „Anulowano” | naprawione (077b036) |
| [TXT-05](#txt-05) | Teksty | `Sources/CMCRCore/SSH.swift:689` | Komunikat SSH: zła nazwa „Logowanie zdalne” i dwuznaczne „na tym Macu” | naprawione (c4822a6) |
| [TXT-06](#txt-06) | Teksty | `Sources/CMCRCore/ScreenCapture.swift:149` | Komunikaty o iMacu ucznia mówią „ten Mac”, czyli w aplikacji Mac nauczyciela | naprawione (27abddf) |
| [TXT-07](#txt-07) | Teksty | `Sources/CMCRCore/Scripts+Classroom.swift:257` | Wynik „wyłączenia za N min” odsyła do przycisku „Anuluj zaplanowane” | naprawione (a8123fa) |
| [TXT-08](#txt-08) | Teksty | `Sources/CMCRCore/Scripts+Setup.swift:166` | Komunikaty gotowości odsyłają do przycisków, których nie ma | naprawione (6526168) |
| [TXT-09](#txt-09) | Teksty | `Sources/CMCRCore/Scripts+Setup.swift:175` | „w Konfiguracja › …” – zły przypadek; dwuznaczne „w Ustawieniach” | naprawione (79f1f2b) |
| [TXT-10](#txt-10) | Teksty | `Sources/CMCRCore/Scripts.swift:369` | Komunikat odmowy instalacji odsyła do nieistniejącego przełącznika | naprawione (d371d77) |
| [TXT-12](#txt-12) | Teksty | `Sources/CMCRManager/App.swift:668` | Ta sama akcja „sesja SSH w Terminalu” ma cztery różne nazwy | naprawione (8c553df) |
| [TXT-13](#txt-13) | Teksty | `Sources/CMCRManager/HostInspector.swift:70` | Panel szczegółów: „120 GB wolne” i „Szyfrowanie dysku: włączony” | naprawione (8c553df) |
| [TXT-14](#txt-14) | Teksty | `Sources/CMCRManager/ReadinessView.swift:279` | Instrukcja „Nagrywanie ekranu” pomija /usr/libexec/sshd-session | naprawione (164bb34) |
| [TXT-15](#txt-15) | Teksty | `Sources/CMCRManager/RemoteBrowserComponents.swift:271` | W oknie pojawia się skrócona etykieta CLI stanu („offline”, „online”, „błąd”) | naprawione (6890f7f) |
| [TXT-16](#txt-16) | Teksty | `Sources/CMCRManager/RemoteBrowserComponents.swift:400` | Trzy różne nazwy opcji macOS „pełny dostęp do dysku dla użytkowników zdalnych” | naprawione (c5393e1) |
| [TXT-17](#txt-17) | Teksty | `Sources/CMCRManager/RemoteBrowserModel.swift:260` | Tytuły zadań przeglądarki: „Usuń/Pobierz/Wyślij 3 elementów” | naprawione (fe7f85a) |
| [TXT-19](#txt-19) | Teksty | `Sources/CMCRManager/Updater.swift:174` | Uaktualnienie aplikacji nazwane „aktualizacją” | naprawione (d4990a4) |
| [TXT-20](#txt-20) | Teksty | `Sources/cmcrctl/CLI.swift:69` | Pomoc cmcrctl: ustawienie „Równoległe operacje” nie istnieje, formatowanie niespójne | naprawione (1d5763e) |
| [TXT-22](#txt-22) | Teksty | `Sources/cmcrctl/ScreenWatch.swift:52` | cmcrctl: „Zakończono: 3 cykli, 1 nowych obrazów” i „1 błędów składni” | naprawione (a0504cc, 1202893) |
| [TXT-23](#txt-23) | Teksty | `setup/cmcr-imac-setup.sh:836` | Raport skryptu konfiguracyjnego: „Zainstalowano Rosetta 2”, „wpis(ów)”, „klucz menedżera” | naprawione (f4adabf) |
| [TXT-24](#txt-24) | Teksty | `Sources/CMCRManager/SetupOptionsSheet.swift:421` | Folder /Applications nazywany raz „Programy”, raz „Aplikacje”; aktualny polski macOS pokazuje „Aplikacje” (zgłoszone przy weryfikacji) | naprawione (164bb34) |
| [UI-01](#ui-01) | Interfejs | `Sources/CMCRManager/App.swift:70` | ⌘, przypisany trzem pozycjom menu – skrót opisany przy „Ustawienia…” nie otwiera okna Ustawień | naprawione (7c11459) |
| [UI-05](#ui-05) | Interfejs | `Sources/CMCRManager/SetupView.swift:378` | „Wczytaj listę z pliku…” zastępuje całą listę komputerów bez potwierdzenia | naprawione (a45dba1) |
| [UI-06](#ui-06) | Interfejs | `Sources/CMCRManager/App.swift:158` | Usunięty standardowy przycisk paska bocznego i wymuszany tryb paska narzędzi | naprawione (ada0970) |
| [UI-07](#ui-07) | Interfejs | `Sources/CMCRManager/AppsView.swift:40` | Lista uruchomionych aplikacji nie wczytuje się dla komputerów zaznaczonych po wejściu w dział | naprawione (4e9b22c) |
| [UI-08](#ui-08) | Interfejs | `Sources/CMCRManager/ClassroomView.swift:496` | Ta sama akcja lub ten sam stan oznaczane różnymi symbolami | naprawione (1849b4d) |
| [UI-10](#ui-10) | Interfejs | `Sources/CMCRManager/ClassroomView.swift:859` | Niespójna terminologia: „sekcja” zamiast „dział”, „Zaktualizowano” dla uaktualnienia aplikacji, „Pobrane rzeczy” vs „Pobrane” | naprawione (164bb34) |
| [UI-12](#ui-12) | Interfejs | `Sources/CMCRManager/ConfigIssuesAlert.swift:48` | Przykładowy komunikat w zrzutach UI podaje nieistniejący plik „hosts.json.damaged” | naprawione (06a56e9) |
| [UI-13](#ui-13) | Interfejs | `Sources/CMCRManager/DashboardView.swift:65` | Tabela działu Komputery z otwartym panelem szczegółów nie mieści się w oknie 1180 pt | naprawione (81b3f99) |
| [UI-14](#ui-14) | Interfejs | `Sources/CMCRManager/JobsView.swift:666` | Błędy zapisu i otwierania sygnalizowane tylko dźwiękiem albo przemilczane | naprawione (06a56e9) |
| [UI-15](#ui-15) | Interfejs | `Sources/CMCRCore/LessonRoutine.swift:169` | „najwyżej N komputerów naraz” – zła odmiana dla N = 1…4 (zgłoszone przy weryfikacji) | naprawione (d8f9dc8) |
| [UI-16](#ui-16) | Interfejs | `Sources/CMCRManager/ScreenControls.swift:49` | „Zmień ograniczenia…” otwiera Konfigurację na zakładce Komputery zamiast ustawień podglądu | naprawione (06a56e9) |
| [UI-17](#ui-17) | Interfejs | `Sources/CMCRManager/ScreenControls.swift:217` | „Szczegóły” w banerze podglądu i pasku Przeglądarki otwiera Zadania bez wskazania właściwego działania | naprawione (06a56e9) |
| [UI-18](#ui-18) | Interfejs | `Sources/CMCRManager/ScreenControls.swift:238` | Animacje przesunięcia i skalowania ignorują ustawienie „Ogranicz ruch” | naprawione (06a56e9) |
| [UI-19](#ui-19) | Interfejs | `Sources/CMCRManager/ScreenTiles.swift:268` | Świeżość obrazu i zaznaczenie kafelka w podglądzie rozróżniane tylko kolorem | naprawione (06a56e9) |
| [UI-20](#ui-20) | Interfejs | `Sources/CMCRManager/ScreenWall.swift:230` | Ikona „Pełny ekran” w Ścianie ekranów wymaga macOS 15 – na macOS 14 przycisk jest bez ikony | naprawione (1849b4d) |
| [UI-21](#ui-21) | Interfejs | `Sources/CMCRManager/ScreenWall.swift:414` | Menu i menu kontekstowe mieszają pozycje z ikonami i bez ikon | naprawione (9e2acf6) |
| [UI-22](#ui-22) | Interfejs | `Sources/CMCRManager/UpdatesView.swift:54` | Symbole SF z ograniczeniami Apple użyte niezgodnie z przeznaczeniem | naprawione (1849b4d) |
| [UI-23](#ui-23) | Interfejs | `Sources/CMCRManager/App.swift:49` | Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) pokazuje tylko, że pomoc jest niedostępna (zgłoszone przy weryfikacji) | naprawione (7c11459) |
| [UI-24](#ui-24) | Interfejs | `Sources/CMCRManager/App.swift:437` | „Usuń grupę” bez potwierdzenia, niespójne role „Przerwij”, przyciski niszczące tuż obok zwykłych | naprawione (9e2acf6) |
| [UI-25](#ui-25) | Interfejs | `Sources/CMCRManager/SetupView.swift:1044` | Zrzut „settings” w ciemnym motywie pokazuje zakładkę Uaktualnienia zamiast Ogólne (zgłoszone przy weryfikacji) | naprawione (06a56e9) |
| [UI-26](#ui-26) | Interfejs | `Sources/CMCRManager/ScreenControls.swift:167` | Trzy akcje nadal z dwoma różnymi symbolami po ujednoliceniu ikon | naprawione (8d03346) |
| [UI-27](#ui-27) | Interfejs | `Sources/CMCRManager/ReadinessView.swift:437` | Wczytanie listy z pliku i zapis do pliku nadal tym samym symbolem | naprawione (da01391) |
| [UI-28](#ui-28) | Interfejs | `Sources/CMCRManager/App.swift:152` | Przywrócony przycisk paska bocznego zawsze trafia do menu przepełnienia „»” | naprawione (bb69701) |
| [UI-29](#ui-29) | Interfejs | `Sources/CMCRManager/DashboardView.swift:136` | „Zapisz raport o komputerach (CSV)…” nadal używa tablecells, łamiąc regułę z da01391: zapis/eksport = square.and.arrow.up | naprawione (f33c3a1) |
| [UI-30](#ui-30) | Interfejs | `Sources/CMCRManager/ScreenWall.swift:211` | Menu, które nadal mieszają pozycje z ikonami i bez ikon (pozostałość po UI-21) | naprawione (f4b7946) |
| [UI-31](#ui-31) | Interfejs | `Sources/CMCRManager/RemoteBrowserView.swift:351` | Potwierdzenie wysłania do podfolderu w Przeglądarce plików nie podaje nazwy przeglądanego komputera | naprawione (26c2695) |
| [UI-32](#ui-32) | Interfejs | `Sources/CMCRManager/SetupView.swift:302` | „Usuń z listy…” w Konfiguracji › Komputery nadal stoi tuż obok zwykłego menu „Grupy” (pozostałość po UI-24) | naprawione (a2065af) |
| [UI-33](#ui-33) | Interfejs | `Sources/CMCRCore/LessonRoutine.swift:29` | Kroki zajęć „Uruchom aplikacje” i „Zamknij aplikacje” mają inne symbole niż te same akcje w dziale Aplikacje | naprawione (c68ff60) |
| [UI-34](#ui-34) | Interfejs | `Sources/CMCRCore/LessonRoutine.swift:37` | Dwa kroki czyszczenia mają po UI-33 ten sam symbol, więc ich kolumny w siatce postępu zakończenia zajęć wyglądają tak samo | naprawione (13ce65e) |
| [WSP-03](#wsp-03) | Współbieżność | `Sources/CMCRManager/App.swift:134` | Odświeżanie co 2 min działa tylko przy otwartym oknie głównym – sama Ściana ekranów nie dostaje aktualnego stanu | naprawione (a00d381) |
| [WSP-04](#wsp-04) | Współbieżność | `Sources/CMCRManager/AppModel+Jobs.swift:322` | „Przerwij” nie działa w trakcie pakowania plików (tar) | naprawione (ff696d5) |
| [WSP-05](#wsp-05) | Współbieżność | `Sources/CMCRManager/AppModel+Jobs.swift:400` | Kliknięcie powiadomienia „Zakończono…” bez okna głównego niczego nie pokazuje | naprawione (a00d381) |
| [WSP-06](#wsp-06) | Współbieżność | `Sources/CMCRManager/AppModel.swift:823` | Lista zainstalowanych aplikacji ignoruje błędy i nie pokazuje postępu | naprawione (4e9b22c) |
| [WSP-07](#wsp-07) | Współbieżność | `Sources/CMCRManager/RemoteBrowserComponents.swift:460` | Nowy folder / Zmień nazwę z „/” w nazwie – tylko dźwięk, nazwa przepada | naprawione (18ff2c5) |
| [WSP-08](#wsp-08) | Współbieżność | `Sources/cmcrctl/ConfigCommands.swift:54` | cmcrctl hosts add/set/remove/generate pisze „Dodano…” i kończy z kodem 0, choć hosts.json nie został zapisany (zgłoszone przy weryfikacji) | naprawione (b5d9416) |
| [WŁ-01](#wł-01) | Własne | `Sources/CMCRManager/App.swift:46` | Menu Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) nie prowadzi do żadnej pomocy | naprawione (7c11459) |
| [ZAD-03](#zad-03) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:440` | Wynik zdalnego zatrzymania nie trafia do podsumowania ani historii – „Anulowano” nawet gdy polecenie nadal działa | naprawione (ff696d5) |
| [ZAD-04](#zad-04) | Zadania, polecenia | `Sources/CMCRCore/JobHistory.swift:183` | Zapis historii może nadpisać cały plik miesiąca jednym wpisem | naprawione (3949bd0) |
| [ZAD-05](#zad-05) | Zadania, polecenia | `Sources/CMCRCore/JobHistory.swift:246` | Historia: wpisy starsze niż 90 dni widoczne z usuniętym wyjściem, limit 3000 tnie partie | naprawione (d0f47d8) |
| [ZAD-06](#zad-06) | Zadania, polecenia | `Sources/CMCRCore/SSH.swift:424` | Przerwanie tuż po starcie pomija zatrzymanie na iMacu, choć polecenie już ruszyło | naprawione (ec7a98f) |
| [ZAD-07](#zad-07) | Zadania, polecenia | `Sources/CMCRCore/SSH.swift:681` | Kod 255 lub „ssh:” w stderr działającego polecenia oznacza iMaca jako niedostępny/błąd | naprawione (1c0355f) |
| [ZAD-08](#zad-08) | Zadania, polecenia | `Sources/CMCRManager/AppModel+Jobs.swift:416` | Powiadomienie „Gotowe na 0 komputerach” gdy wszystko się nie udało | naprawione (ff696d5) |
| [ZAD-09](#zad-09) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:442` | Niespójna terminologia anulowania i nagłówków wyników | naprawione (ff696d5) |
| [ZAD-10](#zad-10) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:450` | Przy błędzie cały stderr jest dopisywany drugi raz do wyniku i historii | naprawione (ff696d5) |
| [ZAD-11](#zad-11) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:491` | „Wyczyść zakończone” gubi oglądaną partię z historii | naprawione (ff696d5) |
| [ZAD-13](#zad-13) | Zadania, polecenia | `Sources/cmcrctl/CLI.swift:240` | cmcrctl uruchamia skrypty bez rejestracji zadania: Ctrl-C nie zatrzymuje polecenia na iMacu | naprawione (ba19edf) |
| [ZAD-14](#zad-14) | Zadania, polecenia | `Sources/cmcrctl/CLI.swift:354` | cmcrctl nie zapisuje działań w dzienniku actions.log | naprawione (7a03609) |
| [ZAD-15](#zad-15) | Zadania, polecenia | `Sources/cmcrctl/CLI.swift:359` | cmcrctl exec --root nie pyta o ryzykowne polecenia, aplikacja pyta | naprawione (5d3bdfc) |
| [ZAD-16](#zad-16) | Zadania, polecenia | `Sources/CMCRManager/AppModel.swift:439` | Przerwane zadania i zadania po limicie czasu mają w historii i eksporcie „kod” lokalnego ssh lub -1 (zgłoszone przy weryfikacji) | naprawione (ff696d5) |
| [ZAJ-02](#zaj-02) | Zajęcia, podgląd | `Sources/CMCRCore/Classroom.swift:563` | Eksport odpowiedzi uczniów do CSV bez ochrony przed formułami | naprawione (bb816ec) |
| [ZAJ-06](#zaj-06) | Zajęcia, podgląd | `Sources/CMCRCore/LessonRoutine.swift:91` | Puste ostrzeżenie końca zajęć pokazuje uczniom pusty komunikat | pominięte |
| [ZAJ-07](#zaj-07) | Zajęcia, podgląd | `Sources/CMCRCore/LessonRoutine.swift:169` | Ręcznie sklejane liczebniki: „najwyżej 2 komputerów”, „3 cykli, 3 nowych obrazów” | naprawione (d8f9dc8) |
| [ZAJ-08](#zaj-08) | Zajęcia, podgląd | `Sources/CMCRCore/ScreenCapture.swift:436` | Jakość JPEG z ustawień stosowana tylko przy zmniejszaniu obrazu | naprawione (0855b88) |
| [ZAJ-09](#zaj-09) | Zajęcia, podgląd | `Sources/CMCRCore/Scripts+Classroom.swift:386` | „Zamknij aplikacje › Wszystkie” zabija aplikacje SIGTERM bez szansy zapisu | pominięte |
| [ZAJ-10](#zaj-10) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomModel.swift:395` | Nieudane ponowne zablokowanie odblokowuje ekran, a aplikacja pokazuje go jako zablokowany | naprawione (2062ac8) |
| [ZAJ-11](#zaj-11) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomModel.swift:427` | Pytanie: pominięte komputery wiszą jako „czeka na odpowiedź” na zawsze | naprawione (2062ac8) |
| [ZAJ-12](#zaj-12) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomModel.swift:428` | Nowe pytanie nie zamyka poprzedniego – stare okna zostają u uczniów, a odpowiedzi znikają z tabeli | pominięte |
| [ZAJ-13](#zaj-13) | Zajęcia, podgląd | `Sources/CMCRManager/ClassroomView.swift:466` | „Gotowe na wszystkich komputerach.” po przerwaniu lub pominięciu komputerów | naprawione (2062ac8) |
| [ZAJ-14](#zaj-14) | Zajęcia, podgląd | `Sources/cmcrctl/ClassroomCommands.swift:357` | cmcrctl lesson start budzi i obsługuje komputery po kolei | naprawione (007beb7) |
| [ZAJ-15](#zaj-15) | Zajęcia, podgląd | `Sources/cmcrctl/ScreenWatch.swift:99` | screen-watch wypisuje ścieżkę klatki, nawet gdy zapis się nie udał | naprawione (75d45af) |
| [ZAJ-17](#zaj-17) | Zajęcia, podgląd | `Sources/CMCRManager/ScreenCenter.swift:510` | Wybór konkretnego monitora ukrywa przełącznik monitorów (zgłoszone przy weryfikacji) | naprawione (2062ac8) |
| [ZAJ-18](#zaj-18) | Zajęcia, podgląd | `Sources/cmcrctl/ScreenWatch.swift:34` | cmcrctl screen-watch i screenshot nie zapisują sesji podglądu w dzienniku działań (zgłoszone przy weryfikacji) | naprawione (31e9c5b) |

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

openScreenSharing otwiera wprost vnc://&lt;konto administratora>@&lt;adres>.local, nie sprawdzając ani stanu komputera (offline/błąd), ani zaufania klucza SSH (nieznany lub ZMIENIONY). Wszystkie wejścia (DashboardView.swift:102, App.swift:660, HostInspector.swift:125, ScreenTiles.swift:304/368/498, ScreenWall.swift:356) są aktywne niezależnie od stanu. Udostępnianie ekranu nie wiąże tożsamości serwera z kluczem zaufanym w aplikacji, a nazwy Bonjour .local nie są uwierzytelniane (README l.174). Scenariusz: imac05 jest wyłączony (albo aplikacja właśnie oznaczyła go „Klucz SSH komputera się zmienił – połączenie przerwano przed logowaniem”), inne urządzenie w sieci odpowiada na imac05.local i wystawia serwer VNC z uwierzytelnianiem ARD (DH bez uwierzytelnienia serwera). Nauczyciel klika „Steruj ekranem” → Udostępnianie ekranu wysyła nazwę konta administratora z URL i hasło (wpisane ręcznie lub automatycznie z Pęku kluczy, jeśli zapamiętane) do podstawionego urządzenia. To dokładnie przypadek, przed którym README obiecuje ochronę („hasło administratora … nie są wysyłane” do niepotwierdzonego urządzenia). Dodatkowo stan .changed nie trafia do untrustedHosts (AppModel.swift:579 – usuwany), więc aplikacja nie ma nawet flagi, którą mogłaby zablokować VNC.

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

Krok „Wyczyść folder cmcr ucznia” wywołuje Scripts.cleanFolder, które usuwa CAŁĄ zawartość folderu (find . -mindepth 1 -maxdepth 1 -exec rm -rf), a nie tylko pliki zebrane chwilę wcześniej. Między migawką tar w kroku „Zbierz prace” a czyszczeniem mija czas transferu, rozpakowania i nowej sesji SSH z sudo (sekundy–minuty), a uczeń jest wciąż zalogowany (wylogowanie jest później, zamykanie aplikacji domyślnie wyłączone; ostrzeżenie każe właśnie „zapisać pracę w folderze cmcr”). Plik zapisany/zmieniony w tym oknie nie trafia do kopii, a potem zostaje skasowany – nieodwracalna utrata pracy ucznia. Dział Pliki ma do tego bezpieczną ścieżkę (Operations.collect + Scripts.removeCollected: usuwa tylko zebrane i niezmienione pliki), której scenariusz nie używa. Dodatkowo krok collect rozpakowuje tar wprost do &lt;folder>/&lt;m.name> bez uniqueURL, więc dwa komputery o tej samej nazwie albo „Powtórz na nieudanych” nadpisują wcześniej zebrane pliki (przy włączonym czyszczeniu – ich jedyną kopię).

**Status:** naprawione (65d8483)

### ZAJ-16

**Awaria po upływie odliczania końca zajęć: zakres Date()...end z odwróconymi granicami** – P0, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomView.swift:470`

Podczas odliczania przed końcem zajęć sekcja postępu buduje `Text(timerInterval: Date()...end, countsDown: true)`, dopóki `run.countdownEnd` nie jest nil. Pętla w ClassroomModel.endLesson sprawdza czas co 0,5 s i dopiero potem zeruje countdownEnd (ClassroomModel.swift:337-340), więc przez ułamek sekundy po `end` wartość nadal istnieje. Każde przeliczenie body w tym oknie tworzy zakres z lowerBound > upperBound, a Swift przerywa program („Range requires lowerBound &lt;= upperBound”, sprawdzane także w buildzie -O). LessonProgressSection ma @EnvironmentObject AppModel, więc przeliczenie wywoła np. wynik okresowego odświeżania stanu co 2 min, zmiana zaznaczenia, start zadania w innym dziale albo przełączenie zakładki. Sekcja jest widoczna domyślnie, bo po starcie zakończenia zajęć widok przełącza się na „Koniec lekcji” i przewija do postępu. Aplikacja pada tuż przed zbieraniem prac i kolejne kroki zakończenia zajęć się nie wykonują. Okno czasowe jest krótkie, ale powtarza się przy każdym zakończeniu zajęć.

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

**Status:** naprawione (fdd24ba). za zgodą właściciela (zmienia to, co widzi uczeń)

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

### REV-11

**Poprawka KOM-04 czyści zalogowanego ucznia na osiągalnych Macach: „Pomiń komputery z zalogowanym uczniem” już ich nie chroni** – P1, Przegląd poprawek, `Sources/CMCRManager/AppModel.swift:746`

applyStatus czyści teraz info["console"] i info["sessions"] po każdym nieudanym sprawdzeniu, a nie tylko dla wyłączonych Maców. Nieudane sprawdzenie daje stan .error zawsze, gdy Mac odpowiedział, ale sprawdzenie się nie powiodło: skrypt stanu przekroczył limit czasu już po uruchomieniu, niezerowy kod wyjścia, limit sesji mux, kex_exchange_identification albo „closed by remote host”. Reachability.isUnreachable jest prawdą tylko dla .offline, więc „Pomiń niedostępne” nie pomija Maców w stanie .error i działania nadal są na nich wykonywane. PowerConfirmSheet.row i PowerRequest.start (PowerView.swift:279, 376-379), ConfirmSheet oraz pendingSkip w endLesson rozstrzygają „pomiń zalogowanych” na podstawie status.loggedInUsers / loggedInText. Po wyczyszczeniu użytkownika taki Mac jest traktowany tak, jakby nikt nie był na nim zalogowany. Nie jest przekreślony, nie wlicza się do licznika „Pomiń komputery z zalogowanym uczniem (N)” ani do potwierdzenia przy ≥5, a ponowne uruchomienie, wylogowanie lub wyłączenie zostaje na nim wykonane. Przed tą zmianą ostatni znany uczeń był zachowywany, więc Mac był pomijany.

Scenariusz: imac07 jest mocno obciążony (uczeń renderuje film), a dwuminutowe sprawdzenie stanu przekracza OperationTimeout.status już po uruchomieniu skryptu. SSH.diagnose zwraca .online, co applyStatus zapisuje jako .error, a console=jan zostaje usunięte. Nauczyciel wybiera Sesja i zasilanie › Uruchom ponownie z włączonym „Pomiń komputery z zalogowanym uczniem”. imac07 nie pokazuje użytkownika i nie zostaje pominięty, bo .error nie oznacza niedostępności. Ponowne uruchomienie zostaje wykonane i jan traci niezapisaną pracę, choć nauczyciel wybrał pomijanie zalogowanych uczniów.

**Status:** naprawione (0807d34). Zalogowanych uczniów kasuje teraz tylko sprawdzenie, z którego wynika, że komputer jest wyłączony (.offline). Po innym błędzie (skrypt stanu przekroczył limit, sshd chwilowo odrzucił sesję, logowanie się nie udało) zostają ostatnio znani uczniowie, więc „Pomiń komputery z zalogowanym uczniem” nadal pomija taki komputer. Test KOM-04 (AppLogicTests.aMacThatStopsAnsweringHasNoLoggedInStudent) zmieniono celowo: używa teraz komputera wyłączonego („No route to host”) zamiast odmowy połączenia.

### REV-18

**rename ponownie używa indeksu tablicy po zmianie, która może podmienić listę komputerów (scalanie z KON-04)** – P1, Przegląd poprawek, `Sources/CMCRManager/ClassroomModel.swift:608`

W onResult funkcji rename pierwszy zapis model.machines[i].name = … uruchamia machines.didSet → ConfigStore.syncHosts. Jeśli w międzyczasie cmcrctl zmienił hosts.json, syncHosts scala zmiany, a applySavedHosts zastępuje całą tablicę (z wpisami usuniętymi lub dodanymi przez cmcrctl). Kod nadal używa starego indeksu i: odczytuje model.machines[i].address, zapisuje nowy adres do model.machines[i] i na tej podstawie buduje `after`. Jeśli usunięto wpis przed i, adres trafia do wpisu innego Maca, a carryTrust kopiuje klucze dla tego wpisu. Jeśli i był ostatnim indeksem, aplikacja ulega awarii (index out of range). Ten wieloetapowy wzorzec z indeksem jest nowy w tej gałęzi (KOM-07), a scalanie przy zapisie pochodzi z KON-04.

Scenariusz: Nauczyciel uruchamia „Zmień nazwy komputerów” z aktualizacją listy komputerów dla imac10–imac15. W trakcie działania zadania skrypt lub nauczyciel w Terminalu wykonuje `cmcrctl hosts remove imac03`. Gdy kończy się zmiana nazwy imac15, zapis nazwy scala usunięcie, więc indeks i wskazuje poza skróconą tablicę (awaria) albo na inny wpis, który otrzymuje nowy adres .local komputera imac15.

**Status:** naprawione (13bd0ff). Po zmianie nazwy wpis komputera (nazwa i adres .local) powstaje lokalnie i jest zapisywany raz, po id (ClassroomModel.renamed). Scalenie zmian cmcrctl w hosts.json nie wpisuje już adresu do cudzego wpisu ani nie wychodzi poza tablicę.

### REV-32

**Po poprawce CLI-02 `trust` z --yes nadal bez pytania rozszerza się na całą pracownię** – P1, Przegląd poprawek, `Sources/cmcrctl/TrustCommand.swift:16`

Poprawka CLI-02 dodaje do targetsOrAllAtTerminal pytanie „Wykonać na wszystkich? [t/N]” (na które --yes nie odpowiada). trust rezygnuje z niego przez `ask: false`. Komentarz w CLI.swift:192 uzasadnia to tym, że trust „i tak pokazuje każdy klucz i o niego pyta”. Przy --yes to nieprawda: jedynym potwierdzeniem w trust jest `confirm(...)` w TrustCommand.swift:65, a `--yes` je pomija (CLI.confirm wraca od razu, gdy ustawiono yes; Arguments.expect zawsze akceptuje --yes). Zatem trust, czyli polecenie zapisujące do known_hosts, zachowuje dokładnie błąd opisany w CLI-02: skrypt uruchomiony z Terminala dziedziczy TTY, a pominięty argument z komputerem zamienia zaufanie do jednego komputera w zaufanie do każdego nowego i każdego ZMIENIONEGO klucza w pracowni, bez żadnego pytania. Osłabia to ścisłe sprawdzanie kluczy komputerów (hostów), które README wymienia jako cechę bezpieczeństwa, a jedyne polecenie wrażliwe pod względem bezpieczeństwa dostaje słabszą ochronę niż exec/lock.

Scenariusz: zajecia.sh zawiera `cmcrctl trust $NR --yes` i jest uruchamiany jako `bash zajecia.sh` z Terminala przy pustym NR (albo z `#3` bez cudzysłowu). isatty(stdin) zwraca true, więc targetsOrAllAtTerminal(nil, ask: false) zwraca wszystkie komputery i wypisuje tylko „Nie podano komputerów – trust na wszystkich”. Skanowanie znajduje np. imac07 ze zmienionym kluczem (urządzenie podszywające się pod ten komputer), a confirm() wraca od razu z powodu --yes. Każdy nowy i zmieniony klucz trafia do known_hosts, a późniejsze polecenia wysyłają hasło administratora do podszywającego się urządzenia.

**Status:** naprawione (fbac161). trust nie ma już wyjątku ask: false. Bez listy komputerów pyta w terminalu „Wykonać na wszystkich? [t/N]”, a --yes na to pytanie nie odpowiada; bez terminala brak listy jest błędem użycia (kod 2). Dzięki temu `trust $NR --yes` z pustym $NR nie zaufa bez pytania wszystkim nowym kluczom w pracowni. Poprawiono też komentarz w CLI.swift i ogólną pomoc.

### REV-60

**Znacznik końca sesji wyprzedza stdout: sesja zerwana, gdy wynik jeszcze napływa, liczy się jako sukces z uciętym wynikiem** – P1, Przegląd poprawek, `Sources/CMCRCore/SSH.swift:537`

Po REV-53 runWithRetry zamienia kod 255 z ssh na kod ze znacznika końca, a SSH.diagnose uznaje rozpoczętą sesję z kodem 255 za zerwaną tylko wtedy, gdy znacznika nie ma. Założenie, że po znaczniku kod 255 może oznaczać jedynie utratę połączenia przy zamykaniu sesji, jest błędne. Znacznik idzie kanałem stderr (dane rozszerzone SSH), a sshd na wolnym łączu trzyma do okna (ok. 2 MB) stdout polecenia, więc znacznik może przyjść wcześniej niż koniec stdout; w ścieżce zadań oba przekaźniki `cat` działają niezależnie. Jeśli połączenie padnie, zanim dotrze reszta stdout, ssh kończy się kodem 255, a wynik to kod 0 i sukces z uciętym wynikiem – wbrew README (wiersz 178) i pomocy cmcrctl („zerwane połączenie – 1”). Przed REV-53 ten sam przebieg dawał „Połączenie zostało przerwane…” i kod 1.

Scenariusz: cmcrctl z HEAD, prywatny sshd przez ProxyCommand ograniczający przepustowość do ok. 1 MB/s i zrywający połączenie po 5,6 MB: `cmcrctl exec 'head -c 6000000 /dev/zero | tr "\0" x' 1 > out` kończy się kodem 0 bez komunikatu błędu, a out ma 5 550 122 z 6 000 000 bajtów; `__run-job` (ścieżka zadań aplikacji) zwraca exit=0 reach=online.

**Status:** naprawione (ab4d7d2). Kod 255 ssh nie jest już zastępowany kodem ze znacznika końca wrappera: sesja, która ruszyła i skończyła się kodem 255, to błąd połączenia („Połączenie zostało przerwane…”, exec zwraca 1, zadanie jest nieudane), chyba że znacznik też podaje 255 (własny `exit 255` polecenia, REV-53 bez zmian), bo znacznik idzie na stderr i może wyprzedzić koniec stdout, a linię podobną do niego może wypisać samo polecenie. Testy: Tests/CMCRCoreTests/RevR5coreTests.swift, celowo zmieniony test w RevR4coreTests.swift (theReportedCodeWinsOverSshs255 → theReportedCodeCountsOverSshs255OnlyWhenItIs255) oraz e2e Tests/e2e/suites/rev-r5-core.sh (linia znacznika od polecenia i zerwane wspólne połączenie; łącze przez ProxyCommand spowolnione do 1 MB/s i zerwane 128 KiB przed końcem 4 MB wyjścia – exec, zadanie, zadanie z wyjściem w pliku).

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

**Status:** naprawione (fdd24ba). za zgodą właściciela (zmienia to, co widzi uczeń)

### ZAJ-05

**Komunikat o podglądzie uznany za wyświetlony przy zablokowanym/uśpionym ekranie** – P1, Zajęcia, podgląd, `Sources/CMCRCore/ScreenCapture.swift:623`

Panel komunikatu zgłasza CMCR:NOTICE:shown, jeśli NSWindow.isVisible jest true po orderFrontRegardless. isVisible oznacza tylko, że okno jest wstawione na ekran – jest true także, gdy sesja ucznia jest zablokowana (wygaszacz z hasłem, ekran blokady), monitor śpi (np. po „Uśpij ekran” z kafelka) albo ekran zakrywa LockScreen z trybu uwagi. Skrypt zapisuje ucznia jako powiadomionego i zaczyna pobierać obraz; panel znika po 8 s, zanim uczeń odblokuje ekran. Po odblokowaniu uczeń jest oglądany bez komunikatu, wbrew README („dopóki iMac nie potwierdzi, że komunikat jest na ekranie, obraz nie jest pobierany”).

**Status:** naprawione (fdd24ba). za zgodą właściciela (zmienia to, co widzi uczeń)

### APL-05

**README: instalacja „wyłącznie przez https://”, a kod przyjmuje też file://** – P2, Aplikacje, instalacja, aktualizacje, `README.md:170`

isSecureDownloadURL i skrypt installFromURL akceptują file:// (curl --proto '=https,file'), komunikat cmcrctl to wspomina, ale README i podpis w GUI („Tylko adresy https://.”) mówią wyłącznie o https://.

**Status:** naprawione (077b036)

### APL-06

**Zabijanie po PID jako root bez sprawdzenia, czyj to proces** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:278`

killProcess wysyła `asroot kill -KILL PID` bez sprawdzenia użytkownika i programu. W GUI PID pochodzi z listy, która nie odświeża się sama (tylko przy wejściu do działu i po akcjach), więc „Wymuś zamknięcie…” w nieaktualnym wierszu (po wylogowaniu/zamknięciu aplikacji) może trafić w inny proces. `cmcrctl kill PID KOMP` przyjmuje wiele komputerów (all, 1-5), choć PID dotyczy jednego Maca – na pozostałych ginie jako root przypadkowy proces, bez potwierdzenia.

**Status:** naprawione (896bd79). Przed kill skrypt sprawdza właściciela i program procesu (zalogowany użytkownik, ta sama aplikacja); poprawka cytowania w c9dd299.

### APL-07

**Odinstalowanie zabija aplikację wszystkim użytkownikom, zanim sprawdzi, czy da się ją usunąć (Safari zawsze, inne bez Pełnego dostępu do dysku)** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:297`

Lista zainstalowanych zawiera /Applications/Safari.app (chronione SIP dowiązanie do cryptexu), a canUninstall (AppsView.swift:399) przepuszcza każdą ścieżkę z /Applications/. uninstallApp najpierw wysyła SIGKILL do wszystkich procesów „/Safari.app/Contents/MacOS/” (wszyscy użytkownicy), potem `rm -rf` kończy się „Operation not permitted” z mylącą radą o Pełnym dostępie do dysku. Podpowiedź przycisku obiecuje, że aplikacji systemowych nie da się tu odinstalować.

**Status:** naprawione (91c88ac). Dowiązania i aplikacje chronione są odrzucane od razu; pakiet jest najpierw przenoszony obok, więc chroniona aplikacja nie jest zamykana ani częściowo usuwana.

### APL-08

**Po „Anuluj” w trakcie instalacji z .dmg obraz zostaje zamontowany** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:415`

cmcr_install_dmg montuje obraz w /tmp/cmcr-mnt.XXXXXX i odmontowuje go dopiero po pętli instalacji. Anulowanie (SIGTERM/SIGKILL grupy procesów przez cancelScript) w trakcie installer/kopiowania nie odmontowuje obrazu – pułapka EXIT roota sprząta tylko $CMCR_TMP – więc ukryty (-nobrowse) obraz i katalog zostają do restartu iMaca.

**Status:** naprawione (983d4ae). Katalog montowania jest odmontowywany w pułapce EXIT także po anulowaniu.

### APL-09

**„Zainstaluj Homebrew” kończy się sukcesem, gdy pobranie instalatora się nie uda** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:564`

Przy błędzie curl (brak sieci, zablokowany GitHub) podstawienie `$(curl …)` daje pusty tekst, `bash -c ""` zwraca 0 – zadanie ma stan „Gotowe”, choć Homebrew nie zostało zainstalowane (błąd curl widać tylko w treści). To samo w gotowym poleceniu „Instalacja Homebrew” (Models.swift:105-106).

**Status:** naprawione (4b85810). Instalator Homebrew pobierany do pliku z kontrolą kodu curl, na końcu sprawdzane jest brew.

### APL-10

**Instalacja aktualizacji ukrywa błąd softwareupdate --list i zgłasza „Brak aktualizacji”** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRCore/Scripts.swift:638`

installUpdates zapisuje wynik `softwareupdate --list` do pliku, ignoruje kod wyjścia i nigdy go nie wypisuje. Gdy lista się nie uda (brak sieci, serwer Apple niedostępny), LABELS jest puste → „✔ Brak aktualizacji do zainstalowania.” i kod 0; „Zainstaluj aktualizacje”, „Tylko pobierz” i cmcrctl updates install kończą się sukcesem bez instalacji.

**Status:** naprawione (e1c5ab0). „Brak aktualizacji” tylko przy „No new software available”; inaczej odpowiedź softwareupdate i kod 1.

### APL-12

**Adres instalatora i „Otwórz” nie są przycinane – spacja na początku daje błąd „tylko https://”** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/InstallView.swift:96`

„Pobierz i zainstaluj” jest aktywny według isSecureDownloadURL, które przycina białe znaki, ale do skryptu trafia nieprzycięty downloadURL. Wklejony adres ze spacją na początku kończy się na iMacu komunikatem „Instalator można pobrać tylko przez https://”, ze spacją na końcu – błędem curl. Tak samo AppsView.swift:130: `open " https://…"` traktuje tekst jak ścieżkę pliku.

**Status:** naprawione (d4754f9)

### APL-13

**Homebrew: przecinki w nazwach pakietów (jak w podpowiedzi) psują polecenie** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/InstallView.swift:111`

Podpowiedź pola to „np. google-chrome, visual-studio-code”, ale brewArguments dzieli tylko po spacjach: powstaje `brew install --cask 'google-chrome,' 'visual-studio-code'` i brew kończy się błędem nieznanego pakietu.

**Status:** naprawione (d4754f9)

### APL-14

**„Pokaż zainstalowane” (Unity) wypisuje też wszystkie dostępne wydania** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/InstallView.swift:185`

Przycisk uruchamia `Unity Hub -- --headless editors --all`, które pokazuje i zainstalowane edytory, i wszystkie wydania dostępne w Hubie; same zainstalowane daje `editors --installed` (-i). Zainstalowane wersje giną w długiej liście. To samo w gotowym poleceniu „Lista zainstalowanych edytorów” (Models.swift:95-96).

**Status:** naprawione (d4754f9)

### APL-15

**Po instalacji aktualizacji lista i plakietka nadal pokazują je jako dostępne** – P2, Aplikacje, instalacja, aktualizacje, `Sources/CMCRManager/UpdatesView.swift:131`

Po udanym „Zainstaluj aktualizacje” model.updates nie jest czyszczone ani sprawdzane ponownie – wiersz komputera dalej pokazuje pomarańczową ikonę z tytułami, a plakietka „Dostępne aktualizacje na N komputerach” (App.swift:178) zostaje do ręcznego „Sprawdź aktualizacje” lub restartu aplikacji.

**Status:** naprawione (d4754f9)

### APL-16

**cmcrctl quit-app --force zabija aplikacje bez potwierdzenia (GUI pyta)** – P2, Aplikacje, instalacja, aktualizacje, `Sources/cmcrctl/CLI.swift:452`

W aplikacji „Wymuś zamknięcie…” wymaga potwierdzenia („Niezapisana praca uczniów przepadnie”), a `cmcrctl quit-app Nazwa [KOMP] --force` od razu wysyła SIGKILL – w terminalu bez KOMP nawet na całej pracowni. To ta sama utrata pracy co przy wylogowaniu, które w CLI pyta o potwierdzenie.

**Status:** naprawione (c068ca5). quit-app --force pyta o potwierdzenie jak „Wymuś zamknięcie…” (bez terminala wymaga --yes).

### APL-17

**cmcrctl updates install nie pozwala na nową wersję macOS, a komunikat odsyła do przełącznika GUI** – P2, Aplikacje, instalacja, aktualizacje, `Sources/cmcrctl/CLI.swift:540`

GUI ma „Pozwól na nową wersję macOS” (allowMajorUpgrade), a CLI zawsze wywołuje installUpdates z domyślnym false i nie ma takiej opcji (ma ją tylko ukryty _builder --major). Skrypt wypisuje w terminalu „wymaga zaznaczenia „Pozwól na nową wersję macOS””, czego w cmcrctl nie da się zrobić.

**Status:** naprawione (a326b29). updates install --major pozwala na nową wersję macOS po potwierdzeniu; komunikat o pominiętej wersji podpowiada --major.

### CLI-03

**--help poleceń podstawowych pokazuje całą pomoc zamiast pomocy polecenia** – P2, cmcrctl, `Sources/cmcrctl/CLI.swift:119`

Dla exec, status, hosts, power, trust itd. `POLECENIE --help` wypisuje pełny tekst (127 wierszy), choć README obiecuje pomoc tego polecenia, a funkcja commandHelp już umie wyciąć jego wiersze z usage.

**Status:** naprawione (40c5b86). POLECENIE --help i help POLECENIE pokazują pomoc tylko tego polecenia.

### CLI-04

**kill PID przyjmuje wiele komputerów – zabija przypadkowe procesy jako root** – P2, cmcrctl, `Sources/cmcrctl/CLI.swift:474`

PID ma sens tylko na jednym Macu, a `cmcrctl kill PID all` wysyła sudo kill -TERM/-KILL do tego samego numeru na każdym komputerze (na innych to np. loginwindow lub aplikacja ucznia z niezapisaną pracą). GUI zabija proces wyłącznie na komputerze, z którego listy pochodzi PID.

**Status:** naprawione (6a3009a). kill PID wymaga dokładnie jednego komputera (inaczej kod 2, nic nie jest wysyłane).

### CLI-05

**cmcrctl logout zawsze wylogowuje natychmiast (bootout)** – P2, cmcrctl, `Sources/cmcrctl/CLI.swift:576`

Scripts.logoutUser() ma force=true, więc `cmcrctl logout` to odpowiednik „Wyloguj natychmiast…” – sesja ucznia kończy się bez szansy na zapis. Odpowiednika zwykłego „Wyloguj” z GUI (Apple Event, aplikacje pytają o zapis) w CLI nie ma, a pomoc opisuje polecenie tylko jako „wyloguj zalogowanego użytkownika”.

**Status:** naprawione (efa60f7). logout prosi o wylogowanie (jak „Wyloguj”), --force wylogowuje natychmiast; oba pytają o potwierdzenie.

### CLI-06

**report używa ConfigStore.loadHosts() – inna lista i brak ostrzeżenia** – P2, cmcrctl, `Sources/cmcrctl/ClassroomCommands.swift:196`

Wszystkie polecenia CLI czytają listę przez readHostsFile i ostrzegają o problemie, a report woła ConfigStore.loadHosts(): przy częściowo uszkodzonym hosts.json raportuje tylko odczytane wpisy (a przy całkiem uszkodzonym – domyślne imac01–imac15) bez żadnego ostrzeżenia, i przy okazji tworzy kopię .bak.

**Status:** naprawione (eba9ddb). report czyta listę jak inne polecenia (readHostsFile) i ostrzega o nieczytelnym hosts.json.

### CLI-07

**schedule set i ask nie biorą ustawień z classroom.json** – P2, cmcrctl, `Sources/cmcrctl/ClassroomCommands.swift:206`

lock bierze komunikat, tryb i czas z classroom.json, ale `schedule set` bez --on/--off stosuje wbudowany EnergySchedule() (07:45/16:30, uśpienie) oraz autorestart/womp = tak, zamiast harmonogramu i polityki zapisanych w aplikacji (config.schedule, autoRestartAfterPowerLoss, wakeOnLAN). `ask` ma stałe 120 s zamiast questionTimeoutMinutes (linia 86).

**Status:** naprawione (72c5a4d). schedule set bez --on/--off stosuje harmonogram i zasady z aplikacji; ask bierze czas pytania z aplikacji.

### CLI-08

**Nieudany zapis hosts.json zgłaszany jako sukces (kod 0)** – P2, cmcrctl, `Sources/cmcrctl/ConfigCommands.swift:54`

ConfigStore.saveHosts połyka błąd zapisu (tylko NSLog i lastSaveError, którego cmcrctl nigdy nie czyta). hosts add/set/remove/generate, rename --update-list i status (MAC) wypisują sukces i kończą się kodem 0. Przy password set --host hasło trafia do Pęku kluczy, ale flaga „własne hasło” nie zostaje zapisana, więc komputer dalej używa hasła wspólnego mimo komunikatu „Zapisano własne hasło”.

**Status:** naprawione (b5d9416). naprawione razem z KON-03

### CLI-09

**hosts generate przyjmuje przecinek w prefiksie (hosts add go odrzuca)** – P2, cmcrctl, `Sources/cmcrctl/ConfigCommands.swift:106`

Prefiks jest sprawdzany jako .sshPart, który nie zabrania przecinka, a staje się też nazwą komputera. `hosts generate "lab,b" --replace` tworzy nazwy „lab,b01”, których nie da się wskazać nazwą (przecinek dzieli listę w KOMP) i adresy „lab,b01.local”, a `hosts add "lab,b01"` ten sam wpis odrzuca.

**Status:** naprawione (5b05936). hosts generate odrzuca prefiks z przecinkiem, jak hosts add.

### CLI-10

**hosts generate --replace nadpisuje uszkodzony hosts.json bez kopii .bak** – P2, cmcrctl, `Sources/cmcrctl/ConfigCommands.swift:122`

Przy nieczytelnym hosts.json --replace (po potwierdzeniu) zapisuje nową listę bez zachowania oryginału; wpisy, adresy MAC i grupy z uszkodzonego pliku przepadają. README obiecuje, że uszkodzony hosts.json nigdy nie jest nadpisywany (aplikacja zostawia *.bak).

**Status:** naprawione (bff98d9). hosts generate --replace zachowuje kopię nieczytelnego hosts.json (.bak) albo nic nie zmienia.

### CLI-11

**screen-watch: ukryta --notified-user pomija komunikat dla ucznia; brak wpisu w dzienniku** – P2, cmcrctl, `Sources/cmcrctl/ScreenWatch.swift:24`

Opcja testowa --notified-user (używana w screens.sh) jest dostępna w zwykłym cmcrctl: podanie konta ucznia sprawia, że skrypt uznaje go za już powiadomionego (scr_notify: [ "$CONSOLE_USER" = "$CMCR_LAST" ] && return 0) i pobiera obraz bez komunikatu „Administrator rozpoczął podgląd”. Ponadto screen-watch i screenshot w CLI nie zapisują sesji podglądu w dzienniku działań (w CLI nie ma żadnego ConfigStore.log).

**Status:** naprawione (90382b2). --notified-user działa tylko w środowisku testów e2e (za zgodą właściciela – nie da się nim pominąć komunikatu dla ucznia); sesje podglądu trafiają do dziennika działań.

### CLI-12

**app-update --beta podpowiada instalację bez --beta** – P2, cmcrctl, `Sources/cmcrctl/SelfUpdateCommand.swift:102`

Po znalezieniu wersji testowej (--beta) podpowiedź brzmi „Instalacja: cmcrctl app-update install”, a bez --beta UpdateFeed sprawdza tylko /releases/latest (bez wydań testowych), więc to polecenie odpowie „jest aktualny – nie ma czego instalować”.

**Status:** naprawione (a3475a0). app-update check --beta podpowiada instalację z --beta.

### CLI-13

**trust odrzuca -j/--prefix, a nie ma go na liście wyjątków** – P2, cmcrctl, `Sources/cmcrctl/TrustCommand.swift:15`

README i pomoc wymieniają polecenia z KOMP bez -j (wake, hosts remove, lesson, rename, setup, readiness, ask), ale trust [KOMP] także kończy się błędem „Opcja -j nie dotyczy polecenia trust” (kod 2).

**Status:** naprawione (aeb43ea). Pomoc -j wymienia trust wśród poleceń bez -j i --prefix.

### CLI-14

**trust: zmieniony klucz zatwierdzany razem z nowymi (jedno pytanie/--yes)** – P2, cmcrctl, `Sources/cmcrctl/TrustCommand.swift:65`

cmcrctl trust dodaje komputery ze zmienionym kluczem do tej samej listy kandydatów co nowe i potwierdza wszystkie jednym pytaniem; `trust all --yes` w skrypcie cicho ufa kluczowi urządzenia podszywającego się pod wyłączonego iMaca, a następne polecenia wysyłają mu hasło. W GUI zmieniony klucz nigdy nie jest zaznaczony z góry (HostTrustReview.setScan: chosen = state == .new).

**Status:** naprawione (c0eb904). Zmieniony klucz nie jest zatwierdzany razem z nowymi – osobne pytanie, na które --yes nie odpowiada.

### CLI-15

**Polecenia modułów nie ostrzegają o uszkodzonym settings.json** – P2, cmcrctl, `Sources/cmcrctl/main.swift:22`

Ostrzeżenia ConfigStore.loadIssues są wypisywane dopiero w linii 25, po ExtraCommands.run, który dla lesson, collect, rm, setup, readiness, rename, lock, install… kończy proces wcześniej. Przy uszkodzonym settings.json te polecenia cicho używają wartości domyślnych (np. domyślny sharedFolder przy lesson end/collect --clean).

**Status:** naprawione (3515af9). Polecenia modułów ostrzegają o uszkodzonej konfiguracji.

### CLI-16

**Komunikat power-later odsyła do nieistniejącego przycisku „Anuluj zaplanowane”** – P2, cmcrctl, `Sources/CMCRCore/Scripts+Classroom.swift:257`

Po zaplanowaniu restartu, wyłączenia lub uśpienia skrypt wypisuje: Można to anulować przyciskiem „Anuluj zaplanowane”. W GUI przycisk nazywa się „Odwołaj” (wiersz „Zaplanowane na później”, PowerView.swift:167). W `cmcrctl power-later` ten sam tekst trafia do terminala, gdzie właściwym poleceniem jest `cmcrctl power-cancel KOMP`. Nauczyciel nie znajdzie wskazanego przycisku ani polecenia.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (a8123fa). Ten sam tekst co TXT-07, wskazuje przycisk i polecenie cmcrctl.

### CLI-17

**install bierze istniejący lokalnie plik lub folder o nazwie KOMP (np. „all”) za instalator** – P2, cmcrctl, `Sources/cmcrctl/ScriptCommands.swift:33`

Ostatni argument uznaje się za KOMP tylko wtedy, gdy taki plik nie istnieje lokalnie. W katalogu ~/Public/cmcr (konwencja cmcr-helpers; Operations.prepareLocalFolders tworzy tam foldery all i &lt;adres>) polecenie `cmcrctl install Firefox.pkg all` traktuje folder all jako instalator. Cały folder jest wysyłany na każdy iMac, a cmcr_install_dir instaluje jako root każdy znaleziony w nim .app/.pkg/.dmg (z tym samym sprawdzeniem podpisu). KOMP przepada: w terminalu cel to „wszystkie” (tylko z komunikatem na stderr), w skrypcie pojawia się błąd „Podaj komputery” mimo podanego all. Przy KOMP w postaci adresu (imac03.local, taki folder też jest w ~/Public/cmcr) polecenie trafia na wszystkie komputery zamiast na jeden, wbrew README:123.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (a0aa5ef). Ostatni argument install wybierający komputery jest zawsze KOMP; plik o tej nazwie – jako ./nazwa.

### CLI-18

**setup-script po cichu ignoruje --verify i --dry-run, więc wygenerowany plik wprowadza zmiany** – P2, cmcrctl, `Sources/cmcrctl/SetupCommands.swift:42`

`cmcrctl setup-script --help` pokazuje te same opcje co setup, w tym „--verify tylko sprawdź (nic nie zmienia)”. Parser przyjmuje --verify i --dry-run (cl.mode), ale SetupScript.standalone dostaje tylko cl.options. Dlatego `cmcrctl setup-script --verify > sprawdz.sh` daje zwykły skrypt konfigurujący, a `sudo bash sprawdz.sh` przy iMacu zmienia konfigurację: ogranicza SSH do administratorów, instaluje klucz, ustawia Wake-on-LAN i folder ucznia, zamiast tylko sprawdzić. Wbrew README:129 nieużywana opcja nie daje kodu 2.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (f07b2af). naprawione razem z PRZ-03/PRZ-17

### DOD-05

**Brak zgody macOS na sieć lokalną diagnozowany jako „wyłączony” dla całej pracowni** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/SSH.swift:716`

Na macOS 15+ ssh i nc uruchamiane przez aplikację podlegają zgodzie na sieć lokalną przyznanej CMCR Manager. Jeśli użytkownik kliknie „Nie zezwalaj” albo okno zgody jeszcze czeka (pierwsza runda przy starcie), connect() kończy się EHOSTUNREACH: ssh wypisuje „No route to host” (kod 255), a nc kończy się kodem 1. SSH.diagnose klasyfikuje to jako .offline z komunikatem „Komputer nie odpowiada (wyłączony lub poza siecią).”, a nazwy .local jako „Nie można odnaleźć nazwy hosta…”. applyStatus zwiększa offlineStreak i wydłuża odstęp sprawdzania, a portAnswers=false blokuje pełne sprawdzenie. „Pomiń niedostępne” (domyślnie włączone) pomija wszystkie komputery, przyciski działań są nieaktywne z podpowiedzią „Kliknij Odśwież albo wyłącz Pomiń niedostępne”. „Test połączenia”, gotowość i „Sprawdź klucz komputera” też zgłaszają „nie odpowiada”. Krok „Na tym Macu: dostęp do sieci lokalnej” w Gotowości ma na sztywno status „Dotyczy tego Maca (nie iMaców).” i attention=false (ReadinessView.swift:859, :319). Tę przyczynę rozpoznaje tylko Wake-on-LAN (Parsers.swift:82). Nauczyciel widzi 15 wyłączonych iMaców i nic nie wskazuje, że problem leży na jego Macu.

**Status:** naprawione (66eb75e). Komunikaty „No route to host” i nierozwiązanej nazwy .local wskazują sieć tego Maca i zgodę na sieć lokalną.

### DOD-06

**„Network is unreachable” (Mac nauczyciela bez sieci) pokazywany jako surowy angielski błąd ssh** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/SSH.swift:734`

Gdy Mac nauczyciela nie ma połączenia z siecią (Wi‑Fi wyłączone, odłączony kabel), ssh do iMaców o adresach IP kończy się „ssh: connect to host 10.0.5.23 port 22: Network is unreachable” (ENETUNREACH). SSH.diagnose nie ma dla tego gałęzi, więc zwraca (.error, surowy angielski stderr). Każdy komputer ma wtedy stan „Błąd połączenia” z angielskim tekstem, bez wskazówki, że chodzi o sieć tego Maca. Przy domyślnych nazwach .local ten sam stan daje „Nie można odnaleźć nazwy hosta w sieci (Bonjour/.local)” → .offline, czyli cała pracownia jako wyłączona.

**Status:** naprawione (ca477c2). „Network is unreachable” opisane po polsku jako brak sieci na tym Macu.

### DOD-07

**Opóźnione wyłączenie/restart: ostrzeżenie i pominięcie zalogowanych tylko według stanu z chwili planowania** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/Scripts+Classroom.swift:256`

delayedPower pokazuje ostrzeżenie tylko użytkownikowi, który jest na konsoli w chwili planowania (l.236-239). Odłożony proces po N min wykonuje `shutdown -r/-h now` bez żadnego sprawdzenia (l.256). Komputery do pominięcia wybiera aplikacja z zapamiętanego stanu: PowerView.swift:405-410, a przy „Zakończ zajęcia” pendingSkip sprzed odliczania (ClassroomModel.swift:317, 332). Stan odświeża się co 2 min. Scenariusz: o 13:50 nauczyciel planuje „Wyłącz za 15 min” z „Uprzedź zalogowanych uczniów” i „Pomiń komputery z zalogowanym uczniem”, a imac05 stoi wtedy na oknie logowania. O 13:55 uczeń loguje się (albo wraca do sesji w tle) i pracuje. Nie dostaje żadnego komunikatu, a o 14:05 komputer wyłącza się razem z jego niezapisaną pracą. Przy natychmiastowym restarcie jest podobnie: uczeń zalogowany po ostatnim odświeżeniu widnieje jako „nikt nie jest zalogowany” i nie zostaje pominięty. Gdy przy planowaniu nikt nie był zalogowany, wynik nie mówi też, że ostrzeżenia nie pokazano.

**Status:** pominięte – część bez wpływu na ucznia naprawiona (wynik mówi, gdy ostrzeżenia nie było komu pokazać, także sesjom w tle); ponowne ostrzeżenie dla sesji, które pojawią się później, oraz pomijanie zalogowanych tuż przed wyłączeniem zmieniają to, co widzi uczeń – czekają na decyzję właściciela

### DOD-08

**„Zakończ zajęcia”: „Zamknij aplikacje” zgłasza „aplikacje zamknięte”, gdy nikt nie jest na konsoli** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/Scripts+Classroom.swift:380`

Przy pustym CONSOLE_USER quitAllApps kończy z kodem 0 (l.380), a quitApp wypisuje „Brak zalogowanego użytkownika.” i też kończy z kodem 0 (Scripts.swift:218). LessonRunner (LessonRoutine.swift:275, 279-282) uznaje to za sukces, więc tabela zajęć pokazuje „✔ aplikacje zamknięte” albo „✔ zamknięto: Pages, Keynote”. Gdy sesja ucznia działa w tle, jej aplikacje zostają otwarte bez autozapisu. Zbierane są pliki bez ostatnich zmian, a późniejszy krok „Wyłącz” te zmiany odrzuca, choć raport twierdzi, że aplikacje zamknięto. outcome() ma już ścieżkę .skipped dla kodu 3, ale te skrypty z niej nie korzystają.

**Status:** naprawione (80da493, 53196b3). skrypt nie zgłasza fałszywego sukcesu bez ucznia przy ekranie (80da493), a scenariusz zajęć pokazuje wtedy krok jako pominięty (53196b3)

### DOD-09

**Uprzejme „Wyloguj” uznaje sukces, gdy tylko zmieni się właściciel konsoli** – P2, Dodatkowe przeszukanie, `Sources/CMCRCore/Scripts.swift:1026`

Pętla oczekiwania po prośbie do loginwindow uznaje wylogowanie, gdy `stat -f%Su /dev/console` przestaje być równe $WHO. Scenariusz: aplikacja ucznia czeka z pytaniem o zapis (np. za blokadą ekranu) i w tym czasie ktoś klika „Przełącz użytkownika” na ekranie blokady. Konsola przechodzi na okno logowania (root), skrypt wypisuje „✔ Wylogowano student.” i kończy z kodem 0, a sesja dalej działa w tle z otwartym pytaniem. Nauczyciel nie dostaje komunikatu „nadal zalogowany – użyj „Wyloguj natychmiast””.

**Status:** naprawione (977ae3f)

### DOD-10

**Przy ProxyJump/ProxyCommand wynik nil sondy portu blokuje pełne sprawdzenie włączonego iMaca** – P2, Dodatkowe przeszukanie, `Sources/CMCRManager/AppModel.swift:543`

SSH.portAnswers zwraca nil, gdy nie da się tego stwierdzić: połączenie idzie przez ProxyJump/ProxyCommand z „Dodatkowe opcje połączenia” (UI podpowiada „np. ProxyJump=brama”) albo nc zakończył się kodem innym niż 1. AppModel porównuje wynik z `== true`, więc nil traktuje jak „port nie odpowiada”, a finishPortProbe(answered:false) pomija pełne sprawdzenie. Iloma komputer wyłączony przez kilka rund (offlineStreak 3–4, nextQuietProbe +450/+570 s) jest sprawdzany tylko przy wygaśnięciu odstępu. Po włączeniu (np. harmonogram 7:30) wraca na listę dopiero po ok. 8–10 min, a nie „w kolejnym odświeżeniu”, jak obiecuje README.

**Status:** naprawione (51ad629)

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

**Status:** naprawione (b58ee2e)

### KOM-02

**Uszkodzony classroom.json po cichu zastępowany wartościami domyślnymi** – P2, Komputery, zasilanie, `Sources/CMCRCore/Classroom.swift:432`; także: `Sources/CMCRManager/ClassroomModel.swift:142`

ClassroomStore.loadConfig przy błędzie dekodowania zwraca ClassroomConfig() bez kopii .bak i bez ostrzeżenia; pierwsza zmiana (układ kolumn tabeli Komputery, zapytanie o wersję aplikacji, dowolne ustawienie) nadpisuje plik. Tracone są harmonogram zasilania, scenariusze zajęć, komunikat trybu uwagi i układ tabeli. Wystarczy jedna wartość złego typu (ręczna edycja, inna wersja aplikacji), bo init(from:) używa try decodeIfPresent. Dla hosts.json/settings.json aplikacja robi kopię i ostrzega.

**Status:** naprawione (0947713). classroom.json wczytywany jak settings.json: kopia .bak, odzysk poprawnych pól, ostrzeżenie w aplikacji (configIssues).

### KOM-03

**Wyłączone przełączniki autorestart/Wake-on-LAN niczego nie wyłączają na iMacu** – P2, Komputery, zasilanie, `Sources/CMCRCore/Scripts+Classroom.swift:297`

Przy „Zastosuj harmonogram” wyłączony przełącznik „Włącz ponownie po zaniku zasilania” lub „Budź przez sieć (Wake-on-LAN)” generuje tylko „:”, więc pmset autorestart/womp zostaje bez zmian. Nauczyciel wyłącza „Budź przez sieć”, stosuje harmonogram, a wynik pod sekcją nadal pokazuje „Wake-on-LAN: tak”. Przełączniki wyglądają jak stan ustawienia, a działają tylko jako „włącz”. To samo w CLI: schedule set --no-womp/--no-autorestart nic nie wyłącza.

**Status:** naprawione (48a551f). Wyłączone przełączniki autorestart/Wake-on-LAN wyłączają te ustawienia na iMacu (także cmcrctl --no-autorestart/--no-womp).

### KOM-04

**Nieaktualny zalogowany uczeń przy wyłączonych komputerach (lista, panel, potwierdzenia)** – P2, Komputery, zasilanie, `Sources/CMCRManager/App.swift:562`

Przy nieudanym sprawdzeniu applyStatus (AppModel.swift:595) zachowuje stare info z console=…. MachineRow, HostInspector („Zalogowany”, HostInspector.swift:45) oraz ConfirmSheet/PowerConfirmSheet pokazują wtedy np. „jan” przy komputerze niedostępnym lub z błędem, wyszukiwarka znajduje go po nazwie ucznia, a w potwierdzeniu komputer z błędem liczy się jako „z zalogowanym”. Tabela Komputery celowo ukrywa to pole dla niedziałających Maców, więc widoki są sprzeczne.

**Status:** naprawione (6ec783a)

### KOM-05

**⇧⌘O „Zaznacz włączone” i kafelek „Włączone” w trakcie odświeżania kasują zaznaczenie** – P2, Komputery, zasilanie, `Sources/CMCRManager/AppModel+Jobs.swift:101`

selectOnline i kafelek „Włączone” (DashboardView.swift:154) porównują bieżący stan z .online. Jawne odświeżenie (⌘R, start aplikacji, import listy) ustawia wszystkim .checking, więc ⇧⌘O (albo klik w kafelek „0 z 15”) w tym czasie zastępuje zapamiętane zaznaczenie pustym zbiorem. Aplikacja ma settledReachability/knownReachability właśnie na czas ponownego sprawdzania, ale tu ich nie używa.

**Status:** naprawione (28b9b05)

### KOM-06

**Nieudany odczyt nazw/FileVault ignorowany – „sprawdzanie…” bez końca** – P2, Komputery, zasilanie, `Sources/CMCRManager/ClassroomModel.swift:521`

loadNames i checkFileVault (ClassroomModel.swift:466) przy !r.succeeded po prostu wracają. W arkuszu „Zmień nazwy komputerów” włączony komputer z błędem (złe hasło, niezaufany klucz, limit czasu) ma w kolumnie „Obecnie” na stałe „sprawdzanie…”, a w panelu szczegółów po „Sprawdź teraz” FileVault zostaje „nie sprawdzono” bez podania przyczyny.

**Status:** naprawione (e02664e)

### KOM-07

**Po zmianie nazwy z aktualizacją listy komputer traci zaufany klucz SSH** – P2, Komputery, zasilanie, `Sources/CMCRManager/ClassroomModel.swift:548`

rename (i cmcrctl rename --update-list) zmienia adres na &lt;nowa>.local, a known_hosts zna klucz tylko pod starym adresem (HostTrust.knownHostsName = adres). Każde kolejne połączenie jest odrzucane jako „klucz nie jest jeszcze zaufany”, okno zaufania pojawia się dopiero przy następnym odświeżeniu (do 2 min) i każe ponownie potwierdzić odciski wszystkich przemianowanych iMaców; arkusz ostrzega tylko o zmianie adresu.

**Status:** naprawione (dc66c55)

### KOM-08

**Kliknięcie kafelka z liczbą 0 kasuje zaznaczenie komputerów** – P2, Komputery, zasilanie, `Sources/CMCRManager/DashboardView.swift:185`

Akcja kafelka to model.selection = ids także dla pustego zbioru („Wymaga uwagi 0”, „Mało miejsca na dysku 0”). Kafelek nie jest wyłączony, a kliknięcie usuwa przygotowane (i zapamiętywane) zaznaczenie bez możliwości cofnięcia.

**Status:** naprawione (28b9b05)

### KOM-09

**Kliknięcie wiersza w tabeli „Komputery” zastępuje zaznaczenie (cele działań)** – P2, Komputery, zasilanie, `Sources/CMCRManager/DashboardView.swift:228`

Tabela działu Komputery ma selection: $model.selection, więc zwykłe kliknięcie wiersza (np. żeby zobaczyć szczegóły) zamienia zaznaczone pola wyboru na ten jeden komputer, a dwuklik i „Pokaż szczegóły” robią selection = [id]. README opisuje zasadę odwrotną (kliknięcie tylko podświetla), działającą na liście obok. Scenariusz: zaznaczonych 12 komputerów, klik w wiersz imac03 w Komputerach, potem w Zajęciach „Zablokuj ekrany” obejmuje już tylko imac03.

**Status:** naprawione (c0a08b0)

### KOM-10

**Panel szczegółów: „Harmonogram zasilania: nie sprawdzono”, choć stan zawiera harmonogram** – P2, Komputery, zasilanie, `Sources/CMCRManager/HostInspector.swift:138`

Scripts.status przy każdym odświeżeniu zwraca power_schedule, womp i autorestart (HostStatus.powerSchedule/wakeOnLANEnabled/autoRestartEnabled), ale nic w aplikacji tego nie używa. scheduleText bierze wyłącznie classroom.schedules, wypełniane dopiero po „Sprawdź teraz”/„Sprawdź obecny”, więc po uruchomieniu każdy komputer ma „nie sprawdzono” (FileVault ma fallback na status, harmonogram nie).

**Status:** naprawione (e02664e)

### KOM-11

**Błędna odmiana „Sprawdzanie… (N pozostało)”** – P2, Komputery, zasilanie, `Sources/CMCRManager/HostInspector.swift:424`

Podsumowanie arkusza „Wersje aplikacji” skleja liczbę z „pozostało”: dla 1 i 2–4 (22–24…) forma jest błędna („2 pozostało” zamiast „pozostały 2”, „1 pozostało” zamiast „pozostał 1”).

**Status:** naprawione (e02664e)

### KOM-12

**Ostrzeżenie o FileVault przed restartem pomija automatyczne odblokowanie** – P2, Komputery, zasilanie, `Sources/CMCRManager/PowerView.swift:302`

PowerConfirmSheet zawsze pisze, że po restarcie komputer zatrzyma się na ekranie odblokowania i będzie niedostępny, choć Scripts.power(.restart)/delayedPower uzbrajają fdesetup authrestart, gdy zapisane hasło należy do konta FileVault (README). checkFileVault odbiera authrestart=yes/no, ale model zapisuje tylko fv, więc ostrzeżenie straszy także tam, gdzie restart przebiegnie bez interwencji.

**Status:** naprawione (e02664e)

### KOM-13

**cmcrctl status zapisuje MAC trasy domyślnej, cmcrctl wake nie preferuje Ethernetu ani nie czeka** – P2, Komputery, zasilanie, `Sources/cmcrctl/CLI.swift:330`

rememberMACs (komentarz „Like the app”) bierze klucz mac (interfejs trasy domyślnej, np. Wi‑Fi), a aplikacja zapisuje HostStatus.mac = mac_ethernet ?? mac. Na iMacu z Wi‑Fi jako trasą domyślną lista dostaje MAC karty Wi‑Fi, a cmcrctl wake (CLI.swift:616) wysyła pakiety tylko na h.macAddress (bez mac_ethernet ze status-cache i rozgłoszenia podsieci) i nie czeka na odpowiedź – inaczej niż aplikacja i opis Wake-on-LAN w README.

**Status:** naprawione (8a9ab17). status zapisuje MAC karty Ethernet; wake budzi jak aplikacja (--wait czeka na odpowiedź).

### KOM-14

**Eksport CSV nie neutralizuje formuł – dane kontrolowane przez ucznia wykonują się w arkuszu** – P2, Komputery, zasilanie, `Sources/CMCRCore/Classroom.swift:563`

CSV.escape cytuje tylko separator, cudzysłowy i znaki nowej linii; pole zaczynające się od =, +, -, @ trafia do pliku dosłownie. W „Porównaj wersje aplikacji” wersja i kompilacja (HostInspector.swift:445-456) pochodzą z Info.plist pakietów wyszukiwanych także w /Users/$CONSOLE_USER/Applications (Scripts+Classroom.swift:352-366), który kontroluje uczeń. Gdy aplikacji nie ma w /Applications, uczeń może podsunąć np. CFBundleShortVersionString „=HYPERLINK("https://…/?"&A2;"6.0")”. README każe otwierać raporty w Excelu, a ten po otwarciu pliku potraktuje pole jako formułę. Ta sama funkcja eksportuje odpowiedzi uczniów (ClassroomView.swift:742), czyli tekst wpisany przez ucznia wprost. Wpływ ograniczony (na Macu brak DDE, link wymaga kliknięcia), stąd P2.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (bb816ec). Komórki CSV zaczynające się od =, +, -, @, tabulatora lub CR dostają apostrof (eksporty aplikacji i cmcrctl).

### KOM-15

**„Zmień nazwy komputerów” nie wykrywa kolizji z nazwami niezaznaczonych komputerów** – P2, Komputery, zasilanie, `Sources/CMCRManager/HostInspector.swift:282`

Właściwość duplicates sprawdza powtórzenia tylko wśród entries, czyli zaznaczonych komputerów. Scenariusz: zaznaczony imac03, nowa nazwa „imac04” (literówka), imac04 jest na liście, ale niezaznaczony. Arkusz nie ostrzega, „Zmień nazwy (1)” jest aktywny, a macOS rozwiązuje konflikt Bonjour, nadając przemianowanemu Macowi imac04-2. Przy włączonej aktualizacji listy wpis dawnego imac03 dostaje nazwę imac04 i adres imac04.local (ClassroomModel.swift:548-551). Klucz pod imac04.local jest zaufany, więc wszystkie następne działania wysłane do tego wpisu trafiają do prawdziwego imac04. HostValidation pokazuje duplikat tylko w Konfiguracji › Komputery i nie blokuje działań.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (dc66c55)

### KON-07

**Poprawny adres MAC bez separatorów oznaczany jako błędny** – P2, Konfiguracja, `Sources/CMCRCore/HostValidation.swift:27`

isValidMAC wymaga 6 grup rozdzielonych „:” lub „-”, więc „a483e7123456” albo „a483.e712.3456” wpisane w kolumnie Adres MAC dostaje ostrzeżenie „Adres MAC ma zły format”, choć Wake-on-LAN (WakeOnLAN.parseMAC) i cmcrctl (HostEntry.normalizedMAC) go akceptują. Aplikacja nie normalizuje też wpisanego MAC jak CLI.

**Status:** naprawione (138cf29). isValidMAC korzysta z HostEntry.normalizedMAC – adres bez separatorów nie jest oznaczany jako błędny.

### KON-08

**Pusta zmienna CMCR_CONFIG_DIR przenosi dziennik działań w inne miejsce** – P2, Konfiguracja, `Sources/CMCRCore/Store.swift:18`

directory ignoruje pustą CMCR_CONFIG_DIR, a logURL sprawdza tylko != nil. Przy `CMCR_CONFIG_DIR=` (np. niezdefiniowana zmienna w skrypcie) konfiguracja jest domyślna, ale dziennik trafia do ~/Library/Application Support/CMCRManager/actions.log zamiast ~/Library/Logs/CMCRManager/actions.log, więc część działań z cmcrctl nie trafia do dziennika pokazywanego w aplikacji.

**Status:** naprawione (564b738). Katalog konfiguracji i dziennik działań używają wspólnego warunku: CMCR_CONFIG_DIR ustawione i niepuste.

### KON-09

**Baner „Nie zapisano hasła administratora” przy samych hasłach „własnych”** – P2, Konfiguracja, `Sources/CMCRManager/ActivityViews.swift:334`

PasswordBanner.isNeeded sprawdza tylko hasło wspólne. W pracowni, w której każdy iMac ma własne hasło (README: wspólne lub per komputer), pomarańczowy baner na każdej stronie twierdzi, że instalacje i aktualizacje nie zadziałają.

**Status:** naprawione (a45dba1)

### KON-10

**Pozycje menu „Przejdź” i „Konfiguracja…” nic nie robią, gdy główne okno jest zamknięte** – P2, Konfiguracja, `Sources/CMCRManager/App.swift:77`

Polecenia ustawiają tylko model.section. Po zamknięciu okna w trakcie zadań (aplikacja działa dalej) albo gdy na wierzchu jest okno Ustawień lub Ściana ekranów, ⌘1…⌘0, ⇧⌘P i ⌘, nie pokazują głównego okna – zmiana jest niewidoczna.

**Status:** naprawione (7c11459)

### KON-11

**Widoczność kolumny Port nie jest zapamiętywana** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:73`

columns to @State w HostsEditor – po przejściu do innej zakładki lub działu i powrocie kolumna Port znów jest ukryta. Dział Komputery zapisuje układ kolumn (DashboardView.swift:345-349).

**Status:** naprawione (05d88af)

### KON-12

**Kolumna Hasło pokazuje „Własne” także, gdy własnego hasła nie ma w Pęku kluczy** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:184`

Po imporcie listy z innego Maca (usesSharedPassword = false) albo po nieudanym zapisie do Pęku kluczy tabela pokazuje „Własne” z podpowiedzią „Ma własne hasło zapisane w Pęku kluczy”, arkusz pokazuje „Bez zmian”, a Keychain.password(for:) po cichu używa hasła wspólnego (logowanie kończy się „Odmowa dostępu”). `cmcrctl password status` w tej sytuacji pisze „własne hasło – brak”.

**Status:** naprawione (a45dba1)

### KON-13

**Błąd importu listy nie wskazuje miejsca problemu** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:382`

ConfigStore.importHosts używa gołego JSONDecoder, więc okno „Nie można wczytać listy” pokazuje ogólny tekst Foundation (np. „nie mają prawidłowego formatu”), choć HostsFile.decodeHosts/describe daje „brak pola „address” (wpis nr 2)” – tak jak cmcrctl.

**Status:** naprawione (a45dba1)

### KON-14

**Generator listy w aplikacji nie sprawdza prefiksu i domeny (cmcrctl je odrzuca)** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:399`

HostListGeneratorSheet tworzy wpisy z dowolnego prefiksu/domeny (np. „imac ” ze spacją, „-x”, „imac;”) i od razu je dopisuje albo zastępuje nimi listę; problem widać dopiero jako trójkąty w tabeli. `cmcrctl hosts generate` odrzuca takie wartości (ConfigCommands.swift:106 i 110). Tabela nie oznacza też nazw z przecinkiem lub „-” na początku, które CLI odrzuca (HostEntry.problem(.name)).

**Status:** naprawione (05d88af)

### KON-15

**Własne hasła zastąpionych lub usuniętych wpisów zostają w Pęku kluczy** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:511`

„Zastąp całą listę…” (komunikat: „własne hasła obecnych wpisów przepadną”), import listy i `cmcrctl hosts remove` (ConfigCommands.swift:97) usuwają wpisy, ale nie usuwają ich elementów admin-&lt;uuid> z Pęku kluczy – inaczej niż „Usuń z listy…” (askDelete, linia 364). Hasła administratorów zostają na Macu nauczyciela bez możliwości usunięcia ich z aplikacji.

**Status:** naprawione (a45dba1)

### KON-16

**„Utwórz (nowy) klucz” ignoruje klucz ustawiony w Ustawieniach › Połączenie** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:680`

SSHKeys.generate zawsze tworzy ~/.ssh/id_ed25519, a currentPrivateKey używa settings.identityFile, gdy jest ustawiony. Przy własnym kluczu przycisk „Utwórz nowy klucz” tworzy klucz, który nie będzie używany ani rozsyłany; gdy ustawiony plik nie istnieje, sekcja dalej pokazuje „Brak klucza”, „Roześlij klucz” jest wyłączone, a kolejne kliknięcie kończy się „Klucz … już istnieje”.

**Status:** naprawione (8994a24)

### KON-17

**„Roześlij klucz” jest aktywne bez pliku .pub i kończy się samym sygnałem dźwiękowym** – P2, Konfiguracja, `Sources/CMCRManager/SetupView.swift:762`

Przycisk jest wyłączany tylko, gdy brak klucza prywatnego (currentKey == nil). Gdy w Ustawieniach wybrano klucz bez pliku .pub (sekcja pokazuje „(brak pliku .pub)”), AppModel.distributeKey robi NSSound.beep() i nic nie zgłasza. W Przygotowaniu iMaców ta sama akcja jest wyłączana przez managerPublicKey == nil.

**Status:** naprawione (8994a24)

### PLI-06

**Nazwa komputera z „/” psuje „Zbierz prace”** – P2, Pliki, przeglądarka, `Sources/CMCRCore/Operations+Browse.swift:91`

Folder hosta to folder.appendingPathComponent(name) z surowego Machine.name (FilesState.swift:152). Nazwy nie są sprawdzane pod kątem „/”, a aplikacja sama przewiduje takie nazwy (SSH.terminalFileName: „Sala 3/iMac”). Dla „Sala 3/iMac” moveItem do nieistniejącego „Sala 3” kończy się błędem i zebrane pliki z tego komputera są odrzucane.

**Status:** naprawione (d2b2916). Folder komputera w „Zbierz prace” ma bezpieczną nazwę („/” i „:” → „-”).

### PLI-07

**Wysyłanie kończy się błędem, gdy pierwszy element ma nazwę zaczynającą się od „-”** – P2, Pliki, przeglądarka, `Sources/CMCRCore/SSH.swift:735`

Payload.make buduje `tar -cf out -C katalog nazwa …`; po opcji -C bsdtar dalej czyta opcje, więc pierwsza nazwa „-szkic.txt” jest traktowana jak zestaw opcji. Wysyłanie (Pliki, Przeglądarka, konwencja, materiały lekcji) kończy się „Nie udało się spakować plików: tar: Can't specify both -t and -c”.

**Status:** naprawione (5978b7b). tar dostaje elementy jako „./nazwa”, więc nazwy zaczynające się od „-” nie są opcjami.

### PLI-08

**Nieudany chown przy wysyłaniu daje zadanie „Gotowe”** – P2, Pliki, przeglądarka, `Sources/CMCRCore/Scripts.swift:805`

`chown -R "$OWNER" "$item" || echo "⚠︎ …" >&2` nie ustawia RC. Przy właścicielu „Inny…” z literówką (konto nie istnieje) pliki zostają root:wheel w folderze ucznia – przy uprawnieniach „Bez zmian” uczeń nie może ich edytować – a zadanie jest zielone, z ostatnim wierszem `ls -ld` jako podsumowaniem.

**Status:** naprawione (a2d24cd). Nieudana zmiana właściciela lub uprawnień przy wysyłaniu to błąd zadania.

### PLI-09

**„Pokaż listę plików” nie rozwija ~ (folder w katalogu administratora)** – P2, Pliki, przeglądarka, `Sources/CMCRCore/Scripts.swift:935`

Okienko wyboru dla „Przeglądanie i porządki” zamienia katalog administratora na „~…” (tokenize z adminHome). listFolder zamienia tylko {console} i wykonuje `ls -la "$DIR"` – w cudzysłowie ~ nie jest rozwijany, więc na każdym iMacu wynik to „ls: ~/Documents: No such file or directory”. Dotyczy też `cmcrctl ls '~/…' KOMP`. „Wyczyść folder…” dla tej ścieżki kończy się mylącym „Odmowa: podaj pełną ścieżkę (podano: ~/Documents)” (Scripts.swift:874), choć powodem jest ochrona katalogu administratora.

**Status:** naprawione (b16e6df). „Pokaż listę plików” rozwija ~; „Wyczyść folder” podaje właściwy powód odmowy.

### PLI-10

**Tekst o {console}: „komputery … zostaną pominięte”, a zadania kończą się błędem** – P2, Pliki, przeglądarka, `Sources/CMCRManager/FilesView.swift:80`

Przy celu z {console} komputery bez zalogowanego użytkownika nie są pomijane: archiwum jest najpierw wysyłane scp, potem pushFinalize kończy się w cmcr_require_console kodem 3 – zadanie ma stan „Błąd” (czerwone, w „Powtórz na nieudanych”), a nie „Pominięto”.

**Status:** naprawione (94f8df5)

### PLI-11

**Podpisy „&lt;nazwa komputera>” przy folderach konwencji, a folder nosi nazwę adresu** – P2, Pliki, przeglądarka, `Sources/CMCRManager/FilesView.swift:350`

pushConvention, pullFiles i „Przygotuj foldery” używają Machine.folderKey = adres (imac04.local), a podpisy mówią „\(local)/&lt;nazwa komputera>” (l. 350 i 374). Nauczyciel, który utworzy ręcznie ~/Public/cmcr/imac04, dostaje „Brak plików … – nic do wysłania”.

**Status:** naprawione (94f8df5)

### PLI-13

**Przełączenie komputera po błędzie wczytywania przenosi ścieżkę poprzedniego iMaca** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:103`

`carry = listing == nil ? path : portablePath()`. Po błędzie (np. „macOS blokuje dostęp” w /Users/imac01/Desktop administratora albo w folderze zalogowanego „jan”) listing jest nil, więc na imac02 otwierane jest „/Users/imac01/Desktop” zamiast „~/Desktop” i pojawia się „Folder nie istnieje”, wbrew „pokazuje ten sam folder”.

**Status:** naprawione (18ff2c5)

### PLI-14

**Przełącznik „Jako administrator” wraca sam do włączonego** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:196`

Wyłączenie trybu w folderze wymagającym sudo wywołuje reload → accessDenied → autoElevate ustawia `asRoot = true` i wczytuje ponownie. Przełącznika nie da się wyłączyć, a przy błędnym haśle każde kliknięcie to kolejna nieudana próba sudo.

**Status:** naprawione (18ff2c5)

### PLI-15

**Zmiany w Przeglądarce pomijane jako „niedostępny”, choć folder właśnie się wczytał** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:220`

runChange używa runBatch bez includeUnreachable. Przy „Pomiń niedostępne” komputer z nieaktualnym stanem offline (np. tuż po włączeniu) jest pomijany: lista folderu działa (Operations.browse nie pomija), a Nowy folder/Usuń/Wyślij/Pobierz kończą się „Pominięto – komputer był niedostępny przy ostatnim sprawdzeniu” do następnego odświeżenia. Udane browse nie aktualizuje stanu (brak recheckAfterLogin).

**Status:** naprawione (18ff2c5)

### PLI-16

**Wspólny stan activity/notice/lastDownload przy równoległych zmianach w Przeglądarce** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:223`

Przyciski nie są blokowane w trakcie zmiany, a runChange nadpisuje `activity`, zaś zakończenie dowolnej zmiany ustawia `activity = nil` i `notice`. Długie wysyłanie + w międzyczasie usunięcie pliku: po usunięciu pasek pokazuje „Gotowe.” bez wskaźnika, choć wysyłanie trwa; notice z poprzedniego komputera zostaje po przełączeniu hosta. Dwa pobierania naraz współdzielą `lastDownload` (l. 271, 277), więc pierwsze zakończenie pokazuje w Finderze pliki drugiego albo nic.

**Status:** naprawione (18ff2c5)

### PLI-17

**Nazwy plików ucznia trafiają bez zmian do dziennika działań (fałszywe wpisy)** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserModel.swift:250`

Tytuły zmian zawierają surowe entry.name („Zmiana nazwy: \(entry.name) → …”, „Usuń „\(name)” …” l. 259, „Pobierz …” l. 270), a runBatch zapisuje je przez ConfigStore.log bez usuwania znaków nowej linii. Uczeń tworzy plik o nazwie z „\n2026-…Z Podgląd ekranu → imac05” – po usunięciu/pobraniu go przez nauczyciela actions.log zawiera sfałszowany wiersz.

**Status:** naprawione (b58ee2e)

### PLI-18

**„Wyślij pliki do tego folderu…” zastępuje istniejące pliki bez pytania** – P2, Pliki, przeglądarka, `Sources/CMCRManager/RemoteBrowserView.swift:343`

Dla bieżącego folderu startUpload pyta „Zastąpić istniejące elementy?”, ale wysyłanie do podfolderu z menu kontekstowego woła browser.upload bez sprawdzenia. pushFinalize przenosi stary plik do $STAGE/old i na końcu `rm -rf "$STAGE"`, więc praca ucznia o tej samej nazwie w podfolderze jest trwale usuwana bez potwierdzenia.

**Status:** naprawione (18ff2c5)

### PLI-19

**Inne domyślne sudo w CLI: collect bez root dla prywatnych folderów, push z właścicielem administratora** – P2, Pliki, przeglądarka, `Sources/cmcrctl/Browse.swift:136`

GUI (FilesState.useCollectSource) automatycznie zbiera z Biurka/Dokumentów z sudo; `cmcrctl collect all --from "/Users/{student}/Desktop"` (forma z README, bez --root) działa jako administrator i kończy się „Brak dostępu do folderu”. GUI pushConvention wysyła jako root z właścicielem ucznia, a `cmcrctl push` bez --root zostawia pliki z właścicielem administratora (CLI.swift:393).

**Status:** naprawione (ced1c71). collect z folderów prywatnych konta działa jako root; pomoc push opisuje --root.

### PLI-20

**cmcrctl ls ŚCIEŻKA KOMP i clean nie rozwijają {student}; clean kończy się kodem 0 bez czyszczenia** – P2, Pliki, przeglądarka, `Sources/cmcrctl/CLI.swift:431`; także: `Sources/cmcrctl/CLI.swift:424`

collect --from, exists, mkdir, rm, get i rename przepuszczają ścieżkę przez settings.resolve, a CLI.listFolder (l. 423) i clean przekazują ją dosłownie. `cmcrctl clean "/Users/{student}/Desktop" all --yes` trafia w cleanFolder na `[ -d "$DIR" ] || { echo "Brak folderu: $DIR"; exit 0; }` – wypisuje „Brak folderu: /Users/{student}/Desktop”, zwraca 0 i nic nie czyści; GUI dla tej samej ścieżki czyści.

**Status:** naprawione (934a05d). ls ŚCIEŻKA KOMP i clean rozwijają {student}.

### PLI-24

**Kliknięcie innego komputera na liście nie przełącza Przeglądarki plików** – P2, Interfejs, `Sources/CMCRManager/RemoteBrowserView.swift:66`

README:12 obiecuje: „kliknięcie innego komputera na liście pokazuje ten sam folder na nim”. Kliknięcie wiersza tylko go jednak podświetla (prywatny stan highlighted, App.swift:252/285; README:106), a Przeglądarka reaguje wyłącznie na zmianę zaznaczenia i tylko wtedy, gdy zaznaczony jest dokładnie jeden komputer (66-70). Przy zapamiętanym zaznaczeniu kilku komputerów ani kliknięcie, ani zaznaczenie kolejnego nie zmienia przeglądanego komputera; działa tylko pole „Komputer” na pasku lokalizacji. Komentarz w linii 67 jest nieaktualny.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (7924cac). duplikat PLI-23

### PRZ-02

**„Przypomnij później” nie anuluje zleconej instalacji – po pobraniu aplikacja sama się zamyka i instaluje** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/Updater.swift:468`

Gdy uaktualnienie nie jest jeszcze pobrane, przycisk „Zainstaluj i uruchom ponownie” (albo „Spróbuj ponownie” w fazie .failed) ustawia installWhenReady = true i zaczyna pobieranie (l. 355). Tak jest w fazie .available/.failed: pobieranie w tle wyłączone, wcześniej anulowane albo nieudane. Jeśli potem użytkownik wybierze „Przypomnij później” (także Esc, bo to .cancelAction), remindLater() tylko ustawia drzemkę i zamyka okno. installWhenReady zostaje, więc po pobraniu download() wywołuje installAndRelaunch() (l. 330–332). Gdy nie trwają zadania, aplikacja nagle się zamyka i instaluje nową wersję (w /Applications wyskakuje prośba o hasło administratora). To przeczy „Przypomnij później (24 h)” i zasadzie „Bez Twojej zgody nic nie jest instalowane”. Nawet bez zadań przepadają niezapisane rzeczy w oknie, np. rozpisana wiadomość.

**Status:** naprawione (d4754f9)

### PRZ-05

**README podaje macOS 13, a aplikacja wymaga macOS 14** – P2, Przygotowanie iMaców, uaktualnienia, `README.md:34`

Wymagania: „Komputer administratora: macOS 13 lub nowszy”. Package.swift ma platforms: [.macOS(.v14)], scripts/build-app.sh wpisuje LSMinimumSystemVersion 14.0 (l. 84) i buduje x86_64 dla macosx14.0 (l. 42). Na macOS 13 aplikacja się nie uruchomi, a manifest uaktualnień (update-signing.swift bierze LSMinimumSystemVersion) odrzuci takiego Maca.

**Status:** naprawione (077b036)

### PRZ-06

**Kod wyjścia 4 skryptu konfiguracyjnego nieopisany w README** – P2, Przygotowanie iMaców, uaktualnienia, `README.md:52`

README wymienia kody 0–3. Skrypt kończy się kodem 4 na macOS starszym niż 11 (setup/cmcr-imac-setup.sh:197, opisane w nagłówku l. 15 i w SetupScript.ExitCode.unsupportedOS), a opakowanie zdalne zwraca 90 przy nieudanym zapisie skryptu.

**Status:** naprawione (077b036)

### PRZ-07

**README: „Skrypt sam wybiera zgodne SDK” – build-app.sh nie ma już tej logiki** – P2, Przygotowanie iMaców, uaktualnienia, `README.md:96`

Funkcję pick_sdk (wybór SDK przy samych Command Line Tools) usunięto w commicie 07f83d1 („build-app.sh: no SDK fallback needed any more”). Zastąpił ją alias ViewState zamiast makra @State. W scripts/build-app.sh nie ma SDKROOT, xcrun --sdk ani wyboru SDK, a README nadal to obiecuje.

**Status:** naprawione (077b036)

### PRZ-08

**Gotowość: przy pierwszym sudo na koncie błędne hasło pokazuje się jako „błąd: WARNING: Improper use…” zamiast „złe hasło”** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/Scripts+Setup.swift:425`

Klasyfikacja błędu sudo bierze tylko pierwszą niepustą linię stderr. Przed pierwszą udaną autoryzacją sudo w macOS wypisuje ostrzeżenie (lecture) „WARNING: Improper use of the sudo command…”. Stderr nie jest wtedy terminalem, więc ostrzeżenie trafia do readiness.err przed „Sorry, try again”. Scenariusz: nowy iMac i złe zapisane hasło. Kolumna „Hasło administratora” pokazuje „błąd” i „sudo nie działa: WARNING: Improper use of the sudo command could lead to data loss.”. Wyświetla tak przy każdym sprawdzeniu, bo bez udanej autoryzacji ostrzeżenie się nie wyłącza.

**Status:** naprawione (1928153). Złe hasło rozpoznawane w całym stderr sudo, także po ostrzeżeniu „WARNING: Improper use…”.

### PRZ-09

**Instalator jako root dopisuje dziennik do ścieżki w katalogu użytkownika (podąża za dowiązaniem, TOCTOU)** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/SelfUpdate.swift:764`

privilegedAppleScript buduje polecenie `… >> '~/Library/Logs/CMCRManager/update.log' 2>&1 &` uruchamiane przez „do shell script … with administrator privileges”, więc plik dziennika otwiera powłoka roota. openLog() (l. 751) sprawdza zapis jako użytkownik, ale wcześniej. Między tym sprawdzeniem a otwarciem przez roota trwa okno z hasłem administratora (sekundy–minuty). Scenariusz: proces na koncie nauczyciela podmienia w tym czasie update.log na dowiązanie, np. do /etc/sudoers.d/x albo /etc/nologin. Root utworzy ten plik lub dopisze do niego wiersze dziennika, a te zawierają m.in. ścieżkę aplikacji, którą użytkownik może nazwać dowolnie, także z nowym wierszem. Funkcja status() w helperze świadomie unika takich zapisów (zapis jako użytkownik), log() nie. Priorytet P2, bo wymaga wcześniejszego wykonania kodu na koncie nauczyciela; to wzmocnienie obrony.

**Status:** naprawione (bd9c7cb). Pomocnik uaktualnienia (root) nie otwiera dziennika w katalogu użytkownika – zapis idzie przez proces z prawami użytkownika.

### PRZ-10

**cmcrctl: przy błędnych literach dni harmonogramu komunikat „wybierz co najmniej jeden dzień”** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/SetupScript.swift:92`

Jeden komunikat obsługuje pusty i niepoprawny ciąg dni. W CLI `cmcrctl setup 1 --power-schedule "MTWXF 07:30"` lub "mtwrf 07:30" daje „✘ Harmonogram: wybierz co najmniej jeden dzień.” (sprawdzone, kod 2), choć dni podano. Użytkownik terminala nie wie, że chodzi o wielkie litery M T W R F S U.

**Status:** naprawione (5f96b5c). Złe litery dni harmonogramu w cmcrctl mają własny komunikat.

### PRZ-11

**cmcrctl setup ignoruje zapisane opcje i po cichu cofa „Logowanie zdalne tylko kluczem”** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRCore/SetupScript.swift:384`

Aplikacja zapisuje opcje w setup-options.json (SetupOptions.load/save), a CLI zawsze zaczyna od SetupOptions() (SetupCommandLine.options, SetupCommands.swift:30). Opcje dwustanowe (sshKeyOnly, restrictSSH, sshKeepAlive, sharedACL, wakeOnLAN) nie mają stanu „bez zmian”. Scenariusz: iMaki skonfigurowano w aplikacji z „Logowanie zdalne tylko kluczem”, a potem uruchomiono `cmcrctl setup all` zgodnie z README, np. po zmianie wersji skryptu. Plik 050-cmcr-manager.conf zostaje nadpisany bez PasswordAuthentication no, więc logowanie hasłem wraca. Raport mówi tylko „Zapisano … (nowe połączenia SSH od razu go używają)”, a --verify „zapisać ustawienia sshd (keepalive)”. README: cmcrctl „korzysta z tej samej konfiguracji … co aplikacja”.

**Status:** naprawione (35d15b3). cmcrctl setup przejmuje z aplikacji „SSH wyłącznie kluczem”; nowa opcja --no-ssh-key-only.

### PRZ-12

**Ponowne sprawdzenie po naprawie jest pomijane, gdy dla iMaca trwa wcześniejsze sprawdzenie – tabela pokazuje stan sprzed naprawy** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/ReadinessView.swift:23`

ReadinessStore.check odrzuca komputery, które są już w `checking`. Szybka naprawa (applyReadinessFix → onResult → ReadinessStore.shared.check([m]), l. 119) i koniec konfiguracji wołają check. Jeśli dla tego iMaca trwa jeszcze sprawdzenie uruchomione wcześniej („Sprawdź wszystkie”, „Sprawdź ponownie”, automatyczne przy otwarciu – z sudo i próbą osascript do 10 s), nowe sprawdzenie nie startuje. Starszy wynik, odczytany przed naprawą (np. WoL „wyłączony”), nadpisuje komórkę i nic go już nie odświeży. Naprawa wygląda na nieskuteczną. Komórka jest klikalna także w trakcie sprawdzania (tylko przygaszona).

**Status:** naprawione (231a108)

### PRZ-13

**Komórka gotowości proponuje naprawę, która nie może pomóc („brak konta” → Utwórz folder ucznia, „nie admin” → Hasło tego komputera…)** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/ReadinessView.swift:804`

fixButton dopasowuje tylko kolumnę i stan. Folder „brak konta” (nostudent, .problem) dostaje wyróżniony przycisk „Utwórz folder ucznia”. Scripts.createStudentFolder kończy się wtedy zawsze błędem „Na tym iMacu nie ma konta ucznia”, choć sam opis komórki każe utworzyć konto. „Hasło administratora: nie admin” (.problem, l. 800) dostaje „Hasło tego komputera…”, a zmiana hasła nie zrobi z konta administratora.

**Status:** naprawione (231a108)

### PRZ-14

**Aplikacja pozwala uruchomić lub zapisać skrypt z niepoprawnym folderem ucznia (CLI to blokuje)** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/SetupOptionsSheet.swift:122`

sharedFolderProblem trafia tylko do ostrzeżeń (l. 156). Przyciski „Skonfiguruj N komputerów”, „Tylko sprawdź” (l. 109) i „Zapisz…” blokuje wyłącznie validationError(). Scenariusz: folder „/Volumes/Dane/cmcr” albo „~/Public/cmcr” w ustawieniach. Każde zadanie roota kończy się wtedy kodem 2 („folder współdzielony musi leżeć w /Users/&lt;konto>/…”), a zapisany plik odmawia działania dopiero przy iMacu, po przejściu do każdego komputera. `cmcrctl setup` w tej samej sytuacji kończy się od razu kodem 2 (SetupCommands.swift:51).

**Status:** naprawione (231a108)

### PRZ-15

**„Tylko sprawdź”/--dry-run twierdzi „Usunięto prawo zapisu…” i nie liczy tej zmiany** – P2, Przygotowanie iMaców, uaktualnienia, `setup/cmcr-imac-setup.sh:475`

Gdy katalog domowy admina jest zapisywalny dla grupy lub innych (sshd StrictModes odrzuca wtedy klucz), w trybie --verify `run chmod` nic nie robi, ale `detail` i tak wypisuje „Usunięto prawo zapisu grupy/innych z … (wymóg sshd)”. Nie powstaje też wpis „Wymaga zmiany”. Jeśli klucz już jest w authorized_keys, raport „Tylko sprawdź” mówi „Klucz SSH menedżera jest już zainstalowany” i „Do zmiany: 0”, choć logowanie kluczem nie działa. W trybie apply chmod nie jest liczony jako zmiana („Bez zmian – wszystko było już skonfigurowane”).

**Status:** naprawione (9eb1ab5). „Tylko sprawdź” liczy zmianę prawa zapisu katalogu domowego; nieudany chmod to błąd.

### PRZ-16

**Nieudane pmset -a (WoL, uśpienie) i scutil --set są połykane – raport mówi „bez zmian”, kod 0** – P2, Przygotowanie iMaców, uaktualnienia, `setup/cmcr-imac-setup.sh:717`

W pm_set wynik `run pmset -a …` decyduje tylko o dopisaniu do PM_DID. Gdy pmset zwróci błąd, ustawienie nie trafia ani do PM_DID, ani do PM_OK, a krok kończy się „Ustawienia zasilania bez zmian.” (skipped, l. 734) albo listą innych ustawień, z kodem 0. Przykład: nieudane `pmset -a womp 1` wygląda na sukces, choć README mówi „włącza Wake-on-LAN”. Poprawka z d87b260 objęła tylko `pmset repeat`. Podobnie step_hostname (l. 789–791) i su_set: niepowodzenie scutil/defaults daje „changed”.

**Status:** naprawione (e3ce5a1). Nieudane pmset -a, scutil --set i defaults write to błędy kroków, nie „bez zmian”.

### PRZ-18

**„Sprawdź teraz” w oknie Ustawień (i „Sprawdź uaktualnienia…” bez widocznego głównego okna) pokazuje wynik w niewidocznym arkuszu** – P2, Przygotowanie iMaców, uaktualnienia, `Sources/CMCRManager/UpdateViews.swift:357`

checkNow() (Updater.swift:230-234) tylko ustawia isSheetPresented = true, a arkusz uaktualnień jest podpięty wyłącznie do głównego okna (App.swift:129 .updaterUI). Przycisk „Sprawdź teraz” w osobnym oknie Ustawienia › Uaktualnienia (SetupView.swift:1038) nie wysuwa głównego okna, w odróżnieniu od „Pokaż szczegóły…” w tej samej sekcji (UpdateViews.swift:331-332, MainWindow.bringToFront). Scenariusz: nauczyciel klika „Sprawdź teraz” w oknie Ustawień. Arkusz z wynikiem („Masz najnowszą wersję”, błąd sieci albo instalacja) pojawia się na głównym oknie, za oknem Ustawień, więc kliknięcie wygląda na bezskuteczne, a błąd sprawdzania nie jest nigdzie widoczny. Gdy główne okno jest zamknięte, a aplikacja działa dalej (trwają zadania, App.swift:20-22, albo otwarta jest Ściana ekranów), menu „Sprawdź uaktualnienia…” (UpdateViews.swift:11) nic nie pokazuje. isSheetPresented=true ukrywa przy tym baner na pasku bocznym (showsBanner, Updater.swift:144).

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (d4754f9)

### REV-01

**KOM-07 naprawiono tylko w aplikacji: `cmcrctl rename --update-list` nadal gubi zaufany klucz komputera (hosta)** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:304`

AUDIT KOM-07 wymienia zarówno zmianę nazwy w aplikacji, jak i `cmcrctl rename --update-list`. Poprawka dodaje HostTrust.carryTrust (Sources/CMCRCore/HostTrust.swift:244), ale wywołuje ją tylko ClassroomModel.rename (Sources/CMCRManager/ClassroomModel.swift:616). Ścieżka CLI zmienia `hosts[i].address` na `<new>.local` i zapisuje hosts.json, nie przenosząc zaufanych kluczy. known_hosts nadal zna klucz tylko pod starym adresem, więc ścisłe sprawdzanie kluczy hostów odrzuca każde kolejne połączenie z tym iMakiem.

Scenariusz: `cmcrctl rename 7 --name imac07b --update-list` kończy się powodzeniem, a w hosts.json jest teraz imac07b.local. Następne wywołanie `cmcrctl status 7` lub `cmcrctl push …` (a także aplikacja, która po KON-04 ponownie wczytuje hosts.json) kończy się błędem „Klucz SSH tego komputera nie jest jeszcze zaufany – połączenie przerwano przed logowaniem…”. Nauczyciel musi ponownie odczytać i uznać za zaufany odcisk klucza każdego iMaca o zmienionej nazwie – a to dokładnie objaw opisany w KOM-07.

**Status:** naprawione (3e0325d). cmcrctl rename-computer --update-list wywołuje teraz HostTrust.carryTrust, tak jak aplikacja. Pod nowym adresem .local zaufane są te same klucze, więc po zmianie nazwy połączenia nie są odrzucane, a każdy inny klucz pod nowym adresem nadal jest odrzucany. Test e2e: rev-g6-cli.sh, sekcja REV-01.

### REV-02

**ZAD-07: rozpoczęta sesja zerwana przez reset TCP jest zgłaszana jako kod wyjścia 255 samego polecenia** – P2, Przegląd poprawek, `Sources/CMCRCore/SSH.swift:761`

Po zmianie ZAD-07 sesja, która już się rozpoczęła (r.started), jest traktowana jako problem z połączeniem tylko przy komunikatach „timeout, server”/„not responding” oraz „closed by remote host”/„broken pipe”. Gdy nawiązana sesja zostanie zresetowana, OpenSSH 9.x kończy działanie z kodem 255 i wypisuje „Read from remote host &lt;h>: Connection reset by peer” (albo „client_loop: send disconnect: Connection reset by peer” / „Connection reset by &lt;ip> port 22”). Żaden z nich nie pasuje, więc diagnose dochodzi do ostatniego przypadku `(.online, "Polecenie zakończone kodem 255.")`. Przed zmianą ten sam wynik był przynajmniej błędem `.error` z komunikatem ssh. Teraz podsumowanie twierdzi, że polecenie zwróciło 255, i pomija ostrzeżenie „polecenie mogło nadal działać na komputerze” (sessionClosed). Polecenie zadania dalej działa na iMacu, bo zadania z założenia przetrwają utratę połączenia.

Scenariusz: Na imac05 trwa długie zadanie (instalacja pakietu .pkg, softwareupdate). Punkt dostępowy Wi‑Fi lub przełącznik resetuje połączenie TCP, a ssh kończy działanie z kodem 255 i komunikatem „Read from remote host imac05.local: Connection reset by peer”. Wiersz zadania i historia pokazują „Polecenie zakończone kodem 255.”, a Mac pozostaje „online”, jakby instalator zakończył się błędem o kodzie 255. W rzeczywistości zerwało się połączenie, a instalacja nadal trwa, więc nauczyciel może uruchomić ją ponownie na Macu, na którym już działa.

**Status:** naprawione (e3caaf4). Zerwana sesja polecenia, które już ruszyło, jest teraz błędem połączenia z komunikatem „polecenie mogło nadal działać na komputerze” zamiast „Polecenie zakończone kodem 255” na komputerze online. Obejmuje to reset („Read from remote host…”, „send disconnect”, „Connection reset/closed by … port 22”) oraz kod 255 bez żadnego komunikatu po utracie wspólnego połączenia (domyślne ustawienie, sprawdzone w e2e). Własny kod 255 polecenia z komunikatem, np. zagnieżdżonego ssh, nadal jest wynikiem polecenia.

### REV-03

**Poprawka KOM-02 pomija zagnieżdżenia: zła wartość w start/end/schedule nadal po cichu resetuje cały scenariusz lub harmonogram** – P2, Przegląd poprawek, `Sources/CMCRCore/Classroom.swift:357`

ClassroomConfig.init(from:) nadal dekoduje `start`, `end`, `schedule` i `lockMode` przez `try?` (wiersze 357-362). Wartość złego typu wewnątrz jednego z tych obiektów nie powoduje więc niepowodzenia całego dekodowania. Zagnieżdżony obiekt wraca do wartości domyślnych, dekodowanie najwyższego poziomu w wierszu 455 się udaje, więc loadConfig(from:) zwraca `.init(value: c)`. Oznacza to brak kopii .bak, brak odzyskiwania poprawnych danych i brak zgłoszonego problemu. Następnie odroczony zapis w ClassroomModel.scheduleSave wpisuje wartości domyślne z powrotem do classroom.json. KOM-02 i README (wiersz 178) opisują właśnie taką utratę: scenariusze zajęć i harmonogram zasilania zastąpione po cichu z powodu jednej złej wartości. Nowe testy obejmują tylko klucze najwyższego poziomu (lockMessage, autoUnlockMinutes).

Scenariusz: classroom.json zawiera `"start": {"wakeWaitMinutes": 3.5, "materialsFolder": "/Users/n/Lekcja", "apps": "Unity Hub", ...}` – po ręcznej edycji albo dlatego, że inna wersja aplikacji zapisała wartość niebędącą liczbą Int. Inny przypadek to `"schedule": {"onDays": ["M","X"], ...}`. LessonStartConfig (lub EnergySchedule) zgłasza błąd, `try?` zamienia go na wartości domyślne, a aplikacja nie pokazuje ostrzeżenia i nie tworzy kopii .bak. Pierwsza zmiana w aplikacji, np. układu kolumn w panelu głównym, nadpisuje wtedy classroom.json, a scenariusz rozpoczęcia zajęć lub harmonogram zasilania nauczyciela przepada bezpowrotnie.

**Status:** naprawione (6a8db4e). Zła wartość wewnątrz start/end/schedule nie zeruje już całego scenariusza: classroom.json trafia do .bak, poprawne pola zagnieżdżone zostają (rekurencyjny ConfigStore.salvage), a ostrzeżenie podaje ścieżkę, np. „start.wakeWaitMinutes”. Nieznaną wartość wyboru (tryb uwagi, zasilanie po zajęciach, typ zdarzenia harmonogramu) aplikacja przy wczytywaniu pliku też zgłasza i robi kopię .bak, zamiast nadpisać ją po cichu.

### REV-04

**Scalanie KON-04 zawodzi, gdy przy starcie aplikacji nie było hosts.json: pierwszy zapis nadal kasuje listę z cmcrctl** – P2, Przegląd poprawek, `Sources/CMCRCore/Store.swift:44`

loadHosts() wywołuje `remember(...)` tylko wtedy, gdy plik udało się odczytać (`let data = try? Data(contentsOf: hostsURL)`). W świeżej konfiguracji bez hosts.json nic nie zostaje zapamiętane. W efekcie outsideChange(at:) zwraca `.none` w wierszu 91 (`guard let last = ...`) bez względu na to, co zapisze inny program. hostsChangedOutside zwraca wtedy nil, więc aplikacja nigdy nie przejmuje listy z cmcrctl. Następne wywołanie syncHosts w didSet AppModel.machines nadpisuje plik domyślną listą, którą aplikacja ma w pamięci, bez scalania. To właśnie nadpisywanie z KON-04, które według README (wiersz 179) już nie występuje.

Scenariusz: Pierwsze uruchomienie: nie ma hosts.json, a aplikacja pokazuje 15 domyślnych komputerów imacNN, które nie są zapisane, bo nic się nie zmieniło. Nauczyciel uruchamia w Terminalu `cmcrctl hosts add imac16 ...` lub `cmcrctl hosts generate --prefix pc ...`, co tworzy hosts.json, i wraca do aplikacji. syncWithOtherPrograms dostaje nil, a lista nadal zawiera 15 domyślnych komputerów. Następna edycja w Konfiguracja › Komputery albo adres MAC ustalony podczas odświeżania w tle zapisuje listę, którą ma aplikacja, a wpisy z cmcrctl znikają z hosts.json.

**Status:** naprawione (3e0e5bd). loadHosts zapamiętuje listę bazową także wtedy, gdy hosts.json nie istniał (puste dane) albo był uszkodzony (po kopii .bak). Lista utworzona później przez cmcrctl jest więc przejmowana, gdy aplikacja wraca na pierwszy plan, i łączona przy jej pierwszym zapisie.

### REV-05

**Zmieniony poza aplikacją hosts.json, który nie jest już poprawnym JSON-em, zostaje po cichu zastąpiony bez ostrzeżenia** – P2, Przegląd poprawek, `Sources/CMCRCore/Store.swift:103`

Jeśli plik zmienił się od ostatniego odczytu lub zapisu przez aplikację i nie daje się już zdekodować, outsideChange zwraca `.unreadable`. hostsChangedOutside zwraca nil, więc po aktywowaniu aplikacji nic się nie pojawia. syncHosts tworzy wtedy kopię .bak (nie sprawdzając, czy się udała) i nadpisuje plik listą, którą ma aplikacja. Poprawne wpisy nie są odzyskiwane tak jak przy wczytywaniu (Lossy), a żaden problem nie jest zapisywany ani zwracany (problem == nil). README (wiersz 178) obiecuje, że uszkodzony hosts.json zostaje odłożony jako *.bak, jego poprawne wpisy zostają zachowane, a aplikacja pokazuje ostrzeżenie. Ta ścieżka po cichu wykonuje tylko pierwszą z tych rzeczy, a dwie pozostałe pomija.

Scenariusz: Przy otwartej aplikacji nauczyciel wkleja w edytorze tekstu do hosts.json pięć nowych wpisów iMaców i zostawia zbędny przecinek na końcu. Aplikacja nigdy ich nie pokazuje i nie wyświetla żadnego komunikatu po przełączeniu na nią. Przy następnym uzupełnianiu adresów MAC w tle lub dowolnej edycji aplikacja zapisuje hosts.json na nowo ze swoją starą listą. Pięć wpisów zostaje tylko w hosts.json.&lt;date>.bak i nic nie informuje nauczyciela, że jego zmiany zostały odrzucone.

**Status:** naprawione (87aecaa). Uszkodzony hosts.json zmieniony poza aplikacją jest zastępowany tylko po udanej kopii .bak; bez kopii zapis zgłasza problem i nie rusza pliku. Poprawne wpisy z pliku są przejmowane, ale brakujące nie są usuwane, a aplikacja pokazuje ostrzeżenie z nazwą kopii (jednowierszowa zmiana wywołania w AppModel.swift, machines didSet → configIssues). Przecinek na końcu tablicy z przykładu recenzji Foundation na obecnym macOS akceptuje, więc test używa brakującego przecinka.

### REV-06

**Szybka poprawka Udostępniania ekranu pisze „tylko administratorzy”, nie sprawdzając kont już obecnych na liście dostępu** – P2, Przegląd poprawek, `Sources/CMCRCore/Scripts.swift:1292`

enableScreenSharing (AUDIT PRZ-01) tworzy lub przywraca grupę com.apple.access_screensharing i zagnieżdża w niej grupę admin. Potem zawsze wypisuje „Dostęp do Udostępniania ekranu: tylko administratorzy.” i uruchamia usługę. Nigdy nie odczytuje bezpośredniego GroupMembership tej grupy. Przywrócona grupa „-disabled” albo istniejąca lista ACL może nadal zawierać konta bez uprawnień administratora. Funkcja ensure_access_group ze skryptu przygotowującego, którą ta poprawka kopiuje, ostrzega o takich kontach („Uwaga: w $g są też konta bez uprawnień administratora”). Szybka poprawka pomija to ostrzeżenie, więc nauczyciel dostaje informację, że obietnica z README (VNC tylko dla administratorów) jest spełniona, choć nie jest.

Scenariusz: Wcześniej ktoś wybrał na iMacu Udostępnianie ekranu › „Tylko ci użytkownicy” i dodał wspólne konto „student”. Nauczyciel klika szybką poprawkę gotowości „Włącz Udostępnianie ekranu”. Grupa już istnieje, a admin jest w niej zagnieżdżony, więc nic się nie zmienia, ale wynik mówi „tylko administratorzy”, a usługa zostaje włączona. Uczeń, który zna wspólne hasło, może teraz z innego iMaca połączyć się z tym iMakiem przez Udostępnianie ekranu.

**Status:** naprawione (0f60f76). Szybka naprawa „Włącz Udostępnianie ekranu” sprawdza teraz bezpośrednich członków com.apple.access_screensharing (jak ensure_access_group w skrypcie konfiguracji). Konta bez uprawnień administratora są wymieniane w ostrzeżeniu ⚠︎ z drogą w Ustawieniach, a „tylko administratorzy” pojawia się tylko wtedy, gdy takich kont nie ma. Usługa jest włączana jak dotąd i nic nie jest usuwane z listy.

### REV-07

**„Wyloguj” (z pytaniem o zapis) traktuje sesję administratora w tle jak sesję ucznia i zawsze kończy się błędem** – P2, Przegląd poprawek, `Sources/CMCRCore/Scripts.swift:1156`

Ścieżka wymuszona pomija sesję administratora działającą w tle („Pominięto sesję w tle konta administratora”). backgroundSessionCheck w Scripts+Classroom.swift także celowo ją pomija (`$2 != a`). Łagodna ścieżka buduje BG ze wszystkich sesji GUI poza sesją użytkownika konsoli, więc obejmuje $CMCR_ADMIN_USER. Jeśli po „Przełącz użytkownika” konto administratora nadal ma otwartą sesję (to prawdopodobne: README każe uruchomić skrypt przygotowujący przy iMacu po zalogowaniu na konto administratora), łagodne wylogowanie zawsze kończy się kodem wyjścia 1. Po wylogowaniu ucznia wypisuje «⚠︎ W tle działa jeszcze sesja: admin – użyj „Wyloguj natychmiast”». Gdy nikogo nie ma przy ekranie, wypisuje „✘ … w tle działa sesja: admin”. Ta rada jest bezużyteczna: „Wyloguj natychmiast” pomija właśnie tę sesję i zgłasza „Nikt poza administratorem nie był zalogowany”.

Scenariusz: Na iMacu administrator po uruchomieniu skryptu przygotowującego użył „Przełącz użytkownika”, więc loginwindow konta admin nadal działa w tle. Nauczyciel uruchamia Sesja i zasilanie › „Wyloguj (z pytaniem o zapis)”. Uczeń zostaje wylogowany, ale zadanie jest czerwone z komunikatem «W tle działa jeszcze sesja: admin – użyj „Wyloguj natychmiast”». Zastosowanie się do tej rady niczego nie zmienia, a każde kolejne łagodne wylogowanie na tym iMacu kończy się tym samym błędem.

**Status:** naprawione (acb1df3). „Wyloguj (z pytaniem o zapis)” pomija przy liczeniu sesji w tle sesję konta administratora ($CMCR_ADMIN_USER), tak jak „Wyloguj natychmiast” i backgroundSessionCheck. Gdy zostaje tylko ona, zadanie kończy się sukcesem. Sesja ucznia w tle nadal jest zgłaszana kodem 1.

### REV-08

**Sprawdzanie trybu uwagi wykrywa pozostały proces automatycznego odblokowania i blokuje podgląd po zdjęciu blokady** – P2, Przegląd poprawek, `Sources/CMCRCore/ScreenCapture.swift:398`

Nowe sprawdzenie z ZAJ-05 odmawia wyświetlenia komunikatu (więc nic nie jest przechwytywane) zawsze, gdy `pgrep -f CMCR_ATTENTION` znajdzie jakikolwiek proces. lockScreen z autoUnlockMinutes > 0 (domyślnie 30, maksymalnie 240) uruchamia proces pomocniczy z uprawnieniami roota: `exec /bin/bash -c 'sleep N; pkill …' CMCR_ATTENTION-unlock N CMCR_ATTENTION` (Scripts+Classroom.swift:67). Jego argv zawiera ten znacznik przez cały czas oczekiwania. Usuwa go tylko unlockScreen albo upływ samego odliczania. Gdy blokada kończy się inaczej, głównie przez wylogowanie sesji ucznia („Wyloguj natychmiast” albo krok wylogowania w „Zakończ zajęcia”, który zabija nakładkę lub LockScreen), proces pomocniczy dalej czeka. Pętla przechwytywania działa jako root zawsze, gdy przy ekranie jest uczeń, więc może odczytać argumenty procesu pomocniczego i nadal zgłasza „ekran jest zablokowany w trybie uwagi” dla ekranu, który nie jest zablokowany.

Scenariusz: Nauczyciel blokuje ekrany w trybie uwagi (automatyczne odblokowanie po 30 min), a potem kończy zajęcia z wylogowaniem, nie klikając „Odblokuj”. Dziesięć minut później loguje się następna klasa, a nauczyciel otwiera Ścianę ekranów. Każdy taki iMac pokazuje „nie udało się wyświetlić informacji o podglądzie … ekran jest zablokowany w trybie uwagi” zamiast obrazu, dopóki nie upłyną te 30 minut albo dopóki nauczyciel nie „odblokuje” ekranu, który wcale nie jest zablokowany.

**Status:** naprawione (4dd272d). Podgląd uznaje tryb uwagi tylko wtedy, gdy komunikat działa jako użytkownik przy ekranie (pgrep -u $CONSOLE_UID). Nie blokuje go już licznik automatycznego odblokowania (proces roota), który zostaje po wylogowaniu. Kontrola LockScreen i zasada „najpierw komunikat, potem obraz” bez zmian. Atrapa pgrep w Tests/e2e/fakes.sh zachowuje teraz -u.

### REV-09

**Odinstalowanie nadal nie wykrywa działających aplikacji, których nazwa jest zapisana na dysku w postaci rozłożonej (NFD) – APL-03 naprawione w połowie** – P2, Przegląd poprawek, `Sources/CMCRCore/Scripts.swift:341`

cmcr_ps wypisuje teraz ścieżki procesów w postaci złożonej (NFC). Dlatego quitApp i killProcess normalizują szukaną nazwę w Swifcie (precomposedStringWithCanonicalMapping). uninstallApp tworzy NAME ze ścieżki, którą dostaje (`basename "$APP" .app`), a ta ścieżka pochodzi bez zmian z installedApps, czyli ma zapis taki jak na dysku (AppModel.uninstall → Scripts.uninstallApp(path)). Komentarz przy samym cmcr_ps mówi, że nazwy z dysku mogą być zdekomponowane. Dla pakietu zapisanego w NFD (np. skopiowanego przez ditto z obrazu .dmg w HFS+) bajtowe index() w awk nigdy nie dopasuje wyniku ps w NFC. PIDS pozostaje puste, aplikacja nie zostaje zakończona, a jej pakiet jest usuwany w trakcie działania. To jest część AUDIT APL-03 dotycząca odinstalowania („uninstallApp nie zabija takiej aplikacji przed rm”).

Scenariusz: /Applications/Übersicht.app ma na dysku zdekomponowane „Ü” i działa u ucznia. Nauczyciel klika Odinstaluj. NAME jest w NFD, a cmcr_ps wypisuje „/Applications/Übersicht.app/Contents/MacOS/Übersicht” w NFC, więc nic nie zostaje zakończone. Pakiet zostaje usunięty, a zadanie zgłasza „Usunięto”, podczas gdy aplikacja nadal działa z usuniętych plików.

**Status:** naprawione (c54fb72). uninstallApp szuka procesów po nazwie przepuszczonej przez to samo iconv UTF-8-MAC → UTF-8 co wyjście cmcr_ps, więc aplikacja zapisana na dysku w NFD (np. skopiowana z obrazu HFS+) jest zamykana przed usunięciem. Operacje na plikach używają nazwy bez zmian.

### REV-10

**Komunikat błędu cmcrctl odsyła do opcji w aplikacji pod nazwą, której już tam nie ma** – P2, Przegląd poprawek, `Sources/CMCRCore/SetupScript.swift:489`

Commit fdd24ba zmienił nazwę przełącznika w części Przygotowanie iMaców na „Zdalne logowanie tylko kluczem” (SetupOptionsSheet.swift:287, „nazwa jak w macOS”). Nowy komunikat błędu PRZ-11 nadal brzmi „W aplikacji (Przygotowanie iMaców) wybrano SSH wyłącznie z kluczem”. Raport z przygotowania i tekst pomocy też wciąż używają nazwy „SSH wyłącznie z kluczem”. Nauczyciel, który chce wyłączyć tę opcję w aplikacji, szuka etykiety, której tam nie ma.

Scenariusz: Nauczyciel uruchamia `cmcrctl setup 3 --no-key` i dostaje komunikat „W aplikacji (Przygotowanie iMaców) wybrano SSH wyłącznie z kluczem…”. Otwiera Przygotowanie iMaców i nie znajduje opcji o tej nazwie, tylko „Zdalne logowanie tylko kluczem”.

**Status:** naprawione (49a436b). Błąd cmcrctl setup przy --no-key i pomoc opcji --ssh-key-only nazywają przełącznik tak jak aplikacja: „Zdalne logowanie tylko kluczem” (Przygotowanie iMaców). Linie raportu skryptu („SSH wyłącznie z kluczem: włączone/wyłączone”) opisują tylko stan i zostały bez zmian. Trzeba też poprawić README:60 (niżej).

### REV-12

**Poprawka ZAD-10 gubi rzeczywisty błąd „Zbierz prace” i cmcr-pull: podsumowaniem staje się ostatni wiersz „ls -l”** – P2, Przegląd poprawek, `Sources/CMCRManager/AppModel.swift:597`

execute nie dopisuje już stderr wyniku, jeśli wcześniej strumieniowo przesłano jakiekolwiek stderr (job.streamedErrors). Scripts.pullArchive zawsze zapisuje do stderr „remote: ls -l …” i listę zawartości folderu, więc flaga jest ustawiona dla każdego zadania „Zbierz prace” (FilesState.collect → Operations.collect) i cmcr-pull (pullFiles → Operations.pull). Gdy kolejny, lokalny krok się nie powiedzie, jego CommandResult zawiera komunikat, który nigdy nie został przesłany strumieniowo. Przykłady: unpackUntrusted nie może ustawić atrybutu kwarantanny, „Nie można utworzyć …”, „Nie można zapisać w …” albo lokalne tar -x kończy się błędem. Taki komunikat nigdy nie trafia teraz do logu. SSH.diagnose zwraca „Polecenie zakończone kodem -1.”, więc podsumowanie ma postać „&lt;ostatni wiersz zdalnego ls -l> (kod -1)”. Przed zmianą stderr było dopisywane, bo log go nie zawierał, i stawało się lastLine oraz podsumowaniem.

Scenariusz: Pliki › Zbierz prace do folderu na dysku zewnętrznym, który jest pełny lub tylko do odczytu. Zdalny tar kończy się powodzeniem, a Operations.collect zwraca .failure("Nie można zapisać w …: No space left on device"). Zadanie zostaje oznaczone jako „Błąd” z podsumowaniem „-rw-r--r--  1 student  staff  2048 29 paź 10:01 projekt.key (kod -1)”, a ani log, ani historia nie zawierają przyczyny.

**Status:** naprawione (acce0a3). Zadanie zapamiętuje stderr przesłany na bieżąco (końcówkę do 300 000 znaków) i dopisuje do dziennika tylko tę część stderr wyniku, której tam jeszcze nie było. Lokalny błąd po udanym pobraniu w „Zbierz prace” i cmcr-pull (pełny lub tylko do odczytu dysk, tar -x, kwarantanna) trafia więc do dziennika, historii i podsumowania; podwojenia z ZAD-10 nadal nie ma.

### REV-13

**Nowe alerty o błędach i powiadomienie o tunelu są tylko w oknie głównym: działania na Ścianie ekranów zawodzą po cichu** – P2, Przegląd poprawek, `Sources/CMCRManager/AppModel.swift:858`

openScreenSharing zgłasza teraz odmowy i błędy tunelu przez model.notice, a postęp przez showToast. reportFailure zastąpiło sygnał dźwiękowy w ScreenActions.save (ScreenTiles.swift:329, 339). Alert model.notice istnieje tylko w ConfigIssuesAlert, który jest podpięty wyłącznie do głównego WindowGroup (App.swift:135). Nakładka z powiadomieniami (toast) również jest tylko w oknie głównym (App.swift:717). Ściana ekranów i okna ekranu poszczególnych Maców wywołują te funkcje (ScreenTiles.swift:314). WSP-03 wprost dopuszcza pozostawienie otwartej tylko Ściany ekranów, a wtedy użytkownik nic nie widzi. Komunikat (notice) pozostaje też ustawiony i przy następnym otwarciu okna głównego wyskakuje jako nieaktualny alert. Przed zmianami z tej gałęzi „Steruj ekranem” otwierało vnc:// bezpośrednio, a zapis kończył się sygnałem dźwiękowym.

Scenariusz: Okno główne jest zamknięte, a Ściana ekranów jest wyświetlana na projektorze. Nauczyciel klika „Steruj ekranem” na Macu, którego klucz nie jest zaufany, albo próbuje zapisać zrzut ekranu, zanim dotrze pierwsza klatka. Nie pojawia się żadne powiadomienie, alert ani okno Udostępniania ekranu. Nauczyciel klika ponownie, a później, po otwarciu okna głównego, widzi alert, który wygląda na niezwiązany z niczym.

**Status:** naprawione (4dd739e). Ściana ekranów i okna „Podgląd ekranu” pokazują teraz komunikaty z model.notice: błąd lub odmowę tunelu Udostępniania ekranu, „Brak obrazu do zapisania”, nieudany zapis zrzutu i sesję SSH w Terminalu. Komunikat pojawia się w oknie, w którym pracuje nauczyciel, więc nie wyskakuje później w oknie głównym. Gdy te okna są kluczowe, pokazują też powiadomienie „Łączenie z … przez szyfrowany tunel SSH…”. Zmiana w ScreenWall.swift to tylko dodanie modyfikatora; w ScreenWindowView treść objęto Group.

### REV-14

**ZAJ-13: komputery, na których kroki nie miały nic do zrobienia, są zgłaszane jako „pominięto”** – P2, Przegląd poprawek, `Sources/CMCRManager/ClassroomModel.swift:76`

skippedHosts liczy każdego Maca, którego wszystkie kroki mają stan .skipped. LessonRunner używa jednak .skipped także dla kroków, które się wykonały, ale nie miały nic do zrobienia: greet, openApps i quitApps zwracają .skipped("nikt nie jest zalogowany"), logout zwraca .skipped("nikt nie był zalogowany"), a materials przy pustym folderze zwraca .skipped("folder z materiałami jest pusty"). Takie komputery są liczone razem z tymi, które naprawdę zostały pominięte (niedostępne lub pominięte z powodu zalogowanego ucznia), a podsumowanie pokazuje pomarańczowe „Pominięto N komputerów – szczegóły w dziale Zadania.”, choć scenariusz wykonał się wszędzie.

Scenariusz: „Rozpocznij zajęcia” zostaje uruchomione z wyłączonym budzeniem i tylko z krokiem „Wyślij powitanie”, zanim uczniowie się zalogują. Każdy Mac dostaje .skipped("nikt nie jest zalogowany"), a pole wyniku pokazuje ⚠ „Pominięto 15 komputerów – szczegóły w dziale Zadania.” To samo dzieje się w scenariuszu zakończenia zajęć z samym krokiem „Wyloguj”, uruchomionym po wyjściu uczniów.

**Status:** naprawione (e74cbda). Podsumowanie zajęć liczy jako pominięte tylko komputery, którym etap zajęć ustawił „pominięto – …” (niedostępny albo zalogowany uczeń), a komputer z błędem liczy raz, jako problem. Kroki bez pracy („nikt nie jest zalogowany”, pusty folder materiałów) nie dają już „Pominięto N komputerów”, a komputer pominięty dopiero po odliczaniu jest liczony.

### REV-15

**Operacja na poprzednim Macu pokazuje postęp i wynik w Przeglądarce plików nowo wybranego Maca** – P2, Przegląd poprawek, `Sources/CMCRManager/RemoteBrowserModel.swift:268`

setHost czyści notice (PLI-16), ale nie czyści runningChanges ani activity. Zakończenie runChange bezwarunkowo ustawia self.notice, a tylko reload() sprawdza, czy m.id == self.hostID. Po przełączeniu komputera (teraz dzieje się to także automatycznie po kliknięciu innego Maca, PLI-23) pasek stanu nowego Maca pokazuje „Wysyłanie 3 elementy…”, a potem „Gotowe.” albo błąd zmiany wykonanej na starym Macu. Żaden z tych tekstów nie podaje nazwy Maca.

Scenariusz: Nauczyciel wysyła duży folder na imac01 w Przeglądarce plików, po czym klika imac02 na liście komputerów. Przeglądarka pokazuje imac02 z komunikatem „Wysyłanie …”, a później „✘ Brak miejsca na dysku” na pasku stanu. Nauczyciel wnioskuje, że problem dotyczy imac02.

**Status:** naprawione (904b458). Trwające zmiany w Przeglądarce pamiętają komputer. Po przełączeniu na inny komputer pasek stanu poprzedza zmianę i jej wynik nazwą komputera, którego dotyczą („imac01: Wysyłanie …”, „imac01: Brak miejsca na dysku”), a zmiana na pokazanym komputerze ma pierwszeństwo.

### REV-16

**Błąd gramatyczny: „Usuwanie/Pobieranie/Wysyłanie 3 elementy…”** – P2, Przegląd poprawek, `Sources/CMCRManager/RemoteBrowserModel.swift:302`

`what` pochodzi teraz z `Polish.count(n, "element", "elementy", "elementów")`, co jest poprawne w tytułach wymagających biernika („Usuń 3 elementy”, „Pobierz 3 elementy”, „Wyślij 3 elementy”). Ten sam ciąg jest jednak używany ponownie w tekstach postępu (activity), które wymagają dopełniacza: „Usuwanie 3 elementów…”, „Pobieranie 3 elementów…”, „Wysyłanie 3 elementów…”. Dla 2–4 (22–24, …) pasek stanu pokazuje teraz „Usuwanie 3 elementy…”. Wcześniejsza stała forma `\(n) elementów` była tu poprawna. Ten sam wzorzec występuje w wierszach 313/316 i 336/337.

Scenariusz: Zaznacz 3 pliki w Przeglądarce plików i wybierz „Usuń”. Pasek stanu pokazuje „Usuwanie 3 elementy…”.

**Status:** naprawione (bd70255). Teksty paska stanu są w dopełniaczu („Usuwanie/Pobieranie/Wysyłanie 3 elementów…”), a tytuły zadań zostają w bierniku („Usuń 3 elementy”) – RemoteBrowserModel.subject.

### REV-17

**Błąd odmiany w komunikacie po ponowieniu: „Pominięto 1 komputer usunięte z listy”** – P2, Przegląd poprawek, `Sources/CMCRManager/AppModel+Jobs.swift:145`

Nowy komunikat w retry() wstawia po Polish.computers(removed) stały imiesłów w liczbie mnogiej „usunięte”. Jest on poprawny tylko dla 2–4. Dla 1 tekst brzmi „Pominięto 1 komputer usunięte z listy komputerów.” (powinno być „usunięty”), a dla 5 i więcej „Pominięto 5 komputerów usunięte…” (powinno być „usuniętych”).

Scenariusz: Usuń jednego Maca z listy, a następnie kliknij „Powtórz na nieudanych” przy zadaniu, które go obejmowało. Komunikat brzmi „Pominięto 1 komputer usunięte z listy komputerów.”

**Status:** naprawione (2e1f8e1). Imiesłów zgadza się teraz z liczbą (Polish.plural): „Pominięto 1 komputer usunięty / 3 komputery usunięte / 5 komputerów usuniętych z listy komputerów”. Uwaga spoza zakresu: gdy powtórzenie nie wymaga potwierdzenia, ten komunikat od razu zastępuje toast „Uruchomiono … (ponowienie)”.

### REV-19

**DOD-13 nie zabezpieczyło tytułu wysyłania: nazwy folderów z iMaca nadal odwracają tytuł zadania** – P2, Przegląd poprawek, `Sources/CMCRManager/RemoteBrowserModel.swift:337`

Poprawka DOD-13/PLI-17 zabezpiecza (escapuje) nazwy pochodzące z iMaca w tytułach operacji Nowy folder, Zmiana nazwy i Usuń, łącznie z l.path. Tytuł wysyłania `Wyślij \(what) → \(m.name):\(destination)` nadal wstawia `destination` bez zabezpieczenia, a jest to l.path albo l.path z dopisanym subfolder.name — obie wartości są odczytywane z iMaca. Znak bidi override w nazwie folderu utworzonego przez ucznia nadal więc odwraca resztę tytułu w dziale „Zadania”, w komunikacie (Uruchomiono „…”) i w polu z wynikiem. Dziennik działań jest zabezpieczany przez ConfigStore.log, ale tytuł w interfejsie — nie.

Scenariusz: Uczeń tworzy w ~/Public/cmcr folder o nazwie `prace\u{202E}fdp.app`. Nauczyciel wysyła do niego plik poleceniem „Wyślij pliki do tego folderu…”. Tytuł zadania w dziale „Zadania” i komunikat pokazują ścieżkę, a następujący po niej tekst jest odwrócony.

**Status:** naprawione (e079cb2). Tytuł wysyłania pokazuje folder docelowy i nazwy plików z widocznymi znakami kierunku (RemoteBrowserModel.uploadTitle). To samo dotyczy ścieżki w pytaniu „Usunąć …?” i nazw z iMaca w „Zastąpić istniejące elementy?”; podtytuł okna i pasek ścieżki nadal pokazują ścieżkę bez zmian (do osobnej poprawki).

### REV-20

**ZAJ-11: ponowione pytanie nadal pokazuje „pominięto – komputer niedostępny”, a Mac nie jest liczony jako oczekujący** – P2, Przegląd poprawek, `Sources/CMCRManager/ClassroomModel.swift:491`

Pominięte Maki dostają teraz round.errors[id] = „pominięto – …”. Pominięcia z powodu niedostępności można ponawiać (Job.isRetryable), więc „Powtórz na nieudanych” ponownie uruchamia na nich operację pytania. Operacja nigdy nie czyści round.errors[m.id] przy starcie. Gdy pytanie jest już na ekranie ucznia, wiersz nadal pokazuje czerwone „pominięto – komputer niedostępny” (answerText w ClassroomView pokazuje błędy, gdy nie ma odpowiedzi), a QuestionRound.pending pomija tego Maca, więc wskaźnik „czeka na odpowiedź: N” nie uwzględnia go, dopóki uczeń nie odpowie.

Scenariusz: imac04 był wyłączony w chwili zadawania pytania i pokazuje „pominięto – komputer niedostępny”. Po włączeniu imac04 nauczyciel klika „Powtórz na nieudanych”. Pytanie pojawia się na imac04, ale aplikacja przez kilka minut, aż do odpowiedzi ucznia, nadal pokazuje czerwony błąd pominięcia i „czeka na odpowiedź: 0”.

**Status:** naprawione (5d3c45d). Pytanie na danym komputerze najpierw czyści jego wcześniejszy błąd i odpowiedź. Po „Powtórz na nieudanych” wiersz czeka na odpowiedź i jest liczony w „czeka na odpowiedź” zamiast pokazywać „pominięto – komputer niedostępny”.

### REV-21

**Zastępcze źródło z KOM-10 pokazuje harmonogram jako surowy angielski tekst pmset, a pusty jako „nie sprawdzono”** – P2, Przegląd poprawek, `Sources/CMCRManager/HostInspector.swift:141`

Gdy nikt nie kliknął „Sprawdź teraz”, scheduleText korzysta teraz zastępczo z HostStatus.powerSchedule. Ta wartość to surowy wynik `pmset -g sched` połączony separatorem `"; "` (Scripts.swift:56), na przykład „wakepoweron at 7:30AM weekdays only; shutdown at 5:00PM weekdays only”. Widok zamienia jedynie `"; "` na podziały wierszy, więc panel szczegółów pokazuje nieprzetłumaczony angielski tekst. Po kliknięciu „Sprawdź teraz” ten sam harmonogram pojawia się po polsku dzięki PowerScheduleParser/RepeatingPowerEvent.text („Obudź lub włącz o 07:30 – dni robocze (Pn–Pt)”). Skrypt stanu zawsze wypisuje też `power_schedule=`. Dla Maca bez powtarzających się zdarzeń HostStatus.value() zamienia pusty ciąg na nil, więc panel nadal pokazuje „nie sprawdzono”, choć udane sprawdzenie nie znalazło żadnego harmonogramu. To dokładnie ten objaw, który opisuje KOM-10 — teraz tylko na Makach bez harmonogramu.

Scenariusz: Otwórz dział „Komputery” i panel szczegółów (⌥⌘I), a następnie kliknij dostępnego (online) iMaca. Jeśli iMac ma harmonogram pmset, „Harmonogram zasilania” pokazuje po angielsku „wakepoweron at 7:30AM weekdays only”. Kliknięcie „Sprawdź teraz” zmienia to na polskie sformułowanie. Jeśli iMac nie ma harmonogramu, panel pokazuje „nie sprawdzono” zamiast „brak”, choć sprawdzanie stanu co 2 minuty zgłosiło już pusty harmonogram.

**Status:** naprawione (e3e40db). Przed „Sprawdź teraz” harmonogram ze zwykłego sprawdzenia stanu przechodzi przez PowerScheduleParser, więc panel szczegółów pokazuje te same polskie opisy co po sprawdzeniu („Obudź lub włącz o 7:30 – dni robocze (Pn–Pt)”). Pusta wartość power_schedule daje „brak”, a „nie sprawdzono” zostaje tylko wtedy, gdy stan w ogóle nie podał harmonogramu (HostInspector.scheduleText(checked:status:)).

### REV-22

**Nowy alert AppNotice jest tylko w oknie głównym, więc błędy ze Ściany ekranów, podglądów i okna Ustawień są ukryte** – P2, Przegląd poprawek, `Sources/CMCRManager/ConfigIssuesAlert.swift:44`

W ramach UI-14 sygnały dźwiękowe zastąpiono wywołaniami model.reportFailure/reportSaveProblem, które ustawiają model.notice. Jedynym widokiem, który prezentuje model.notice, jest ten modyfikator, zastosowany raz w ContentView, czyli w głównym WindowGroup. Ściana ekranów (scena Window), okna „Podgląd ekranu” i scena Settings nie mają niczego, co by go pokazywało, a mimo to też ustawiają komunikaty: ScreenActions.save w ScreenTiles.swift:329/339 („Brak obrazu do zapisania”, „Nie udało się zapisać zrzutu ekranu”) z menu kafelka „Zapisz zrzut ekranu…”, openTerminal/openScreenSharing z menu kafelków oraz reportSaveProblem, gdy nie da się zapisać ustawienia zmienionego w oknie Ustawień. WSP-03 wprost wspiera pracę z samą Ścianą ekranów (przy zamkniętym oknie głównym). W takim układzie błąd nie jest pokazywany wcale, a nieaktualny alert pojawia się później, po ponownym otwarciu okna głównego. Gdy okno główne jest otwarte na innym ekranie, alert modalny pojawia się tam, a nie w oknie, w którym użytkownik pracuje.

Scenariusz: Zamknij okno główne i zostaw Ścianę ekranów na projektorze (albo zostaw okno główne pod nią). Kliknij kafelek prawym przyciskiem, wybierz „Zapisz zrzut ekranu…” i wskaż wolumin tylko do odczytu. data.write zgłasza błąd, a reportFailure ustawia model.notice, ale na Ścianie ekranów nic się nie pojawia. Użytkownik nie widzi żadnego błędu, a właśnie ten problem miało rozwiązać UI-14. Alert wyskakuje bez kontekstu przy następnym otwarciu okna głównego.

**Status:** naprawione (4dd739e). Alert komunikatu (NoticeAlert) ma każde okno, które może go wywołać: główne, Ściana ekranów, Podgląd ekranu i Ustawienia (w AppSettingsWindow dodano tylko modyfikator). Pokazuje go jedno okno: kluczowe (lub to, do którego należy kluczowy arkusz czy panel zapisu), w drugiej kolejności główne, a w ostateczności pierwsze z przodu. Nie zmienia się ono, dopóki komunikat nie zostanie zamknięty.

### REV-23

**Przejdź › dział wysuwa okno Ustawień zamiast otworzyć zamknięte okno główne (KON-10 nienaprawione w swoim scenariuszu)** – P2, Przegląd poprawek, `Sources/CMCRManager/App.swift:765`

GoToSectionButton wywołuje MainWindow.bringToFront (ScreenTiles.swift:343). Jeśli żadne widoczne okno nie ma identyfikatora z prefiksem „main”, funkcja ta sięga zastępczo po `candidates.first`, czyli dowolne widoczne okno, które może zostać oknem głównym i nie jest oknem ekranu. Od UI-01 ⌘, otwiera okno Ustawień SwiftUI (Settings), czyli NSWindow z paskiem tytułu, które może zostać oknem głównym. KON-10 opisuje właśnie ten przypadek: okno główne zamknięte w trakcie zadań, okno Ustawień na wierzchu. bringToFront wywołuje wtedy makeKeyAndOrderFront na oknie Ustawień i nigdy nie wywołuje openWindow(id: "main"). model.section się zmienia, ale żadne okno tego nie pokazuje.

Scenariusz: Uruchom długie zadanie, zamknij okno główne (aplikacja dalej działa) i naciśnij ⌘, aby otworzyć „Ustawienia”. Następnie wybierz Przejdź › Zadania (albo ⇧⌘, Konfiguracja). Okno Ustawień wysuwa się na wierzch, a okno główne się nie pojawia, więc zmiany działu nie widać. Ten sam mechanizm zastępczy dotyczy kliknięcia powiadomienia (WSP-05), które korzysta z tej samej funkcji.

**Status:** naprawione (6e1b3df). MainWindow.bringToFront przyjmuje już tylko okno z grupy głównej („main…”, widoczne albo w Docku); gdy go nie ma, otwiera nowe zamiast wysuwać okno Ustawień lub ekranu. Poprawka dotyczy też kliknięcia powiadomienia, „Otwórz Konfigurację”, „Sprawdź uaktualnienia…” i „Pokaż szczegóły…”, bez zmian w miejscach wywołania.

### REV-24

**Potwierdzenie „Usuń grupę” używa mianownika po „z”: „Grupa zniknie z 1 komputer / z 3 komputery”** – P2, Przegląd poprawek, `Sources/CMCRManager/App.swift:441`

Nowe potwierdzenie z UI-24 buduje komunikat jako `"Grupa zniknie z \(Polish.computers(members))"`. Polish.computers zwraca formę mianownika z liczebnikiem („1 komputer”, „3 komputery”, „5 komputerów”), a przyimek „z” wymaga dopełniacza. Poprawnie brzmią tylko liczby od 5 wzwyż. Do tego przypadku istnieje już Polish.ofComputers, które daje „1 komputera” / „N komputerów”.

Scenariusz: Utwórz grupę z jednym lub trzema Makami, kliknij prawym przyciskiem jej etykietę i wybierz „Usuń grupę…”. Alert brzmi „Grupa zniknie z 1 komputer.” albo „Grupa zniknie z 3 komputery.”

**Status:** naprawione (53b14f9). W potwierdzeniu „Usuń grupę…” jest teraz Polish.ofComputers, czyli „Grupa zniknie z 1 komputera / z 3 komputerów”. To sama zmiana tekstu, bez testu.

### REV-25

**Stopka generatora: „Przedrostek nazwy pusta wartość”, a pole, którego dotyczy, ma etykietę „Początek nazwy”** – P2, Przegląd poprawek, `Sources/CMCRManager/SetupView.swift:535`

Nowe patternProblem (KON-14) wkleja surowy tekst HostEntry.problem bezpośrednio po rzeczowniku: `"Przedrostek nazwy \(p) – popraw go…"`. Działa to dla komunikatów zaczynających się od czasownika („zawiera spację”), ale dla pustej wartości HostEntry.problem zwraca „pusta wartość”, co daje niegramatyczne zdanie. CLI stawia przed opisem problemu dwukropek (`"\(lead) „\(value)”: \(problem)."`). Komunikat nazywa też pole „Przedrostek nazwy”, podczas gdy pole tekstowe w tym samym arkuszu ma etykietę „Początek nazwy”.

Scenariusz: Otwórz Konfiguracja › Komputery › Utwórz listę… i wyczyść pole „Początek nazwy” (np. żeby wpisać nowy przedrostek). Stopka pokazuje „Przedrostek nazwy pusta wartość – popraw go, zanim utworzysz listę.”, a oba przyciski są nieaktywne.

**Status:** naprawione (ac814f8). Stopka generatora listy przy pustym polu mówi „Wpisz początek nazwy, zanim utworzysz listę.”. Pozostałe problemy nazywają pole jak jego etykieta i stawiają dwukropek przed opisem, jak w cmcrctl, np. „Początek nazwy: zawiera spację – …”, „Domena sieci: … – popraw ją…”.

### REV-26

**Podpowiedź FileVault przy każdym Macu w arkuszu ponownego uruchamiania przeczy nowemu ostrzeżeniu z KOM-12** – P2, Przegląd poprawek, `Sources/CMCRManager/PowerView.swift:393`

W ramach KOM-12 główne ostrzeżenie arkusza (fileVaultWarning) mówi teraz, że gdy da się włączyć jednorazowe odblokowanie (fileVaultAutoUnlock == true), komputery powinny uruchomić się ponownie bez hasła FileVault. Pomarańczowa plakietka „FileVault” w każdym wierszu nadal ma bezwarunkową podpowiedź „Po ponownym uruchomieniu komputer zatrzyma się na ekranie odblokowania dysku.”, czyli dokładnie to fałszywe twierdzenie, które KOM-12 miało usunąć. Ten sam arkusz daje więc dwie sprzeczne odpowiedzi.

Scenariusz: Zaznacz iMaki z włączonym FileVault, dla których checkFileVault zgłasza authrestart=yes, i wybierz „Uruchom ponownie…”. Baner mówi, że powinny uruchomić się ponownie bez hasła FileVault, a podpowiedź po najechaniu na plakietkę FileVault w wierszu mówi, że ten iMac zatrzyma się na ekranie odblokowania dysku.

**Status:** naprawione (48c9182). Podpowiedź oznaczenia „FileVault” przy komputerze w arkuszu restartu zależy teraz od fileVaultAutoUnlock tego komputera. Gdy jednorazowe odblokowanie da się uzbroić tylko na części komputerów, ostrzeżenie podaje, ilu dotyczy każda odpowiedź, więc nie przeczy już podpowiedziom w żadną stronę.

### REV-27

**Instalacja aktualizacji usuwa z widoku aktualizacje, których nie zainstalowano (nowa wersja macOS lub niezalecane)** – P2, Przegląd poprawek, `Sources/CMCRManager/UpdatesView.swift:151`

Poprawka APL-15 wykonuje `model.updates[m.id] = nil` po każdej udanej instalacji, więc wiersz Maca i plakietka na pasku bocznym (App.swift:173) znikają. Jednak Scripts.installUpdates instaluje tylko część listy: bez „Pozwól na nową wersję macOS” pomija przejście na nową główną wersję macOS (wypisuje „↷ Pominięto przejście na nową wersję systemu”), a z „Tylko zalecane aktualizacje” pomija pozycje niezalecane. Gdy nie zostaje nic do zainstalowania, i tak kończy się kodem 0 („✔ Brak aktualizacji do zainstalowania.”). W takich przypadkach aktualizacje są nadal dostępne, ale okno nic już o nich nie mówi. Wcześniej okno pokazywało nieaktualne dane, teraz ukrywa aktualizacje, które wciąż czekają na instalację.

Scenariusz: „Sprawdź aktualizacje” wyświetla dla imac03 „macOS Tahoe 27.1” (przejście na nową główną wersję z 26) i „Safari 20”. Nauczyciel klika „Zainstaluj aktualizacje” przy wyłączonym „Pozwól na nową wersję macOS”. Skrypt instaluje tylko Safari, pomija nową wersję systemu, a zadanie kończy się powodzeniem. Wiersz imac03 i plakietka „Dostępne aktualizacje” znikają, choć nowa wersja macOS jest nadal oferowana. Jeśli przejście na nową wersję było jedyną aktualizacją, nic nie zostaje zainstalowane, a wiersz i plakietka i tak znikają.

**Status:** naprawione (cd7a2e1). Po udanej instalacji z listy i plakietki znikają tylko aktualizacje, których etykiety skrypt wypisał jako „→ etykieta” (UpdateInfo.remaining). Pominięta nowa wersja macOS i dodatkowe aktualizacje przy „Tylko zalecane” zostają. Wpis znika, gdy nic nie zostało albo gdy lista przy instalacji była pusta, a nic nie mogło zostać pominięte. Format wyjścia skryptu pilnuje e2e rev-g5-views.

### REV-28

**WSP-07/UI-14 nienaprawione w wyborze folderu: błędna nazwa w „Nowy folder” nadal daje tylko sygnał dźwiękowy i przepada** – P2, Przegląd poprawek, `Sources/CMCRManager/RemoteFolderPicker.swift:60`

Poprawka dodaje do `namePrompt` wywołanie zwrotne `onInvalid` i przekazuje je tylko z RemoteBrowserPage. Arkusz wyboru folderu (folder docelowy w dziale „Pliki”, źródło dla „Zbierz prace”, folder do wyczyszczenia) nadal wywołuje `.namePrompt($prompt, folder: browser.path) { ... }` bez `onInvalid`, więc wykonuje się stara gałąź z `NSSound.beep()`. Alert się zamyka, wpisana nazwa przepada i nic nie wyjaśnia dlaczego. Okno wyboru nie ma też paska stanu, który pokazałby `browser.notice`. AUDIT WSP-07 i UI-14 wskazują jako źródło błędu wspólne namePrompt (RemoteBrowserComponents.swift:460), więc ta połowa problemu nadal pozostaje nierozwiązana.

Scenariusz: W dziale „Pliki” nauczyciel otwiera „Wybierz folder…”, klika „Nowy folder” i wpisuje „Prace 2024/25”. Kliknięcie „Utwórz” daje tylko sygnał dźwiękowy: alert znika, folder nie powstaje i żaden komunikat nie wyjaśnia, że znak „/” jest niedozwolony.

**Status:** naprawione (dbcf38d). „Nowy folder” i „Zmień nazwę” to jeden wspólny arkusz, także w wyborze folderu (Pliki, Zbierz prace, czyszczenie). Przy złej nazwie arkusz pokazuje powód pod polem, wyłącza przycisk i zostaje otwarty z wpisaną nazwą.

### REV-29

**Znacznik zaznaczenia zasłania pierwszy przycisk paska akcji (pokazywanego po najechaniu) na zaznaczonych kafelkach** – P2, Przegląd poprawek, `Sources/CMCRManager/ScreenTiles.swift:497`

Nowy znacznik UI-19 to `.overlay(alignment: .topLeading)` z `.padding(6)` i bez `.allowsHitTesting(false)`. Jest dodawany po nakładce `ScreenActionBar` pokazywanej po najechaniu kursorem, która również jest wyrównana do lewego górnego rogu i ma `.padding(6)`. Na zaznaczonym kafelku znacznik (ok. 6–24 pt) jest rysowany nad pierwszą ikoną paska („Powiększ”, ok. 12–38 pt, albo „Otwórz w nowym oknie”, gdy nie ma powiększenia). Zasłania część ikony i przechwytuje kliknięcia w tę część. Równoczesny gest kliknięcia kafelka w ScreenGrid przełącza wtedy zaznaczenie, zamiast uruchomić akcję przycisku.

Scenariusz: Na Ścianie ekranów nauczyciel zaznacza imac04 (widać znacznik), najeżdża na niego kursorem i klika lewą połowę ikony „Powiększ”. Kliknięcie trafia w znacznik: ekran nie zostaje powiększony, a zamiast tego kafelek zostaje odznaczony. Ikona jest też wyraźnie zasłonięta przez znacznik.

**Status:** naprawione (7ced267). Znacznik zaznaczenia kafelka znika, gdy wskaźnik jest nad kafelkiem i pokazuje się pasek przycisków; zaznaczenie nadal widać po obramowaniu w kolorze akcentu. Znacznik nigdy nie przyjmuje kliknięć (allowsHitTesting(false)). Sprostowanie do opisu: zwykłe kliknięcie w znacznik nie odznaczało kafelka, tylko zostawiało zaznaczony sam ten kafelek, a przycisk „Powiększ” nie działał.

### REV-30

**Komunikat o nieprawidłowej nazwie ma link „Szczegóły” do nieistniejącego zadania i jest ukryty, gdy trwa inna zmiana** – P2, Przegląd poprawek, `Sources/CMCRManager/RemoteBrowserView.swift:221`

Poprawka WSP-07 zgłasza nieprawidłową nazwę przez `notice = Notice(text: ..., isError: true)` bez batchID. Pasek stanu pokazuje „Szczegóły” przy każdym komunikacie i wywołuje `model.showJobs(notice.batchID)`. Przy nil JobsView zastępczo wybiera najnowszą partię, więc link otwiera niezwiązane działanie (problem UI-17 w nowej postaci). Pasek stanu pokazuje też `browser.activity` w pierwszej kolejności, przed `browser.notice`. Gdy trwa wysyłanie lub usuwanie, komunikat o nieprawidłowej nazwie w ogóle się nie wyświetla, a po zakończeniu tej zmiany runChange nadpisuje komunikat własnym wynikiem. Nauczyciel znów nie dostaje wtedy żadnej informacji zwrotnej, a to jest objaw opisany w WSP-07.

Scenariusz: (1) Nauczyciel wpisuje „Prace 2024/25” w „Nowy folder”. Pasek stanu pokazuje „Nie utworzono ani nie zmieniono nazwy – nazwa nie może zawierać „/”” i oferuje „Szczegóły”. Kliknięcie otwiera Zadania z ostatnim wysyłaniem, które nie ma nic wspólnego z tym komunikatem. (2) Gdy trwa długie „Wysyłanie…”, nauczyciel próbuje użyć tej samej nazwy: widać tylko „Wysyłanie…”, a potem „Gotowe.” zastępuje komunikat, więc przyczyna nigdy nie zostaje pokazana.

**Status:** naprawione (dbcf38d). Złą nazwę wyjaśnia arkusz, a nie pasek stanu, więc wyjaśnienia nie zasłania „Wysyłanie…” ani nie nadpisuje go „Gotowe.”. „Szczegóły” pojawiają się tylko przy komunikacie, który ma zadanie (batchID).

### REV-31

**Potwierdzenie wysyłania do podfolderu mówi o zastąpieniu elementów o tych samych nazwach i usunięciu starych wersji, a foldery są scalane** – P2, Przegląd poprawek, `Sources/CMCRManager/RemoteBrowserView.swift:350`

Nowe pytanie PLI-18 brzmi: „Elementy o tych samych nazwach w folderze „X” zostaną zastąpione, a poprzednie wersje usunięte.” pushFinalize zastępuje tylko pliki i pakiety .app. Istniejący folder o tej samej nazwie jest scalany za pomocą ditto, a jego dotychczasowa zawartość zostaje. Potwierdzenie dla bieżącego folderu (wiersz 387) opisuje to poprawnie: „Pliki o tych samych nazwach zostaną zastąpione, a do folderów zostanie dodana nowa zawartość.” Oba pytania opisują tę samą operację inaczej, a pytanie dla podfolderu błędnie podaje, że foldery zostaną zastąpione.

Scenariusz: Nauczyciel wysyła lokalny folder „Projekt” do podfolderu ucznia „Prace”, w którym jest już „Projekt” z plikami ucznia. Okno dialogowe informuje, że stara wersja zostanie usunięta, ale pliki ucznia zostają, a dodawane są tylko nowe lub zmienione pliki.

**Status:** naprawione (833a4f4). Pytanie przy „Wyślij pliki do tego folderu…” brzmi jak przy bieżącym folderze: pliki o tych samych nazwach są zastępowane, a do folderów o tych samych nazwach dodawana jest nowa zawartość. Test e2e rev-g4-classroom-browser potwierdza to zachowanie.

### REV-33

**rename-computer --name nie wykrywa nazwy innego Maca z listy komputerów (KOM-15 poprawiono tylko w aplikacji)** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:281`

Poprawka KOM-15 (dc66c55) dodaje sprawdzenie, czy nowej nazwy nie używa już inny, niezaznaczony komputer, ale tylko w aplikacji (HostInspector). cmcrctl renameComputers sprawdza wyłącznie isValidLocalHostName. Z opcją --update-list zmienia potem nazwę i adres wpisu na kolidujące. Nowym adresem wpisu staje się nazwa .local innego Maca, którego klucz jest już zaufany, więc kolejne polecenia dla tego wpisu trafiają do tamtego Maca. Tymczasem macOS rozwiązuje konflikt Bonjour, nadając nazwę imac04-2.

Scenariusz: Na liście komputerów są imac03 i imac04. Polecenie z literówką `cmcrctl rename-computer 3 --name imac04 --update-list --yes` zmienia nazwę imac03 (macOS nadaje mu imac04-2.local). hosts.json ma teraz dwa wpisy „imac04” / imac04.local. `cmcrctl lock 3` albo `power shutdown 3` działa teraz na prawdziwym imac04, którego klucz jest zaufany, bez żadnego ostrzeżenia.

**Status:** naprawione (62d94d5). rename-computer odrzuca nazwę sieciową, którą ma już inny komputer z listy (z jego adresu .local lub z nazwy na liście), oraz nazwę, która powtarza się wśród zmienianych komputerów. To błąd użycia (kod 2) sprawdzany przed potwierdzeniem, także z --dry-run, więc nic nie zostaje zmienione. Reguła jest ta sama co w oknie aplikacji „Zmień nazwy komputerów” (KOM-15).

### REV-34

**readiness nadal po cichu akceptuje --no-key, --verify i --dry-run (niepełna poprawka PRZ-17)** – P2, Przegląd poprawek, `Sources/cmcrctl/SetupCommands.swift:48`

PRZ-17 opisuje, że readiness po cichu akceptuje opcje polecenia setup, a README:129 wymaga kodu wyjścia 2 dla opcji, której polecenie nie używa. Poprawka odrzuca tylko cl.configurationFlags, a SetupScript.swift:438 pomija na tej liście --no-key, --verify i --dry-run. readiness używa tylko cl.publicKey i cl.positional, więc te trzy opcje są nadal akceptowane i ignorowane. Co gorsza, gdy aplikacja zapisała „SSH wyłącznie z kluczem”, SetupCommandLine zgłasza błąd przy --no-key i każe dodać --no-ssh-key-only, które readiness z kolei odrzuca jako opcję tylko dla setup. Użytkownik krąży między dwoma sprzecznymi komunikatami o błędzie.

Scenariusz: `cmcrctl readiness all --verify` albo `cmcrctl readiness 3 --no-key` wykonuje sprawdzenie i kończy się kodem 0 zamiast 2. Gdy w aplikacji zapisano sshKeyOnly, `cmcrctl readiness 3 --no-key` kończy się błędem „…usuń --no-key albo dodaj --no-ssh-key-only”. Zastosowanie się do tej rady przez `cmcrctl readiness 3 --no-key --no-ssh-key-only` znów kończy się błędem „opcja --no-ssh-key-only dotyczy polecenia setup”.

**Status:** naprawione (cbf8d79). readiness odrzuca teraz także --no-key, --verify i --dry-run (kod 2, nic nie jest uruchamiane). Opcji zapisanych w aplikacji nie wczytuje, więc przy „SSH wyłącznie z kluczem” już nie radzi dodać --no-ssh-key-only. --pubkey i --pubkey-file działają jak wcześniej.

### REV-35

**Ctrl-C przy -j > 1 kończy program z wnętrza zadania, więc zbuforowane wyjście innych Maców, w tym wynik zatrzymania, nie jest wypisywane** – P2, Przegląd poprawek, `Sources/cmcrctl/Interrupt.swift:83`

finish() wywołuje exitWhenStopped(), a zadanie, które kończy się jako ostatnie, wywołuje exit(128+sig) z wnętrza swojego bloku w runHosts. Dzieje się to przed io.close()/sink.finish(i). OrderedOutput przekazuje na bieżąco tylko wyjście pierwszego komputera w kolejce, a wyjście wszystkich pozostałych buforuje do finish(). Wiersze „▸ &lt;wynik>”, które akcja anulowania w SSH.run oraz finish() zapisują przez io.stream, giną więc dla wszystkich komputerów poza pierwszym. Te wiersze mówią „Zatrzymano polecenie na komputerze” albo „Nie udało się połączyć, aby zatrzymać polecenie – może ono nadal działać”. To samo dotyczy wierszy raportu „✘ … Anulowano” dla poszczególnych komputerów. Jest też wyścig: finish() odczytuje `stop = interruptedBy` przed usunięciem zadania z `active`, w osobnej sekcji krytycznej. Jeśli sygnał nadejdzie między tymi krokami, to zadanie kończy się normalnie, choć received() już anulowało pozostałe zadania. Te zadania czekają wtedy bez końca w exitWhenStopped na exit, który nigdy nie nastąpi. Skutkiem jest zawieszenie programu, jeśli nie zostały już komputery do uruchomienia, albo kod wyjścia 0 zamiast 130, gdy było to jedyne zadanie.

Scenariusz: `cmcrctl exec "sleep 100; shutdown -r now" 1-8 -j 8 --root --yes`, a potem Ctrl-C. Przed wyjściem z kodem 130 pojawia się tylko „▸ Zatrzymano polecenie na komputerze.” dla imac01. Wynik dla imac02–imac08 zostaje w OrderedOutput i jest porzucany przez exit(), nawet jeśli np. zatrzymanie na imac05 się nie powiodło i jego restart wciąż czeka na wykonanie. Nauczyciel widzi tylko „Przerywanie…” i nie wie, które iMaki mogą jeszcze się zrestartować.

**Status:** naprawione (cdf30fe). Po Ctrl-C przerwane zadania nie wywołują już exit() od środka, tylko zwracają anulowany wynik. Dzięki temu także przy -j N widać wynik każdego komputera, w kolejności listy: wiersz „▸ …” o tym, jak poszło zatrzymanie, i „✘ … Anulowano.”. Kolejnych komputerów cmcrctl już nie uruchamia, tylko je wymienia („▸ Nie uruchomiono polecenia na 1 komputerze: imac02.”), a main.swift kończy kodem 128 + sygnał. Rejestracja zadania i odczyt sygnału są teraz w jednej sekcji krytycznej, więc żadne zadanie nie czeka bez końca.

### REV-36

**Pomoc i README obiecują, że Ctrl-C zatrzymuje polecenie na iMakach, ale rm, install, push, collect, lesson, rename-computer, setup i ask nadal działają bez rejestracji** – P2, Przegląd poprawek, `Sources/cmcrctl/CLI.swift:88`

ZAD-13 poprawiono tylko dla runScript i runEach – dwóch ścieżek przechodzących przez Interruption.shared.run. Wszystkie inne polecenia wprowadzające zmiany nadal wywołują SSH.run, Operations.* albo LessonRunner.run bez ProcessHandle. Dotyczy to rm/mkdir/rename (Browse.swift:81-106), collect --clean i get (Browse.swift:120,145), install (ScriptCommands.swift:67, Operations.install), push/pull (CLI.swift:447,467), lesson (ClassroomCommands.swift:381), rename-computer (:316), ask (:266) i setup apply (SetupCommands.swift:82). Te skrypty nie dostają identyfikatora zadania ani przekaźników (relays) i nie jest dla nich instalowana żadna obsługa Interruption. Ctrl-C nadal zabija tylko lokalne cmcrctl/ssh, a wrapper ignoruje HUP, więc zdalna część skryptu działa dalej albo ginie w połowie przy następnym zapisie (SIGPIPE). Utrata połączenia przerywa ją w ten sam sposób. Mimo to nowy tekst pomocy (CLI.swift:88), README:129 i Interrupt.swift:6 („Every remote command runs as a registered job”) twierdzą, że Ctrl-C zatrzymuje polecenie na iMakach – dla wszystkich poleceń.

Scenariusz: `cmcrctl install Xcode.pkg all` (albo `cmcrctl rm all "/Users/{student}/Desktop/*" --yes`, albo `cmcrctl lesson end all --yes`), a potem Ctrl-C. cmcrctl kończy się kodem 130 zgodnie z dokumentacją, ale na przetwarzanym iMacu (lub iMakach) instalator nadal działa jako root albo usuwanie, wylogowywanie i czyszczenie trwają dalej. Ewentualnie zdalna część skryptu ginie w połowie przy następnym zapisie. Nauczyciel dostał informację, że polecenie zostało tam zatrzymane.

**Status:** naprawione (e0209b0). Wszystkie polecenia, które coś zmieniają na iMacach, działają teraz jako zarejestrowane zadania, więc Ctrl-C zatrzymuje je także na iMacach. Dotyczy to też rm, mkdir, rename, get, collect, install, push, pull, ask, rename-computer, lesson i setup: pojedyncze skrypty idą przez Interruption.run, a Operations, Payload.make i LessonRunner dostają uchwyt z Interruption.job. Pomoc (kody wyjścia) i opis w Interrupt.swift wymieniają dokładnie te polecenia. Uwaga: ask po Ctrl-C zamyka okna pytań u uczniów – tak jak „Przerwij” w aplikacji.

### REV-37

**Ostrzeżenie CLI-15 pojawia się przed wczytaniem classroom.json – uszkodzony plik po cichu daje wartości domyślne w schedule set, ask, lock i lesson** – P2, Przegląd poprawek, `Sources/cmcrctl/main.swift:25`

main.swift wypisuje ConfigStore.loadIssues zaraz po wczytaniu settings.json. ClassroomStore.loadConfig(), którego problemy według dokumentacji są zawarte w ConfigStore.loadIssues i ClassroomStore.loadIssue, uruchamia się dopiero później, wewnątrz ClassroomCLI (ClassroomCommands.swift:61, 92, 108, 334). Później nic nie wypisuje zgłoszonego przez niego problemu; grep nie znajduje w cmcrctl żadnego użycia ClassroomStore.loadIssue. Od poprawki CLI-07 `schedule set` (bez --on/--off) i `ask` (bez --timeout) biorą wartości z classroom.json. Obcięty lub uszkodzony plik jest więc bez ostrzeżenia zastępowany wartościami domyślnymi ClassroomConfig(). Aplikacja pokazuje ten sam problem wśród problemów z konfiguracją.

Scenariusz: classroom.json jest uszkodzony (np. obcięty podczas synchronizacji). `cmcrctl schedule set all --yes` stosuje w całej pracowni wbudowany harmonogram usypiania 07:45/16:30 oraz domyślne zasady automatycznego restartu i Wake-on-LAN, zamiast harmonogramu zapisanego w aplikacji. `cmcrctl ask "…" all` używa domyślnego limitu czasu. Nie pojawia się żaden wiersz ⚠ – to dokładnie to ciche przejście na wartości domyślne, które miały usunąć CLI-07 i CLI-15.

**Status:** naprawione (c13a5e2). lock, ask, schedule set i lesson czytają classroom.json przez ClassroomCLI.loadConfig. Przy uszkodzonym pliku ta funkcja wypisuje „⚠ …” przed wykonaniem polecenia, więc wartości domyślne nie wchodzą już po cichu. Pozostałe polecenia nie czytają tego pliku, więc nie ma przy nich ostrzeżeń ani kopii .bak.

### REV-38

**Podpowiedź logout proponuje --force przy każdym błędzie, także dla niedostępnego Maca, i pojawia się przed komunikatem o błędzie** – P2, Przegląd poprawek, `Sources/cmcrctl/CLI.swift:678`

Domknięcie note zwraca podpowiedź „--force” zawsze, gdy `!r.succeeded`. Obejmuje to wyłączonego Maca, odrzucony klucz komputera (hosta), złe hasło i przekroczenie czasu – wszystkie przypadki, w których łagodne wylogowanie w ogóle nie dotarło do loginwindow. runScript wypisuje też note przed io.report(r), więc propozycja pojawia się przed właściwą przyczyną. Podpowiedź ma sens tylko wtedy, gdy sam skrypt się uruchomił i zgłosił, że łagodne wylogowanie zostało odrzucone lub się nie zakończyło (exit 1 po starcie).

Scenariusz: `cmcrctl logout 4 --yes` przy uśpionym imac04 wypisuje „  (cmcrctl logout imac04 --force – wylogowanie natychmiastowe, niezapisane dane przepadną)”, a po nim „✘ imac04: … nie odpowiada …”. Zachęca to nauczyciela do wymuszenia wylogowania, które nie uda się z tego samego powodu. Proponowane polecenie jest też błędne dla nazw komputerów zawierających spacje, na które `.name` pozwala.

**Status:** naprawione (be764fe). Podpowiedź „cmcrctl logout … --force” pojawia się tylko wtedy, gdy skrypt się wykonał, zakończył kodem 1 i sam odesłał do „Wyloguj natychmiast”. Nie ma jej przy wyłączonym komputerze, nieznanym kluczu, złym haśle ani po przekroczeniu limitu czasu. Jest wypisywana pod wierszem „✘ …” z przyczyną, a nazwa komputera jest ujęta w cudzysłów, gdy powłoka tego wymaga (np. 'imac 05').

### REV-39

**Sprawdzenie właściciela z PLI-08 odrzuca liczbowe UID, które chown przyjmuje – wysyłanie do folderów usuniętych kont teraz zawodzi** – P2, Przegląd poprawek, `Sources/CMCRCore/Scripts.swift:862`

Nowe sprawdzenie uruchamia `id -u "$OWNER_USER"`, zanim cokolwiek zostanie zapisane. `id` w macOS (kod z FreeBSD) akceptuje argument liczbowy tylko wtedy, gdy dla tego uid istnieje wpis passwd. `chown` akceptuje dowolny liczbowy uid. Zdalna przeglądarka plików buduje właściciela na podstawie listy plików (RemoteBrowserModel.swift:334: `"\(ownerName):\(groupName)"`, gdzie ownerName pochodzi z `stat %Su`). Dla folderu, którego konto usunięto, `stat %Su` wypisuje sam uid (np. `503`). Przed tą zmianą przy takim wysyłaniu wykonywano chown na 503:staff i kończyło się ono powodzeniem. Teraz całe wysyłanie jest odrzucane z kodem wyjścia 2.

Scenariusz: Konto ucznia usunięto, a jego folder domowy zachowano (/Users/olduser należy do uid 503). Nauczyciel otwiera ten folder w zdalnej przeglądarce plików i upuszcza do niego plik. upload() przekazuje właściciela „503:staff” z uprawnieniami roota, a pushFinalize wypisuje „✘ Konto „503” nie istnieje na tym komputerze – nic nie wysłano” i kończy się kodem 2. Przeglądarka nie daje innej możliwości wysłania plików do tego folderu, więc wysyłanie, które wcześniej działało, jest teraz niemożliwe.

**Status:** naprawione (47079e8). pushFinalize nie sprawdza już `id -u` dla właściciela podanego samym numerem (folder usuniętego konta, `stat %Su` pokazuje uid) – numer trafia do chown jak przed PLI-08. Nazwa konta (literówka w „Inny…”) nadal jest sprawdzana przed zapisem; test e2e rev-r2-scripts.sh, sekcja REV-39.

### REV-40

**Wyłączenie „SSH wyłącznie z kluczem” razem z keepalive zostawia logowanie hasłem wyłączone; krok jest tylko oznaczany „bez zmian”** – P2, Przegląd poprawek, `setup/cmcr-imac-setup.sh:551`

step_sshd_tuning odczytuje teraz cur_ko z istniejącego 050-cmcr-manager.conf, ale nadal kończy się wcześniej ze stanem 'skipped' zawsze, gdy OPT_SSH_TUNING=0 i OPT_SSH_KEY_ONLY=0. Dzieje się tak nawet wtedy, gdy istniejący plik drop-in zawiera 'PasswordAuthentication no', czyli gdy użytkownik wyraźnie wybrał wyłączenie trybu tylko z kluczem. Zmiana w raporcie z PRZ-11 jedynie opisuje pozostały stan („Ustawienia sshd bez zmian (SSH wyłącznie z kluczem: włączone)”). Nie stosuje wybranego ustawienia i nie zapisuje ani ostrzeżenia, ani błędu. README:60 mówi, że `--no-ssh-key-only` wyłącza tryb tylko z kluczem i przywraca logowanie hasłem. Ten sam kod jest w Sources/CMCRCore/SetupScriptTemplate.swift:555.

Scenariusz: iMaki skonfigurowano z aplikacji z włączonymi opcjami „Zamykaj zawieszone połączenia” i „Zdalne logowanie tylko kluczem”, więc plik drop-in zawiera keepalive i PasswordAuthentication no. Nauczyciel później wyłącza obie opcje i uruchamia „Skonfiguruj zaznaczone” (albo `cmcrctl setup all --no-ssh-tuning --no-ssh-key-only`). Skrypt dostaje --no-ssh-tuning bez --ssh-key-only i wypisuje „– Ustawienia sshd bez zmian (SSH wyłącznie z kluczem: włączone)” jako krok pominięty. Kończy się kodem 0, a logowanie SSH hasłem pozostaje wyłączone – wbrew wyraźnemu wyborowi i README:60. To samo dzieje się z --verify: nie pojawia się wpis o oczekującej zmianie.

**Status:** naprawione (0f0dd15). Z --no-ssh-tuning bez --ssh-key-only, gdy plik 050-cmcr-manager.conf ma „PasswordAuthentication no”, skrypt usuwa teraz tylko linie logowania kluczem (keepalive bez zmian) tą samą drogą co zwykły zapis (kopia, sshd -t, przywrócenie). Raport i --verify mówią „logowanie hasłem znów działa / znów zadziała”; SetupScriptTemplate.swift wygenerowany ponownie, test e2e sekcja REV-40.

### REV-41

**Odczyt kontrolny w pm_set porównuje napisy: --display-sleep z wiodącym zerem jest teraz zgłaszane jako błąd pmset (exit 1)** – P2, Przegląd poprawek, `setup/cmcr-imac-setup.sh:752`

Poprawka PRZ-16 sprawdza powodzenie przez [ "$(pm_get "$1")" = "$2" ], czyli porównanie napisów między znormalizowaną liczbą całkowitą wypisywaną przez pmset a surową wartością opcji. Walidacja --display-sleep (wiersz 147) odrzuca tylko znaki niebędące cyframi, więc wartości takie jak „05” czy „010” są akceptowane. pmset -a zapisuje 5/10, pmset -g wypisuje „5”/„10”, porównanie zawodzi i ustawienie trafia do PM_FAIL. Przed tą zmianą to samo wejście dawało „changed” i kod wyjścia 0. Teraz jest to fałszywy błąd kroku, a wynik „fail” w setup.json sprawia, że Gotowość przy każdym uruchomieniu pokazuje „zgłosiło błędy”. Ten sam kod jest w SetupScriptTemplate.swift:756.

Scenariusz: Przy iMacu: `sudo bash cmcr-imac-setup.sh --display-sleep 05`. pmset poprawnie ustawia displaysleep 5. pm_get zwraca „5”, co nie jest równe „05”, więc raport wypisuje „✘ pmset nie zmienił ustawień zasilania: uśpienie ekranu po 05 min.”, a skrypt kończy się kodem 1. Każde kolejne uruchomienie to powtarza, bo cur „5” nigdy nie będzie równe „05”.

**Status:** naprawione (685a4dc). Skrypt usuwa zera na początku wartości --display-sleep zaraz po walidacji („05” → 5, „00” → 0), więc odczyt z pmset zgadza się z wartością i nie ma fałszywego „✘ pmset nie zmienił…”. Atrapa pmset w fakes.sh zapisuje liczby jak prawdziwy pmset; test e2e sekcja REV-41.

### REV-42

**Tekst z TXT-08 „Zainstaluj klucz logowania” (niżej) wypisuje też cmcrctl readiness, gdzie niżej nic nie ma** – P2, Przegląd poprawek, `Sources/CMCRCore/Scripts+Setup.swift:166`

Opis stanu 'missing' dla SSH to tekst z Core, wspólny dla okienka (popover) w aplikacji i dla `cmcrctl readiness` (SetupCommands.swift wypisuje item.detail dla każdego elementu, który nie jest ok). Nowe sformułowanie odsyła „(niżej)” do przycisku, który istnieje tylko w okienku gotowości w aplikacji. Ten tekst pokazuje też dymek podpowiedzi w aplikacji (ReadinessView.swift:725) i wyjście w terminalu, a tam poniżej nie ma żadnego przycisku. W CLI następny wiersz to kolejne sprawdzenie.

Scenariusz: `cmcrctl readiness all` na iMacu bez klucza aplikacji wypisuje „⚠︎ SSH  hasło”, a po nim „Połączenie działa, ale klucz SSH tej aplikacji nie jest zainstalowany – logowanie hasłem. Napraw: „Zainstaluj klucz logowania” (niżej), …”. Użytkownik terminala szuka czegoś poniżej i znajduje następny wiersz (sudo). Nie jest podane żadne polecenie CLI, chociaż `cmcrctl setup NR` zainstalowałoby klucz.

**Status:** naprawione (7a1bed5). Usunięto „(niżej)” ze wspólnego tekstu CMCRCore o braku klucza SSH – ten tekst widać też w podpowiedzi komórki i w `cmcrctl readiness`, gdzie pod nim nie ma przycisku. W okienku gotowości przycisk „Zainstaluj klucz logowania” nadal jest tuż pod tekstem; test RevR2scriptsTests.theMissingKeyDetailDoesNotPointBelow.

### REV-43

**Pełny przebieg e2e nie przechodzi: wspólne połączenia SSH grupy rev-g6-cli przeżywają do grupy screens** – P2, Przegląd poprawek, `Tests/e2e/run.sh:252`

Grupa rev-g6-cli łączy się z adresami .local przez ProxyCommand, a jej połączenia ControlPersist (120 s) działają jeszcze, gdy grupa screens (uruchamiana po niej, kolejność alfabetyczna) sprawdza, że testowy sshd nie ma już procesów sesji. Pełny `Tests/e2e/run.sh` kończy się wtedy „✘ na żywo: zostały procesy sesji”, choć każda z grup osobno przechodzi.

Scenariusz: `CMCR_E2E_SUITES=rev-g6-cli,screens Tests/e2e/run.sh` – „Wynik: 162 zaliczonych, 1 niezaliczonych”.

**Status:** naprawione (1461c95). run.sh po każdej grupie zamyka połączenia ControlPersist; ta sama para grup daje teraz 163 zaliczonych, 0 niezaliczonych.

### REV-44

**Ctrl-C w trakcie pakowania w `install` (lub `lesson start` z materiałami) zostawia działający tar i wielogigabajtowe archiwum w $TMPDIR** – P2, Przegląd poprawek, `Sources/cmcrctl/ScriptCommands.swift:59`

REV-36 dodało uchwyt do Payload.make, a Interrupt.swift:54-58 mówi, że przerwanie kończy pakowanie. `install` nadal pakuje przez `Payload.make(urls)` bez uchwytu, zanim zostanie zarejestrowane jakiekolwiek zadanie. `lesson start` robi to samo ze swoimi materiałami w ClassroomCommands.swift:418. Ponieważ zadanie jeszcze nie istnieje, procedury obsługi SIGINT nie są zainstalowane i Ctrl-C kończy cmcrctl domyślną akcją. Process z Foundation uruchamia każdy proces potomny we własnej grupie procesów (sprawdzone: PGID potomka to jego własny PID), więc SIGINT z terminala nigdy nie dociera do /usr/bin/tar. tar działa dalej i nic nie usuwa tego, co zapisał: ani `defer removeItem(payload)` w cmcrctl, ani własne sprzątanie i chmod 0600 w Payload.make nigdy się nie wykonują. Pakowanie dużej aplikacji .app lub folderu materiałów może trwać kilka minut, więc Ctrl-C w tym momencie to normalna reakcja. Na iMacach nic jeszcze wtedy nie zostało zmienione, więc jest to lokalny wyciek miejsca na dysku i czasu procesora, a nie problem po stronie zdalnej.

Scenariusz: Odtworzyłem to zestawem testów próbnych we własnym worktree (e2e, port 2461). Utworzyłem `big.app` o rozmiarze 3 GB i uruchomiłem `cmcrctl install big.app 1 --allow-unsigned`, po czym 0,2 s po pojawieniu się tar wysłałem SIGINT do grupy procesów. cmcrctl natychmiast zakończył się kodem 130, niczego nie wypisując. `/usr/bin/tar -cf $TMPDIR/cmcr-payload-<uuid>.tar -C … ./big.app` działał dalej po zakończeniu cmcrctl. Gdy skończył, zostawił w $TMPDIR plik cmcr-payload-*.tar o rozmiarze 3 145 736 704 bajtów i uprawnieniach `-rw-r--r--`, którego nic nigdy nie usuwa. `lesson start` przechodzi tą samą ścieżką przy dużym folderze „Materiały” (ClassroomCommands.swift:418).

**Status:** naprawione (3ac2c94). Pakowanie plików w `install` i w `lesson start` (materiały) jest teraz zadaniem przerywalnym (`Interruption.pack`): Ctrl-C zatrzymuje tar, usuwa niedokończone archiwum z katalogu tymczasowego i kończy cmcrctl kodem 130, a na iMacach nic nie zostaje uruchomione. Gotowe archiwum jest usuwane także przy natychmiastowym zakończeniu (drugie Ctrl-C), a `install` zapisuje wpis w dzienniku działań dopiero po spakowaniu plików.

### REV-45

**README: polecenia tylko do odczytu kończą się od razu po Ctrl-C, ale `ls ŚCIEŻKA KOMP`, `updates history`, `setup --verify/--dry-run` i `rm --dry-run` to zadania** – P2, Przegląd poprawek, `README.md:129`

Tekst README z REV-36 (commit 8e13057) mówi: „polecenia, które tylko odczytują, kończą się od razu”. Kilka poleceń, które tylko odczytują, działa przez Interruption.run jako zarejestrowane zadania:
- `ls ŚCIEŻKA KOMP` i `updates history` (runScript, CLI.swift:490, 655)
- `setup --verify/--dry-run` (SetupCommands.swift:97)
- `rm --dry-run` (Browse.swift:98)

W ich przypadku Ctrl-C wypisuje „▸ Przerywanie – zatrzymywanie polecenia…”, zatrzymuje zadanie na bieżącym iMacu i czeka na to zatrzymanie, a następnie, przed zakończeniem kodem 130, wymienia Maki, na których polecenia nie uruchomiono. Jeśli Mac w trakcie przebiegu stał się niedostępny, oczekiwanie może trwać aż do upływu limitu czasu nawiązywania połączenia ssh. Interrupt.swift:12 przyznaje, że `ls` i updates history są wyjątkiem, ale README (specyfikacja) tego nie mówi. Tekst pomocy nie powtarza tego twierdzenia.

Scenariusz: `cmcrctl setup 1-15 --verify` (lub `cmcrctl ls /Users 1-15`), Ctrl-C w trakcie pracy na imac01. Zamiast zakończyć się od razu, jak obiecuje README:129, polecenie wypisuje „▸ Przerywanie – zatrzymywanie polecenia na komputerach (imac01)…”, „▸ Zatrzymano polecenie na komputerze.”, „✘ imac01: Anulowano.” i „▸ Nie uruchomiono polecenia na 14 komputerach: imac02, …”. Potem kończy się kodem 130.

**Status:** naprawione (1b0de00). README wymienia polecenia tylko do odczytu, które Ctrl-C kończy od razu, oraz te, które działają jako zadania i są najpierw zatrzymywane na iMacach (ls ŚCIEŻKA KOMP, updates history, setup --verify/--dry-run, rm --dry-run) – zgodnie z opisem w Sources/cmcrctl/Interrupt.swift.

### REV-46

**lesson: ostrzeżenie o uszkodzonym classroom.json pojawia się dopiero po pytaniu „Wykonać na wszystkich?”, inaczej niż w lock/ask/schedule set** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:67`

W `run` gałąź `case "lesson"` buduje listę komputerów przez `ModuleHosts.changing(a[1], ...)` jako argument `lesson(...)`. Gdy w terminalu nie podano listy komputerów, to wywołanie zadaje pytanie „Wykonać na wszystkich? [t/N]”. `ClassroomCLI.loadConfig()`, które wypisuje wiersz „⚠ Plik ustawień zajęć (classroom.json) jest uszkodzony …”, uruchamia się dopiero wewnątrz `lesson()` (wiersz 396). `lock` (wiersz 71), `schedule set` (wiersz 118) i `ask` wczytują konfigurację, zanim ustalą komputery, więc u nich ostrzeżenie pojawia się przed pytaniem. REV-37 mówi, że ostrzeżenie jest zgłaszane przed wykonaniem polecenia, tak jak dla settings.json w main.swift, gdzie pojawia się przed jakimkolwiek pytaniem. Przy `lesson start`, a także przy `lesson end` bez działań zakłócających, nie ma już żadnego dalszego potwierdzenia. Nauczyciel odpowiada więc na jedyne pytanie, nie wiedząc, że zamiast zapisanego scenariusza uruchomi się scenariusz wbudowany.

Scenariusz: classroom.json jest uszkodzony (np. `{"schedule": {"powerOnEnabled": tr`). W terminalu uruchom `cmcrctl lesson start` bez listy komputerów. Wynik: „Nie podano komputerów – lesson start na wszystkich: …”, a potem „Wykonać na wszystkich? [t/N]”. Wiersz ⚠ pojawia się dopiero po odpowiedzi „t”, po czym domyślny scenariusz (wybudzenie + powitanie) od razu się uruchamia. Po odpowiedzi „n” ostrzeżenie w ogóle się nie pojawia. `cmcrctl lock` w tym samym stanie wypisuje najpierw wiersz ⚠, a potem pytanie. Oba przypadki odtworzyłem przez `script -q /dev/null` we własnej kompilacji.

**Status:** naprawione (c6cefc8). `lesson start|end` wczytuje classroom.json przed wyborem komputerów, więc ostrzeżenie „⚠ Plik ustawień zajęć (classroom.json) jest uszkodzony…” pojawia się przed pytaniem „Wykonać na wszystkich?”, tak jak w `lock`, `ask` i `schedule set`; plik jest czytany tylko raz.

### REV-47

**Podpowiedź logout --force nie ujmuje w cudzysłów nazwy komputera z „!” (lub „=” na początku), więc wklejona do zsh/bash nie działa** – P2, Przegląd poprawek, `Sources/cmcrctl/CLI.swift:693`

REV-38 buduje podpowiedź przez `CommandLineLog.describe(["logout", h.name, "--force"])`, tak aby dało się ją skopiować do powłoki. `describe` (Sources/CMCRCore/CommandLineSupport.swift:24) ujmuje argument w cudzysłów tylko wtedy, gdy zawiera on jeden ze znaków ` \t'"\\$`;&|&lt;>(){}*?[]#~`. Nie ujmuje w cudzysłów znaku „!”, który interaktywny zsh (domyślny w macOS) i bash traktują jako rozwinięcie historii, gdy nie jest ujęty w cudzysłów. Nie ujmuje też „=” na początku argumentu, które zsh rozwija do ścieżki polecenia. Nazwy komputerów nie są sprawdzane pod kątem tych znaków; sprawdzane są tylko adresy i konta. We własnej kompilacji potwierdziłem, że describe zostawia `Sala!B` bez cudzysłowu: wiersz w actions.log ma postać `cmcrctl logout Sala!B --yes`.

Scenariusz: Na liście komputerów jest wpis o nazwie `Sala!B`. `cmcrctl logout 'Sala!B' --yes` kończy się odmową (np. Automation -1743 albo niezapisany dokument ucznia). Wypisana podpowiedź to `(cmcrctl logout Sala!B --force – …)`. Wklejenie jej do Terminala daje `zsh: event not found: B` (bash: `!B: event not found`), więc logout --force, na które wskazuje podpowiedź, nigdy się nie wykonuje. Nazwa w rodzaju `=imac3` daje `zsh: imac3 not found`.

**Status:** naprawione (66e742f). CommandLineLog.describe (podpowiedź „cmcrctl logout … --force” i wpisy actions.log) zostawia bez cudzysłowu tylko słowa z liter, cyfr, znaków ._,:/@%+=- i znaków spoza ASCII, niezaczynające się od „=”, więc nazwy jak „Sala!B” czy „=imac3” idą w apostrofy i wklejona podpowiedź działa w zsh i bash. Testy: RevR3coreTests oraz e2e rev-r3-core.sh, sekcja REV-47, która wkleja podpowiedź do interaktywnego zsh i bash.

### REV-48

**Literówka w liczbowym właścicielu omija teraz sprawdzenie z PLI-08: pliki trafiają do uid bez konta, a wysyłanie kończy się kodem 0** – P2, Przegląd poprawek, `Sources/CMCRCore/Scripts.swift:869`

REV-39 usuwa sprawdzenie istnienia konta, gdy część użytkownika w OWNER składa się wyłącznie z cyfr. Obejmuje to zamierzony przypadek, w którym przeglądarka przekazuje uid folderu usuniętego konta. Przepuszcza jednak także każdą błędnie wpisaną liczbę z pola tekstowego „Inny…” (podpowiedź „użytkownik[:grupa]”), z `cmcrctl push` lub z procedury zajęć. chown przyjmuje dowolny uid do 2147483647, więc pliki po cichu trafiają do uid, który nie ma konta. Ochrona przed dokładnie taką literówką była powodem wprowadzenia PLI-08. Liczba większa niż UID_MAX (np. 99999999999) również przechodzi przez wstępne sprawdzenie. Wtedy cmcr_walk tworzy brakujące foldery docelowe jako root, jego `chown "$owner" . 2>/dev/null` po cichu się nie udaje, a potem `chown -R` kończy się błędem dla każdego elementu. Efekt to puste foldery należące do roota w obszarze użytkownika i kod wyjścia 1, czyli właśnie to, czemu PLI-08 miało zapobiegać („pliki zostałyby własnością roota”). Sprawdziłem przypadki nadużyć i są bezpieczne: 0, 0:0 i 0503 działają jak wcześniej (chown odczytuje je jako liczby dziesiętne; root był już dopuszczany przez `id -u 0`). -1 i 123abc są nadal odrzucane. Zabezpieczenia przed dowiązaniami symbolicznymi nie zależą od tego sprawdzenia.

Scenariusz: Pliki › Wyślij, Właściciel „Inny…” = „5011:staff” (miało być 501), cel /Users/student/Desktop, tryb „Bez zmian”. Przed REV-39: „✘ Konto „5011” nie istnieje…”, kod wyjścia 2, nic nie zostaje zapisane. Po REV-39: kod wyjścia 0, a pliki należą do uid 5011, więc uczeń nie może ich edytować. Z właścicielem „99999999999:staff” i celem, który jeszcze nie istnieje, np. /Users/olduser/new: ./new zostaje utworzony jako root, chown każdego elementu się nie udaje, zostaje pusty folder „new” należący do roota, kod wyjścia 1.

**Status:** naprawione (3fb07fc). Właściciel podany samym numerem przechodzi tylko wtedy, gdy `id -u` zna takie konto albo gdy ten uid jest właścicielem folderu docelowego (lub najgłębszego istniejącego folderu na drodze), czyli w przypadku folderu usuniętego konta z REV-39. Liczby powyżej 2147483647 są odrzucane od razu; w innych przypadkach pojawia się komunikat „Konto … nie istnieje”, kod 2, zanim cokolwiek zostanie zapisane lub utworzone. Testy: e2e rev-r3-core.sh, sekcja REV-48; sekcja REV-39 w rev-r2-scripts.sh korzysta teraz z atrapy stat.uid udającej folder usuniętego konta.

### REV-49

**Przy --ssh-key-only i nieudanej instalacji klucza raport mówi, że logowanie hasłem pozostaje włączone, choć jest już wyłączone** – P2, Przegląd poprawek, `setup/cmcr-imac-setup.sh:585`

step_sshd_tuning obiecuje, że raport jasno podaje, czy logowanie hasłem jest wyłączone (komentarz w wierszu 551, key_only_text). Na ścieżce `--ssh-key-only` z KEY_OK!=1 funkcja zwraca stały tekst: „…więc logowanie hasłem zostaje włączone (inaczej utracisz dostęp). Pominięto.” Wartość cur_ko nie jest brana pod uwagę. Jeśli wcześniejsze uruchomienie zapisało już „PasswordAuthentication no”, plik pozostaje nietknięty i logowanie hasłem nadal jest wyłączone. Raport mówi nauczycielowi coś przeciwnego, więc sądzi on, że ma awaryjną możliwość logowania hasłem. Wiersz 583 („--ssh-key-only wymaga podania klucza…”) także nie podaje bieżącego stanu. Osadzona kopia zawiera ten sam tekst (Sources/CMCRCore/SetupScriptTemplate.swift:589).

Scenariusz: iMac został skonfigurowany z --ssh-key-only, więc plik drop-in zawiera PasswordAuthentication no. Nauczyciel ponownie uruchamia setup z --ssh-key-only, a step_ssh_key się nie udaje: np. ~/.ssh jest dowiązaniem symbolicznym, --pubkey jest nieprawidłowy albo nie da się zapisać authorized_keys. Wynik to „✘ --ssh-key-only: klucza aplikacji nie udało się zainstalować, więc logowanie hasłem zostaje włączone…”, ale 050-cmcr-manager.conf nadal zawiera PasswordAuthentication no. Odtworzone przez uruchomienie wyodrębnionej funkcji step_sshd_tuning z KEY_OK=0 na takim pliku drop-in.

**Status:** naprawione (82a214c). Przy --ssh-key-only bez klucza albo po nieudanej instalacji klucza raport podaje stan z pliku sshd: „ustawienia sshd bez zmian, logowanie hasłem pozostaje wyłączone (SSH wyłącznie z kluczem: włączone)” albo „logowanie hasłem zostaje włączone, inaczej utracisz dostęp (SSH wyłącznie z kluczem: wyłączone)”. Wcześniej zawsze twierdził, że logowanie hasłem zostaje włączone. Test: e2e rev-r3-core.sh, sekcja REV-49.

### REV-50

**--display-sleep 0/00 jest raportowane jako „uśpienie ekranu po 0 min”, choć 0 wyłącza usypianie ekranu** – P2, Przegląd poprawek, `setup/cmcr-imac-setup.sh:781`

REV-41 normalizuje „00” do „0”, a jego test e2e sprawdza tekst „uśpienie ekranu po 0 min.”. Dla pmset displaysleep 0 oznacza, że usypianie ekranu jest wyłączone („value in minutes, or 0 to disable”), więc raport i setup.json mówią, że ekran zasypia po 0 minutach (czyli od razu), podczas gdy w rzeczywistości nigdy nie zasypia. Teksty pomocy mówią tylko „uśpienie ekranu po MIN minutach” (setup/cmcr-imac-setup.sh:84, SetupScript.swift:412) i nie wyjaśniają, co oznacza 0. Osadzona kopia: SetupScriptTemplate.swift:785.

Scenariusz: `cmcrctl setup 3 --display-sleep 0` lub `sudo bash cmcr-imac-setup.sh --display-sleep 00` wypisuje „✚ Zasilanie: …, uśpienie ekranu po 0 min.”, a pmset ma teraz displaysleep 0, co oznacza, że ekran nigdy nie zasypia.

**Status:** naprawione (15ab812). --display-sleep 0 (także „00”) jest w raporcie i setup.json opisane jako „bez usypiania ekranu” zamiast „uśpienie ekranu po 0 min”. Pomoc skryptu i `cmcrctl setup --help` mówią „uśpienie ekranu po MIN minutach (0 – nigdy)”. Testy: e2e rev-r3-core.sh, sekcja REV-50, oraz poprawione oczekiwanie w sekcji REV-41 w rev-r2-scripts.sh.

### REV-51

**README: zerwane połączenie nie jest zgłaszane jako kod wyjścia, ale historia w aplikacji, eksporty i cmcrctl exec nadal podają kod 255** – P2, Przegląd poprawek, `README.md:178`

Commit c000530 dodał: „Zerwane połączenie z poleceniem, które już działało, jest zgłaszane jako błąd połączenia (…), a nie jako kod wyjścia polecenia.” Stosuje się do tego tylko tekst podsumowania. AppModel.swift:623 nadal zapisuje `job.exitCode = r.exitCode` (255), bo nil dostają tylko zadania anulowane i przerwane po przekroczeniu limitu czasu. Wiersz historii pokazuje wtedy „Niepowodzenie (kod 255)” z podpowiedzią „Polecenie zakończyło się kodem 255” (JobsView.swift:537-542). „Zapisz do pliku…” / „Eksportuj…” zapisują „, kod 255” (JobsView.swift:650, 661). W cmcrctl `exec` używa report(passThrough: true) (Output.swift:180), więc proces kończy się kodem 255, a wiersz 129 README mówi, że `exec` zwraca kod zdalnego polecenia.

Scenariusz: Na imac04 działa `exec` lub zadanie korzystające ze współdzielenia połączenia, gdy współdzielone połączenie ssh zostaje zerwane (reset Wi-Fi, keepalive). Podsumowanie poprawnie brzmi „Połączenie zostało przerwane – polecenie mogło nadal działać na komputerze”. Ale Zadania › historia pokazuje „Niepowodzenie (kod 255)” / „Polecenie zakończyło się kodem 255”, a eksport zawiera „=== imac04 – Niepowodzenie, kod 255 ===”. `cmcrctl exec 'long-task' 4; echo $?` wypisuje 255, czego skrypt nie odróżni od sytuacji, w której samo zdalne polecenie zakończyło się kodem 255.

**Status:** naprawione (ed59d5a, 35aee45). W aplikacji zadanie, którego połączenie SSH się zerwało albo się nie udało (SSH.diagnose daje stan inny niż „włączony”), nie ma kodu wyjścia, tak jak zadanie po przekroczeniu czasu (ZAD-16): historia w Zadaniach, „Zapisz do pliku…” i „Eksportuj…” pokazują błąd połączenia zamiast „kod 255”, a własny kod polecenia (także 255) zostaje. cmcrctl exec przekazuje kod zdalnego polecenia tylko wtedy, gdy polecenie zakończyło się samo na komputerze, który odpowiedział; nieudane lub zerwane połączenie daje kod 1.

### REV-52

**cmcrctl rename (i arkusz w aplikacji) przyjmuje przenumerowanie lub zamianę na nazwę .local, którą ma jeszcze inny Mac z listy, wbrew nowej regule w README** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:304`

README.md:130 (c000530) mówi, że nowa nazwa, której adres .local ma już inny komputer z listy, jest błędem (kod 2) i nic nie zostaje zmienione. namesTaken() pomija wszystkie Maki, którym zmienia się nazwę (`where !renaming.contains(m.id)`), a HostInspector.swift:319 robi to samo. Mac, któremu nazwa zmienia się później w tym samym przebiegu, nie jest więc liczony jako posiadacz swojego obecnego adresu. Zmiany nazw wykonują się po kolei, w kolejności listy (ClassroomCommands.swift:361), więc wcześniejszy Mac zajmuje nazwę, która jest nadal używana w sieci.

Scenariusz: Na liście są imac05 (adres imac05.local, nazwa na liście zmieniona na „imac06”) i imac06 (adres imac06.local, nazwa na liście „imac07”), np. po wstawieniu Maca i przenumerowaniu. `cmcrctl rename 5,6 --update-list --yes` nie zgłasza konfliktu. imac05 dostaje LocalHostName imac06, podczas gdy imac06 nadal ogłasza imac06.local, więc Bonjour zmienia jego nazwę na imac06-2. Mimo to --update-list zapisuje dla niego adres imac06.local i przenosi tam jego zaufany klucz. Gdy imac06 staje się imac07, pod imac06.local nic nie odpowiada i ten iMac jest nieosiągalny z listy. Zamiana (1↔2) zawsze kończy się w ten sposób.

**Status:** naprawione (b12d083). `cmcrctl rename` i okno „Zmień nazwy komputerów” odrzucają nową nazwę, której adres .local ma jeszcze inny komputer zmieniany w tym samym poleceniu (przenumerowanie, zamiana nazw). cmcrctl kończy się wtedy kodem 2 bez zmian, a w aplikacji wiersz jest oznaczony i przycisk wyłączony; obie podpowiadają zmianę w dwóch krokach, a przy zamianie nazwę tymczasową (`--name`). Wspólna reguła to `RenamePlan.namesStillHeld` w CMCRCore.

### REV-53

**cmcrctl exec zwraca 1 zamiast własnego kodu polecenia 255, gdy polecenie nic nie wypisało na stderr (exit 255, exit -1)** – P2, Przegląd poprawek, `Sources/cmcrctl/Output.swift:184`

Po REV-51 `exec` przekazuje kod zdalnego polecenia tylko wtedy, gdy SSH.diagnose zwraca stan „włączony”. Dla rozpoczętej sesji diagnose uznaje kod 255 z pustym stderr za zerwane wspólne połączenie (sessionClosed), bo otoczka skryptu ma znacznik początku, ale nie ma znacznika końca – polecenie, które samo kończy się kodem 255 i nic nie pisze na stderr, wygląda jak zerwana sesja. Wcześniej taki przypadek zachowywał przynajmniej kod 255; teraz cmcrctl wypisuje fałszywe „Połączenie zostało przerwane – polecenie mogło nadal działać na komputerze.” i kończy się kodem 1, wbrew README (wiersz 129: „`exec` zwraca kod zdalnego polecenia”).

Scenariusz: osiągalny Mac, połączenie w porządku: `cmcrctl exec 'exit 255' 1` albo `cmcrctl exec 'echo wynik; exit -1' 1` – oba kończą się kodem 1 z komunikatem o przerwanym połączeniu (na bb69701: 255).

**Status:** naprawione (7008694). Wrapper zdalnego skryptu pisze teraz na samym końcu (w pułapce EXIT, po sprzątaniu) znacznik `CMCR:SESSION-ENDED <kod>`. SSH.runWithRetry usuwa go z wyjścia i zapisuje kod w CommandResult.endCode, a SSH.diagnose uznaje 255 sesji, która ruszyła, za kod polecenia tylko wtedy, gdy znacznik dotarł. Dzięki temu `cmcrctl exec 'exit 255'` i `exec 'exit -1'` zwracają 255 zamiast 1 i nie pokazują już fałszywego „Połączenie zostało przerwane…”.

### REV-54

**cmcrctl rename przy przesunięciu nazw w kółko (trzy komputery i więcej) radzi „najpierw X, potem Y” po okręgu – każdy pierwszy krok jest odrzucany** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:353`

Podpowiedź o nazwie tymczasowej (`--name`) pojawia się tylko przy zamianie dwóch komputerów. Przy rotacji A→b, B→c, C→a każdy komputer ma radę „Zmień nazwy w dwóch krokach: najpierw &lt;następny>, potem &lt;ten>”, która zatacza koło, a wykonanie dowolnego kroku osobno jest odrzucane (nazwę ma nadal komputer spoza tego polecenia). Rotację da się zrobić tylko przez nazwę tymczasową, o której komunikat w tym przypadku nie mówi.

Scenariusz: lista {imac02 @ imac01.local}, {imac03 @ imac02.local}, {imac01 @ imac03.local}; `cmcrctl rename @1,@2,@3 --dry-run` radzi kolejno „najpierw imac03”, „najpierw imac01”, „najpierw imac02”, a `cmcrctl rename @2 --dry-run` kończy się kodem 2.

**Status:** naprawione (ac724b1). cmcrctl rename rozpoznaje teraz każdą pętlę nazw (zamianę dwóch komputerów i przesunięcie nazw w kółko między trzema i więcej) i wtedy radzi nazwę tymczasową, a nie podaje rad „najpierw X, potem Y”, które zataczały koło. Przy dłuższym przenumerowaniu podaje całą kolejność od komputera z wolną nazwą (RenamePlan.order); podpowiedź w oknie aplikacji zostaje bez zmian, bo zakres obejmował tylko cmcrctl.

### REV-55

**Rada „zmień nazwy w dwóch krokach” pomija --update-list, więc drugi krok wykonany dosłownie jest odrzucany** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:357`

Komunikat przy przenumerowaniu („najpierw X, potem Y”) i README (wiersz 130) nie mówią, że pierwszy krok musi zaktualizować listę komputerów (`--update-list`, w cmcrctl domyślnie wyłączone). Bez tego stary adres .local X zostaje na liście i drugi krok jest odrzucany jako kolizja – już po zmianie nazwy X na iMacu. Rada o nazwie tymczasowej przy zamianie ma tę samą lukę.

Scenariusz: lista {imac06 @ imac05.local}, {imac07 @ imac06.local}; `cmcrctl rename imac06,imac07` radzi „najpierw imac07, potem imac06”; `cmcrctl rename imac07` (bez --update-list) zmienia nazwę iMaca, a `cmcrctl rename imac06` kończy się kodem 2: „ten adres ma już imac07 z listy komputerów”.

**Status:** naprawione (53309f2). Obie rady cmcrctl rename (dwa kroki i zamiana nazw) mówią teraz „za każdym razem z --update-list”, więc drugi krok nie jest już odrzucany przez nieaktualną listę. Rada przy zamianie dodaje też, że na końcu komputer z nazwą tymczasową dostaje docelową nazwę przez --name, bo z --update-list nazwa tymczasowa trafia na listę.

### REV-56

**Cytowanie z REV-47 pomija „=” na początku, po którym stoi znak łączący – zsh nadal rozwija słowo jako ścieżkę polecenia** – P2, Przegląd poprawek, `Sources/CMCRCore/CommandLineSupport.swift:26`

CommandLineLog.describe sprawdza `text.hasPrefix("=")`, a Swift porównuje tu całe znaki (klastry grafemów). Gdy po „=” stoi znak łączący (np. U+0301) albo selektor wariantu, tworzy z nim jeden znak i hasPrefix zwraca false, więc słowo zostaje bez apostrofów. Nazwy komputerów dopuszczają takie znaki.

Scenariusz: komputer o nazwie „=\u0301imac3”, odmowa wylogowania: podpowiedź „cmcrctl logout =́imac3 --force” wklejona do zsh daje „zsh: ́imac3 not found”.

**Status:** naprawione (0d0bddd). describe() sprawdza pierwszy skalar Unicode zamiast pierwszego znaku (Character). Słowo zaczynające się od „=” ze znakiem łączącym (np. „=\u{0301}imac3”, U+FE0F, U+0903) też trafia teraz w cudzysłów, więc podpowiedź `logout --force` i wpis w actions.log da się wkleić do zsh.

### REV-57

**Zerwane połączenie po wpisie polecenia na stderr nadal jest zgłaszane jako „Polecenie zakończone kodem 255” (exec: kod 255), wbrew README** – P2, Przegląd poprawek, `README.md:129`

README (wiersze 129 i 178) obiecuje, że zerwane połączenie z działającym poleceniem jest zgłaszane jako błąd połączenia (exec: kod 1), a nie jako kod polecenia. SSH.diagnose uznaje jednak kod 255 rozpoczętej sesji za zerwanie tylko przy pustym stderr, a stderr zawiera też to, co wypisało samo polecenie. Jeśli polecenie zdążyło coś wypisać na stderr (postęp brew, softwareupdate, installer), wynik to „Polecenie zakończone kodem 255.” i kod 255 – w cmcrctl i w aplikacji.

Scenariusz: `cmcrctl exec "echo ruszyło >&2; sleep 4; …" 1`, w trakcie zamknięcie wspólnego połączenia (`ssh -S <gniazdo> -O exit`): „✘ imac01: Polecenie zakończone kodem 255.” i kod 255; ten sam przebieg z echo na stdout daje komunikat o przerwanym połączeniu i kod 1.

**Status:** naprawione (7008694). Ten sam mechanizm co w REV-53: kod 255 bez znacznika końca oznacza zerwane połączenie bez względu na treść stderr. Polecenie, które pisało na stderr, zanim padło wspólne połączenie, kończy się więc komunikatem „Połączenie zostało przerwane…” i kodem 1, jak obiecuje README, a nie „kodem 255”.

### REV-58

**README mówi, że cmcrctl rename sprawdza kolizje nazw „tak jak okno „Zmień nazwy komputerów””, ale oba sprawdzają inne nazwy** – P2, Przegląd poprawek, `README.md:130`

cmcrctl (ClassroomCLI.namesTaken) bierze zajęte nazwy z adresów .local innych komputerów i z ich nazw na liście. Okno w aplikacji (RenameComputersSheet.namesTaken) bierze je z adresów .local i z nazw LocalHostName odczytanych z iMaców, ale nie z nazw na liście. Te same dane dają więc różne wyniki.

Scenariusz: imac03 ma adres IP 192.168.1.13 i nazwę „imac03” na liście, jego LocalHostName nie jest znane. `cmcrctl rename 5 --name imac03` kończy się kodem 2 („ten adres ma już imac03”), a w oknie aplikacji ta sama nazwa dla imac05 przechodzi bez ostrzeżenia.

**Status:** naprawione (4c309d3). cmcrctl i okno „Zmień nazwy komputerów” używają jednej funkcji RenamePlan.namesTaken: liczy się adres .local, nazwa na liście i, w aplikacji, nazwa odczytana z iMaca. Okno blokuje teraz także nazwę z listy komputera z adresem IP, z którego nazwy nie odczytano.

### REV-59

**Test zapisu z błędem (KON-03) porównuje globalny lastSaveError, który równolegle zerują inne testy** – P2, Przegląd poprawek, `Tests/CMCRCoreTests/StoreTests.swift:128`

StoreTests.aFailedSaveIsReported sprawdza `ConfigStore.lastSaveError == problem`. lastSaveError jest stanem globalnym, a udane zapisy w innych zestawach działających w tym samym czasie (RevG1coreTests.syncHosts, inne testy ConfigRecoveryTests) ustawiają go na nil. Test zależy więc od kolejności wątków.

Scenariusz: przebieg `scripts/test.sh --unit` po scaleniu czwartej rundy: „ConfigStore.lastSaveError → nil”, 1 niezaliczony test.

**Status:** naprawione (d35ee19). Asercja na globalnym lastSaveError usunięta (nie ma odbiorcy w aplikacji ani w cmcrctl); test nadal sprawdza błąd zwracany wywołującemu. Trzy pełne przebiegi testów jednostkowych bez błędów.

### REV-61

**Rada przy przesunięciu nazw w kółko nie podaje kolejności pozostałych komputerów, a podsuwana kolejność jest odwrotna** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:316`

Przy rotacji nazw między trzema i więcej komputerami cmcrctl wymienia komputery w kolejności pętli i radzi „nadaj najpierw jednemu z nich nazwę tymczasową, potem zmień nazwy pozostałych po kolei”. Po nadaniu nazwy tymczasowej pozostałe da się zmienić tylko w kolejności odwrotnej do wypisanej, więc wykonanie rady „po kolei” jest odrzucane. README (wiersz 130: „kolejność podaje cmcrctl”) nie jest więc prawdziwe dla rotacji.

Scenariusz: A imac02@imac01.local, B imac03@imac02.local, C imac01@imac03.local; `rename @1,@2,@3 --dry-run` wymienia imac02, imac03, imac01; po `rename imac02 --name tymczasowa` polecenie `rename imac03` kończy się kodem 2 – działająca kolejność to imac01, potem imac03.

**Status:** naprawione (ea2d06d). Przy nazwach przesuwanych w kółko rada `cmcrctl rename` podaje teraz całą kolejność: najpierw nazwa tymczasowa dla komputera, którego dotyczy rada, potem pozostałe komputery pętli wstecz, na końcu docelowa nazwa (`--name`), za każdym razem z `--update-list`. Kolejność i treść są w CMCRCore (RenamePlan.steps, RenamePlan.advice), a test e2e wykonuje radę każdego komputera dosłownie, krok po kroku (obroty trzech i czterech komputerów oraz przenumerowanie).

### REV-62

**Powtórzone nowe nazwy giną za radą o kolejności; wykonanie jej zostawia komputer z nazwą tymczasową** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:363`

W cmcrctl rename sprawdzenie nazw zajętych przez inne zmieniane komputery (z radą o kolejności) działa przed sprawdzeniem powtórzeń i kończy pętlę. Gdy dwa komputery mają dostać tę samą nazwę .local, a nazwę tę ma jeszcze trzeci zmieniany komputer, żaden nie dostaje błędu „powtarza się”, tylko radę, której nie da się dokończyć. Okno w aplikacji sprawdza powtórzenia wcześniej, więc reguły się różnią.

Scenariusz: A imac02@imac01.local, B imac01@imac02.local, C IMAC02@imac03.local; `rename @1,@2,@3 --dry-run` daje rady o zamianie, bez błędu powtórzenia A/C; wykonanie rady zostawia A z nazwą tymczasowa.local.

**Status:** naprawione (605a0c6). `cmcrctl rename` sprawdza teraz nazwy w tej samej kolejności co okno aplikacji: adres zajęty, powtórzenie, adres innego zmienianego komputera. Błąd „powtarza się” dostaje każdy komputer z tą nazwą (wspólne RenamePlan.repeatedNames, używane też w oknie), więc nie pojawia się już rada o kolejności, której nie da się dokończyć.

### REV-63

**Okno „Zmień nazwy komputerów” nadal radzi „najpierw tylko X, potem ten komputer”, co nie działa przy przenumerowaniu trzech i więcej komputerów** – P2, Przegląd poprawek, `Sources/CMCRManager/HostInspector.swift:261`

REV-54 poprawiło rady tylko w cmcrctl. Podpowiedź w oknie aplikacji nadal mówi „Zmień nazwy w dwóch krokach: najpierw tylko &lt;inny>, potem ten komputer”, a przy przenumerowaniu dłuższym niż dwa komputery wskazany pierwszy krok blokuje to samo okno (wspólna reguła z REV-58): czerwona etykieta i wyłączony przycisk.

Scenariusz: imac05, imac06, imac07 z nowymi nazwami imac06, imac07, imac08 – okno radzi zacząć od imac06, a dla samego imac06 → imac07 blokuje zmianę; działająca kolejność to imac07, imac06, imac05.

**Status:** naprawione (cd58fea). Podpowiedź w oknie „Zmień nazwy komputerów” pochodzi z tej samej funkcji co w cmcrctl (RenamePlan.advice, in: .app): podaje całą kolejność z nazwami wpisanymi w oknie i mówi „zaznaczając za każdym razem tylko jeden komputer, z włączoną aktualizacją listy komputerów”. Zastępuje dawne „w dwóch krokach: najpierw tylko …”, a aplikacja sama aktualizuje listę, gdy ten przełącznik jest włączony (ClassroomModel.renamed).

### REV-64

**Rada o kolejności zmiany nazw prowadzi przez komputer, którego nazwa powtarza się albo jest zajęta – wykonanie jej zostawia komputer z nazwą tymczasową** – P2, Przegląd poprawek, `Sources/cmcrctl/ClassroomCommands.swift:354`

REV-62 zgłasza powtórzoną nazwę dla każdego komputera z tą nazwą, ale mapa nazw zajętych przez inne zmieniane komputery nadal powstaje ze wszystkich zmian, także odrzuconych. Komputer bez własnego błędu dostaje radę o kolejności, która przechodzi przez komputer z odrzuconą nazwą – i nie da się jej dokończyć. To samo w oknie „Zmień nazwy komputerów”.

Scenariusz: imac02@imac01.local, imac01@imac02.local, imąc02@imac03.local; `rename @1,@2,@3 --dry-run` zgłasza powtórzenie dla imac02 i imąc02, a imac01 dostaje radę o zamianie z nazwą tymczasową. Po jej wykonaniu ostatni krok (`rename tymczasowa --name imac02`) kończy się kodem 2 i komputer zostaje z nazwą tymczasowa.local.

**Status:** naprawione (c3622f7). Rada o kolejności (cmcrctl rename KOMP i okno „Zmień nazwy komputerów”) nie podaje już kolejności prowadzącej przez komputer, którego nowa nazwa jest niepoprawna, zajęta albo powtarza się (wspólne RenamePlan.rejections). Zamiast niej pojawia się np. „Najpierw popraw nazwę imac02 (adres powtarza się) – dopiero wtedy da się podać kolejność.”; sprawdzenie w rev-r5-rename.sh wyłapuje teraz też radę „Przy zamianie nazw…”.

### REV-65

**Rada w oknie „Zmień nazwy komputerów” nie podaje nowych nazw w krokach, a okno po zamknięciu zapomina wpisane nazwy** – P2, Przegląd poprawek, `Sources/CMCRCore/RenamePlan.swift:164`

W aplikacji RenamePlan.advice wypisuje kroki jako „zmień nazwę X” albo „najpierw imac07, potem imac06”, bez docelowej nazwy (tylko ostatni krok ją podaje). Wpisane nowe nazwy istnieją tylko w polach okna, które po zamknięciu wraca do nazw z listy, a przycisk „Zmień nazwy” jest wyłączony, dopóki konflikt trwa. Nauczyciel musi zamknąć okno, żeby wykonać radę, i traci wiedzę, kto miał dostać jaką nazwę.

Scenariusz: imac01, imac02, imac03 z nowymi nazwami imac02, imac03, imac01 – podpowiedź wymienia komputery, ale nie mówi, na co zmienić imac03 i imac02 w kolejnych krokach.

**Status:** naprawione (40e7e26). W oknie „Zmień nazwy komputerów” każdy krok rady podaje nazwę wpisaną w oknie, np. „najpierw imac07 na imac08, potem imac06 na imac07” albo „zmień nazwę imac03 na imac01”. Zamiana dwóch nazw dostaje te same kroki z nazwami, bo okno po zamknięciu zapomina wpisane nazwy; cmcrctl bez zmian (tam nowymi nazwami są nazwy z listy).

### REV-66

**Ostrzeżenia o konfiguracji pokazuje tylko główne okno, choć README obiecuje komunikaty w oknie, w którym się pracuje** – P2, Przegląd poprawek, `README.md:179`

README (wiersz 179) mówi, że komunikaty o błędach pojawiają się w oknie, w którym się pracuje – także w Ścianie ekranów, oknach podglądu i Ustawieniach. Tak działa tylko `model.notice`. Ostrzeżenia o konfiguracji (`model.configIssues`: uszkodzony hosts.json zmieniony poza aplikacją, classroom.json przy starcie) pokazuje wyłącznie ConfigIssuesAlert w głównym oknie. Aplikacja działa też przy samej Ścianie ekranów (odświeżanie w tle startuje także z niej i zapisuje listę po poznaniu adresu MAC).

Scenariusz: zamknięte główne okno, otwarta Ściana ekranów; hosts.json zepsuty ręcznie; odświeżenie poznaje adres MAC i zapisuje listę – kopia .bak powstaje, ale żadne ostrzeżenie nie pojawia się w Ścianie ekranów.

**Status:** naprawione (1ba58a7). Ostrzeżenia o konfiguracji (uszkodzony hosts.json lub settings.json, nieczytelny classroom.json) pokazuje teraz, tak jak komunikaty, jedno okno: to, w którym się pracuje, także Ściana ekranów, okna podglądu i Ustawienia, a nie tylko okno główne. Alert o Pęku kluczy zostaje w oknie głównym, bo hasła ustawia się tylko tam; tej części zgłoszenia nie potwierdzono.

### REV-67

**Problem z konfiguracją dodany, gdy ostrzeżenie jest już na ekranie, nie zostaje pokazany, a „OK” go usuwa** – P2, Przegląd poprawek, `Sources/CMCRManager/ConfigIssuesAlert.swift:134`

ConfigIssuesNotice pokazuje alert na podstawie pierwszego problemu na liście, a treść buduje z całej listy. Gdy w trakcie wyświetlania alertu dojdzie nowy problem, pierwszy element się nie zmienia, więc alert nie pojawia się ponownie, a już otwarte okno alertu nie odświeża treści. Oba przyciski („OK”, „Pokaż pliki w Finderze”) czyszczą całą listę, także problem, którego nauczyciel nie widział.

Scenariusz: ostrzeżenie o uszkodzonym hosts.json otwarte w Ścianie ekranów; kolejna błędna edycja pliku daje drugi problem (inna kopia .bak); „OK” usuwa oba, drugi nie pojawia się nigdzie.

**Status:** naprawione (4ba95e9). Alert ostrzeżeń o konfiguracji pokazuje migawkę problemów z chwili otwarcia (ConfigIssuesBatch) i przy „OK” lub „Pokaż pliki w Finderze” usuwa tylko je. Problem dopisany przy otwartym alercie pokazuje następny alert i nie znika już niepokazany (test: RevR7appTests.aProblemFoundWhileTheAlertIsOpenIsShownByTheNextOne, theNextAlertComesAfterTheOpenOne).

### REV-68

**Ten sam tekst problemu z konfiguracją, który pojawi się ponownie, trafia do okna wybranego poprzednio, a nie do okna, w którym się pracuje** – P2, Przegląd poprawek, `Sources/CMCRManager/ConfigIssuesAlert.swift:121`

Okno do pokazania problemu jest zapamiętywane według tekstu pierwszego problemu i nie jest zapominane po zamknięciu alertu. Ten sam tekst pojawia się ponownie, gdy uszkodzona zawartość jest identyczna (kopia .bak jest wtedy ta sama), więc alert trafia do okna z poprzedniego razu, jeśli jest nadal otwarte, a nie do okna, w którym nauczyciel pracuje.

Scenariusz: okno główne i Ściana ekranów otwarte; pierwszy alert w oknie głównym, „OK”; nauczyciel pracuje w Ścianie ekranów, ten sam problem wraca – alert znów pokazuje okno główne.

**Status:** naprawione (4ba95e9). Każda partia ostrzeżeń o konfiguracji ma własny identyfikator, a po zamknięciu alertu NoticeWindows zapomina wybrane okno. Ten sam tekst problemu pokazuje się więc później w oknie, w którym się wtedy pracuje, a nie w oknie wybranym poprzednio, np. w Ścianie ekranów (test: RevR7appTests.theSameProblemAgainIsShownByTheWindowInUseNow).

### REV-69

**Rada w oknie zmiany nazw podaje kolejność, której pierwszy krok samo okno odrzuca, gdy nazwa z listy zmienianego komputera różni się od jego obecnej nazwy .local** – P2, Przegląd poprawek, `Sources/CMCRCore/RenamePlan.swift:100`

W oknie aplikacji każdy krok rady to zmiana nazwy jednego komputera, sprawdzana także względem nazw z listy innych komputerów (reguła z REV-58). Kolejność liczy jednak tylko adres .local i nazwę odczytaną z iMaca, więc gdy wpisana nazwa komputera X jest nazwą z listy komputera Y (zmienianego w tym samym oknie), a ta nie jest obecną nazwą .local Y, rada stawia X na początku, a jego krok jest odrzucany; odwrotna kolejność też nie działa i pomogłaby tylko nazwa tymczasowa, o której rada nie mówi.

Scenariusz: A „imac03” @imac03.local, B „imac02” @imac06.local; wpisane A → imac02, B → imac03 – rada każe zacząć od A, a okno dla samego A pokazuje „imac02.local ma już imac02”.

**Status:** naprawione (7e6ae29, 3b2fefa). Okno „Zmień nazwy komputerów” liczy teraz nazwę zmienianego komputera na liście jako nazwę, którą ten komputer jeszcze ma (RenamePlan.namesStillHeld, tak jak namesTaken), a kolejność czeka na każdy komputer, który ma jeszcze nową nazwę (RenamePlan.holders, steps/advice(for:holders:)). Dzięki temu podpowiedź podaje kolejność albo nazwę tymczasową, które da się wykonać krok po kroku; przy dwóch pętlach są dwie nazwy tymczasowe, „inna” i „(wcześniej imacNN)”. W cmcrctl kolejności się nie zmieniły. Testy: RevR7renameTests, w tym 4000 losowych list przechodzonych według reguł okna; żaden krok nie jest odrzucany, a na 99df5bb odrzucany był w 387 z 989 kolejności.

### REV-70

**README: limit czasu przy sprawdzaniu stanu nie zawsze zachowuje ostatnio zalogowanego ucznia** – P2, Przegląd poprawek, `README.md:106`

README (wiersz 106) podaje „przekroczony limit czasu” jako przykład błędu, po którym zostaje ostatnio zalogowany uczeń. Kod zachowuje ucznia tylko wtedy, gdy limit czasu minął po rozpoczęciu skryptu stanu; limit czasu przed rozpoczęciem SSH.diagnose uznaje za komputer niedostępny i aplikacja czyści zalogowanych, jak przy wyłączonym komputerze.

Scenariusz: obciążony iMac przyjmuje połączenie TCP, ale nie zgłasza startu skryptu przed upływem limitu – komputer jest „Niedostępny”, bez ucznia, a opcja pominięcia zalogowanych go nie pomija.

**Status:** naprawione (53fb6bc). README opisuje teraz oba przypadki: limit czasu przed połączeniem – komputer niedostępny bez ucznia; limit czasu działającego skryptu, błędne hasło lub chwilowa odmowa – zostaje ostatnio zalogowany uczeń.

### REV-71

**Okno „Zmień nazwy komputerów” pozwala dać innemu komputerowi adres zaznaczonego komputera, którego nazwa się nie zmienia** – P2, Przegląd poprawek, `Sources/CMCRManager/HostInspector.swift:318`

Zajęte nazwy w oknie liczyły się bez wszystkich zaznaczonych komputerów, także tych, których nowa nazwa jest taka jak obecna (isUnchanged) – a takie komputery nie są zmieniane. Ich adres .local, nazwa z listy i nazwa odczytana z iMaca nie były więc zajęte dla innych, a sprawdzenie powtórzeń widziało tylko nazwę z listy.

Scenariusz: imac03 (zmieniony wcześniej na iMacu, na liście nadal z adresem imac07.local, odczytana nazwa imac03) i imac05 zaznaczone razem; dla imac05 wpisane imac07 – okno nie zgłasza konfliktu, a po zmianie dwa wpisy listy wskazują na ten sam adres.

**Status:** naprawione (26ca4c7). Zajęte nazwy, powtórzenia i odrzucenia liczą teraz tylko komputery zmieniane (RenameComputersSheet.conflicts); zaznaczony komputer bez nowej nazwy zachowuje swój adres, nazwę z listy i nazwę odczytaną z iMaca, a jego wiersz nie pokazuje ostrzeżeń.

### REV-72

**Ostrzeżenie o konfiguracji znika po zminimalizowaniu jego okna i wraca dopiero później, w innym oknie** – P2, Przegląd poprawek, `Sources/CMCRManager/ConfigIssuesAlert.swift:218`

Gdy okno z arkuszem ostrzeżenia o konfiguracji (lub komunikatu) zostanie zminimalizowane, wybór okna przechodzi na inne otwarte okno, ale to okno nie odświeża widoku (wybór nie jest obserwowany), więc alertu nie pokazuje żadne okno. Przywrócone okno też go nie pokazuje, bo wybór wskazuje już inne. Alert wraca dopiero przy niezwiązanej zmianie modelu (np. odświeżenie co 2 minuty) – i to w innym oknie niż to, w którym się pracuje.

Scenariusz: ostrzeżenie w Ścianie ekranów na projektorze; nauczyciel minimalizuje Ścianę ekranów – alert znika, główne okno nic nie pokazuje, po przywróceniu Ściany też nic; po ok. 2 minutach alert pojawia się w głównym oknie.

**Status:** naprawione (7c35a9e). Gdy okno z komunikatem lub ostrzeżeniem o konfiguracji zminimalizowano (albo zamknięto z kodu), komunikat przechodził do innego okna, ale nic go nie odświeżało, więc alert znikał do jakiejś niezwiązanej zmiany modelu (do 2 min). Teraz wszystkie okna obserwują NoticeWindows i od razu sprawdzają wybór, gdy komunikat zmienia okno. Okno wracające na ekran przejmuje komunikat, którego wybrane okno nie pokazuje, a komunikat już pokazany zostaje tam, gdzie jest.

### REV-73

**Okno zmiany nazw wskazuje zły komputer i opisuje nieistniejący konflikt Bonjour, gdy nową nazwę ma inny komputer tylko jako nazwę na liście** – P2, Przegląd poprawek, `Sources/CMCRManager/HostInspector.swift:262`

Po REV-69 lista komputerów, które „mają jeszcze” nową nazwę, obejmuje też nazwy z listy, ale etykieta i podpowiedź wiersza zostały bez zmian: „&lt;nazwa>.local ma jeszcze &lt;inny>” i „Ten adres ma teraz &lt;inny> … – macOS nadałby jednemu z nich inny adres”. Gdy pierwszy taki komputer ma tę nazwę tylko jako nazwę na liście, oba zdania są nieprawdziwe (macOS nie nadałby numerowanego adresu), a gdy inny komputer naprawdę ma ten adres, etykieta wskazuje niewłaściwy.

Scenariusz: „imac05”@imac05.local, „imac02”@imac06.local, „imac04”@imac02.local, wpisane imac02, imac07, imac08 – wiersz imac05 mówi „imac02.local ma jeszcze imac02”, choć adres imac02.local ma imac04.

**Status:** naprawione (d2e8652). W oknie „Zmień nazwy komputerów” czerwony wiersz wskazuje teraz najpierw komputer, który ma nową nazwę jako adres .local albo nazwę odczytaną z iMaca (np. „imac02.local ma jeszcze imac04” zamiast „imac02”). Gdy inny zmieniany komputer ma tę nazwę tylko na liście, wiersz mówi „„imac02” jest jeszcze na liście”, a podpowiedź wyjaśnia, że po nieudanej zmianie lista miałaby dwa komputery o tej nazwie, zamiast błędnie mówić o konflikcie adresów w sieci. Rada o kolejności i reguły RenamePlan bez zmian (RenameComputersSheet.stillHeldText, test RevR8renameTests).

### REV-74

**Nieudane działanie na komputerze, który przestał odpowiadać, oznacza go jako niedostępny, ale zostawia ostatnio zalogowanego ucznia** – P2, Przegląd poprawek, `README.md:106`

README (wiersz 106) mówi, że niedostępny komputer nie pokazuje ucznia. Czyści go jednak tylko sprawdzenie stanu (applyStatus). Gałąź błędu działania w AppModel.execute ustawia przy wyniku „niedostępny” tylko stan i komunikat, więc uczeń zostaje przy komputerze oznaczonym jako Niedostępny – na liście, w panelu szczegółów i w wyszukiwaniu.

Scenariusz: imac04 z uczniem „jan” przestaje odpowiadać; wiadomość do imac04 kończy się błędem połączenia przed startem – lista pokazuje imac04 jako Niedostępny z „jan”, a panel szczegółów „Zalogowany: jan”.

**Status:** naprawione (d4cad13). Akcja, która zastała komputer wyłączony (limit czasu przed startem skryptu, „No route to host”), oznaczała go jako „Niedostępny”, ale zostawiała ucznia z ostatniego sprawdzenia: na liście, w szczegółach, w wyszukiwarce i w potwierdzeniach. Teraz ścieżka błędu zadania czyści zalogowanych tak samo jak sprawdzenie stanu (wspólna funkcja forgetStudents), a po innych błędach uczniowie zostają (REV-11).

### REV-75

**Błąd zapisu classroom.json w aplikacji nie jest zgłaszany, a cmcrctl status przy błędzie zapisu adresu MAC kończy się kodem 0 – wbrew README** – P2, Przegląd poprawek, `README.md:180`

README (wiersz 180): gdy pliku nie da się zapisać, aplikacja to zgłasza, a cmcrctl kończy się błędem. Aplikacja zgłasza to tylko dla hosts.json i settings.json; zapis classroom.json (scenariusze zajęć, harmonogram zasilania, tryb uwagi) gubi zwrócony błąd. `cmcrctl status`, który przy okazji zapisuje poznane adresy MAC, przy błędzie zapisu tylko wypisuje ostrzeżenie i zwraca 0.

Scenariusz: folder konfiguracji tylko do odczytu; zmiana scenariusza „Koniec lekcji” w aplikacji – brak komunikatu, zmiana znika po ponownym uruchomieniu.

**Status:** naprawione (0b945d8, 88d2c7b). Przyczyna nieudanego zapisu classroom.json (scenariusze zajęć, harmonogram zasilania, tryb uwagi) była gubiona, więc zmiana bez ostrzeżenia znikała po ponownym uruchomieniu. Teraz ClassroomStore.saveConfig zwraca przyczynę, a aplikacja pokazuje ją tak jak dla hosts.json i settings.json, raz na plik (ostatni błąd jest pamiętany osobno dla każdego pliku). Część o `cmcrctl status` opisuje README (88d2c7b): status tylko ostrzega, że nie zapisał adresu MAC.

### REV-77

**Test przerwania przed znacznikiem startu ma zbyt ciasny limit czasu i nie przechodzi na runnerze CI** – P2, Przegląd poprawek, `Tests/CMCRCoreTests/P2CoreTests.swift:553`

P2CancelBeforeTheMarkerTests.aCancelWhileStillLoggingInThroughASharedConnectionNeedsNoRemoteStop wymagał zakończenia w 3 s. Na GitHub Actions (macos-26, równoległe zestawy testów) przerwanie trwało 3,6 s, więc CI pull requesta #1 nie przeszło, choć zachowanie było poprawne (nie było próby zdalnego zatrzymania).

Scenariusz: `scripts/test.sh --unit` w workflow CI – „(Date().timeIntervalSince(start) → 3.6294100284576416) &lt; (3 → 3.0)”.

**Status:** naprawione (8e0e9af). Limit podniesiony do 15 s z komentarzem: zdalne zatrzymanie czekałoby na ConnectTimeout i OperationTimeout.cancel (po 30 s), więc test nadal je wykrywa; tekst „zatrzymać” sprawdza osobna asercja.

### TXT-01

**Podpowiedź „Ściana ekranów” obiecuje tylko zaznaczone komputery, a okno domyślnie pokazuje wszystkie** – P2, Teksty, `Sources/CMCRManager/MainToolbar.swift:59`

Podpowiedź przycisku na pasku narzędzi brzmi „Pokaż ekrany wszystkich zaznaczonych komputerów w osobnym oknie…”. Ściana ma jednak domyślne źródło `.all`, niezależne od zaznaczenia (ScreenWall.swift:103, ScreenWallSource). Nauczyciel zaznacza 3 komputery i klika przycisk zgodnie z podpowiedzią. Otwiera się podgląd wszystkich komputerów z listy, a każdy zalogowany uczeń dostaje komunikat „Administrator rozpoczął podgląd Twojego ekranu”. Tekst wprowadza w błąd co do skutku. ScreensView.swift:31 opisuje to poprawnie: „pokazuje wszystkie komputery naraz”.

**Status:** naprawione (8c553df)

### TXT-02

**README: filtr i skrót opisane jako „online”, w UI to „Włączone”** – P2, Teksty, `README.md:106`

README pisze „filtr stanu (online, niedostępne, …)” i „⇧⌘O zaznacz online”. W UI filtr nazywa się „Włączone” (App.swift:505, „like everywhere else”), a pozycja menu ⇧⌘O to „Zaznacz włączone komputery” (App.swift:63). Ta sama linia ma też zdanie bez spójnika: „…były wyłączone (offline) — także w trakcie ponownego sprawdzania — zamiast czekać na limit czasu — trafiają do wyników jako pominięte…”. README:9 również mówi „Stan pracowni (online, …)”.

**Status:** naprawione (077b036)

### TXT-03

**README: „Pliki › Konwencja cmcr-helpers” – takiej pozycji nie ma** – P2, Teksty, `README.md:114`

Tabela odpowiedników wskazuje „Pliki › Konwencja cmcr-helpers” (cmcr-push) oraz „… › Pobierz” (115). Sekcja nazywa się „Foldery „all” i komputerów (jak w cmcr-helpers)” (FilesView.swift:380) i ma przyciski „Tylko foldery komputerów”, „Wyślij wszystko” i „Pobierz”. Nazwa zmieniła się w commicie 2295211 („native grouped forms”), README pozostało bez zmian.

**Status:** naprawione (077b036)

### TXT-04

**README: „Anuluj” zatrzymuje polecenie – przycisk to „Przerwij”; stan „Przerwano” vs wynik „Anulowano”** – P2, Teksty, `README.md:177`

README: „**Anuluj** zatrzymuje polecenie także na iMacu”. Wszystkie przyciski zatrzymujące zadania nazywają się „Przerwij” (Components.swift:536 i 700, ActivityViews.swift:193, ClassroomView.swift:496). Ten sam przerwany job ma w kolumnie Stan „Przerwano” (AppModel+Jobs.swift:33), a w kolumnie Wynik „Anulowano” (AppModel.swift:431 i 442, SSH.swift:662).

**Status:** naprawione (077b036)

### TXT-05

**Komunikat SSH: zła nazwa „Logowanie zdalne” i dwuznaczne „na tym Macu”** – P2, Teksty, `Sources/CMCRCore/SSH.swift:689`

Przy „Connection refused” użytkownik widzi: „Połączenie odrzucone – włącz „Logowanie zdalne” (Remote Login) na tym Macu.”. Komunikat trafia do wyniku zadania, podpowiedzi wiersza komputera, inspektora i komórki SSH w Gotowości. W macOS i w całym projekcie opcja nazywa się „Zdalne logowanie” (README:36, setup). W aplikacji „ten Mac” konsekwentnie oznacza komputer nauczyciela („Dotyczy tego Maca (nie iMaców)”, ReadinessView.swift:859; „Pęk kluczy tego Maca”). Komunikat podsuwa więc włączenie SSH na Macu nauczyciela zamiast na iMacu. Podobnie niespójne są Scripts+Setup.swift:40 („Logowanie zdalne działa…”) oraz SetupOptionsSheet.swift:283 („Logowanie zdalne tylko kluczem”) obok :169 („Zdalne logowanie tylko dla administratorów”).

**Status:** naprawione (c4822a6). Komunikat o odrzuconym połączeniu wskazuje „Zdalne logowanie” na iMacu.

### TXT-06

**Komunikaty o iMacu ucznia mówią „ten Mac”, czyli w aplikacji Mac nauczyciela** – P2, Teksty, `Sources/CMCRCore/ScreenCapture.swift:149`

Na kafelku podglądu konkretnego iMaca widać „Zrzut ekranu nieudany. Na tym Macu nadaj sesjom SSH uprawnienie…”. W linii 147 jest „…nie jest administratorem tego Maca”. W aplikacji „ten Mac” konsekwentnie znaczy komputer nauczyciela („Folder na tym Macu”, „Klucz logowania tego Maca”, „Dotyczy tego Maca (nie iMaców)”). Nauczyciel może więc nadawać uprawnienie Nagrywania ekranu na własnym Macu. Mniej mylące, bo pokazywane w wyniku konkretnego iMaca, są zdalne komunikaty Scripts+Classroom.swift:43, 74, 76 i Scripts.swift:764, 949, 1070.

**Status:** naprawione (27abddf). Komunikaty podglądu dla nauczyciela mówią „ten iMac”, nie „ten Mac”.

### TXT-07

**Wynik „wyłączenia za N min” odsyła do przycisku „Anuluj zaplanowane”** – P2, Teksty, `Sources/CMCRCore/Scripts+Classroom.swift:257`

Po zaplanowaniu restartu, wyłączenia lub uśpienia (GUI i cmcrctl power-later) wynik mówi: „Można to anulować przyciskiem „Anuluj zaplanowane”.”. Takiego przycisku nie ma. W GUI jest „Odwołaj” w wierszu „Zaplanowane na później” (PowerView.swift:167, 387), w CLI `cmcrctl power-cancel`. Tytuł zadania odwołania „Anuluj zaplanowane wyłączenie/restart” (ClassroomModel.swift:454) pomija uśpienie i używa innego czasownika niż przycisk.

**Status:** naprawione (a8123fa). Wskazówka odsyła do „Sesja i zasilanie › Zaplanowane na później › Odwołaj” i cmcrctl power-cancel.

### TXT-08

**Komunikaty gotowości odsyłają do przycisków, których nie ma** – P2, Teksty, `Sources/CMCRCore/Scripts+Setup.swift:166`

Komórka SSH (stan „hasło”) każe użyć „Roześlij klucz SSH”. Przycisk nazywa się „Roześlij klucz” (SetupView.swift:759), a w dymku tej komórki przycisk naprawy to „Zainstaluj klucz logowania” (ReadinessView.swift:783). Linia 168 odsyła do „Dostęp i hasła › Wygeneruj nowy klucz”, a przycisk to „Utwórz klucz” lub „Utwórz nowy klucz” (SetupView.swift:690).

**Status:** naprawione (6526168). Komunikaty kolumny SSH odsyłają do istniejących przycisków.

### TXT-09

**„w Konfiguracja › …” – zły przypadek; dwuznaczne „w Ustawieniach”** – P2, Teksty, `Sources/CMCRCore/Scripts+Setup.swift:175`

Szczegóły gotowości w liniach 175, 179 i 193 mówią „zapisz je w Konfiguracja › Dostęp i hasła” i „popraw nazwę w Konfiguracja › Ustawienia”. Po „w” potrzebny jest miejscownik, a reszta aplikacji pisze „w Konfiguracji › …” (ScreenCapture.swift:145, App.swift:307). W 193 „Utwórz je w Ustawieniach (Użytkownicy i grupy)” chodzi o Ustawienia systemowe, ale w tym samym zdaniu pada „Konfiguracja › Ustawienia” aplikacji. Ta sama dwuznaczność jest w komunikacie uaktualnienia SelfUpdate.swift:879 („(Ustawienia › Prywatność i ochrona › Zarządzanie aplikacjami?)”), który aplikacja pokazuje jako powód błędu.

**Status:** naprawione (79f1f2b). „w Konfiguracji ›”, „w Ustawieniach systemowych ›” zamiast dwuznacznych „Ustawień”.

### TXT-10

**Komunikat odmowy instalacji odsyła do nieistniejącego przełącznika** – P2, Teksty, `Sources/CMCRCore/Scripts.swift:369`

Po odrzuceniu niepodpisanego instalatora wynik zadania mówi: „zaznacz „Zezwól na instalatory bez podpisu” w dziale Instalacja”. Przełącznik nazywa się jednak „Zezwalaj na instalatory bez podpisu Apple” i leży w sekcji „Bezpieczeństwo” (InstallView.swift:76, 81; README:170).

**Status:** naprawione (d371d77). Odmowa instalacji wskazuje przełącznik „Zezwalaj na instalatory bez podpisu Apple” (Instalacja › Bezpieczeństwo, --allow-unsigned).

### TXT-12

**Ta sama akcja „sesja SSH w Terminalu” ma cztery różne nazwy** – P2, Teksty, `Sources/CMCRManager/App.swift:668`

README:113 wskazuje „menu kontekstowe › Sesja SSH w Terminalu”. W menu kontekstowym listy komputerów pozycja nazywa się jednak „Otwórz w Terminalu (SSH)” (lub „(pierwsze 4)”). „Sesja SSH w Terminalu” jest tylko w menu kafelka podglądu (ScreenTiles.swift:415). Dalej są „Otwórz w Terminalu (dla zaawansowanych)” (DashboardView.swift:122) i „Otwórz w Terminalu” (HostInspector.swift:130, CommandsView.swift:68).

**Status:** naprawione (8c553df)

### TXT-13

**Panel szczegółów: „120 GB wolne” i „Szyfrowanie dysku: włączony”** – P2, Teksty, `Sources/CMCRManager/HostInspector.swift:70`

Sekcja Dysk pokazuje „%.0f GB wolne z %.0f GB”. Przy typowych wartościach (≥5 GB) liczebnik wymaga „wolnych”, a dla 1 GB „wolny”. W linii 85 etykieta „Szyfrowanie dysku” (rodzaj nijaki) ma wartości „włączony”/„wyłączony” (linie 87–88), a powinno być „włączone”/„wyłączone”.

**Status:** naprawione (8c553df)

### TXT-14

**Instrukcja „Nagrywanie ekranu” pomija /usr/libexec/sshd-session** – P2, Teksty, `Sources/CMCRManager/ReadinessView.swift:279`

Instrukcja krok po kroku („Otwórz instrukcję”, ManualStep.screenRecording, linie 276–280) każe dodać tylko /usr/libexec/sshd-keygen-wrapper, a przycisk kopiowania kopiuje tylko tę ścieżkę (311). README:78, szczegół komórki (Scripts+Setup.swift:233), komunikat podglądu (ScreenCapture.swift:149) i skrypt (setup:929) mówią, że na nowszym macOS (OpenSSH 9.8+, sshd-session) trzeba dodać także /usr/libexec/sshd-session. Nauczyciel postępujący według instrukcji z aplikacji zostaje na macOS 15+ z podglądem samej tapety.

**Status:** naprawione (164bb34)

### TXT-15

**W oknie pojawia się skrócona etykieta CLI stanu („offline”, „online”, „błąd”)** – P2, Teksty, `Sources/CMCRManager/RemoteBrowserComponents.swift:271`; także: `Sources/CMCRManager/PowerView.swift:354`

Okno konsekwentnie używa Reachability.displayName („Włączony”, „Niedostępny”, „Błąd połączenia”, „Nie sprawdzono” – Components.swift:31; komentarz: „the CLI keeps the short label”). W kilku miejscach trafia tam jednak `.label` z CLI. Selektor komputera w Przeglądarce plików pokazuje „imac04 (offline)” i „imac04 (błąd)”. Arkusz potwierdzenia zasilania pokazuje „pominięty – offline” (PowerView.swift:354), choć ConfirmSheet pisze „pominięty – niedostępny” (Components.swift:178). Duży kafelek podglądu pokazuje „offline” pod „Komputer nie odpowiada” (ScreenCenter.swift:395). Raport CSV zapisywany z okna ma w kolumnie „Stan” wartości „online”, „offline”, „nieznany”, „błąd” (Classroom.swift:605).

**Status:** naprawione (6890f7f)

### TXT-16

**Trzy różne nazwy opcji macOS „pełny dostęp do dysku dla użytkowników zdalnych”** – P2, Teksty, `Sources/CMCRManager/RemoteBrowserComponents.swift:400`

Tę samą opcję z Ustawień systemowych, którą nauczyciel musi znaleźć przy iMacu, opisano w cudzysłowie na trzy sposoby. (1) „Zezwalaj zdalnym użytkownikom na pełny dostęp do dysku” – tutaj i w README:171. (2) „Daj użytkownikom zdalnym pełny dostęp do dysku” – README:77, ReadinessView.swift:275, Scripts+Setup.swift:46 i 250, setup/cmcr-imac-setup.sh:920 i 922. (3) „Pełny dostęp do dysku dla zdalnych użytkowników” – Scripts.swift:303, 321, 791, 821, 922, przy czym ścieżka pomija tam krok ⓘ. Ta sama opcja ma w różnych miejscach różne nazwy, a co najmniej dwie z nich nie są dosłowną etykietą z macOS.

**Status:** naprawione (c5393e1). Wszędzie dosłowna etykieta macOS „Daj użytkownikom zdalnym pełny dostęp do dysku” (sprawdzona w polskiej lokalizacji Ustawień systemowych); część w aplikacji i README – b19829f.

### TXT-17

**Tytuły zadań przeglądarki: „Usuń/Pobierz/Wyślij 3 elementów”** – P2, Teksty, `Sources/CMCRManager/RemoteBrowserModel.swift:260`; także: `Sources/CMCRManager/RemoteBrowserModel.swift:259`, `Sources/CMCRManager/RemoteBrowserView.swift:373`

`what` jest ręcznie sklejane jako "\(n) elementów" (linie 259, 270, 292) i trafia do tytułów zadań „Usuń \(what) z …” (260), „Pobierz \(what) z …” (272) i „Wyślij \(what) → …” (293). Dla n = 2–4 i 22–24 wymagany jest biernik „elementy”. Błędny tytuł widać w Zadaniach, w historii, w actions.log i w toście „Uruchomiono „Usuń 3 elementów z /Users/student/Desktop” na 1 komputerze”. Aktywność „Usuwanie 3 elementów…” (dopełniacz) jest poprawna.

**Status:** naprawione (fe7f85a)

### TXT-19

**Uaktualnienie aplikacji nazwane „aktualizacją”** – P2, Teksty, `Sources/CMCRManager/Updater.swift:174`

README i UI rozróżniają „uaktualnienia” CMCR Manager („Sprawdź uaktualnienia…”, „Uaktualnienia CMCR Manager”) od „aktualizacji” macOS (dział Aktualizacje). Toast po udanej instalacji brzmi jednak „Zaktualizowano do wersji X”, a szczegół gotowości (Scripts+Setup.swift:270) każe „zaktualizuj CMCR Manager”.

**Status:** naprawione (d4990a4). „Uaktualniono do wersji X” (164bb34) i „uaktualnij CMCR Manager” w gotowości.

### TXT-20

**Pomoc cmcrctl: ustawienie „Równoległe operacje” nie istnieje, formatowanie niespójne** – P2, Teksty, `Sources/cmcrctl/CLI.swift:69`

Pomoc -j odsyła do „„Równoległe operacje” z ustawień”, a w aplikacji to ustawienie nazywa się „Komputery obsługiwane naraz” (SetupView.swift:882). Do tego w `cmcrctl --help` brakuje pustego wiersza przed nagłówkiem „Instalacja i inne” (Legacy.swift:161), nagłówek „Zajęcia, zasilanie i raporty:” jako jedyny ma dwukropek (ClassroomCommands.swift:7), a wiersz `selftest` jest przesunięty o kolumnę (CLI.swift:65).

**Status:** naprawione (1d5763e). Pomoc cmcrctl: właściwa nazwa ustawienia „Komputery obsługiwane naraz”, spójne nagłówki.

### TXT-22

**cmcrctl: „Zakończono: 3 cykli, 1 nowych obrazów” i „1 błędów składni”** – P2, Teksty, `Sources/cmcrctl/ScreenWatch.swift:52`

Podsumowanie screen-watch skleja liczebniki ręcznie. Domyślne --frames 3 daje „3 cykli”, a istniejący test e2e (Tests/e2e/suites/screens.sh:86: 3 klatki, 1 nowa) wypisuje „Zakończono: 3 cykli, 1 nowych obrazów.”. Poprawnie: „3 cykle, 1 nowy obraz”. Tak samo CLI.swift:637 („selftest: 1 błędów składni”, „2 błędów”) i :640 („N skryptów” – dziś 89, poprawnie, ale nie dla 92–94).

**Status:** naprawione (a0504cc, 1202893). Liczebniki screen-watch i selftest przez Polish.count.

### TXT-23

**Raport skryptu konfiguracyjnego: „Zainstalowano Rosetta 2”, „wpis(ów)”, „klucz menedżera”** – P2, Teksty, `setup/cmcr-imac-setup.sh:836`

(1) Brak odmiany nazwy: „Zainstalowano Rosetta 2.” (836), „Instalacja Rosetta 2 nie powiodła się” (837), „zainstalować Rosetta 2.” (834), „--rosetta zainstaluj Rosetta 2” (88). Aplikacja odmienia: „Zainstaluj Rosettę 2” (SetupOptionsSheet.swift). (2) Liczebniki z nawiasami: „jest już 3 wpis(ów)” (466), „zapis 1 klucza(y)” (514). (3) „Klucz SSH menedżera” (521–524), a aplikacja mówi „klucz SSH aplikacji”. (4) „(stan pokaże CMCR Manager: Konfiguracja › Przygotowanie iMaców › Sprawdź)” (929) – przycisk to „Sprawdź wszystkie” (ReadinessView.swift:396).

**Status:** naprawione (f4adabf). Raport skryptu: „Rosettę 2”, liczebniki bez nawiasów, „klucz SSH aplikacji”, „Sprawdź wszystkie”.

### TXT-24

**Folder /Applications nazywany raz „Programy”, raz „Aplikacje”; aktualny polski macOS pokazuje „Aplikacje”** – P2, Teksty, `Sources/CMCRManager/SetupOptionsSheet.swift:421`

Ten sam folder /Applications ma w aplikacji dwie nazwy. „Programy”: InstallView.swift:55 („Aplikacje trafią do folderu Programy”), AppsView.swift:287/316/317, ulubione Przeglądarki i wyboru folderu RemoteBrowse.swift:266, instrukcja SetupOptionsSheet.swift:421 („otwórz Terminal (Programy › Narzędzia)”), README:11. „Aplikacje”: SelfUpdate.swift:649/652 i README:190. Aktualny polski macOS pokazuje w Finderze „Aplikacje” (sprawdzone na 27.0.1: SystemFolderLocalizations pl, Applications => „Aplikacje”, Utilities => „Narzędzia”). Nauczyciel przy iMacu z aktualnym macOS, który idzie za instrukcją zapisu skryptu, szuka folderu „Programy › Narzędzia”, którego w Finderze nie ma. W Przeglądarce plików widzi ulubiony folder pod inną nazwą niż w Finderze.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (164bb34)

### UI-01

**⌘, przypisany trzem pozycjom menu – skrót opisany przy „Ustawienia…” nie otwiera okna Ustawień** – P2, Interfejs, `Sources/CMCRManager/App.swift:70`; także: `README.md:182`, `Sources/CMCRManager/App.swift:68`

CommandGroup(replacing: .appSettings) usuwa standardową pozycję „Ustawienia…” sceny Settings i wstawia „Konfiguracja…” (⌘,), która tylko przełącza dział w głównym oknie. Okno Ustawień (AppSettingsWindow) da się otworzyć wyłącznie linkiem na dole Konfiguracja › Ustawienia (SetupView.swift:786). README i teksty w aplikacji (SetupView.swift:789 „(⌘,)”, 792 „z menu CMCR Manager › Ustawienia… (⌘,)”) opisują nieistniejącą pozycję. Skutek uboczny: SnapshotRenderer.captureSettings (SnapshotRenderer.swift:155-165) wybiera pozycję z ⌘, – okno Ustawień się nie otwiera, wpis „settings” kończy się komunikatem „Brak okna Ustawień” i nie powstaje zrzut okna Ustawień wymagany w Etapie 3. Dodatkowo ⌘, jest przypisany dwóm pozycjom (App.swift:70 i Przejdź › Konfiguracja, App.swift:81). To regresja z równoległych commitów 776e90c (okno Ustawień ⌘,) i ba73c33 (Konfiguracja… ⌘,).

**Status:** naprawione (7c11459)

### UI-05

**„Wczytaj listę z pliku…” zastępuje całą listę komputerów bez potwierdzenia** – P2, Interfejs, `Sources/CMCRManager/SetupView.swift:378`

importHosts() od razu wykonuje model.machines = hosts (didSet natychmiast zapisuje hosts.json) – bez potwierdzenia i bez oznaczenia akcji jako niszczącej (pozycja menu ze zwykłą ikoną square.and.arrow.down, SetupView.swift:299-303). Wybranie złego pliku nieodwracalnie kasuje grupy, notatki, adresy MAC, porty i ustawienia haseł bieżącej listy; własne hasła usuniętych wpisów zostają w Pęku kluczy (askDelete, 364, je czyści). Generator (askReplace, 506-516) i CLI (README: zastępowanie listy pyta o potwierdzenie) wymagają potwierdzenia.

**Status:** naprawione (a45dba1)

### UI-06

**Usunięty standardowy przycisk paska bocznego i wymuszany tryb paska narzędzi** – P2, Interfejs, `Sources/CMCRManager/App.swift:158`

.toolbar(removing: .sidebarToggle) usuwa systemowy przycisk pokazywania/ukrywania paska bocznego (bo przy wymuszonych podpisach nie mieścił się). Po ukryciu paska (⌃⌘S lub przeciągnięciem) nie ma widocznej kontrolki, by go przywrócić – tylko Widok › Pokaż pasek boczny. ToolbarTitlesShown (MainToolbar.swift:84-88) przy każdym uruchomieniu wymusza tryb „ikona i tekst”, nadpisując wybór użytkownika z poprzedniej sesji.

**Status:** naprawione (ada0970)

### UI-07

**Lista uruchomionych aplikacji nie wczytuje się dla komputerów zaznaczonych po wejściu w dział** – P2, Interfejs, `Sources/CMCRManager/AppsView.swift:40`

refreshRunningApps jest wywoływane tylko w onAppear (AppsView.swift:39-41) i przyciskiem „Odśwież listę”. Komputery zaznaczone później trafiają do grupy „Wczytywanie listy…” z klepsydrą (AppsView.swift:191-192), choć nic się nie wczytuje. Błędy listy zainstalowanych są pomijane (AppModel.swift:823 – komputer po prostu nie jest liczony do „Sprawdzono N komputerów”).

**Status:** naprawione (4e9b22c)

### UI-08

**Ta sama akcja lub ten sam stan oznaczane różnymi symbolami** – P2, Interfejs, `Sources/CMCRManager/ClassroomView.swift:496`; także: `Sources/CMCRManager/AppModel.swift:36`, `Sources/CMCRManager/PowerView.swift:155`

„Przerwij”: stop.circle (Components.swift:536/700, ActivityViews.swift:193) i xmark.circle w scenariuszu zajęć (ClassroomView.swift:496). Tryb uwagi: eye.slash (zakładka i nagłówek, ClassroomView.swift:24/613) i lock.fill (przyciski i wskaźniki, ClassroomView.swift:110/591/606, DashboardView.swift:262). Wake-on-LAN: sunrise (Obudź), dot.radiowaves.left.and.right (ReadinessView.swift:435/807, SetupOptionsSheet.swift:206), network (EnergyScheduleView.swift:73). Stan „niedostępny”: moon.zzz.fill (Components.swift:22, DashboardView.swift:162), moon.zzz (ScreenTiles.swift:151), wifi.slash (ReadinessView.swift:484, RemoteBrowserComponents.swift:386, HostTrustSheet.swift:128). Włączanie po zaniku zasilania: bolt.circle (EnergyScheduleView.swift:64) i bolt.fill (SetupOptionsSheet.swift:212). „Hasło tego komputera…”: key (SetupView.swift:233) i key.fill (ReadinessView.swift:797/802). Uprawnienia administratora: lock.shield (Przeglądarka) i lock.fill (CommandsView.swift:112). Import i eksport tym samym square.and.arrow.down („Wczytaj listę z pliku…” SetupView.swift:302, „Zapisz skrypt do pliku…” ReadinessView.swift:422).

**Status:** naprawione (1849b4d)

### UI-10

**Niespójna terminologia: „sekcja” zamiast „dział”, „Zaktualizowano” dla uaktualnienia aplikacji, „Pobrane rzeczy” vs „Pobrane”** – P2, Interfejs, `Sources/CMCRManager/ClassroomView.swift:859`

README i reszta UI mówią „dział” („w dziale Zadania”), a ClassroomView.swift:859 „(sekcja Aplikacje)” i ScreenControls.swift:221 „Pokaż wyniki w sekcji Zadania”. README i menu rozróżniają Aktualizacje (iMaki) i Uaktualnienia (CMCR Manager), a toast po instalacji brzmi „Zaktualizowano do wersji X” (Updater.swift:174). Folder Downloads: „Pobrane rzeczy” (SetupOptionsSheet.swift:420) i „Pobrane” (ClassroomView.swift:361, 405; Sources/CMCRCore/RemoteBrowse.swift:261).

**Status:** naprawione (164bb34)

### UI-12

**Przykładowy komunikat w zrzutach UI podaje nieistniejący plik „hosts.json.damaged”** – P2, Interfejs, `Sources/CMCRManager/ConfigIssuesAlert.swift:48`

Tekst dla SnapshotRenderer (podstrona configissues) mówi „Oryginał zachowano jako hosts.json.damaged”, a ConfigStore zapisuje kopię jako &lt;nazwa>.&lt;data>.bak (Sources/CMCRCore/Store.swift:63, 163; README: „*.bak”). Zrzuty w docs/ui-review pokażą nieprawdziwą informację.

**Status:** naprawione (06a56e9)

### UI-13

**Tabela działu Komputery z otwartym panelem szczegółów nie mieści się w oknie 1180 pt** – P2, Interfejs, `Sources/CMCRManager/DashboardView.swift:65`

Domyślnie widoczne kolumny mają minimalne szerokości 60+95+70+90+45+80 = 440 pt (DashboardView.swift:255-334). Przy minimalnym oknie 1180 pt (pasek boczny 190–210, lista 250–290) i inspektorze 260–310 pt (DashboardView.swift:67) na tabelę zostaje ok. 330–390 pt po marginesach 2×20 – pojawia się przewijanie poziome, a kolumna „Uwagi” z komunikatami błędów jest poza widokiem. Komentarz (288) zakłada dopasowanie do 1180 pt tylko bez inspektora, a stan inspektora jest zapamiętywany (@AppStorage dashboardInspector).

**Status:** naprawione (81b3f99). sprawdzone zrzutem 1180×720 z otwartym panelem szczegółów: wszystkie domyślne kolumny mieszczą się bez przewijania (wcześniejszy commit ada0970 zmniejszył szerokości)

### UI-14

**Błędy zapisu i otwierania sygnalizowane tylko dźwiękiem albo przemilczane** – P2, Interfejs, `Sources/CMCRManager/JobsView.swift:666`; także: `Sources/CMCRManager/AppModel.swift:778`, `Sources/CMCRManager/ClassroomModel.swift:596`, `Sources/CMCRManager/ClassroomModel.swift:606`, `Sources/CMCRManager/SetupView.swift:306`

Bez komunikatu dla użytkownika: zapis eksportu wyników zadań (JobsView.swift:666), brak dziennika działań (JobsView.swift:159), zapis raportu CSV i odpowiedzi/wersji (ClassroomModel.swift:596, 606), zapis zrzutu ekranu (ScreenTiles.swift:319, 329), otwarcie sesji SSH w Terminalu (AppModel.swift:698), przygotowanie folderów all/&lt;komputer> (AppModel.swift:778), rozsyłanie klucza bez pliku .pub (AppModel.swift:909), niepoprawna nazwa w „Nowy folder”/„Zmień nazwę” – alert znika razem z wpisaną nazwą (RemoteBrowserComponents.swift:460). Eksport listy komputerów try? ConfigStore.exportHosts (SetupView.swift:306) nie daje nawet dźwięku. Np. zapis eksportu na wolumin tylko do odczytu kończy się samym „bip”.

**Status:** naprawione (06a56e9)

### UI-15

**„najwyżej N komputerów naraz” – zła odmiana dla N = 1…4** – P2, Interfejs, `Sources/CMCRCore/LessonRoutine.swift:169`

Limit pochodzi z settings.maxParallel (zakres 1…32, SetupView.swift:879; ClassroomModel.swift:288). Przy limicie 2–4 wynik scenariusza zajęć mówi „Czekam na swoją kolej (najwyżej 3 komputerów naraz)…”, a przy limicie 1 – „najwyżej 1 komputerów”.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (d8f9dc8). „najwyżej 1 komputer / 3 komputery / 5 komputerów naraz”.

### UI-16

**„Zmień ograniczenia…” otwiera Konfigurację na zakładce Komputery zamiast ustawień podglądu** – P2, Interfejs, `Sources/CMCRManager/ScreenControls.swift:49`

SetupView trzyma zakładkę w @ViewState (SetupView.swift:30), więc każde wejście do działu zaczyna od „Komputery”. Odnośnik „Zmień ograniczenia…” z paska podglądu i Ściany ekranów (ScreenControls.swift:48-51) ustawia tylko model.section = .setup – ustawienia prywatności podglądu są w zakładce Ustawienia (lub w oknie Ustawień › Podgląd ekranów). Tak samo powrót do Konfiguracji po sprawdzeniu wyników w Zadaniach gubi wybraną zakładkę.

**Status:** naprawione (06a56e9)

### UI-17

**„Szczegóły” w banerze podglądu i pasku Przeglądarki otwiera Zadania bez wskazania właściwego działania** – P2, Interfejs, `Sources/CMCRManager/ScreenControls.swift:217`; także: `Sources/CMCRManager/RemoteBrowserView.swift:219`

Oba odnośniki ustawiają tylko model.section = .jobs (ScreenControls.swift:217, RemoteBrowserView.swift:219). JobsView wybiera najnowsze działanie tylko gdy focusedBatchID == nil (JobsView.swift:71), więc jeśli wcześniej oglądano inne działanie, kliknięcie „Szczegóły” przy „Wiadomość – nie powiodło się na 2 z 10” pokazuje stare wyniki. Toast i BatchResultsView używają poprawnie model.showJobs(batch.id).

**Status:** naprawione (06a56e9)

### UI-18

**Animacje przesunięcia i skalowania ignorują ustawienie „Ogranicz ruch”** – P2, Interfejs, `Sources/CMCRManager/ScreenControls.swift:238`

Tylko ActionToastOverlay (ActivityViews.swift:44-54) sprawdza accessibilityReduceMotion. Bez sprawdzenia: baner wyniku podglądu .move(edge: .bottom) (ScreenControls.swift:238), powiększanie ekranu .scale + .animation (ScreenGrid.swift:116-119) i animowane przewijanie (ScreenGrid.swift:90), baner uaktualnienia (UpdateViews.swift:24, 56), toast po uaktualnieniu .move(edge: .top) (UpdateViews.swift:431), przewijanie do postępu zajęć (ClassroomView.swift:90).

**Status:** naprawione (06a56e9)

### UI-19

**Świeżość obrazu i zaznaczenie kafelka w podglądzie rozróżniane tylko kolorem** – P2, Interfejs, `Sources/CMCRManager/ScreenTiles.swift:268`

FreshnessBadge pokazuje zawsze circle.fill – zielony/pomarańczowy/czerwony (aktualny/opóźniony/stary); tekst wieku nie mówi, który próg przekroczono. Obramowanie kafelka (ScreenTiles.swift:544-549) sygnalizuje zaznaczenie (accent), problem (czerwony/pomarańczowy) i nieaktualność (pomarańczowy) tylko kolorem i grubością. Także „mało miejsca” w kolumnie Wolne miejsce (DashboardView.swift:417-421) tylko kolorem. Stany Reachability, Job, Readiness i StepState mają osobne kształty – tu tego brakuje.

**Status:** naprawione (06a56e9)

### UI-20

**Ikona „Pełny ekran” w Ścianie ekranów wymaga macOS 15 – na macOS 14 przycisk jest bez ikony** – P2, Interfejs, `Sources/CMCRManager/ScreenWall.swift:230`

arrow.up.left.and.arrow.down.right.rectangle pochodzi z SF Symbols 6 (name_availability.plist: 2024 → macOS 15.0), a cel aplikacji to macOS 14 (Package.swift, LSMinimumSystemVersion 14.0). Na macOS 14 Label pokaże pusty obrazek. Wszystkie pozostałe użyte nazwy symboli (sprawdzone NSImage(systemSymbolName:) i name_availability) są dostępne od macOS ≤ 14.0.

**Status:** naprawione (1849b4d)

### UI-21

**Menu i menu kontekstowe mieszają pozycje z ikonami i bez ikon** – P2, Interfejs, `Sources/CMCRManager/ScreenWall.swift:414`

W menu z ikonami są pozycje tylko tekstowe: „Podgląd ekranu w nowym oknie” (ScreenWall.swift:414, w MachineContextMenu App.swift:657), „Pokaż szczegóły” (DashboardView.swift:235), „Wstrzymaj podgląd ekranów” obok „Ściana ekranów” z ikoną w menu Okno (ScreenWall.swift:399/401), menu „Wstaw polecenie” z ikoną tylko przy poleceniach root (CommandsView.swift:111-115). Menu całkowicie tekstowe przy menu Przejdź z ikonami (App.swift:79): Widok/Edycja/aplikacja (App.swift:54, 61, 63, 65, 69; UpdateViews.swift:11), menu grupy (App.swift:433-437), Zaznacz (App.swift:513-524, także menu pustego obszaru listy), menu kontekstowe wyników zadań (JobsView.swift:363, 366, 370) i Eksportuj (JobsView.swift:322, 326).

**Status:** naprawione (9e2acf6)

### UI-22

**Symbole SF z ograniczeniami Apple użyte niezgodnie z przeznaczeniem** – P2, Interfejs, `Sources/CMCRManager/UpdatesView.swift:54`

Według symbol_restrictions.strings (CoreGlyphs): apple.logo – tylko dla „Sign in with Apple” (nagłówek „Aktualizacje macOS”, UpdatesView.swift:54); safari – tylko dla przeglądarki Safari (nagłówek „Otwórz stronę internetową lub plik”, AppsView.swift:135 – otwiera w domyślnej przeglądarce); iphone.gen2 – tylko dla iPhone’a (przycisk „Zainstaluj Android SDK”, InstallView.swift:215); person.badge.key – tylko dla kluczy dostępu (ulubiony folder „Katalog domowy administratora”, Sources/CMCRCore/RemoteBrowse.swift:267); macbook – tylko dla MacBooka („Folder na tym Macu”, SetupView.swift:830 – Mac nauczyciela nie musi nim być).

**Status:** naprawione (1849b4d)

### UI-23

**Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) pokazuje tylko, że pomoc jest niedostępna** – P2, Interfejs, `Sources/CMCRManager/App.swift:49`

Aplikacja nie zastępuje grupy poleceń .help, a pakiet nie ma Księgi pomocy (w Info.plist z scripts/build-app.sh:70-89 brak CFBundleHelpBookName). Menu w zrzucie docs/ui-review/before/setup-light.txt zawiera „Pomoc aplikacji CMCR Manager [⌘?]”. Jej wybór kończy się tylko systemowym komunikatem „Pomoc aplikacji CMCR Manager nie jest dostępna.” (AppKit HelpManager.loctable), mimo że instrukcja istnieje w README – to martwa pozycja menu.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (7c11459)

### UI-24

**„Usuń grupę” bez potwierdzenia, niespójne role „Przerwij”, przyciski niszczące tuż obok zwykłych** – P2, Interfejs, `Sources/CMCRManager/App.swift:437`

„Usuń…” w pasku Przeglądarki stoi między „Pobierz…” a „Wyślij tutaj…” (RemoteBrowserView.swift:97-122); „Odinstaluj…” tuż obok „Uruchom” (AppsView.swift:308-324); „Usuń harmonogram…” obok „Zastosuj harmonogram” (EnergyScheduleView.swift:96-99); „Usuń z listy…” obok wyróżnionego „Dodaj komputer” (SetupView.swift:262-276); „Wymuś zamknięcie…” obok „Zamknij” w każdym wierszu (AppsView.swift:438-452). „Przerwij” scenariusza zajęć ma role: .cancel (ClassroomView.swift:493), a „Przerwij” zadań role: .destructive (Components.swift:535). „Usuń grupę” (App.swift:437) zdejmuje grupę ze wszystkich komputerów bez potwierdzenia.

**Status:** naprawione (9e2acf6)

### UI-25

**Zrzut „settings” w ciemnym motywie pokazuje zakładkę Uaktualnienia zamiast Ogólne** – P2, Interfejs, `Sources/CMCRManager/SetupView.swift:1044`

AppSettingsWindow.onSnapshotSubpage zmienia zakładkę tylko dla znanej nazwy. Pusta podstrona (wpis „settings” bez „:zakładka”) nie przywraca zakładki Ogólne, a okno Ustawień jest używane ponownie w kolejnym przebiegu. W ciemnym przebiegu wpis „settings” następuje po jasnym „settings:updates”, więc docs/ui-review/before/settings-dark.png jest identyczny z settings-updates-dark.png i brakuje zrzutu zakładki Ogólne w ciemnym motywie wymaganego w Etapie 3. SnapshotRenderer.swift:12-13 zapowiada, że pusta podstrona oznacza powrót do domyślnej.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (06a56e9)

### UI-26

**Trzy akcje nadal z dwoma różnymi symbolami po ujednoliceniu ikon** – P2, Interfejs, `Sources/CMCRManager/ScreenControls.swift:167`

„Otwórz Konfigurację”: gearshape (RemoteBrowserComponents.swift:352) i arrow.up.forward.app (SetupView.swift:1087). „Rozpocznij zajęcia”: play.fill na przycisku i play.circle w nagłówku (ClassroomView.swift:225/233). „Wyślij wiadomość”: text.bubble w Ścianie ekranów i siatce podglądu (ScreenWall.swift:356, ScreenGrid.swift:279), ale paperplane.fill w arkuszu wiadomości (ScreenControls.swift:167) – a paperplane oznacza w aplikacji wysyłanie plików. W dziale Sesja i zasilanie przycisk „Wyślij wiadomość” też miał paperplane.fill (PowerView.swift:70).

**Status:** naprawione (8d03346). Wyjątek w teście: „Zamknij” nazywa dwie różne akcje (zamknięcie komunikatu w oknie – xmark, zamknięcie aplikacji na iMacach – xmark.circle). Wariant .fill tego samego symbolu oznacza włączony stan (plakietka „Jako administrator”).

### UI-27

**Wczytanie listy z pliku i zapis do pliku nadal tym samym symbolem** – P2, Interfejs, `Sources/CMCRManager/ReadinessView.swift:437`

Poprawka UI-08 nie objęła przykładu z samego zgłoszenia: „Zastąp listę z pliku…” (SetupView.swift:324) i „Zapisz skrypt do pliku…” (ReadinessView.swift:437) miały square.and.arrow.down, podobnie „Zapisz do pliku…” w Zadaniach (JobsView.swift:329), „Zapisz zrzut ekranu…” (ScreenTiles.swift:426) i „Zapisz…” w arkuszu przygotowania iMaców (SetupOptionsSheet.swift:122). Jednocześnie „Zapisz listę do pliku…” i „Eksportuj…” miały square.and.arrow.up – ta sama czynność miała dwa symbole, a dwie przeciwne czynności jeden.

**Status:** naprawione (da01391)

### UI-28

**Przywrócony przycisk paska bocznego zawsze trafia do menu przepełnienia „»”** – P2, Interfejs, `Sources/CMCRManager/App.swift:152`

Poprawka UI-06 przywróciła systemowy przycisk paska bocznego, ale w trybie „ikona i tekst” jego tytuł („Ukryj pasek boczny”) nie mieści się nad paskiem bocznym (190–210 pt minus przyciski okna). Przycisk zawsze ląduje w menu przepełnienia „»” na prawym końcu paska, także w oknie 1440 pt, w którym na pasku jest dużo wolnego miejsca – opis paska w zrzucie after/dashboard-light.txt: „Ukryj pasek boczny (overflow)”.

**Status:** naprawione (bb69701). Przycisk „Pasek boczny” (sidebar.left) stoi na początku paska kolumny z listą komputerów i przełącza widoczność kolumn; ⌃⌘S w menu Widok działa jak wcześniej. Przy 1180 pt z otwartym panelem szczegółów do „»” trafia tylko „Aktywność”.

### UI-29

**„Zapisz raport o komputerach (CSV)…” nadal używa tablecells, łamiąc regułę z da01391: zapis/eksport = square.and.arrow.up** – P2, Interfejs, `Sources/CMCRManager/DashboardView.swift:136`

da01391 ustanawia regułę „zapis i eksport z aplikacji – square.and.arrow.up”, a docs/ui-review/README.md:112 ją wymienia. Każdy inny zapis lub eksport do pliku już się do niej stosuje, w tym eksporty CSV „Eksportuj CSV…” (ClassroomView.swift:756, HostInspector.swift:421). Raport CSV w Komputery › Więcej › Raporty zapisuje plik z symbolem „tablecells”. importAndSaveHaveDifferentSymbols sprawdza tylko, czy import i zapis nigdy nie mają wspólnego symbolu, a nie czy wszystkie zapisy mają ten sam, więc tego nie wychwytuje.

Scenariusz: Komputery › Więcej › Raporty › „Zapisz raport o komputerach (CSV)…” pokazuje ikonę tabeli. Przycisk „Eksportuj CSV…” w wynikach pytań i w arkuszu wersji aplikacji, który również zapisuje plik CSV, pokazuje square.and.arrow.up.

**Status:** naprawione (f33c3a1). „Zapisz raport o komputerach (CSV)…” ma teraz symbol square.and.arrow.up, jak każdy zapis i eksport do pliku. Nowy test SymbolAvailabilityTests.everySaveToAFileHasTheSaveSymbol wymaga tego symbolu dla każdego tytułu „Zapisz…”, „Eksportuj…” i „… do pliku…”; wyjątkiem są „Zapisz hasło” i „Zapisz jako fragment…”, które nie zapisują pliku.

### UI-30

**Menu, które nadal mieszają pozycje z ikonami i bez ikon (pozostałość po UI-21)** – P2, Interfejs, `Sources/CMCRManager/ScreenWall.swift:211`

W menu Ściana ekranów › Widok (ScreenWall.swift:211-215) opcje układu mają ikony, ale przełącznik „Pokaż podpisy na ekranach” nie ma żadnej – to mieszanie pozycji z ikonami i bez ikon, które zgłaszało UI-21. Sprawdź pozostałe menu wskazane przez recenzenta: menu odświeżania (ScreenWall.swift:65-77: „Odświeżaj także, gdy aplikacja jest w tle”, „Wstrzymaj cały podgląd”), menu Filtr listy komputerów (App.swift:385-403), przełączniki grup w menu kontekstowych (ActivityViews.swift:388, App.swift:527), „Dni robocze/Codziennie/Weekendy” (EnergyScheduleView.swift:168-170), Szablony (PowerView.swift:51, ClassroomView.swift:578).

Scenariusz: Otwórz Ściana ekranów › Widok: pozycje układu mają ikony, „Pokaż podpisy na ekranach” – nie.

**Status:** naprawione (f4b7946). W menu Widok ściany ekranów przełącznik „Pokaż podpisy na ekranach” ma teraz ikonę text.below.photo, tak jak układy nad nim. Pozostałe wskazane menu nie mieszają ikon w jednej sekcji: menu odświeżania i Filtr są w całości bez ikon, a listy grup, dni, szablonów i aplikacji to całe menu albo całe sekcje bez ikon.

### UI-31

**Potwierdzenie wysłania do podfolderu w Przeglądarce plików nie podaje nazwy przeglądanego komputera** – P2, Interfejs, `Sources/CMCRManager/RemoteBrowserView.swift:351`

Po UI-04 potwierdzenia usunięcia i zastąpienia podają nazwę przeglądanego komputera (RemoteBrowserView.swift:387 „ na komputerze X”, 404 „z komputera X”). Potwierdzenie wysłania do podfolderu (RemoteBrowserView.swift:351-355, „Wysłać do folderu „X”?”) podaje tylko folder.

Scenariusz: Przeglądając imac04, wybierz „Wyślij pliki do tego folderu…” na podfolderze: pytanie nie mówi, którego komputera dotyczy.

**Status:** naprawione (26c2695). Pytanie przed wysłaniem do podfolderu brzmi teraz „Pliki o tych samych nazwach w folderze „X” na komputerze imac04 zostaną zastąpione…” (RemoteBrowserModel.uploadConfirmation). We wszystkich pytaniach i oknach wyboru przeglądarki nazwa komputera ma widoczne znaki kierunku tekstu (TerminalText.escape, jak w REV-19).

### UI-32

**„Usuń z listy…” w Konfiguracji › Komputery nadal stoi tuż obok zwykłego menu „Grupy” (pozostałość po UI-24)** – P2, Interfejs, `Sources/CMCRManager/SetupView.swift:302`

UI-24 oddzieliło przyciski niszczące od zwykłych akcji, ale w pasku pod listą komputerów separator stoi tylko między „Dodaj komputer” a „Usuń z listy…”. Zwykłe menu „Grupy” nadal przylega do przycisku niszczącego – tak jak w stanie wyjściowym (zrzuty setup-light.png przed i po).

**Status:** naprawione (a2065af). Pasek w Konfiguracja › Komputery ma teraz układ [Dodaj komputer][Grupy] | [Usuń z listy…], więc przycisk niszczący stoi osobno za separatorem, tak jak „Usuń…” w Przeglądarce plików.

### UI-33

**Kroki zajęć „Uruchom aplikacje” i „Zamknij aplikacje” mają inne symbole niż te same akcje w dziale Aplikacje** – P2, Interfejs, `Sources/CMCRCore/LessonRoutine.swift:29`

LessonStepKind.openApps („Uruchom aplikacje”) uruchamia ten sam skrypt co „Uruchom” w dziale Aplikacje, ale ma symbol macwindow.badge.plus (który już znaczy „Otwórz w nowym oknie”), a Aplikacje – play.fill. LessonStepKind.quitApps („Zamknij aplikacje”) uruchamia ten sam skrypt co „Zamknij”, ale ma xmark.app, a Aplikacje – xmark.circle. Test oneTitleOneSymbol tego nie widzi, bo nie czyta LessonStepKind.icon.

Scenariusz: Zajęcia › Początek lekcji – krok „Uruchom aplikacje” z symbolem okna; Aplikacje › „Uruchom” z symbolem odtwarzania.

**Status:** naprawione (c68ff60). Kroki zajęć „Uruchom aplikacje” i „Zamknij aplikacje” mają teraz symbole przycisków Aplikacje › „Uruchom” (play.fill) i „Zamknij” (xmark.circle). „Wyślij powitanie” ma teraz text.bubble jak „Wyślij wiadomość”, a „Wyczyść folder ucznia” i „Wyczyść Pobrane rzeczy” mają trash jak Pliki › „Wyczyść folder…”, bo uruchamiają te same skrypty; „Uprzedź uczniów” zostaje przy exclamationmark.bubble jak „Uprzedź zalogowanych uczniów”, a test RevR6appTests.everyLessonStepHasTheSymbolOfTheSameActionInTheApp porównuje symbol każdego kroku z odpowiadającą mu akcją aplikacji.

### UI-34

**Dwa kroki czyszczenia mają po UI-33 ten sam symbol, więc ich kolumny w siatce postępu zakończenia zajęć wyglądają tak samo** – P2, Interfejs, `Sources/CMCRCore/LessonRoutine.swift:37`

Po UI-33 „Wyczyść folder ucznia” i „Wyczyść Pobrane rzeczy” mają symbol trash (ta sama akcja co w Plikach). Siatka postępu zajęć opisuje kolumny kroków samą ikoną (nazwa tylko w podpowiedzi), a oba kroki stoją obok siebie, więc ✕ w jednej z dwóch identycznych kolumn nie mówi, który folder nie został wyczyszczony.

Scenariusz: Zakończ zajęcia z obydwoma krokami czyszczenia; błąd czyszczenia Pobranych rzeczy na imac04 – z samej siatki nie widać, który to krok.

**Status:** naprawione (13ce65e). W tabeli postępu zajęć kroki o tym samym symbolu (oba czyszczenia mają trash) mają pod symbolem krótki podpis: „folder ucznia” i „Pobrane”. Dzięki temu ✕ w kolumnie mówi, którego folderu nie wyczyszczono, a symbole (jedna akcja – jeden symbol) i podpowiedzi zostają bez zmian (test: RevR7appTests.everyColumnOfTheRunGridHasAHeaderOfItsOwn).

### WSP-03

**Odświeżanie co 2 min działa tylko przy otwartym oknie głównym – sama Ściana ekranów nie dostaje aktualnego stanu** – P2, Współbieżność, `Sources/CMCRManager/App.swift:134`; także: `Sources/CMCRManager/App.swift:135`

Pętla i attach siedzą w .task okna głównego (WindowGroup). Gdy nauczyciel zamknie okno główne i zostawi Ścianę ekranów (np. na projektorze), stan nie jest odświeżany (tylko przy aktywacji aplikacji) – źródło „Tylko włączone”/„Z zalogowanym uczniem” nie pokaże iMaców włączonych później. Odwrotnie: każde nowe okno główne (⌘N) startuje własną pętlę i pełne refreshStatus() – odświeżanie co ~60 s zamiast 120 s, a globalne arkusze (uaktualnienie, potwierdzenie powtórzenia, klucze komputerów, błędy konfiguracji) pokazują się w każdym oknie.

**Status:** naprawione (a00d381). pętla odświeżania w AppModel; to, że każde dodatkowe główne okno (⌘N) pokazuje te same arkusze, opisano jako propozycję w docs/ui-review/README.md (okno główne jako Window)

### WSP-04

**„Przerwij” nie działa w trakcie pakowania plików (tar)** – P2, Współbieżność, `Sources/CMCRManager/AppModel+Jobs.swift:322`

Payload.make uruchamia /usr/bin/tar bez ProcessHandle, a Batch.cancel działa tylko przez handle (zadania nie są anulowane jako Task). Przy instalatorach/folderach rzędu GB po „Przerwij” zadania zostają „W toku”, aż tar zapisze całe archiwum, dopiero potem kończą się jako anulowane. Dotyczy SharedPayload (wysyłanie, instalacja, materiały zajęć), cmcr-push (AppModel.swift:749) i wysyłania w Przeglądarce.

**Status:** naprawione (ff696d5)

### WSP-05

**Kliknięcie powiadomienia „Zakończono…” bez okna głównego niczego nie pokazuje** – P2, Współbieżność, `Sources/CMCRManager/AppModel+Jobs.swift:400`

Po zamknięciu okna z trwającymi zadaniami aplikacja działa dalej i po ≥30 s wysyła powiadomienie. Router.didReceive tylko aktywuje aplikację i ustawia section/focusedBatchID – bez okna głównego nic się nie pojawia (brak odpowiednika MainWindow.bringToFront). Delegate centrum powiadomień jest ustawiany dopiero w post(), więc powiadomienia z poprzedniego uruchomienia nie są obsługiwane.

**Status:** naprawione (a00d381)

### WSP-06

**Lista zainstalowanych aplikacji ignoruje błędy i nie pokazuje postępu** – P2, Współbieżność, `Sources/CMCRManager/AppModel.swift:823`

refreshInstalledApps zapisuje wynik tylko przy r.succeeded. Błąd logowania, sudo czy limit 40 s nie zostawia śladu: gdy zawiodą wszystkie komputery, „Pobierz listę” wygląda na martwy przycisk, przy części – komputery znikają z liczników bez wyjaśnienia, a stara lista zostaje bez oznaczenia. refreshRunningApps błędy zapisuje (HostApps.error).

**Status:** naprawione (4e9b22c)

### WSP-07

**Nowy folder / Zmień nazwę z „/” w nazwie – tylko dźwięk, nazwa przepada** – P2, Współbieżność, `Sources/CMCRManager/RemoteBrowserComponents.swift:460`

W alercie namePrompt nieprawidłowa nazwa (np. „Prace 2024/25”, „.”, „..”) kończy się NSSound.beep(); przycisk alertu i tak zamyka okno, więc wpisany tekst ginie, a nauczyciel nie wie, czemu folder nie powstał.

**Status:** naprawione (18ff2c5)

### WSP-08

**cmcrctl hosts add/set/remove/generate pisze „Dodano…” i kończy z kodem 0, choć hosts.json nie został zapisany** – P2, Współbieżność, `Sources/cmcrctl/ConfigCommands.swift:54`

ConfigStore.saveHosts (Store.swift:185-198) połyka błąd zapisu (tylko NSLog i nieczytany lastSaveError). Polecenia CLI zmieniające listę komputerów zawsze wypisują komunikat sukcesu i zwracają 0: ConfigCommands.swift:54, 71, 97, 122, 127, 178, rename --update-list w ClassroomCommands.swift:306 i zapis MAC w CLI.swift:350. Przy katalogu konfiguracji bez prawa zapisu (np. utworzonym przez sudo) albo przy pełnym dysku skrypt administratora uzna zmianę za wykonaną, a lista się nie zmieni.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (b5d9416). naprawione razem z KON-03

### WŁ-01

**Menu Pomoc › „Pomoc aplikacji CMCR Manager” (⌘?) nie prowadzi do żadnej pomocy** – P2, Własne, `Sources/CMCRManager/App.swift:46`

Aplikacja nie zastępuje standardowej grupy poleceń .help, a pakiet nie ma książki pomocy (Help Book). Pozycja „Pomoc aplikacji CMCR Manager” (⌘?) w menu Pomoc, widoczna w opisie menu ze zrzutów (docs/ui-review/before/*.txt), pokazuje więc tylko systemowy komunikat, że pomoc nie jest dostępna. Specyfikacją aplikacji jest README na GitHubie – menu Pomoc powinno do niego prowadzić.

**Status:** naprawione (7c11459)

### ZAD-03

**Wynik zdalnego zatrzymania nie trafia do podsumowania ani historii – „Anulowano” nawet gdy polecenie nadal działa** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:440`

Po Przerwij lokalne ssh dostaje SIGTERM i SSH.run wraca natychmiast; execute ustawia stan cancelled, summary „Anulowano” i archiwizuje zadanie. Zdalne zatrzymanie (cancelRemote, do ~30 s) kończy się później, a jego komunikat (np. „Nie udało się połączyć, aby zatrzymać polecenie – może ono nadal działać na komputerze” albo „Nie udało się zatrzymać wszystkich procesów…”) jest dopisywany tylko do logu w pamięci. Historia, „Kopiuj wynik” i eksport (fullOutput czyta plik z dysku) go nie zawierają, a kolumna Wynik nadal pokazuje „Anulowano”. Scenariusz: nauczyciel przerywa „softwareupdate --install --restart” na zawieszonym iMacu, zatrzymanie się nie udaje, a aplikacja raportuje przerwanie – iMac restartuje się później. Test e2e __run-job czeka na cancellationFinished(), aplikacja nie.

**Status:** naprawione (ff696d5)

### ZAD-04

**Zapis historii może nadpisać cały plik miesiąca jednym wpisem** – P2, Zadania, polecenia, `Sources/CMCRCore/JobHistory.swift:183`

Gdy FileHandle(forWritingTo:) nie otworzy istniejącego jobs-YYYY-MM.jsonl (np. brak prawa zapisu do pliku przy wspólnym CMCR_CONFIG_DIR, przywrócone uprawnienia), kod przechodzi do `line.write(to: file, options: .atomic)`, który przez plik tymczasowy i rename zastępuje cały plik miesiąca tą jedną linią – historia miesiąca znika bez komunikatu.

**Status:** naprawione (3949bd0). JobHistory.write dopisuje linię przez open(O_APPEND|O_CREAT) i zgłasza błąd zamiast zastępować cały plik miesiąca.

### ZAD-05

**Historia: wpisy starsze niż 90 dni widoczne z usuniętym wyjściem, limit 3000 tnie partie** – P2, Zadania, polecenia, `Sources/CMCRCore/JobHistory.swift:246`

purge usuwa katalogi wyjścia po dniu (&lt; dzień graniczny), ale pliki jobs-YYYY-MM.jsonl dopiero gdy cały miesiąc jest starszy – wpisy do ~120 dni zostają na liście „Historia”, a ich wynik pokazuje „(nie można odczytać …/output/2026-07-15/…)”. purge działa tylko przy starcie aplikacji. Do tego load(limit: 3000) ucina po rekordach, nie po partiach – najstarsza wczytana partia ma część komputerów (zła liczba, niepełne „Zaznacz nieudane”).

**Status:** naprawione (d0f47d8). Lista historii pomija partie sprzed granicy 90 dni i stosuje limit do całych partii.

### ZAD-06

**Przerwanie tuż po starcie pomija zatrzymanie na iMacu, choć polecenie już ruszyło** – P2, Zadania, polecenia, `Sources/CMCRCore/SSH.swift:424`

Akcja anulowania wywołuje cancelRemote tylko gdy lokalnie odebrano znacznik CMCR:SESSION-STARTED. Jeśli wrapper już go wypisał (i ustawił trap '' HUP), a znacznik jeszcze nie dotarł (okno ~RTT, np. Przerwij zaraz po starcie na 15 iMacach przez Wi-Fi), aplikacja pisze „Polecenie nie zostało uruchomione na komputerze”, zabija lokalne ssh, a skrypt na iMacu – po zarejestrowaniu i z przekaźnikami do /dev/null – wykonuje się do końca. Mechanizm znacznika .cancel (dla rejestracji po anulowaniu) jest w tym przypadku nieużywany.

**Status:** naprawione (ec7a98f). Przerwanie tuż po starcie ssh wysyła prośbę o zatrzymanie także bez znacznika startu.

### ZAD-07

**Kod 255 lub „ssh:” w stderr działającego polecenia oznacza iMaca jako niedostępny/błąd** – P2, Zadania, polecenia, `Sources/CMCRCore/SSH.swift:681`

diagnose traktuje każdy wynik z exitCode 255 albo stderr zawierającym „ssh:” jako błąd połączenia, nie sprawdzając r.started. Polecenie w dziale Polecenia, np. `git clone git@github.com:…` bez sieci („ssh: Could not resolve hostname…”, kod 128) albo `ssh inny.local …` (kod 255, „timed out”), daje podsumowanie „Nie można odnaleźć nazwy hosta…”/„Komputer nie odpowiada”, a execute ustawia stan .offline – przez kolejne do 2 min ten działający iMac jest pomijany przez „Pomiń niedostępne”.

**Status:** naprawione (1c0355f). Po starcie polecenia za błąd połączenia uchodzi tylko zerwanie sesji; inne kody to „Polecenie zakończone kodem N”.

### ZAD-08

**Powiadomienie „Gotowe na 0 komputerach” gdy wszystko się nie udało** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel+Jobs.swift:416`

JobNotifier.post zawsze zaczyna treść od „Gotowe \(Polish.onComputers(batch.succeeded))”, więc dla partii z samymi błędami lub przerwanej powiadomienie brzmi „Gotowe na 0 komputerach · błędy: 15”.

**Status:** naprawione (ff696d5)

### ZAD-09

**Niespójna terminologia anulowania i nagłówków wyników** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:442`

README mówi o przycisku „Anuluj”, w UI jest „Przerwij”, stan zadania to „Przerwano”, liczniki „Przerwane”, a podsumowanie zadania „Anulowano” (431, 442; także CommandResult „Anulowano.”). Nagłówek wyników w Poleceniach i innych działach to „Wynik ostatniej operacji” (CommandsView.swift:25), a w LastBatchView „Wynik ostatniego działania” (Components.swift:806).

**Status:** naprawione (ff696d5)

### ZAD-10

**Przy błędzie cały stderr jest dopisywany drugi raz do wyniku i historii** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:450`

stderr jest już strumieniowany do logu zadania (OutputSink), ale execute dopisuje r.stderr ponownie, jeśli cały połączony stderr nie jest podciągiem logu. Przy przeplecionym stdout/stderr (typowe dla instalatorów, brew, skryptu konfiguracji) nigdy nie jest, więc każdy nieudany job ma na końcu duplikat całego stderr – w podglądzie, historii i eksporcie; przy dużym stderr (setki kB) duplikat wypycha z 300 kB bufora prawdziwą końcówkę wyjścia.

**Status:** naprawione (ff696d5)

### ZAD-11

**„Wyczyść zakończone” gubi oglądaną partię z historii** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:491`

clearFinishedBatches zeruje focusedBatchID, gdy id nie ma w model.batches – a id partii z historii nigdy tam nie ma. Oglądając wpis z historii i klikając „Wyczyść zakończone”, użytkownik traci widok (onChange przełącza na pierwszą trwającą partię albo „Wybierz działanie”); to samo dla właśnie przenoszonej do historii partii z tej sesji.

**Status:** naprawione (ff696d5)

### ZAD-13

**cmcrctl uruchamia skrypty bez rejestracji zadania: Ctrl-C nie zatrzymuje polecenia na iMacu** – P2, Zadania, polecenia, `Sources/cmcrctl/CLI.swift:240`

runScript (exec, updates install, logout, power…) wywołuje SSH.run bez ProcessHandle, więc skrypt nie dostaje jobID: brak rejestru w /tmp/cmcr-jobs i przekaźników wyjścia, a cmcrctl nie obsługuje SIGINT (main.swift ignoruje tylko SIGPIPE). Ctrl-C zabija lokalne ssh, a wrapper ignoruje HUP – np. `cmcrctl exec "sleep 60; shutdown -r now" all --root` wykona restart mimo przerwania. Odwrotnie przy utracie połączenia (uśpienie MacBooka) ciało ginie na pierwszym zapisie (SIGPIPE), np. w trakcie `cmcrctl updates install all --restart --yes`. Aplikacja w obu przypadkach zachowuje się zgodnie z README (Anuluj zatrzymuje, utrata połączenia nie przerywa).

**Status:** naprawione (ba19edf). Ctrl-C w cmcrctl zatrzymuje polecenie także na iMacach (kod 130/143).

### ZAD-14

**cmcrctl nie zapisuje działań w dzienniku actions.log** – P2, Zadania, polecenia, `Sources/cmcrctl/CLI.swift:354`

Aplikacja loguje każde działanie (AppModel.runBatch → ConfigStore.log), a cmcrctl nie wywołuje ConfigStore.log w ogóle (poza HostTrust.trust). `cmcrctl exec … --root`, `power restart`, `logout`, `clean`, a także `screenshot`/`screen-watch` (README: „każda sesja podglądu jest zapisywana w dzienniku działań”) nie zostawiają śladu w wspólnym dzienniku – audyt „kto zrestartował pracownię” jest niepełny.

**Status:** naprawione (7a03609). cmcrctl zapisuje polecenia zmieniające stan i czytające prace uczniów w actions.log.

### ZAD-15

**cmcrctl exec --root nie pyta o ryzykowne polecenia, aplikacja pyta** – P2, Zadania, polecenia, `Sources/cmcrctl/CLI.swift:359`

W aplikacji CommandsView.run sprawdza CommandRisk (rm -r, shutdown/reboot, diskutil, dscl -delete, pmset…) dla poleceń root i wymaga potwierdzenia z listą komputerów. cmcrctl exec wykonuje to samo bez pytania, również w terminalu, podczas gdy `power restart` pyta – `cmcrctl exec "shutdown -r now" all --root` restartuje pracownię bez potwierdzenia.

**Status:** naprawione (5d3bdfc). exec --root z ryzykownym poleceniem pyta w terminalu, jak aplikacja.

### ZAD-16

**Przerwane zadania i zadania po limicie czasu mają w historii i eksporcie „kod” lokalnego ssh lub -1** – P2, Zadania, polecenia, `Sources/CMCRManager/AppModel.swift:439`

execute zapisuje job.exitCode = r.exitCode dla każdego wyniku, zanim rozróżni stan. Dla zadania przerwanego w trakcie jest to status lokalnego klienta ssh zabitego SIGTERM-em (ProcessRunner zwraca terminationStatus, Process.swift:361-368, np. 255). Dla zadania przerwanego w kolejce sesji albo podczas ponawiania jest to -1 z CommandResult.cancelledResult (Process.swift:40), a dla limitu czasu znów status ssh. Historia pokazuje to w kolumnie Stan jako „Przerwano (kod 255)” z podpowiedzią „Polecenie zakończyło się kodem 255 …” (JobsView.swift:525-531). Eksport pisze „=== imac04 – Przerwano, kod -1 ===” (JobsView.swift:637, 648). Ten kod nie pochodzi z polecenia na iMacu, a README obiecuje w historii kod wyjścia polecenia.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (ff696d5)

### ZAJ-02

**Eksport odpowiedzi uczniów do CSV bez ochrony przed formułami** – P2, Zajęcia, podgląd, `Sources/CMCRCore/Classroom.swift:563`

Odpowiedzi wpisuje uczeń (dowolny tekst), a CSV.escape tylko cytuje separator/cudzysłowy. Odpowiedź zaczynająca się od =, +, -, @ (np. =HYPERLINK("https://…";"Kliknij") albo =1+1) po otwarciu „odpowiedzi.csv” w Excelu/Numbers jest wykonywana jako formuła (CSV/formula injection). To samo dotyczy „Kopiuj” (TSV wklejany do arkusza). Raport ma się otwierać w Excelu (README), więc to realna ścieżka.

**Status:** naprawione (bb816ec). Ta sama neutralizacja w eksporcie odpowiedzi; „Kopiuj” używa CSV.tsv.

### ZAJ-06

**Puste ostrzeżenie końca zajęć pokazuje uczniom pusty komunikat** – P2, Zajęcia, podgląd, `Sources/CMCRCore/LessonRoutine.swift:91`

Krok „Uprzedź uczniów” jest dodawany zawsze, gdy włączony jest przełącznik, nawet przy pustym polu „Komunikat” (dla powitania tekst jest sprawdzany). Uczniowie dostają wtedy okno „Koniec zajęć” bez treści z przyciskiem OK.

**Status:** pominięte – wymaga decyzji właściciela: zmienia komunikat, który widzą uczniowie (pusty komunikat końca zajęć). Propozycja: przy pustym polu wysyłać domyślny tekst „Za chwilę koniec zajęć – zapisz pracę w folderze cmcr.” albo nie pozwalać uruchomić kroku bez treści.

### ZAJ-07

**Ręcznie sklejane liczebniki: „najwyżej 2 komputerów”, „3 cykli, 3 nowych obrazów”** – P2, Zajęcia, podgląd, `Sources/CMCRCore/LessonRoutine.swift:169`

Komunikat kolejki w scenariuszu używa stałej formy „komputerów”, a limit pochodzi z ustawienia „Jednoczesne operacje” (1–32): dla 1–4 i 22–24 powstaje „najwyżej 1 komputerów naraz”, „najwyżej 3 komputerów naraz”. Analogicznie cmcrctl screen-watch kończy się tekstem „Zakończono: 3 cykli, 3 nowych obrazów.” (domyślnie --frames 3) – poprawnie „3 cykle, 3 nowe obrazy”, „1 cykl, 1 nowy obraz” (Sources/cmcrctl/ScreenWatch.swift:52).

**Status:** naprawione (d8f9dc8). Odmiana w scenariuszu zajęć poprawiona razem z UI-15; licznik w cmcrctl screen-watch – w pakiecie cmcrctl.

### ZAJ-08

**Jakość JPEG z ustawień stosowana tylko przy zmniejszaniu obrazu** – P2, Zajęcia, podgląd, `Sources/CMCRCore/ScreenCapture.swift:436`

sips z -s formatOptions &lt;jakość> uruchamia się wyłącznie, gdy zrzut jest większy od żądanego rozmiaru. Gdy ekran jest mniejszy lub równy (np. iMac 21,5" 1920 px przy rozdzielczości ≥ 1920 w ustawieniach, MacBook 1440 px przy powiększeniu 1600 px, „Wszystkie ekrany” z mniejszym monitorem), wysyłany jest surowy JPEG screencapture z domyślną jakością – ustawienie „Jakość obrazu” jest ignorowane, wbrew README („ograniczona … jakość JPEG”).

**Status:** naprawione (0855b88). Każdy zrzut przekodowywany z jakością z ustawień; -Z tylko przy zmniejszaniu.

### ZAJ-09

**„Zamknij aplikacje › Wszystkie” zabija aplikacje SIGTERM bez szansy zapisu** – P2, Zajęcia, podgląd, `Sources/CMCRCore/Scripts+Classroom.swift:386`

Wariant „Wszystkie aplikacje ucznia” wysyła kill -TERM do wszystkich aplikacji (natychmiastowe zakończenie, bez okna „Zachować zmiany?”), podczas gdy „Tylko wybrane” wysyła standardowe „Zakończ” (Apple Event). Komentarz planu mówi o „graceful quit (autosave)”, a README – że „Zamknij” pozwala uczniowi zapisać pracę; podpis kroku obiecuje, że „w kopii znajdą się zapisane pliki”, tymczasem niezapisane zmiany giną tuż przed zbieraniem.

**Status:** pominięte – wymaga decyzji właściciela: zmienia sposób zamykania aplikacji w sesji ucznia (uczeń zobaczyłby pytania o zapisanie zmian). Propozycja: najpierw standardowe „Zakończ” dla każdej aplikacji, po kilku sekundach SIGTERM dla pozostałych – albo opisać w UI, że zamykanie jest wymuszone.

### ZAJ-10

**Nieudane ponowne zablokowanie odblokowuje ekran, a aplikacja pokazuje go jako zablokowany** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomModel.swift:395`

Skrypt blokady najpierw zabija istniejącą blokadę i jej licznik automatycznego odblokowania (pkill LockScreen, pkill -f TAG), a dopiero potem próbuje nowej. Gdy nowa się nie uruchomi (tryb „Blokada systemowa” na Macu bez działającego LockScreen albo błąd osascript), skrypt kończy się kodem 1 – ekran ucznia jest już odblokowany. W aplikacji wynik nieudany jest ignorowany, więc locks[m.id] zostaje i „Zablokowane teraz”/baner nadal pokazują komputer jako zablokowany.

**Status:** naprawione (2062ac8). aplikacja pokazuje prawdziwy stan po nieudanym ponownym zablokowaniu; zmiana kolejności w skrypcie blokady (zdejmowanie starej blokady dopiero po założeniu nowej) zmienia to, co widzi uczeń – czeka na decyzję właściciela

### ZAJ-11

**Pytanie: pominięte komputery wiszą jako „czeka na odpowiedź” na zawsze** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomModel.swift:427`

QuestionRound powstaje dla wszystkich zaznaczonych komputerów, ale runBatch przy włączonym (domyślnie) „Pomiń niedostępne” nie wykonuje operacji dla komputerów offline – nie trafiają ani do answers, ani do errors. round.pending nigdy nie spada do zera: kręcący się wskaźnik „czeka na odpowiedź: N” i wiersze „czeka na odpowiedź…” zostają do zamknięcia aplikacji, a CSV ma dla nich puste pola bez wyjaśnienia.

**Status:** naprawione (2062ac8)

### ZAJ-12

**Nowe pytanie nie zamyka poprzedniego – stare okna zostają u uczniów, a odpowiedzi znikają z tabeli** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomModel.swift:428`

ask() zastępuje classroom.question nową rundą, ale nie anuluje batcha poprzedniej (round.batch jest zapisywany i nigdzie nieużywany), a dział nie ma przycisku zakończenia pytania. Gdy nauczyciel poprawi literówkę i zada pytanie ponownie, uczniowie mają dwa okna jedno na drugim (do 10 min), a odpowiedzi na pierwsze trafiają do niewidocznej już rundy – znikają z tabeli i eksportu CSV.

**Status:** pominięte – wymaga decyzji właściciela: poprawka zamykałaby u uczniów okno poprzedniego pytania. Propozycja: przed nowym pytaniem przerwać poprzednie (zamyka okna na iMacach) albo zapytać nauczyciela; dodać przycisk „Zakończ pytanie”.

### ZAJ-13

**„Gotowe na wszystkich komputerach.” po przerwaniu lub pominięciu komputerów** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ClassroomView.swift:466`

Podsumowanie liczy tylko wiersze z .failed. Po „Przerwij” w trakcie odliczania wszystkie kroki dostają .skipped(„anulowano”), a przy „Pomiń niedostępne” część komputerów jest pomijana w całości – w obu przypadkach widać zieloną ikonę i „Gotowe na wszystkich komputerach.”, choć zajęć nie zakończono albo z części komputerów nie zebrano prac.

**Status:** naprawione (2062ac8)

### ZAJ-14

**cmcrctl lesson start budzi i obsługuje komputery po kolei** – P2, Zajęcia, podgląd, `Sources/cmcrctl/ClassroomCommands.swift:357`

W aplikacji pakiety Wake-on-LAN idą do wszystkich komputerów naraz, a czekanie i kolejne kroki biegną równolegle. W cmcrctl każdy komputer przechodzi cały scenariusz osobno: następny Mac dostaje pakiet budzenia dopiero po zakończeniu wszystkich kroków poprzedniego (łącznie z czekaniem do N min). Dla 15 uśpionych iMaców start zajęć ze skryptu trwa wielokrotnie dłużej niż „ten sam scenariusz z aplikacji” (README).

**Status:** naprawione (007beb7). lesson budzi i obsługuje komputery naraz (ConcurrencyLimiter), jak aplikacja.

### ZAJ-15

**screen-watch wypisuje ścieżkę klatki, nawet gdy zapis się nie udał** – P2, Zajęcia, podgląd, `Sources/cmcrctl/ScreenWatch.swift:99`

Zapis klatki jest w try?, a niezależnie od wyniku wypisywane jest „Klatka N: nowy obraz … → &lt;ścieżka>” i liczone frames += 1; polecenie kończy się kodem 0, choć w folderze nie ma żadnego pliku (np. folder tylko do odczytu, pełny dysk).

**Status:** naprawione (75d45af). Nieudany zapis klatki kończy screen-watch błędem (kod 1).

### ZAJ-17

**Wybór konkretnego monitora ukrywa przełącznik monitorów** – P2, Zajęcia, podgląd, `Sources/CMCRManager/ScreenCenter.swift:510`

displayCount jest brany z liczby ekranów w ostatniej klatce (`feed.set(\.displayCount, max(1, count))`). Po wybraniu „Ekran 2” skrypt przechwytuje tylko ten ekran, więc count = 1 i displayCount spada do 1. W oknie pojedynczego komputera znika wtedy z paska narzędzi menu monitora (ScreenWall.swift:336 `if feed.displayCount > 1`). W menu „Więcej › Monitor” znikają pozycje „Ekran 1…N” (ScreenTiles.swift:430-434), a wybrana wartość traci tag i Picker nie ma zaznaczenia. Żeby przejść na inny monitor, trzeba najpierw wybrać „Wszystkie ekrany”.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (2062ac8)

### ZAJ-18

**cmcrctl screen-watch i screenshot nie zapisują sesji podglądu w dzienniku działań** – P2, Zajęcia, podgląd, `Sources/cmcrctl/ScreenWatch.swift:34`

README (Podgląd ekranu – ograniczenia) zapewnia, że każda sesja podglądu jest zapisywana w dzienniku działań. W aplikacji robi to ScreenCenter: ConfigStore.log przy pierwszej klatce użytkownika, przy powiadomieniu i przy nieudanym powiadomieniu (ScreenCenter.swift:518, 548, 561). cmcrctl screen-watch i cmcrctl screenshot używają tego samego skryptu przechwytywania, ale nie robią żadnego wpisu – w Sources/cmcrctl nie ma ani jednego wywołania ConfigStore.log. Podgląd ekranu ucznia z terminala nie zostawia więc śladu w actions.log.

*Zgłoszone przez recenzenta przy weryfikacji innej pozycji; sprawdzane przy naprawie.*

**Status:** naprawione (31e9c5b). screenshot i screen-watch zapisują sesje podglądu w dzienniku działań.

## Odrzucone przy weryfikacji

Zgłoszenia, które niezależny recenzent sprawdził w kodzie i uznał za niepoprawne (zachowanie zamierzone, obsłużone gdzie indziej albo scenariusz niemożliwy). Nie wliczają się do podsumowania.

| Plik:linia | Zgłoszenie | Dlaczego odrzucone |
|---|---|---|
| `Sources/CMCRCore/Operations+Browse.swift:71` | „Zbierz prace” odrzuca całe archiwum, gdy jeden plik jest nieczytelny | Przesłanka „tar wysyła resztę” jest fałszywa dla `tar -cf - .` (pullArchive): sprawdziłem lokalnie bsdtar 3.5.3, który po „Can't open” przerywa przechodzenie katalogu, więc pozostałe pliki (w kolejności readdir) w ogóle nie trafiają do archiwum. Odrzucenie arbitralnie uciętego archiwum i zgłoszenie błędu z komunikatem tar to bezpieczniejsze zachowanie; proponowana poprawka zapisywałaby losowy podzbiór prac. |
| `Sources/CMCRCore/SelfUpdate.swift:649` | Komunikat uaktualnienia: przenieś do „folderu Aplikacje” zamiast „Programy” | Aktualny polski macOS nazywa /Applications „Aplikacje” (sprawdzone na macOS 27.0.1: /System/Library/CoreServices/SystemFolderLocalizations/pl.lproj, „Applications” => „Aplikacje”). SelfUpdate.swift:649/652 i README:190 są więc poprawne, a proponowana zmiana na „Programy” wprowadziłaby błąd. Niespójność istnieje w odwrotną stronę – miejsca z „Programy” zgłaszam w missed. |
| `Sources/CMCRManager/AppModel.swift:304` | „Zezwalaj na instalatory bez podpisu Apple” zostaje włączone do końca sesji, także dla instalacji z internetu | To zachowanie zamierzone. Komentarz w AppModel.swift:302-303 mówi tylko, że flaga jest domyślnie wyłączona i nie zapisuje się między uruchomieniami, i tak właśnie działa; README (l. 170) opisuje zwykły przełącznik włączany przez nauczyciela. Każdy instalator przyjęty dzięki fladze dostaje w wyniku ostrzeżenie „instaluję mimo to” (Scripts.swift:365-366), więc automatyczne wyłączanie to propozycja zmiany projektu, a nie usterka. |
| `Sources/CMCRManager/AppModel.swift:653` | Po REV-74 zadanie zakończone „Connection timed out during banner exchange” czyści zalogowanych uczniów, choć sshd tylko wolno odpowiada | Odrzucone przez obu sceptyków: przekroczenie czasu na banner to upływ ConnectTimeout przed nawiązaniem połączenia, czyli „bez połączenia przed upływem limitu czasu” – przypadek, w którym README (wiersz 106) każe nie pokazywać ucznia; tak samo działa sprawdzenie stanu co 2 minuty od c760cfe, a REV-74 tylko wyrównało ścieżkę zadań. Ucznia zachowuje chwilowa odmowa (kex_exchange_identification), która ma osobną gałąź. |
| `Sources/CMCRManager/ClassroomView.swift:749` | Odpowiedzi uczniów i macierz gotowości to listy z kolumnami bez Table | Odpowiedzi są pokazywane jako dwukolumnowa lista (komputer · uczeń → odpowiedź) z kopiowaniem i eksportem CSV (ClassroomView.swift:723-781), co spełnia README:147. Brak sortowania i zaznaczania oraz Grid zamiast Table w macierzy gotowości (README:57 też nazywa ją tabelą) to preferencja projektowa bez scenariusza błędu. |
| `Sources/CMCRManager/Components.swift:329` | Sztywne rozmiary czcionek i kolory z przezroczystością zamiast stylów semantycznych | Sztywne .font(.system(size:)) dotyczą wyłącznie obrazków SF Symbols w ramkach o stałym rozmiarze (Components.swift:328-329, PowerView.swift:285-286, SettingsComponents.swift:9-13 – kafelek 22×22, DashboardView.swift:373-377 – kółko 24×24, ScreenTiles.swift:218-219/245/276); cały tekst używa stylów semantycznych. Kolory to semantyczne .secondary i accent z przezroczystością, bez RGB ani hex. Różne obramowanie CodeEditor (CommandsView.swift:50 i SetupView.swift:893) to drobna preferencja – nie ma naruszenia HIG ani scenariusza błędu. |
| `Sources/CMCRManager/JobsView.swift:349` | Bieżące zadania nie pokazują kodu wyjścia | W bieżącym widoku kod wyjścia widać w kolumnie Wynik dla błędów polecenia: „… (kod N)” albo „Polecenie zakończone kodem N.” (AppModel.swift:451-453), a eksport zawiera kod (JobsView.swift:637). Kodu brak tylko przy rozpoznanych błędach (hasło sudo, SSH, limit czasu), gdzie zastępuje go opis, więc README („z wynikiem, kodem wyjścia”) jest spełnione. Komentarz w HistoryDetailView mówi o tych samych kolumnach, nie o identycznej treści. |
| `Sources/CMCRManager/UpdateViews.swift:147` | Niespójny myślnik: „—” obok „–” | Pauza i półpauza są w polszczyźnie równoprawnymi myślnikami. Dwa wystąpienia „—” w UI (UpdateViews.swift:147, RemoteBrowserView.swift:53) i mieszanie ich w README to kwestia stylu typograficznego bez błędnego ani mylącego tekstu, więc według reguły „bez preferencji stylu” nie jest to usterka. |
| `Sources/cmcrctl/CLI.swift:384` | cmcrctl exec/push/pull: angielskie nagłówki, w push z polską liczbą | Nagłówki „Running command on / Pushing to / Pulling from … ...” są w cmcrctl od wersji 1.0 (6c43abc, „Command line counterpart of cmcr-helpers.sh”) jako odpowiednik wyjścia cmcr-helpers. Przypina je e2e (Tests/e2e/suites/cli.sh:39, 80, 84, 102, 113), a polską odmianę w push dodano świadomie w 40c5f5c („push item plural”). To zamierzona zgodność, więc dwujęzyczność jest kwestią stylu, nie usterką. |

## Stan końcowy

Sprawdzenia uruchomione po ostatniej zmianie kodu aplikacji (gałąź `audit/fixes-and-ui` @ `ece4dc3`). Późniejsze commity zmieniają tylko ten plik i próg czasu w jednym teście (REV-77, `8e0e9af`); po nim testy jednostkowe przeszły ponownie: 103 + 415, 0 nieudanych.

| Sprawdzenie | Wynik |
|---|---|
| `swift build --scratch-path <tymczasowy>` (czysty katalog) | kod 0; 5 ostrzeżeń – te same 5 ostrzeżeń linkera o ścieżkach wyszukiwania co w stanie wyjściowym; 0 ostrzeżeń kompilatora Swift, 0 błędów |
| `scripts/test.sh` | kod 0; testy jednostkowe: 103 w 18 zestawach (CMCRManagerTests) + 415 w 72 zestawach (CMCRCoreTests), 0 nieudanych; e2e: 1835 zaliczonych, 0 niezaliczonych |
| `CMCR_SIGN_IDENTITY=- scripts/build-app.sh` | kod 0; te same 5 ostrzeżeń linkera |
| `"build/CMCR Manager.app/Contents/MacOS/CMCRManager" --cmcr-self-test` | `1.1.0` = plik `VERSION` |
| `build/cmcrctl selftest` | kod 0: „90 skryptów (treść, tryb użytkownika i root) – składnia bash poprawna” |
| Zrzuty „after” | `docs/ui-review/after/` – te same 18 ekranów co „before”, jasny i ciemny motyw; opis w `docs/ui-review/README.md` |

Bez zmian względem `main`: `Sources/CMCRCore/UpdateKeys.swift`, skrypty w `scripts/` (w tym podpis i wydanie). `scripts/release.sh` nie był uruchamiany, a na `main` nic nie trafiło.
