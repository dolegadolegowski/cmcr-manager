# Przegląd interfejsu CMCR Manager (Etap 3)

Zrzuty stanu wyjściowego są w [`before/`](before), stanu po zmianach – w [`after/`](after). Obie serie zrobiono
tak samo, więc można je porównywać plik w plik (z jednym wyjątkiem – zob. UI-25 niżej):

- środowisko demonstracyjne `Tests/ui/demo-env.sh` (lokalny sshd na 127.0.0.1 z atrapami z `Tests/e2e/fakes.sh`;
  jeden osiągalny „iMac” – `imac01` – i pięć nieosiągalnych), bez prawdziwych iMaców, bez konfiguracji
  i Pęku kluczy użytkownika (`CMCR_CONFIG_DIR`, `CMCR_KEYCHAIN_SERVICE` z demo-env);
- aplikacja zbudowana w trybie debug i opakowana w tymczasowy pakiet o identyfikatorze `pl.cmcr.manager.uitest`
  (polskie teksty systemowe, osobne preferencje – nie dotyka ustawień zainstalowanej aplikacji);
- zrzuty z `SnapshotRenderer` (`CMCR_SNAPSHOT_DIR`, `CMCR_SNAPSHOT_SECTIONS`, `CMCR_SNAPSHOT_WINDOWS=wall,screen`),
  okno 1440×900 pt, motyw jasny i ciemny; pliki `*.txt` obok zrzutów działów zawierają pasek narzędzi, układ tabeli
  i pełne menu aplikacji z tego przebiegu;
- dodatkowo każdy dział sprawdzono w oknie 1180×720 pt (najmniejszy rozmiar okna), także z otwartym panelem
  szczegółów w dziale Komputery.

W stanie wyjściowym (`main` @ `c7d00ec`) pozycja menu „Ustawienia…” nie otwierała okna Ustawień (UI-01), więc
`SnapshotRenderer` nie mógł go sfotografować. Do serii `before/settings-*` dodano tylko w kodzie zrzutów (nie
w aplikacji) pomocnicze otwarcie okna przez `openSettings`; okno i jego zawartość są takie, jak w `main`.

Uwaga: zrzuty pokazują dane z Maca, na którym je zrobiono (nazwa konta w kolumnie „Zalogowany”, adres MAC
interfejsu, aplikacje uruchomione w tle w dziale Aplikacje, ścieżka tymczasowego pakietu aplikacji w Ustawieniach
› Uaktualnienia).

## Pliki

Każdy ekran w motywie jasnym i ciemnym; „opis” to plik `*.txt` z paskiem narzędzi, układem tabeli i pełnym menu aplikacji.

