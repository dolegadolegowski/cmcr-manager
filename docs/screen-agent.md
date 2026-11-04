# CMCR Screen Agent – projekt podglądu ekranu przez usługę na iMacu

Dokument dla osób rozwijających CMCR Manager. Opisuje, dlaczego podgląd ekranu nie robi już zrzutu
z sesji SSH, tylko prosi o niego usługę zainstalowaną na iMacu, i jaki jest kontrakt między częściami.

## Dlaczego

Do wersji 1.2.0 skrypt podglądu uruchamiał `/usr/sbin/screencapture` przez `launchctl asuser` z sesji SSH.
macOS przypisuje taki proces do procesu odpowiedzialnego sesji SSH (`/usr/libexec/sshd-keygen-wrapper`,
w nowszych systemach także `sshd-session`), więc:

- uprawnienie „Nagrywanie ekranu i dźwięku systemowego” trzeba było nadać narzędziu SSH, ręcznie, przez ⌘⇧G
  i ścieżkę, a w macOS 26.1–26.2 wpis w ogóle nie pojawiał się na liście;
- bez uprawnienia `screencapture` często zapisywał samą tapetę, której skrypt nie odróżniał od podglądu;
- informacja dla ucznia (JXA przez `osascript` z sesji SSH) bywała niewidoczna lub zbyt wolna, a każda taka
  porażka blokowała zrzut;
- macOS 27 nie pozwala już czytać bazy TCC, z której korzystało sprawdzanie gotowości.

## Jak to działa teraz

```
CMCR Manager ──ssh──► skrypt podglądu (root, jedna sesja na strumień)
                          │  co interwał:
                          ├─► cmcr-screen-agent client <uid> notice … ─┐
                          ├─► cmcr-screen-agent client <uid> capture … ─┤ gniazdo unix
                          │                                             ▼
                          │                           CMCR Screen Agent (LaunchAgent w sesji ucznia)
                          │                           – robi zrzut tylko na żądanie (ScreenCaptureKit)
                          │◄── zapisany plik shots/<uid>/screen-<n>.jpg (każdy kolejny zastępuje poprzedni)
                          └─► CMCR1 FRAME … (plik wysłany do aplikacji)
```

- **Usługa** – „CMCR Screen Agent.app” (`pl.cmcr.manager.screen-agent`) uruchamiana przez launchd jako
  LaunchAgent w sesji graficznej zalogowanego użytkownika. To ona jest procesem odpowiedzialnym, więc
  uprawnienie do nagrywania ekranu nadaje się jej, pod jej nazwą, raz na iMaca (dla wszystkich kont).
  Nic nie robi, dopóki nie zostanie wywołana – zrzut powstaje wyłącznie na żądanie.
- **Klient** – ten sam plik wykonywalny w trybie `client`, uruchamiany przez skrypt podglądu (root) z sesji SSH.
  Łączy się z gniazdem usługi zalogowanego użytkownika, sprawdza, że po drugiej stronie jest prawdziwa usługa,
  wysyła polecenie i zapisuje odebrany zrzut w folderze tylko dla roota, zastępując poprzedni.
- **Aplikacja** – bez zmian w widokach: `ScreenStream`/`ScreenCenter` dalej odbierają `CMCR1 FRAME`, tylko
  zrzut pochodzi od usługi. Instalacja, aktualizacja, prośba o uprawnienie i usunięcie usługi są w
  Konfiguracja › Przygotowanie iMaców (Szybkie naprawy, okno komórki „Podgląd ekranu”, „Skonfiguruj zaznaczone”)
  i w `cmcrctl screen-agent`.

## Ścieżki na iMacu

Wszystkie stałe są w `Sources/CMCRCore/ScreenAgentInfo.swift` (i powtórzone w agencie – test pilnuje zgodności).

