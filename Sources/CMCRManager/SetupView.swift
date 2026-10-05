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
    @ViewState private var rows: Set<UUID> = []
    @ViewState private var newGroupFor: Set<UUID>?
    @ViewState private var importError: String?

    var body: some View {
        let issues = HostValidation.issues(in: model.machines)
        VStack(alignment: .leading, spacing: 12) {
            table(issues)
                .frame(minHeight: 220, maxHeight: .infinity)
            listButtons
            if !issues.isEmpty { issueSummary(issues) }
            generator
        }
        .padding(20)
        .confirmation($confirm)
        .sheet(item: $passwordFor) { m in
            HostPasswordSheet(machine: m).environmentObject(model)
        }
        .sheet(item: Binding(get: { newGroupFor.map(IDSet.init) }, set: { newGroupFor = $0?.ids })) { target in
            GroupNameSheet(title: "Nowa grupa (\(Polish.computers(target.ids.count)))") { name in
                HostGroups.add(name, to: target.ids, in: &model.machines)
            }
        }
        .alert("Nie można zaimportować listy", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private struct IDSet: Identifiable {
        let ids: Set<UUID>
        var id: Int { ids.hashValue }
    }

    // MARK: Table

    func table(_ issues: [UUID: [HostIssue]]) -> some View {
        Table(model.machines, selection: $rows) {
            TableColumn("") { m in
                if let list = issues[m.id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(list.map(\.message).joined(separator: "\n"))
                        .accessibilityLabel("Problem: \(list.map(\.message).joined(separator: " "))")
                }
            }
            .width(18)
            TableColumn("Nazwa") { m in
                TextField("Nazwa", text: field(m.id, \.name), prompt: Text("imac01"))
                    .labelsHidden()
            }
            .width(min: 80, ideal: 100)
            TableColumn("Adres (host)") { m in
                TextField("Adres", text: field(m.id, \.address), prompt: Text("imac01.local"))
                    .labelsHidden()
            }
            .width(min: 120, ideal: 160)
            TableColumn("Konto administratora") { m in
                TextField("Konto", text: field(m.id, \.user), prompt: Text("imac01"))
                    .labelsHidden()
            }
            .width(min: 90, ideal: 120)
            TableColumn("Port") { m in
                TextField("Port", value: portField(m.id), format: .number.grouping(.never))
                    .labelsHidden()
                    .monospacedDigit()
                    .help("Port SSH (zwykle 22), od 1 do 65535")
            }
            .width(min: 50, ideal: 56)
            TableColumn("MAC (Wake-on-LAN)") { m in
                TextField("MAC", text: field(m.id, \.macAddress), prompt: Text("uzupełni się sam"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .help("Uzupełniany automatycznie przy odświeżaniu stanu włączonego komputera")
            }
            .width(min: 120, ideal: 150)
            TableColumn("Grupy") { m in
                Menu {
                    GroupMembershipMenu(ids: [m.id]) { newGroupFor = [m.id] }
                } label: {
                    Text(m.groups.isEmpty ? "Brak" : m.groups.joined(separator: ", "))
                        .foregroundStyle(m.groups.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .help("Grupy pozwalają szybko zaznaczać i filtrować komputery (np. rząd ławek)")
            }
            .width(min: 90, ideal: 130)
            TableColumn("Hasło") { m in
                Button(m.usesSharedPassword ? "Wspólne" : "Własne") { passwordFor = m }
                    .controlSize(.small)
                    .help(m.usesSharedPassword ? "Używa wspólnego hasła administratora. Kliknij, aby ustawić własne."
                                               : "Ma własne hasło w Pęku kluczy. Kliknij, aby zmienić.")
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Menu("Grupy") {
                    GroupMembershipMenu(ids: ids) { newGroupFor = ids }
                }
                Divider()
                Button("Usuń z listy…", role: .destructive) { askDelete(ids) }
            }
        }
        .onDeleteCommand { askDelete(rows) }
    }

    var listButtons: some View {
        HStack(spacing: 8) {
            Button {
                let m = HostValidation.nextMachine(after: model.machines)
                model.machines.append(m)
                rows = [m.id]
            } label: {
                Label("Dodaj komputer", systemImage: "plus")
            }
            .help("Dodaje kolejny komputer (pierwszy wolny numer, np. imac16)")
            Button(role: .destructive) {
                askDelete(rows)
            } label: {
                Label("Usuń", systemImage: "minus")
            }
            .disabled(rows.isEmpty)
            .help("Usuwa zaznaczone wiersze z listy (na samych iMacach nic się nie zmienia)")
            Menu {
                GroupMembershipMenu(ids: rows) { newGroupFor = rows }
            } label: {
                Label("Grupy", systemImage: "tag")
            }
            .fixedSize()
            .disabled(rows.isEmpty)
            .help("Dodaje zaznaczone wiersze do grupy lub je z niej usuwa")
            Spacer()
            Button {
                importHosts()
            } label: {
                Label("Importuj…", systemImage: "square.and.arrow.down")
            }
            .help("Zastępuje listę komputerami z pliku JSON")
            Button {
                if let url = Pickers.save(name: "cmcr-komputery.json") {
                    try? ConfigStore.exportHosts(model.machines, to: url)
                }
            } label: {
                Label("Eksportuj…", systemImage: "square.and.arrow.up")
            }
            .help("Zapisuje listę komputerów (z grupami) do pliku JSON")
        }
    }

    func issueSummary(_ issues: [UUID: [HostIssue]]) -> some View {
        let lines = model.machines.compactMap { m in
            issues[m.id].map { "\(m.name.isEmpty ? "(bez nazwy)" : m.name): \($0.map(\.message).joined(separator: " "))" }
        }
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Do poprawienia: \(Polish.computers(lines.count))").fontWeight(.semibold)
                ForEach(lines.prefix(4), id: \.self) { Text($0).lineLimit(2) }
                if lines.count > 4 { Text("… i \(lines.count - 4) więcej") }
            }
            .font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    var generator: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    LabeledContent("Prefiks") {
                        TextField("Prefiks", text: $prefix).labelsHidden().frame(width: 80)
                    }
                    Stepper("Od numeru \(start)", value: $start, in: 0...999).fixedSize()
                    Stepper("Liczba: \(count)", value: $count, in: 1...250).fixedSize()
                    Stepper("Cyfr: \(digits)", value: $digits, in: 1...4).fixedSize()
                    LabeledContent("Domena") {
                        TextField("Domena", text: $domain).labelsHidden().frame(width: 80)
                    }
                }
                let preview = Machine.generate(prefix: prefix, start: start, count: count, digits: digits, domain: domain)
                Text("Np.: \(preview.prefix(3).map(\.destination).joined(separator: ", "))\(preview.count > 3 ? " … \(preview.last!.destination)" : "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack {
                    Button(role: .destructive) {
                        confirm = ConfirmRequest(title: "Zastąpić listę komputerów?",
                                                 message: "Obecna lista (\(Polish.computers(model.machines.count))) zostanie zastąpiona \(preview.count) wygenerowanymi wpisami. Grupy i własne hasła obecnych wpisów przepadną.",
                                                 button: "Zastąp", targets: []) {
                            model.machines = preview
                            model.selection = []
                            model.refreshStatus()
                        }
                    } label: {
                        Label("Zastąp listę", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        let existing = Set(model.machines.map { $0.address.lowercased() })
                        model.machines += preview.filter { !existing.contains($0.address.lowercased()) }
                        model.refreshStatus()
                    } label: {
                        Label("Dopisz brakujące", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("Dodaje tylko komputery, których adresu jeszcze nie ma na liście")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Generator listy (jak pętla w cmcr-helpers.sh)", systemImage: "wand.and.stars")
        }
    }

    // MARK: Editing helpers

    /// Binds a field by host id (index bindings crash when a row is deleted while one of its fields is edited).
    func field(_ id: UUID, _ key: WritableKeyPath<Machine, String>) -> Binding<String> {
        Binding(get: { model.machine(id)?[keyPath: key] ?? "" },
                set: { value in
                    if let i = model.machines.firstIndex(where: { $0.id == id }) { model.machines[i][keyPath: key] = value }
                })
    }

    func portField(_ id: UUID) -> Binding<Int> {
        Binding(get: { model.machine(id)?.port ?? 22 },
                set: { value in
                    guard HostValidation.portRange.contains(value) else {
                        NSSound.beep()
                        return
                    }
                    if let i = model.machines.firstIndex(where: { $0.id == id }) { model.machines[i].port = value }
                })
    }

    func askDelete(_ ids: Set<UUID>) {
        let doomed = model.machines.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        let names = doomed.prefix(5).map(\.name).joined(separator: ", ") + (doomed.count > 5 ? "…" : "")
        confirm = ConfirmRequest(
            title: doomed.count == 1 ? "Usunąć \(doomed[0].name) z listy?" : "Usunąć \(Polish.computers(doomed.count)) z listy?",
            message: "\(names) – \(doomed.count == 1 ? "zniknie" : "znikną") z listy. Na samych iMacach nic się nie zmienia.",
            button: "Usuń", targets: []) {
            for m in doomed where !m.usesSharedPassword { model.setPassword("", for: m) }
            model.machines.removeAll { ids.contains($0.id) }
            rows.subtract(ids)
        }
    }

    func importHosts() {
        guard let url = Pickers.files(allowFolders: false, types: [.json]).first else { return }
        do {
            let hosts = try ConfigStore.importHosts(from: url)
            guard !hosts.isEmpty else {
                importError = "Plik nie zawiera żadnego komputera."
                return
            }
            model.machines = hosts
            rows = []
            model.refreshStatus()
        } catch {
            importError = "\(url.lastPathComponent): \(error.localizedDescription)"
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
    @ViewState private var confirm: ConfirmRequest?
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
                    Button("Usuń", role: .destructive) {
                        confirm = ConfirmRequest(
                            title: "Usunąć hasło administratora z Pęku kluczy?",
                            message: "Bez hasła instalacje, aktualizacje i inne operacje wymagające uprawnień (sudo) przestaną działać, dopóki nie zapiszesz go ponownie.",
                            button: "Usuń hasło", targets: []) { model.setSharedPassword("") }
                    }
                    .disabled(!model.hasSharedPassword)
                }
                Text("Hasło służy do sudo (instalacje, aktualizacje, uruchamianie aplikacji u użytkownika, podgląd ekranu) oraz do logowania SSH, dopóki klucz nie zostanie rozesłany. Jest przekazywane wyłącznie przez szyfrowane połączenie SSH (stdin), nigdy w linii poleceń.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TargetButton(title: "Sprawdź sudo na zaznaczonych", icon: "checkmark.shield", prominent: false,
                             includeUnreachable: true) {
                    model.runScript("Test sudo", on: model.selectedMachines, includeUnreachable: true) { _ in Scripts.sudoTest() }
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
                    TargetButton(title: "Roześlij klucz na zaznaczone", icon: "paperplane", prominent: true,
                                 includeUnreachable: true) {
                        model.distributeKey(model.selectedMachines)
                    }
                    .disabled(SSHKeys.currentPrivateKey(settings: model.settings) == nil)
                    TargetButton(title: "Testuj logowanie", icon: "bolt.horizontal", prominent: false,
                                 includeUnreachable: true) {
                        model.runScript("Test połączenia", on: model.selectedMachines, includeUnreachable: true,
                                        script: { _ in
                                            RemoteScript("echo \"Połączono z $(scutil --get ComputerName) jako $(id -un)\"")
                                        },
                                        onResult: { m, r in model.recheckAfterLogin(m, r) })
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
        .confirmation($confirm)
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