| Ekran | Przed | Po |
|---|---|---|
| Komputery | [jasny](before/dashboard-light.png) · [ciemny](before/dashboard-dark.png) · [opis](before/dashboard-light.txt) | [jasny](after/dashboard-light.png) · [ciemny](after/dashboard-dark.png) · [opis](after/dashboard-light.txt) |
| Zajęcia | [jasny](before/classroom-light.png) · [ciemny](before/classroom-dark.png) · [opis](before/classroom-light.txt) | [jasny](after/classroom-light.png) · [ciemny](after/classroom-dark.png) · [opis](after/classroom-light.txt) |
| Podgląd ekranów | [jasny](before/screens-light.png) · [ciemny](before/screens-dark.png) · [opis](before/screens-light.txt) | [jasny](after/screens-light.png) · [ciemny](after/screens-dark.png) · [opis](after/screens-light.txt) |
| Sesja i zasilanie | [jasny](before/power-light.png) · [ciemny](before/power-dark.png) · [opis](before/power-light.txt) | [jasny](after/power-light.png) · [ciemny](after/power-dark.png) · [opis](after/power-light.txt) |
| Pliki | [jasny](before/files-light.png) · [ciemny](before/files-dark.png) · [opis](before/files-light.txt) | [jasny](after/files-light.png) · [ciemny](after/files-dark.png) · [opis](after/files-light.txt) |
| Przeglądarka plików | [jasny](before/browser-light.png) · [ciemny](before/browser-dark.png) · [opis](before/browser-light.txt) | [jasny](after/browser-light.png) · [ciemny](after/browser-dark.png) · [opis](after/browser-light.txt) |
| Aplikacje | [jasny](before/apps-light.png) · [ciemny](before/apps-dark.png) · [opis](before/apps-light.txt) | [jasny](after/apps-light.png) · [ciemny](after/apps-dark.png) · [opis](after/apps-light.txt) |
| Instalacja | [jasny](before/install-light.png) · [ciemny](before/install-dark.png) · [opis](before/install-light.txt) | [jasny](after/install-light.png) · [ciemny](after/install-dark.png) · [opis](after/install-light.txt) |
| Aktualizacje | [jasny](before/updates-light.png) · [ciemny](before/updates-dark.png) · [opis](before/updates-light.txt) | [jasny](after/updates-light.png) · [ciemny](after/updates-dark.png) · [opis](after/updates-light.txt) |
| Zadania | [jasny](before/jobs-light.png) · [ciemny](before/jobs-dark.png) · [opis](before/jobs-light.txt) | [jasny](after/jobs-light.png) · [ciemny](after/jobs-dark.png) · [opis](after/jobs-light.txt) |
| Polecenia | [jasny](before/commands-light.png) · [ciemny](before/commands-dark.png) · [opis](before/commands-light.txt) | [jasny](after/commands-light.png) · [ciemny](after/commands-dark.png) · [opis](after/commands-light.txt) |
| Konfiguracja | [jasny](before/setup-light.png) · [ciemny](before/setup-dark.png) · [opis](before/setup-light.txt) | [jasny](after/setup-light.png) · [ciemny](after/setup-dark.png) · [opis](after/setup-light.txt) |
| Okno Ustawień (⌘,) › Ogólne | [jasny](before/settings-light.png) · [ciemny – pokazuje zakładkę Uaktualnienia (UI-25)](before/settings-dark.png) | [jasny](after/settings-light.png) · [ciemny](after/settings-dark.png) |
| Okno Ustawień › Połączenie | [jasny](before/settings-connection-light.png) · [ciemny](before/settings-connection-dark.png) | [jasny](after/settings-connection-light.png) · [ciemny](after/settings-connection-dark.png) |
| Okno Ustawień › Podgląd ekranów | [jasny](before/settings-screens-light.png) · [ciemny](before/settings-screens-dark.png) | [jasny](after/settings-screens-light.png) · [ciemny](after/settings-screens-dark.png) |
| Okno Ustawień › Uaktualnienia | [jasny](before/settings-updates-light.png) · [ciemny](before/settings-updates-dark.png) | [jasny](after/settings-updates-light.png) · [ciemny](after/settings-updates-dark.png) |
| Ściana ekranów (⇧⌘E) | [jasny](before/window-wall-light.png) · [ciemny](before/window-wall-dark.png) | [jasny](after/window-wall-light.png) · [ciemny](after/window-wall-dark.png) |
| Okno podglądu jednego ekranu | [jasny](before/window-screen-light.png) · [ciemny](before/window-screen-dark.png) | [jasny](after/window-screen-light.png) · [ciemny](after/window-screen-dark.png) |

## Co się zmieniło

Każda zmiana ma w nawiasie numer z [AUDIT.md](../../AUDIT.md). Pliki `*.txt` obok zrzutów działów zawierają pełne
menu aplikacji, więc zmiany w menu widać, porównując np. `before/dashboard-light.txt` z `after/dashboard-light.txt`.

### Menu i skróty klawiszowe (UI-01, UI-21, UI-23, UI-30, KON-10, WŁ-01)

- **⌘,** otwiera okno Ustawień, jak w każdej aplikacji na Maca. Wcześniej ten sam skrót miały trzy pozycje menu
  („Konfiguracja…” i „Ustawienia…” w menu aplikacji oraz „Konfiguracja” w menu Przejdź), a „Ustawienia…” nie
  otwierało okna.
- Dział Konfiguracja ma **⇧⌘,** w menu Przejdź, Polecenia – **⇧⌘P**, pozostałe działy – **⌘1…⌘0** w kolejności
  paska bocznego.
- Pozycja menu Przejdź pokazuje główne okno, a gdy zostało zamknięte (zadania nadal trwają) – otwiera je ponownie.
  Wcześniej dział zmieniał się w niewidocznym oknie.