| Co | Ścieżka | Właściciel / prawa |
|---|---|---|
| Aplikacja usługi | `/Library/Application Support/CMCR/ScreenAgent/CMCR Screen Agent.app` | root:wheel, 755 |
| Plik wykonywalny | `…/CMCR Screen Agent.app/Contents/MacOS/cmcr-screen-agent` | |
| LaunchAgent | `/Library/LaunchAgents/pl.cmcr.manager.screen-agent.plist` | root:wheel, 644 |
| Gniazda | `/Library/Application Support/CMCR/ScreenAgent/run/<uid>.sock` | katalog root:wheel 1733, gniazdo 0600 (użytkownik) |
| Zrzuty | `/Library/Application Support/CMCR/ScreenAgent/shots/<uid>/screen-<n>.jpg` | katalogi root:wheel 700, pliki 600 |

W kompilacjach DEBUG (testy e2e) wszystkie ścieżki systemowe są poprzedzone `$CMCR_SETUP_ROOT_PREFIX`,
tak jak w skrypcie przygotowania. Kompilacje wydań ignorują tę zmienną.

LaunchAgent: `Label`, `Program` = bezwzględna ścieżka pliku wykonywalnego, `ProgramArguments` =
`[<exe>, "serve"]`, `RunAtLoad` true, `KeepAlive` true, `LimitLoadToSessionType` `Aqua`,
`ProcessType` `Interactive`, `AssociatedBundleIdentifiers` = `[pl.cmcr.manager.screen-agent]`,
`ThrottleInterval` 5. Bez `StandardOutPath`.

## Protokół gniazda (wersja `CMCRA1`)

Jedno polecenie na połączenie. Klient wysyła jeden wiersz, usługa odpowiada i zamyka połączenie.
Pola rozdziela pojedyncza spacja; teksty podawane przez użytkownika są w base64 (UTF-8; pusty tekst to `-`,
bo pustego pola nie da się odróżnić od podwójnej spacji; odczyt przyjmuje base64 z dopełnieniem `=` i bez).
Po nagłówku `IMG …` (zakończonym `\n`) idzie dokładnie `<bajty>` bajtów JPEG, a zaraz po nich następny nagłówek.
Kod wspólny dla usługi i klienta (protokół, ścieżki, skalowanie, JPEG, zapis plików) jest w `Sources/ScreenAgentKit`.

| Żądanie | Odpowiedź |
|---|---|
| `CMCRA1 PING` | `OK PING <wersja> perm=<granted\|denied> locked=<0\|1> console=<0\|1> asleep=<0\|1> user=<b64 nazwa>` |
| `CMCRA1 CAPTURE <maxpx> <jakość 10-100> <main\|all\|1-9>` | `OK CAPTURE <liczba> <b64 aplikacja na pierwszym planie>` i dla każdego ekranu `IMG <n> <szer> <wys> <bajty>` + bajty JPEG |
| `CMCRA1 NOTICE <b64 tytuł> <b64 tekst>` | `OK NOTICE <shown\|hidden\|locked>` (panel znika sam po 8 s) |
| `CMCRA1 FRONT` | `OK FRONT <b64 nazwa>` |
| `CMCRA1 REQUEST-PERMISSION` | `OK PERMISSION <granted\|denied>` (pokazuje systemowe okno macOS) |
| błąd | `ERR <kod> <b64 opis>` – kody: `noperm`, `locked`, `notconsole`, `asleep`, `nodisplay`, `failed`, `protocol` |

Zasady usługi:
- przed każdym zrzutem `CGPreflightScreenCaptureAccess()`; bez uprawnienia `ERR noperm` – nigdy nie wywołuje
  okna z prośbą poza `REQUEST-PERMISSION` (uczeń nie może go zatwierdzić);
- po `ERR noperm` w procesie starszym niż 30 s kończy się po odpowiedzi (launchd uruchamia go ponownie), bo
  macOS zapamiętuje stan uprawnienia na czas życia procesu – nadane uprawnienie działa wtedy bez restartu Maca;
  tak samo po `OK PING … perm=denied` (sprawdzanie gotowości widzi wtedy przy następnym razie świeży stan),
  ale nie przez 120 s po `REQUEST-PERMISSION` (okno macOS może być jeszcze na ekranie);
