import AppKit
import CMCRCore
import SwiftUI

struct SetupView: View {
    @ViewState private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                Text("Komputery").tag(0)
                Text("Dostęp i hasła").tag(1)
                Text("Ustawienia").tag(2)
                Text("Przygotowanie iMaców").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 20)
            switch tab {
            case 0: HostsEditor()
            case 1: AccessSettings()
            case 2: GeneralSettings()
            default: RemoteSetup()
            }
        }
    }
}

// MARK: - Hosts

struct HostsEditor: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var prefix = "imac"
    @ViewState private var start = 1
    @ViewState private var count = 15
    @ViewState private var digits = 2
    @ViewState private var domain = "local"
    @ViewState private var confirm: ConfirmRequest?
    @ViewState private var passwordFor: Machine?

    var body: some View {
        Page {
            SectionBox(title: "Lista komputerów", icon: "desktopcomputer") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Nazwa").font(.caption.weight(.semibold))
                        Text("Adres (host)").font(.caption.weight(.semibold))
                        Text("Konto admin.").font(.caption.weight(.semibold))
                        Text("Port").font(.caption.weight(.semibold))
                        Text("MAC (Wake-on-LAN)").font(.caption.weight(.semibold))
                        Text("Hasło").font(.caption.weight(.semibold))
                        Text("")
                    }
                    ForEach($model.machines) { $m in
                        GridRow {
                            TextField("imac01", text: $m.name).frame(width: 90)
                            TextField("imac01.local", text: $m.address).frame(minWidth: 120, maxWidth: 180)
                            TextField("imac01", text: $m.user).frame(width: 100)
                            TextField("22", value: $m.port, format: .number.grouping(.never)).frame(width: 50)
                            TextField("aa:bb:cc:dd:ee:ff", text: $m.macAddress).frame(width: 140).font(.body.monospaced())
                            Button(m.usesSharedPassword ? "wspólne" : "własne") { passwordFor = m }
                                .controlSize(.small)
                            Button {
                                let target = m
                                confirm = ConfirmRequest(title: "Usunąć \(target.name)?", message: "Komputer zniknie z listy (nic nie jest zmieniane na samym iMacu).", button: "Usuń") {
                                    model.machines.removeAll { $0.id == target.id }
                                    model.selection.remove(target.id)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    Button("Dodaj komputer") {
                        let n = model.machines.count + 1
                        let name = String(format: "imac%02d", n)
                        model.machines.append(Machine(name: name, address: "\(name).local", user: name))
                    }
                    Button("Importuj…") {
                        if let url = Pickers.files(allowFolders: false, types: [.json]).first,
                           let hosts = try? ConfigStore.importHosts(from: url) {
                            model.machines = hosts
                        } else {
                            NSSound.beep()
                        }
                    }
                    Button("Eksportuj…") {
                        if let url = Pickers.save(name: "cmcr-komputery.json") {
                            try? ConfigStore.exportHosts(model.machines, to: url)
                        }
                    }
                }
            }

            SectionBox(title: "Generator (jak pętla w cmcr-helpers.sh)", icon: "wand.and.stars") {
                HStack {
                    TextField("prefiks", text: $prefix).frame(width: 80)
                    Stepper("od \(start)", value: $start, in: 0...999).frame(width: 90)
                    Stepper("liczba \(count)", value: $count, in: 1...250).frame(width: 110)
                    Stepper("cyfr \(digits)", value: $digits, in: 1...4).frame(width: 90)
                    Text("domena")
                    TextField("local", text: $domain).frame(width: 80)
                }
                let preview = Machine.generate(prefix: prefix, start: start, count: count, digits: digits, domain: domain)
                Text("Np.: \(preview.prefix(3).map(\.destination).joined(separator: ", "))\(preview.count > 3 ? " … \(preview.last!.destination)" : "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Zastąp listę") {
                        confirm = ConfirmRequest(title: "Zastąpić listę komputerów?",
                                                 message: "Obecna lista (\(model.machines.count)) zostanie zastąpiona \(preview.count) wygenerowanymi wpisami.",
                                                 button: "Zastąp") {
                            model.machines = preview
                            model.selection = []
                            model.refreshStatus()
                        }
                    }
                    Button("Dopisz do listy") {
                        let existing = Set(model.machines.map(\.address))
                        model.machines += preview.filter { !existing.contains($0.address) }
                        model.refreshStatus()
                    }
                }
            }
        }
        .confirmation($confirm)
        .sheet(item: $passwordFor) { m in
            HostPasswordSheet(machine: m).environmentObject(model)
        }
    }
}