- **Pomoc › Instrukcja CMCR Manager (⌘?)** otwiera instrukcję (README projektu), **Historia wersji** – listę wydań.
  Wcześniej „Pomoc aplikacji CMCR Manager” pokazywała tylko systemowy komunikat, że pomoc jest niedostępna.
- Bez zmian zostały skróty w menu Edycja – **Zaznacz wszystkie komputery (⇧⌘A)**, **Zaznacz włączone komputery
  (⇧⌘O)**, **Odznacz wszystkie komputery (⇧⌘D)**, obok systemowego „Zaznacz wszystko”, które zaznacza tekst – i Widok:
  **Odśwież stan komputerów (⌘R)** oraz systemowe **Pokaż/Ukryj pasek boczny (⌃⌘S)**. Trzy pozycje Edycji
  i „Odśwież stan komputerów” mają teraz ikony; pozycja systemowa jest bez zmian.
- W każdym menu i menu kontekstowym pozycje mają ikony albo cała sekcja jest bez nich (listy wyboru: grupy,
  szablony, dni, opcje odświeżania). Wcześniej w jednym menu część pozycji miała ikony, a część nie – ostatnio
  „Pokaż podpisy na ekranach” w menu Widok Ściany ekranów.

### Pasek boczny i pasek narzędzi (UI-06, UI-28)

- Wrócił przycisk pokazywania i ukrywania paska bocznego (był usunięty). To przycisk „Pasek boczny” na początku
  paska kolumny z listą komputerów: systemowy, z tytułem „Ukryj pasek boczny”, nie mieścił się nad paskiem bocznym
  i zawsze lądował w menu „»”. Skrót ⌃⌘S w menu Widok działa jak wcześniej.
- Tryb paska narzędzi (Ikona i tekst / Tylko ikona), który nauczyciel wybierze z menu kontekstowego paska, jest
  zapamiętywany. Wcześniej aplikacja wymuszała go przy każdym uruchomieniu.

### Dział Komputery i wylogowanie (UI-13, KOM-09, UI-02, UI-03)

- W najmniejszym oknie (1180 pt) z otwartym panelem szczegółów tabela się mieści: kolumny Wolne miejsce i macOS
  ustępują miejsca, kolumna Stan nie jest obcinana.
- Kliknięcie wiersza pokazuje szczegóły komputera w panelu i **nie zmienia** zaznaczonych komputerów (celów działań).
  Wcześniej zwykłe kliknięcie zastępowało zaznaczenie 12 komputerów jednym. Podpowiedź nad tabelą mówi o tym wprost.
- Menu kontekstowe tabeli działa na wszystkich wierszach, dla których je otwarto (wcześniej na jednym, przypadkowym
  komputerze), a „Pokaż szczegóły” i dwuklik – na jednym wierszu.
- „Wyloguj…” w dziale Sesja i zasilanie zawsze pyta o potwierdzenie (wcześniej wylogowywało wszystkie zaznaczone
  komputery od razu).

### Symbole SF: jedna akcja – jeden symbol (UI-08, UI-20, UI-22, UI-26, UI-27, UI-29, UI-33, UI-34)

Ta sama akcja lub ten sam stan ma wszędzie ten sam symbol, a wczytanie pliku i zapis do pliku mają różne symbole.
Kilka ogólnych symboli ma nadal dwa pokrewne znaczenia, np. `gearshape` (dział Konfiguracja i zakładka Ogólne okna
Ustawień), `power` (Wyłącz i dział Sesja i zasilanie), `terminal` (Sesja SSH i dział Polecenia), `eye.slash` (ukryte
pliki i podgląd zablokowany dla konta).

Kroki scenariusza zajęć mają symbole tych samych akcji w aplikacji: „Uruchom aplikacje” – `play.fill`, „Zamknij
aplikacje” – `xmark.circle`, „Wyślij powitanie” – `text.bubble`, czyszczenie folderów – `trash` (test
`RevR6appTests.everyLessonStepHasTheSymbolOfTheSameActionInTheApp`). W tabeli postępu zajęć kolumny kroków o tym
samym symbolu mają krótki podpis („folder ucznia”, „Pobrane”).