- zrzut, który nie skończy się w 8 s, kończy się `ERR failed` (klient czeka 10 s);
- ekran zablokowany (`CGSessionCopyCurrentDictionary`, `CGSSessionScreenIsLocked`) → `ERR locked`, sesja nie
  na pierwszym planie (szybkie przełączanie użytkowników) → `ERR notconsole`, uśpiony ekran → `ERR asleep`;
- zrzut przez `SCScreenshotManager.captureImage` (macOS 14+), skalowany tak, by dłuższy bok ≤ maxpx,
  kodowany do JPEG przez ImageIO z podaną jakością; numeracja ekranów jak w `screencapture -D`
  (1 = główny, potem kolejne z `CGGetActiveDisplayList`);
- `NOTICE` w sesji, która nie jest na ekranie (szybkie przełączanie użytkowników), odpowiada `hidden`;
- przyjmuje połączenia tylko od roota (uid 0) albo od tego samego użytkownika (`getpeereid`);
- gniazdo tworzy po usunięciu starego wpisu, który jest jego własnym gniazdem; z obcym plikiem kończy się błędem;
  bez katalogu `run` kończy się z komunikatem na stderr (i w os_log), ścieżka dłuższa niż `sun_path` (103 bajty)
  też jest błędem; gniazdo powstaje od razu z prawami 0600 (umask);
- co 5 s sprawdza, czy gniazdo wciąż jest jego (to samo i-węzło); usunięte albo zastąpione przez drugą kopię
  (np. „Zakończ i otwórz ponownie” w Ustawieniach systemowych) – kończy się, launchd zostawia jedną;
- `SIGTERM` (`launchctl bootout`) usuwa jego gniazdo; dziennik tylko w os_log (`pl.cmcr.manager.screen-agent`),
  bez plików.

Podpis usługi ma włączony hardened runtime (`codesign --options runtime`), więc `launchctl setenv
DYLD_INSERT_LIBRARIES …` w sesji ucznia nie wstrzyknie biblioteki do procesu, któremu ufa klient.

## Klient (`cmcr-screen-agent client <uid> <polecenie> …`)

Uruchamia go root (albo sam zalogowany użytkownik). Przed wysłaniem polecenia sprawdza:
`lstat` gniazda (gniazdo, nie dowiązanie, właściciel = uid), `LOCAL_PEERCRED` (uid = docelowy uid) i
`LOCAL_PEERPID` → `proc_pidpath` = zainstalowany plik wykonywalny usługi (ta sama ścieżka po `realpath` albo
ten sam plik – urządzenie i i-węzeł), a ten proces działa w trybie `serve` (argumenty z `kern.procargs2`:
`LOCAL_PEERPID` wskazuje proces, który utworzył gniazdo nasłuchujące – obcy program mógłby je przekazać
potomkowi i uruchomić przez `exec` prawdziwą usługę w krótkim trybie, np. `client`). Inaczej `ERR untrusted`. Katalog `run` musi być prawdziwym katalogiem
roota (albo samego klienta). Uruchomiony przez innego użytkownika niż root i `<uid>` kończy się kodem 2.

| Polecenie | Wyjście (stdout, wiersze) | Kod wyjścia |
|---|---|---|
| `ping` | `AGENT <wersja> perm=… locked=… console=… asleep=… user=<nazwa>` | 0 |
| `capture <maxpx> <jakość> <ekran>` | `FRONT <nazwa>`, potem `SHOT <n> <szer> <wys> <bajty> <ścieżka>` dla każdego ekranu | 0 |
| `notice <b64 tytuł> <b64 tekst>` | `NOTICE shown\|hidden\|locked` | 0 |
| `front` | `FRONT <nazwa>` | 0 |
| `request-permission` | `PERMISSION granted\|denied` | 0 |
| błąd | `ERR <kod> <opis zwykłym tekstem>` | patrz niżej |