struct HostPasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let machine: Machine
    @ViewState private var useShared = true
    @ViewState private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hasło administratora – \(machine.name)").font(.headline)
            Picker("", selection: $useShared) {
                Text("Wspólne hasło").tag(true)
                Text("Własne hasło tego komputera").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if !useShared {
                SecureField("Hasło konta \(machine.user)", text: $password)
            }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                Button("Zapisz") {
                    if let i = model.machines.firstIndex(where: { $0.id == machine.id }) {
                        model.machines[i].usesSharedPassword = useShared
                    }
                    if !useShared && !password.isEmpty { model.setPassword(password, for: machine) }
                    if useShared { model.setPassword("", for: machine) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { useShared = machine.usesSharedPassword }
    }
}

// MARK: - Access

struct AccessSettings: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var password = ""
    @ViewState private var keyInfo = ""
    @ViewState private var keygenOutput = ""

    var body: some View {
        Page {
            SectionBox(title: "Hasło administratora (wspólne dla kont imacNN)", icon: "key.fill") {
                HStack {
                    SecureField(model.hasSharedPassword ? "•••••••• (zapisane w Pęku kluczy)" : "Hasło kont administracyjnych", text: $password)
                        .frame(maxWidth: 320)
                    Button("Zapisz w Pęku kluczy") {
                        model.setSharedPassword(password)
                        password = ""
                    }
                    .disabled(password.isEmpty)
                    Button("Usuń") { model.setSharedPassword("") }
                        .disabled(!model.hasSharedPassword)
                }
                Text("Hasło służy do sudo (instalacje, aktualizacje, uruchamianie aplikacji u użytkownika, podgląd ekranu) oraz do logowania SSH, dopóki klucz nie zostanie rozesłany. Jest przekazywane wyłącznie przez szyfrowane połączenie SSH (stdin), nigdy w linii poleceń.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TargetButton(title: "Sprawdź sudo na zaznaczonych", icon: "checkmark.shield", prominent: false) {
                    model.runScript("Test sudo", on: model.selectedMachines) { _ in Scripts.sudoTest() }
                }
            }

            SectionBox(title: "Klucz SSH (README: Distribute your SSH key)", icon: "key.horizontal") {
                Text(keyInfo).font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Wygeneruj nowy klucz (ed25519)") {
                        Task {
                            let r = await SSHKeys.generate()
                            keygenOutput = r.stdoutText + r.stderrText
                            reloadKey()
                        }
                    }
                    TargetButton(title: "Roześlij klucz na zaznaczone", icon: "paperplane", prominent: true) {
                        model.distributeKey(model.selectedMachines)
                    }
                    .disabled(SSHKeys.currentPrivateKey(settings: model.settings) == nil)
                    TargetButton(title: "Testuj logowanie", icon: "bolt.horizontal", prominent: false) {
                        model.runScript("Test połączenia", on: model.selectedMachines) { _ in
                            RemoteScript("echo \"Połączono z $(scutil --get ComputerName) jako $(id -un)\"")
                        }
                    }
                }
                if !keygenOutput.isEmpty {
                    Text(keygenOutput).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("Pierwsza dystrybucja loguje się hasłem administratora (zapisz je wyżej). Potem połączenia używają klucza.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LastBatchView(section: .setup)
        }
        .onAppear(perform: reloadKey)
    }

    func reloadKey() {
        if let key = SSHKeys.currentPrivateKey(settings: model.settings) {
            let pub = SSHKeys.publicKey(for: key) ?? "(brak pliku .pub)"
            keyInfo = "\(key.path)\n\(pub.prefix(80))…"
        } else {
            keyInfo = "Brak klucza w ~/.ssh – wygeneruj go poniżej."
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Konta i foldery (cmcr-helpers)") {
                TextField("Konto ucznia", text: $model.settings.studentUser)
                TextField("Folder współdzielony na iMacach", text: $model.settings.sharedFolder)
                HStack {
                    TextField("Folder lokalny", text: $model.settings.localFolder)
                    Button("Wybierz…") { if let u = Pickers.folder() { model.settings.localFolder = u.path } }
                }
            }
            Section("Połączenie SSH") {
                HStack {
                    TextField("Klucz prywatny (puste = domyślne ~/.ssh/id_*)", text: $model.settings.identityFile)
                    Button("Wybierz…") {
                        if let u = Pickers.files(allowFolders: false).first { model.settings.identityFile = u.path }
                    }
                }
                Stepper("Limit czasu połączenia: \(model.settings.connectTimeout) s", value: $model.settings.connectTimeout, in: 2...60)
                Stepper("Równoległe operacje: \(model.settings.maxParallel)", value: $model.settings.maxParallel, in: 1...32)
                Toggle("Współdzielone połączenia SSH (szybsze)", isOn: $model.settings.reuseConnections)
                    .help("Kolejne operacje na tym samym iMacu korzystają z jednego połączenia, więc podgląd ekranów i polecenia startują szybciej.")
                VStack(alignment: .leading) {
                    Text("Dodatkowe opcje ssh (-o), po jednej w linii, np. ProxyJump=brama – mają pierwszeństwo przed ustawieniami aplikacji")
                        .font(.caption).foregroundStyle(.secondary)
                    CodeEditor(text: $model.settings.extraSSHOptions)
                        .frame(height: 60)
                }
            }
            Section("Podgląd ekranów – ograniczenia") {
                Toggle("Powiadamiaj użytkownika o rozpoczęciu podglądu", isOn: $model.settings.notifyOnObserve)
                Toggle("Podgląd tylko kont standardowych (bez kont administratorów)", isOn: $model.settings.observeOnlyStandardAccounts)
                TextField("Dozwolone konta (np. student; puste = wszystkie)", text: $model.settings.observeAllowedUsers)
                Stepper("Odświeżanie co \(model.settings.screenshotInterval) s", value: $model.settings.screenshotInterval, in: 3...300)
                Stepper("Maks. rozdzielczość: \(model.settings.screenshotMaxSize) px", value: $model.settings.screenshotMaxSize, in: 480...2560, step: 160)
                Stepper("Jakość JPEG: \(model.settings.screenshotQuality)%", value: $model.settings.screenshotQuality, in: 20...95, step: 5)
            }
            Section("Pliki aplikacji") {
                LabeledContent("Konfiguracja", value: ConfigStore.directory.path)
                LabeledContent("Dziennik działań", value: ConfigStore.logURL.path)
                Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directory]) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Remote setup

struct RemoteSetup: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page {
            SectionBox(title: "Działania na zaznaczonych iMacach", icon: "wrench.and.screwdriver") {
                HStack {
                    TargetButton(title: "Utwórz folder cmcr ucznia", icon: "folder.badge.plus", prominent: false) {
                        let path = model.settings.sharedFolder, owner = model.settings.studentUser
                        model.runScript("Folder \(path)", on: model.selectedMachines) { _ in
                            Scripts.prepareSharedFolder(path, owner: owner)
                        }
                    }
                    TargetButton(title: "Włącz Udostępnianie ekranu", icon: "rectangle.on.rectangle", prominent: false) {
                        model.runScript("Włącz Udostępnianie ekranu", on: model.selectedMachines) { _ in Scripts.enableScreenSharing() }
                    }
                    TargetButton(title: "Włącz Wake-on-LAN", icon: "sunrise", prominent: false) {
                        model.runScript("pmset womp 1", on: model.selectedMachines) { _ in Scripts.enableWakeOnLAN() }
                    }
                    TargetButton(title: "Zapomnij klucz hosta", icon: "key.slash", prominent: false) {
                        model.forgetHostKeys(model.selectedMachines)
                    }
                }
            }
            SectionBox(title: "Jednorazowo na każdym iMacu (lokalnie, przy komputerze)", icon: "checklist") {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Ustawienia systemowe › Ogólne › Udostępnianie › Logowanie zdalne: włącz, dostęp dla administratorów (konto imacNN). Zaznacz „Zezwalaj zdalnym użytkownikom na pełny dostęp do dysku”, by móc pobierać pliki z chronionych folderów ucznia.")
                    step(2, "Podgląd ekranu: Ustawienia › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego › „+” › Cmd+Shift+G › /usr/libexec/sshd-keygen-wrapper › włącz. Bez tego zrzut pokaże tylko tapetę lub się nie powiedzie.")
                    step(3, "Pełne zdalne sterowanie (opcjonalnie): Udostępnianie › Udostępnianie ekranu – włącz dla administratorów. Aplikacja otwiera wtedy wbudowane „Udostępnianie ekranu” (VNC).")
                    step(4, "Wake-on-LAN: Ustawienia › Energia › „Budź przy dostępie do sieci” (lub przycisk powyżej).")
                    step(5, "Na tym Macu: przy pierwszym połączeniu zezwól aplikacji CMCR Manager na dostęp do sieci lokalnej.")
                }
                .font(.callout)
            }
        }
    }

    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.callout.weight(.bold)).frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