Pilnują tego testy `SymbolAvailabilityTests`:

- `oneTitleOneSymbol` – każdy tytuł `Label(…, systemImage:)` i przycisku z `title:`/`icon:` ma jeden symbol
  (wariant `.fill` oznacza włączony stan tej samej akcji, np. plakietka „Jako administrator”). Wyjątkiem są trzy
  tytuły, które nazywają dwie różne rzeczy: „Zamknij” (komunikat w oknie – `xmark`, aplikacja na iMacach –
  `xmark.circle`), „Otwórz” (folder w Przeglądarce plików – `folder`, adres na iMacach – `arrow.up.forward.app`)
  i „Budzenie przez sieć” (akcja Obudź – `sunrise`, ustawienie Wake-on-LAN – `dot.radiowaves.left.and.right`);
- `importAndSaveHaveDifferentSymbols` – wczytanie pliku do aplikacji i zapis do pliku nie mają wspólnego symbolu;
- `everySaveToAFileHasTheSaveSymbol` – każdy zapis i eksport do pliku („Zapisz…”, „Eksportuj…”, „… do pliku…”) ma
  `square.and.arrow.up`;
- `everySymbolExistsOnTheDeploymentTarget` – każdy symbol istnieje w macOS 14 (wcześniej „Pełny ekran” w Ścianie
  ekranów miał symbol z macOS 15 i na macOS 14 przycisk był bez ikony);
- `noSymbolReservedByAppleIsUsed` – bez symboli zastrzeżonych przez Apple (apple.logo, safari, macbook,
  iphone.gen2, person.badge.key zastąpione neutralnymi).

Słownik najważniejszych symboli:

| Znaczenie | Symbol SF |
|---|---|
| Komputery / brak komputerów | `desktopcomputer` |
| Włączony | `checkmark.circle.fill` |
| Niedostępny | `moon.zzz.fill` |
| W toku, wczytywanie | `hourglass` |
| Odśwież, sprawdź ponownie, spróbuj ponownie | `arrow.clockwise` |
| Zaznacz… / Odznacz… | `checkmark.square` / `square` |
| Zaznacz włączone komputery | `checkmark.circle` |
| Przerwij | `stop.circle` |
| Rozpocznij zajęcia / Uruchom | `play.fill` |
| Zakończ zajęcia | `flag.checkered` |
| Tryb uwagi, zablokuj ekrany / odblokuj ekrany | `lock.display` / `lock.open.display` |
| Zadaj pytanie | `questionmark.bubble` |
| Wyślij wiadomość | `text.bubble` |
| Wyślij pliki | `paperplane` |
| Zbierz prace uczniów | `tray.and.arrow.down` |
| Podgląd ekranu | `eye` |
| Ukryte pliki | `eye.slash` |
| Ściana ekranów | `rectangle.split.3x3` |
| Steruj ekranem, udostępnianie ekranu | `rectangle.on.rectangle` |
| Obudź (Wake-on-LAN) / ustawienie Wake-on-LAN | `sunrise` / `dot.radiowaves.left.and.right` |
| Uśpij ekrany | `moon` |
| Uśpij | `powersleep` |
| Uruchom ponownie | `restart` |
| Wyłącz, dział Sesja i zasilanie | `power` |
| Wyloguj | `rectangle.portrait.and.arrow.right` |
| Uprawnienia administratora | `lock.shield` |
| Klucz komputera (hosta) | `key.viewfinder` |
| Hasło | `key.fill` |
| FileVault | `lock.doc` |
| Gotowość iMaców | `checklist` |
| Usuń… / Odinstaluj… | `trash` |
| Wyczyść listę | `eraser` |
| Wczytanie z pliku (Zastąp listę z pliku…) | `square.and.arrow.down` |
| Zapis do pliku i eksport (Zapisz…, Eksportuj…) | `square.and.arrow.up` |
| Kopiuj | `doc.on.doc` |
| Pokaż szczegóły | `info.circle` |
| Konfiguracja, Otwórz Konfigurację | `gearshape` |
| Sesja SSH w Terminalu, dział Polecenia | `terminal` |
| Instrukcja / Historia wersji | `book` / `clock.arrow.circlepath` |