Kody wyjścia: 0 sukces, 2 błędne użycie, 10 usługa nie odpowiada (brak gniazda, odmowa, limit czasu 10 s),
11 usługa niezaufana, 12 `noperm`, 13 `locked`, 14 `notconsole`/`asleep`/`nodisplay`, 15 `failed`,
16 błąd protokołu lub zapisu, 1 inne.

`<kod>` w `ERR` klienta: kody usługi jak wyżej oraz `usage` (2), `unreachable` (10), `untrusted` (11),
`write` (16, zapis zrzutu), `protocol` (16), `error` (1); nieznany kod nowszej usługi daje 1. Nazwy aplikacji,
konta i opisy są w jednym wierszu (znaki sterujące, np. nowe wiersze, zamienione na spacje), więc nie mogą udawać
wierszy `SHOT`. Pusta nazwa aplikacji to wiersz `FRONT ` (ze spacją). Limit czasu: 10 s na połączenie i na
każdą ciszę, najwyżej 30 s na całą wymianę.

`capture` zapisuje każdy ekran do `shots/<uid>/screen-<n>.jpg` przez plik tymczasowy w tym samym katalogu i
`rename` (więc kolejny zrzut atomowo zastępuje poprzedni) i usuwa `screen-<m>.jpg` ekranów, których w tym
zrzucie nie było. Katalogi `shots` i `shots/<uid>` tworzy jako 700 (istniejące muszą być prawdziwymi
katalogami tego, kto uruchamia klienta, nie dowiązaniami; szersze prawa zawęża). Przyjmuje tylko dane zaczynające
się jak JPEG. Zalogowany użytkownik uruchamiający klienta dla własnej sesji (skrypt podglądu bez sudo) nie może
pisać w `shots` roota – zapisuje wtedy do `$TMPDIR/cmcr-screen-agent/<uid>/`; wiersze `SHOT` zawsze podają
właściwą ścieżkę.

Pakiet usługi buduje `scripts/make-agent-bundle.sh BINARY OUT_DIR [IDENTITY] [KEYCHAIN]` (wersja z
`BINARY --version`, `LSUIElement`, podpis z hardened runtime). `scripts/build-app.sh` wkłada go do
`CMCR Manager.app/Contents/Helpers` przed podpisaniem aplikacji (ta sama tożsamość podpisu, przy `UNIVERSAL=1`
te same architektury) i kopiuje obok `build/cmcrctl`; `scripts/release.sh` i CI sprawdzają podpis i wersję.
Aplikacja i cmcrctl znajdują go przez `ScreenAgentLocator.bundledAgent()`.

## Skrypt podglądu (`Scripts.screenCapture`)

Zachowuje dotychczasowy protokół z aplikacją (`HELLO`, `INFO`, `FRAME`, `SAME`, `STATE`, `NOTIFIED`, `BYE`,
polecenia `now/size/interval/display/pause/resume/quit`), ograniczenia (lista dozwolonych kont, tylko konta
standardowe) i zasadę „najpierw informacja dla ucznia w tej sesji logowania, potem obraz” (KON-06).
Zmienia się tylko to, kto robi zrzut:

- uruchamia się jako root (jedno sudo na strumień), chyba że konto SSH jest zalogowanym użytkownikiem;
- informacja dla ucznia: `client <uid> notice` zamiast JXA przez `osascript`;
- aplikacja na pierwszym planie: z odpowiedzi `capture` zamiast `lsappinfo`;
- zrzut: `client <uid> capture <maxpx> <jakość> <ekran>`, potem `md5` każdego pliku i `FRAME`/`SAME` –
  bez `screencapture` i bez ponownego kodowania przez `sips`;
- usługa nie odpowiada (kod 10): `launchctl print gui/<uid>/<label>` → `bootstrap` (gdy nie załadowana) albo
  `kickstart -k`, do 5 s oczekiwania na gniazdo, jedna ponowna próba; dalej `STATE agent-down`;
- brak pliku usługi → `STATE agent-missing`, kod 11 → `STATE agent-untrusted`, kod 12 → `STATE agent-perm`,
  kod 13 (ekran zablokowany) → `STATE notify … locked` (jak dotąd: bez potwierdzonej informacji nie ma obrazu),
  kod 14/15/16 → `STATE capture <user> <opis>`;