### Przyciski niszczące i potwierdzenia (UI-24, UI-32, UI-05, UI-04, UI-31)

- „Usuń…”, „Odinstaluj…”, „Usuń harmonogram…”, „Usuń z listy…” i „Wymuś zamknięcie…” nie stoją już tuż obok
  zwykłych akcji: oddziela je separator albo stoją po lewej, jak w oknach macOS. „Przerwij” scenariusza zajęć ma tę
  samą rolę co „Przerwij” zadań. „Usuń grupę…” pyta o potwierdzenie i mówi, z ilu komputerów zniknie grupa.
- „Zastąp listę z pliku…” (wcześniej „Wczytaj listę z pliku…”) pyta, zanim zastąpi całą listę komputerów.
- Pytania przed usunięciem, zastąpieniem i wysłaniem do podfolderu w Przeglądarce plików wymieniają przeglądany
  komputer, a nie komputery zaznaczone na liście (UI-31).

### Stany, dostępność i komunikaty (UI-19, UI-18, UI-14, REV-13, REV-22, REV-29, REV-66, REV-72, REV-75)

- Świeżość obrazu w podglądzie, zaznaczenie kafelka i mało miejsca na dysku widać nie tylko po kolorze: mają własny
  kształt lub znacznik. Znacznik zaznaczenia nie zasłania już przycisku „Powiększ” na kafelku Ściany ekranów.
- Animacje przesunięcia i skalowania respektują „Ogranicz ruch” z Ustawień systemowych › Dostępność.
- Nieudany zapis eksportu, raportu CSV, zrzutu ekranu i listy komputerów, otwarcie sesji w Terminalu czy brak
  dziennika działań kończą się alertem, który mówi, co się nie udało i dlaczego (wcześniej samym sygnałem
  dźwiękowym albo niczym). Alert pokazuje okno, w którym pracuje nauczyciel (także Ściana ekranów, okna podglądu
  i Ustawienia). Tak samo ostrzeżenia o uszkodzonych plikach konfiguracji i o nieudanym zapisie `classroom.json`;
  alert o Pęku kluczy zostaje w głównym oknie, bo hasła ustawia się tylko tam. Gdy okno z alertem zostanie
  zminimalizowane, alert od razu przechodzi do innego otwartego okna.

### Teksty (UI-10, UI-15, TXT-01, TXT-05, TXT-12, TXT-13, TXT-15, TXT-16, TXT-24)

- „dział” zamiast „sekcja”; „panel szczegółów”, „Ściana ekranów”, „Sesja SSH w Terminalu” – jedną nazwą wszędzie.
- Foldery jak w polskim macOS: Aplikacje, Narzędzia, Pobrane rzeczy. Opcje macOS dosłownie jak w Ustawieniach
  systemowych: „Zdalne logowanie”, „Daj użytkownikom zdalnym pełny dostęp do dysku”.
- Poprawna odmiana liczebników („najwyżej 1 komputer / 3 komputery / 5 komputerów naraz”, „z 1 komputera / z 3
  komputerów”, „Usuwanie 3 elementów…”).
- Stan komputera w raporcie CSV tymi samymi słowami co w oknie.

### Właściwe miejsca docelowe (UI-16, UI-17)

- „Zmień ograniczenia…” otwiera okno Ustawień na zakładce Podgląd ekranów, a nie Konfigurację na zakładce
  Komputery. Wybrane zakładki Konfiguracji i okna Ustawień są zapamiętywane.
- „Szczegóły” w banerze podglądu i w Przeglądarce plików otwierają w Zadaniach to działanie, a nie ostatnio
  oglądane.

### Dział Aplikacje (UI-07, WSP-06)

- Listy aplikacji pokazują wczytywanie i błędy. Komputery zaznaczone po wejściu w dział też są wczytywane (wcześniej
  lista zostawała pusta).

### Komunikat o podglądzie dla ucznia (KON-06, ZAJ-04, ZAJ-05)

- Przełącznik „Powiadamiaj o podglądzie” usunięto; jego miejsce zajął wiersz „Powiadomienie ucznia o podglądzie:
  zawsze” z wyjaśnieniem (Ustawienia › Podgląd ekranów i Konfiguracja › Ustawienia; zrzuty `settings-screens-*.png`).
  Uczeń dostaje komunikat po każdym zalogowaniu, ale dopiero na widocznym ekranie: nie na zablokowanym, uśpionym ani
  zasłoniętym trybem uwagi. Zmianę zatwierdził właściciel projektu.