- odnawianie zapamiętanej zgody replayd (macOS 15+) dotyczy klientów usługi (identyfikator i ścieżka pliku
  wykonywalnego), nie `sshd-keygen-wrapper`.

Szczegóły wykonania:
- brak usługi sprawdzany jest przed przejściem na roota (bez sudo), więc „brak usługi” nie ginie za błędem hasła;
- kody wyjścia: `agent-missing`/`agent-down`/`agent-untrusted` → 9 (`ScriptCode.agentUnavailable`), `agent-perm` → 5,
  `notify` → 8; `scr_run_root` przepuszcza 9 jak pozostałe kody wyniku;
- zrzut jest czytany raz do prywatnej kopii w `$CMCR_TMP` (md5 i wysyłka z tej samej kopii – drugi podgląd tego
  samego konta może w tym czasie podmienić plik usługi); ścieżka pliku pochodzi z wiersza `SHOT`;
- kod 14 z kodem `asleep`/`notconsole`/`nodisplay` dostaje opis po polsku („ekran jest uśpiony”, …);
- tryb uwagi (`LockScreen`, nakładka `CMCR_ATTENTION`) sprawdza dalej skrypt, przed zapytaniem usługi – usługa go nie widzi;
- przy kodzie 10: `launchctl enable gui/<uid>/<label>` (uczeń mógł usługę wyłączyć we własnej sesji), potem
  `bootstrap`/`kickstart -k` i do 5 s oczekiwania, aż usługa odpowie na `ping` (samo gniazdo nic nie znaczy – zabita
  usługa zostawia stare); `Operations.screenshot` ma limit 60 s (sudo + dwa takie wznowienia).

## Instalacja (`Operations.installScreenAgent`)

1. Aplikacja znajduje własną kopię usługi (`ScreenAgentLocator.bundledAgent()`, `Contents/Helpers`),
   pakuje ją (`Payload.make`) i wysyła (`SSH.upload`) do `/tmp/cmcr-up-*.tar`.
2. `Scripts.installScreenAgent(remoteTar:)` (root): rozpakowuje do `$CMCR_TMP`, sprawdza identyfikator,
   wersję i podpis (`codesign --verify --strict`), porównuje z zainstalowaną kopią. **Tę samą wersję zostawia
   bez zmian** (z podpisem ad-hoc każda wymiana pliku unieważnia nadane uprawnienie), inną – wymienia:
   `bootout` we wszystkich sesjach graficznych, podmiana katalogu, `chown -R root:wheel`, usunięcie
   `com.apple.quarantine`, zapis LaunchAgenta (`plutil -lint`, 644), katalogi `run` (1733) i `shots` (700),
   `bootstrap gui/<uid>` w każdej sesji graficznej, `client <uid> ping`.
3. Wynik w wierszach `CMCR:AGENT <installed|updated|unchanged> <wersja>` i
   `CMCR:AGENT-SESSION <konto> <uid> <wiersz ping albo ERR …>`.

Szczegóły instalacji:
- aplikacja jest wymieniana tylko wtedy, gdy zainstalowanej nie ma, ma inną wersję albo nieprawidłowy podpis;
  sam LaunchAgent (porównany bajt po bajcie z `ScreenAgentInfo.launchAgentPlist(executable: "$R"+ścieżka)`) jest
  przepisywany niezależnie – zmiana tylko jego to też `updated` (aplikacja i uprawnienie zostają);
- gdy nowa kopia ma inne wymaganie podpisu (`codesign -d -r-`, przy podpisie ad-hoc zawsze) niż wymieniana, skrypt
  robi `tccutil reset ScreenCapture pl.cmcr.manager.screen-agent` i ostrzega, że uprawnienie trzeba nadać ponownie
  (stary wpis pokazywałby włączony przełącznik, a macOS i tak odmawiałby nowej kopii);
- przed `bootstrap` jest `launchctl enable`; usługa załadowana, ale milcząca, dostaje `kickstart -k`;
- kod wyjścia 0 także wtedy, gdy usługa w którejś sesji nie odpowiada (widać to w `CMCR:AGENT-SESSION … ERR …`);
  1 – nieprawidłowe archiwum, identyfikator, wersja, podpis albo błąd zapisu (z przywróceniem poprzedniej kopii).

Usuwanie (`Scripts.removeScreenAgent`): `bootout` w sesjach, usunięcie LaunchAgenta, aplikacji, `run`, `shots`
i `tccutil reset ScreenCapture pl.cmcr.manager.screen-agent`. Wynik: `CMCR:AGENT removed <wersja>` albo
`CMCR:AGENT absent -`.

Prośba o uprawnienie (`Scripts.requestScreenAgentPermission`): `client <uid> request-permission` w sesji
zalogowanego użytkownika – macOS pokazuje przy komputerze okno z przyciskiem „Otwórz Ustawienia systemowe”, a
usługa pojawia się na liście „Nagrywanie ekranu i dźwięku systemowego”. Włączyć ją musi administrator przy
komputerze (albo uczeń, jeśli profil MDM PPPC ma `AllowStandardUserToSetSystemService`). Wynik:
`CMCR:AGENT-PERMISSION <granted|denied>`; kody: 0, 3 (nikt nie jest zalogowany), 9 (brak usługi, nie odpowiada także
po ponownym uruchomieniu, niezaufana), 1 (inny błąd).

Stan (`Scripts.screenAgentStatus`, `Operations.screenAgentStatus`): wiersze `console=…`, `agent_installed=0|1`,
`agent_version=…` (bez sudo) oraz z sesji osoby przy komputerze (jako root, chyba że to konto SSH) `agent_loaded=0|1`,
`agent_ping=<AGENT … albo ERR <kod> <opis>>`, `agent_ping_rc=<kod klienta>`. Te same wiersze wypisuje sprawdzanie
gotowości; oba czyta jedna funkcja `ScreenAgentStatus.parse`.

## Gotowość (kolumna „Podgląd ekranu”, `ReadinessCheck.screen`)

Sprawdzanie (`Scripts.readiness`) dopisuje `kv agent_installed 0|1`, `kv agent_version X`, `kv agent_loaded
0|1`, `kv agent_ping <wiersz AGENT … albo ERR …>` i `kv agent_ping_rc N` (część root; gdy konto SSH jest osobą przy
komputerze – bez sudo). Nie czyta już bazy TCC ani nie uruchamia `CGPreflightScreenCaptureAccess` z sesji SSH. Stan:

| Warunek | Stan | Krótko |
|---|---|---|
| brak usługi | problem (naprawialne konfiguracją) | „brak usługi” |
| starsza wersja niż `ScreenAgentInfo.version` | warning (naprawialne) | „v1.0.0” |
| nikt nie jest zalogowany | unknown | „nikt nie zalogowany” |
| usługa nie odpowiada | warning (naprawialne) | „nie odpowiada” |
| na gnieździe odpowiada inny program (kod 11) | warning (naprawialne) | „niezaufana” |
| brak sudo (nie da się zapytać usługi innego konta) | unknown | „?” |
| `perm=denied` | manual (wizyta przy komputerze) | „nadaj uprawnienie” |
| `perm=granted` | ok | „gotowy” |

Od macOS 15 komórka dopisuje też stan zapamiętanej zgody replayd (okno „…chce pominąć systemowy wybór okien”).

## Skrypt przygotowania (`setup/cmcr-imac-setup.sh` 1.2.0)