### Zrzuty (UI-12, UI-25)

- Przykładowy komunikat w kodzie zrzutów (podstrona `configissues` w `SnapshotRenderer`, poza tą serią) podaje
  prawdziwą nazwę kopii (`hosts.json.<data>.bak`), a zrzut „settings” w ciemnym motywie pokazuje zakładkę Ogólne
  (wcześniej Uaktualnienia).

## Propozycje większych zmian (nie wdrożone)

Te zmiany wymagają większej przebudowy układu, więc są tylko opisane. Żadna nie zmienia tego, co widzą uczniowie.

1. **Główne okno jako `Window` zamiast `WindowGroup`.** Plik › „Nowe okno CMCR Manager” (⌘N) otwiera drugie główne
   okno ze wspólnym działem i zaznaczeniem komputerów, ale z osobnym wyszukiwaniem i filtrem listy, co myli. Jedno
   okno `Window` pasuje do modelu aplikacji, a menu Przejdź nie musiałoby szukać okna do pokazania.
2. **Jedno pole wyszukiwania.** `NativeSearchField` (`ActivityViews.swift`) i `SearchField`
   (`RemoteBrowserComponents.swift`) to dwa podobne opakowania `NSSearchField`. Jeden komponent dałby to samo
   zachowanie i wygląd we wszystkich działach i mniej kodu do utrzymania.
3. **Gotowość iMaców jako `Table`.** Macierz gotowości to `Grid`. `Table` dałaby sortowanie po kolumnie, ukrywanie
   kolumn i zaznaczanie wierszy, tak jak w dziale Komputery (zgłoszenie UI-09 odrzucono jako usterkę, ale zmiana
   pomogłaby przy dużej pracowni).
4. **Ustawienia w jednym miejscu.** Te same ustawienia są w oknie Ustawień (⌘,) i w Konfiguracji › Ustawienia.
   Proponujemy zostawić je tylko w oknie Ustawień, a w Konfiguracji – listę komputerów, dostęp i przygotowanie iMaców.
5. **Lista zadań jako `Table`.** Dział Zadania to `HSplitView` z listą (`List`) i wynikiem wybranego zadania.
   `Table` z kolumnami (początek, działanie, komputery, wynik) pozwoliłaby sortować i szybciej znaleźć zadanie
   w długiej historii, a `NavigationSplitView` dałby standardowy podział okna.
6. **Pasek narzędzi w oknie 1180 pt.** Z otwartym panelem szczegółów przycisk „Aktywność” trafia do menu „»”.
   Rzadziej używane akcje („Więcej”, „Aktywność”) można zebrać w jednym menu, żeby przy każdym rozmiarze okna
   wszystkie były na pasku.
7. **Baner „brak dostępu do sieci lokalnej”.** Gdy macOS nie pozwala aplikacji łączyć się z siecią lokalną, komunikaty
   przy komputerach już to mówią (DOD-05). Jeden baner nad listą z przyciskiem do Ustawień systemowych › Prywatność
   i ochrona › Sieć lokalna byłby czytelniejszy niż ten sam opis przy każdym iMacu.
8. **„Ostatnio zalogowany” w panelu szczegółów.** Komputer, którego nie udało się sprawdzić, zachowuje ostatnio
   zalogowanego ucznia (REV-11), ale pole „Zalogowany” wygląda wtedy jak świeży stan. Dopisek „ostatnio: jan (12:41)”
   pokazałby, że to stan z wcześniejszego sprawdzenia.
9. **Kolumny tabeli Komputery przy zmniejszaniu okna.** Kolumny rozszerzone w oknie 1440 pt zachowują szerokość po
   zmniejszeniu okna do 1180 pt (bez panelu szczegółów), więc tabela przewija się w poziomie – tak samo było
   w stanie wyjściowym. Proporcjonalne zwężanie kolumn (styl autodopasowania kolumn `NSTableView`) albo ukrywanie
   kolumny „Uwagi” poniżej pewnej szerokości usunęłoby przewijanie.