Skrypt nie może zainstalować usługi (plik wykonywalny jest w aplikacji). W `step_tcc` zamiast sprawdzania uprawnienia
sesji SSH jest krok `screen_agent`: brak usługi albo starsza wersja niż `CMCR_SCREEN_AGENT_VERSION` → `warn` z
instrukcją instalacji z aplikacji, `perm=denied` → `todo` (włączyć przy komputerze), `perm=granted` → `ok`; nigdy
`fail`. JSON znacznika ma nowe pole `"screen_agent": "<wersja>|none"`, a `"screen_capture_remote"` pochodzi z `ping`
usługi. Blok CMCR-REPLAYD odnawia zgodę replayd pod dwoma kluczami – identyfikatorem usługi (`CMCR_SC_ID`) i ścieżką
jej pliku wykonywalnego (`CMCR_SC_EXE`) – w formacie macOS 15.0 albo 15.1+. Klucze mają kropki i spacje, więc odczyt
i zapis idą przez `/usr/libexec/PlistBuddy` (`Print -x`, jedno wywołanie `Delete`+`Merge /dev/stdin`), nie `plutil`.

## Podpis i uprawnienie

Z podpisem ad-hoc macOS wiąże uprawnienie z konkretnym plikiem (cdhash): nowa wersja usługi wymaga ponownego
nadania uprawnienia na każdym iMacu. Dlatego usługa ma własny numer wersji (`ScreenAgentInfo.version`)
i jest wymieniana tylko przy jego zmianie. Stała tożsamość podpisu (`scripts/make-signing-identity.sh`)
sprawia, że uprawnienie przetrwa także nowe wersje usługi.

## Testy

Tylko w kompilacjach DEBUG (w `-c release` tego kodu nie ma; `cmcr-screen-agent --test-seams` wypisuje wtedy
błąd użycia zamiast `debug`):

- `CMCR_SETUP_ROOT_PREFIX=<katalog>` – wszystkie ścieżki systemowe (aplikacja, `run`, `shots`) pod tym katalogiem,
  w trybie `serve` i `client`;
- `CMCR_SCREEN_AGENT_TEST_DIR=<katalog>` – `serve` działa bez AppKit, ScreenCaptureKit i TCC, stan bierze z plików
  w katalogu (czytanych przy każdym poleceniu): `perm` (`denied` = brak uprawnienia), `locked`, `notconsole`,
  `asleep` (istnieje = tak), `notice` (`shown`/`hidden`/`locked`, domyślnie `shown`), `front` (domyślnie
  „Finder”), `user`, `displays` (domyślnie 1), `size` (np. `1920x1080`, domyślnie `1440x900`), `variant` (istnieje =
  inne kolory obrazu, więc inna suma md5), `capture-fail` (`ERR failed` z treścią pliku), `capture-delay`
  (sekundy), `old` (proces liczy się jako starszy niż 30 s); zapisuje `requests.log` (każde polecenie, `NOTICE`
  także odkodowany: `NOTICE-TEXT <tytuł> | <tekst>`) i `permission-requested`. Obraz testowy to jednolite tło
  z kilkoma prostokątami w rozmiarze po skalowaniu do `maxpx`, kodowane z podaną jakością. W trybie `client`
  zmienna sprawia, że klient ufa usłudze działającej jako ten sam użytkownik, nawet dla innego `<uid>` (testy e2e
  nie mają roota ani drugiego konta) – sprawdzenie ścieżki pliku wykonywalnego zostaje;
- `CMCR_SCREEN_AGENT_TEST_UID=<n>` – `serve` tworzy `<n>.sock` zamiast gniazda własnego uid.

`Tests/ScreenAgentKitTests` sprawdzają protokół, skalowanie, numerację ekranów, base64, zapis zrzutów, zgodność
stałych z `ScreenAgentInfo` i uruchamiają prawdziwy plik wykonywalny (debug) w trybie testowym w katalogu
tymczasowym: `ping`/`capture`/`notice`/`front`, podmiana i usuwanie plików, kody `noperm`/`locked`/…, odmowa
obcemu programowi na gnieździe. `Tests/e2e/run.sh` buduje pakiet usługi z kompilacji debug do
`$WORK/agent-bundle` i eksportuje `CMCR_SCREEN_AGENT_APP` (uwzględniane tylko w kompilacji DEBUG albo w środowisku
testów e2e).
