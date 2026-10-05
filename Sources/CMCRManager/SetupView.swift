import AppKit
import CMCRCore
import SwiftUI

enum SetupTab: String, CaseIterable, Identifiable {
    case hosts, access, general, readiness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hosts: return "Komputery"
        case .access: return "Dostęp i hasła"
        case .general: return "Ustawienia"
        case .readiness: return "Przygotowanie iMaców"
        }
    }

    var icon: String {
        switch self {
        case .hosts: return "desktopcomputer"
        case .access: return "key"
        case .general: return "gearshape"
        case .readiness: return "checklist"
        }
    }
}

struct SetupView: View {
    @ViewState private var tab = SetupTab.hosts

    var body: some View {
        VStack(spacing: 0) {
            Picker("Część konfiguracji", selection: $tab) {
                ForEach(SetupTab.allCases) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            Group {
                switch tab {
                case .hosts: HostsEditor()
                case .access: AccessSettings()
                case .general: GeneralSettings()
                case .readiness: ReadinessView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onSnapshotSubpage { sub in
            if let t = SetupTab(rawValue: String(sub.split(separator: "+").first ?? "")) { tab = t }
        }
    }
}

// MARK: - Hosts

struct HostsEditor: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var confirm: ConfirmRequest?
    @ViewState private var passwordFor: Machine?
    @ViewState private var rows: Set<UUID> = []
    @ViewState private var newGroupFor: Set<UUID>?
    @ViewState private var importError: String?
    @ViewState private var showGenerator = false
    /// Columns shown in the table (right-click the header to change); Port is hidden by default.
    @ViewState private var columns = TableColumnCustomization<Machine>()

    var body: some View {
        let issues = HostValidation.issues(in: model.machines)
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Komputery w pracowni", icon: "desktopcomputer",
                       subtitle: "Lista komputerów, którymi zarządza aplikacja. Kliknij pole w tabeli, aby je poprawić – zmiany zapisują się od razu. Więcej kolumn (np. Port) pokażesz prawym kliknięciem nagłówka tabeli.") {
                Text(Polish.computers(model.machines.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            table(issues)
                .frame(minHeight: 200, maxHeight: .infinity)
                .overlay {
                    if model.machines.isEmpty { emptyList }
                }
            listButtons
            if !issues.isEmpty { issueSummary(issues) }
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
        .sheet(isPresented: $showGenerator) {
            HostListGeneratorSheet().environmentObject(model)
        }
        .alert("Nie można wczytać listy", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .onSnapshotSubpage { sub in
            showGenerator = sub == "hosts+generator"
            passwordFor = sub == "hosts+password" ? model.machines.first : nil
        }
    }

    private struct IDSet: Identifiable {
        let ids: Set<UUID>
        var id: Int { ids.hashValue }
    }

    var emptyList: some View {
        ContentUnavailableView {
            Label("Lista jest pusta", systemImage: "desktopcomputer")
        } description: {
            Text("Dodaj komputery pojedynczo albo utwórz całą listę według wzoru, np. imac01 … imac15.")
        } actions: {
            Button {
                showGenerator = true
            } label: {
                Label("Utwórz listę…", systemImage: "wand.and.stars")
            }
        }
    }

    // MARK: Table

    func table(_ issues: [UUID: [HostIssue]]) -> some View {
        Table(model.machines, selection: $rows, columnCustomization: $columns) {
            TableColumn("Nazwa") { m in
                HStack(spacing: 4) {
                    TextField("Nazwa", text: field(m.id, \.name), prompt: Text("imac01"))
                        .labelsHidden()
                        .help("Nazwa widoczna w aplikacji, np. imac01")
                    if let list = issues[m.id] {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(list.map(\.message).joined(separator: "\n"))
                            .accessibilityLabel("Do poprawienia: \(list.map(\.message).joined(separator: " "))")
                    }
                }
            }
            .width(min: 60, ideal: 68)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Adres w sieci") { m in
                HStack(spacing: 2) {
                    TextField("Adres w sieci", text: field(m.id, \.address), prompt: Text("imac01.local"))
                        .labelsHidden()
                        .help("Nazwa sieciowa lub adres IP komputera, np. imac01.local")
                    // A non-standard port stays visible while the Port column is hidden.
                    if m.port != 22, columns[visibility: "port"] != .visible {
                        Text(":\(String(m.port))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("Niestandardowy port połączenia. Zmienisz go w kolumnie Port – kliknij prawym przyciskiem nagłówek tabeli.")
                    }
                }
            }
            .width(min: 90, ideal: 108)
            .customizationID("address")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Administrator") { m in
                TextField("Konto administratora", text: field(m.id, \.user), prompt: Text("imac01"))
                    .labelsHidden()
                    .help("Konto administratora na tym komputerze, którym loguje się aplikacja")
            }
            .width(min: 64, ideal: 80)
            .customizationID("user")
            TableColumn("Hasło") { m in
                Button {
                    passwordFor = m
                } label: {
                    Label(m.usesSharedPassword ? "Wspólne" : "Własne", systemImage: m.usesSharedPassword ? "key" : "key.fill")
                }
                .controlSize(.small)
                .help(m.usesSharedPassword ? "Używa wspólnego hasła administratora. Kliknij, aby ustawić własne hasło tego komputera."
                                           : "Ma własne hasło zapisane w Pęku kluczy. Kliknij, aby je zmienić.")
            }
            .width(min: 72, ideal: 76)
            .customizationID("password")
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
            .width(min: 60, ideal: 74)
            .customizationID("groups")
            TableColumn("Adres MAC") { m in
                TextField("Adres MAC", text: field(m.id, \.macAddress), prompt: Text("uzupełni się sam"))
                    .labelsHidden()
                    .font(.callout.monospacedDigit())
                    .help("Potrzebny do budzenia komputera przez sieć (Wake-on-LAN). Uzupełnia się sam, gdy komputer jest włączony.")
            }
            .width(min: 96, ideal: 112)
            .customizationID("mac")
            TableColumn("Port") { m in
                TextField("Port", value: portField(m.id), format: .number.grouping(.never))
                    .labelsHidden()
                    .monospacedDigit()
                    .help("Port połączenia (zwykle 22), od 1 do 65535")
            }
            .width(min: 36, ideal: 44)
            .customizationID("port")
            .defaultVisibility(.hidden)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Menu {
                    GroupMembershipMenu(ids: ids) { newGroupFor = ids }
                } label: {
                    Label("Grupy", systemImage: "tag")
                }
                if ids.count == 1, let id = ids.first, let m = model.machine(id) {
                    Button {
                        passwordFor = m
                    } label: {
                        Label("Hasło tego komputera…", systemImage: "key")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    askDelete(ids)
                } label: {
                    Label("Usuń z listy…", systemImage: "trash")
                }
            }
        }
        .onDeleteCommand { askDelete(rows) }
    }

    var listButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                editButtons
                Spacer(minLength: 12)
                fileButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { editButtons }
                HStack(spacing: 8) { fileButtons }
            }
        }
    }

    @ViewBuilder var editButtons: some View {
        Button {
            let m = HostValidation.nextMachine(after: model.machines)
            model.machines.append(m)
            rows = [m.id]
        } label: {
            Label("Dodaj komputer", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("n", modifiers: [.command, .option])
        .help("Dodaje kolejny komputer z pierwszym wolnym numerem, np. imac16 (⌥⌘N)")
        Button(role: .destructive) {
            askDelete(rows)
        } label: {
            Label("Usuń z listy…", systemImage: "trash")
        }
        .disabled(rows.isEmpty)
        .help(rows.isEmpty ? "Najpierw kliknij wiersz w tabeli (z ⌘ – kilka wierszy)."
                           : "Usuwa wybrane wiersze z listy – na samych iMacach nic się nie zmienia (klawisz Delete)")
        Menu {
            GroupMembershipMenu(ids: rows) { newGroupFor = rows }
        } label: {
            Label("Grupy", systemImage: "tag")
        }
        .fixedSize()
        .disabled(rows.isEmpty)
        .help(rows.isEmpty ? "Najpierw kliknij wiersz w tabeli (z ⌘ – kilka wierszy)."
                           : "Dodaje wybrane wiersze do grupy lub usuwa je z grupy")
    }

    @ViewBuilder var fileButtons: some View {
        Button {
            showGenerator = true
        } label: {
            Label("Utwórz listę…", systemImage: "wand.and.stars")
        }
        .help("Tworzy całą listę według wzoru, np. imac01 … imac15 (jak pętla w cmcr-helpers.sh)")
        Menu {
            Button {
                importHosts()
            } label: {
                Label("Wczytaj listę z pliku…", systemImage: "square.and.arrow.down")
            }
            Button {
                if let url = Pickers.save(name: "cmcr-komputery.json") {
                    try? ConfigStore.exportHosts(model.machines, to: url)
                }
            } label: {
                Label("Zapisz listę do pliku…", systemImage: "square.and.arrow.up")
            }
            .disabled(model.machines.isEmpty)
        } label: {
            Label("Plik listy", systemImage: "doc.text")
        }
        .fixedSize()
        .help("Zapisuje listę komputerów (z grupami) do pliku JSON albo zastępuje ją listą z takiego pliku – np. przy przenoszeniu na inny Mac")
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
            button: "Usuń z listy", targets: []) {
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

/// Builds the host list from a pattern, like the loop at the top of cmcr-helpers.sh.
struct HostListGeneratorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var prefix = "imac"
    @ViewState private var start = 1
    @ViewState private var count = 15
    @ViewState private var digits = 2
    @ViewState private var domain = "local"
    @ViewState private var confirm: ConfirmRequest?

    private var preview: [Machine] {
        Machine.generate(prefix: prefix, start: start, count: count, digits: digits, domain: domain)
    }

    private var missing: [Machine] {
        let existing = Set(model.machines.map { $0.address.lowercased() })
        return preview.filter { !existing.contains($0.address.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Utwórz listę komputerów").font(.title2.weight(.semibold))
                    Text("Nazwy powstają według wzoru – tak jak pętla w cmcr-helpers.sh: nazwa komputera jest też nazwą konta administratora, a adres to nazwa z domeną.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section("Wzór") {
                    TextField(text: $prefix, prompt: Text("imac")) {
                        SettingLabel(title: "Początek nazwy", caption: "np. imac → imac01, imac02…", icon: "character.cursor.ibeam", color: .gray)
                    }
                    LabeledContent {
                        NumberField(value: $start, range: 0...999, name: "Pierwszy numer")
                    } label: {
                        SettingLabel(title: "Pierwszy numer", icon: "number", color: .blue)
                    }
                    LabeledContent {
                        NumberField(value: $count, range: 1...250, name: "Liczba komputerów")
                    } label: {
                        SettingLabel(title: "Liczba komputerów", icon: "desktopcomputer", color: .blue)
                    }
                    LabeledContent {
                        NumberField(value: $digits, range: 1...4, name: "Cyfry w numerze")
                    } label: {
                        SettingLabel(title: "Cyfry w numerze", caption: "2 → imac01, 3 → imac001", icon: "textformat.123", color: .gray)
                    }
                    TextField(text: $domain, prompt: Text("local")) {
                        SettingLabel(title: "Domena sieci", caption: "Zwykle „local” – adres imac01.local", icon: "network", color: .blue)
                    }
                }
                Section {
                    ForEach(previewLines, id: \.self) { line in
                        Text(line)
                            .font(.callout.monospaced())
                            .foregroundStyle(line == "…" ? .secondary : .primary)
                    }
                } header: {
                    Text("Podgląd (konto@adres)")
                } footer: {
                    FormFooter(footerText)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(role: .destructive) {
                    askReplace()
                } label: {
                    Label("Zastąp całą listę…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(preview.isEmpty)
                .help("Usuwa obecną listę i wstawia wygenerowaną (grupy i własne hasła obecnych wpisów przepadną)")
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.machines += missing
                    model.refreshStatus()
                    dismiss()
                } label: {
                    Text(missing.isEmpty ? "Dopisz brakujące" : "Dopisz \(Polish.computers(missing.count))")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(missing.isEmpty)
                .help("Dodaje tylko komputery, których adresu jeszcze nie ma na liście")
            }
            .padding(16)
        }
        .frame(width: 540)
        .confirmation($confirm)
    }

    private var previewLines: [String] {
        let all = preview.map(\.destination)
        guard all.count > 4, let last = all.last else { return all }
        return Array(all.prefix(3)) + ["…", last]
    }

    private var footerText: String {
        if preview.isEmpty { return "Wzór nie daje żadnego komputera." }
        if missing.isEmpty { return "Wszystkie te komputery już są na liście." }
        let present = preview.count - missing.count
        return present == 0 ? "Żadnego z nich nie ma jeszcze na liście."
                            : "Już na liście: \(Polish.computers(present)) – zostaną pominięte przy dopisywaniu."
    }

    private func askReplace() {
        let generated = preview
        confirm = ConfirmRequest(title: "Zastąpić listę komputerów?",
                                 message: "Obecna lista (\(Polish.computers(model.machines.count))) zostanie zastąpiona wygenerowaną (\(Polish.computers(generated.count))). Grupy i własne hasła obecnych wpisów przepadną.",
                                 button: "Zastąp listę", targets: []) {
            model.machines = generated
            model.selection = []
            model.refreshStatus()
            dismiss()
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
        Form {
            Section {
                Picker(selection: $useShared) {
                    Text("Wspólne hasło administratora").tag(true)
                    Text("Własne hasło tego komputera").tag(false)
                } label: {
                    SettingLabel(title: "Hasło", caption: "Konto \(machine.user) na \(machine.name)", icon: "key.fill", color: .gray)
                }
                .pickerStyle(.radioGroup)
                if !useShared {
                    SecureField(text: $password, prompt: Text(machine.usesSharedPassword ? "Wpisz hasło" : "Bez zmian")) {
                        Text("Hasło konta \(machine.user)")
                    }
                    .onSubmit(save)
                }
            } header: {
                Text("Hasło administratora – \(machine.name)")
            } footer: {
                FormFooter("Wspólne hasło ustawisz w zakładce Dostęp i hasła. Własne hasło jest zapisywane w Pęku kluczy tego Maca i ma pierwszeństwo przed wspólnym.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { useShared = machine.usesSharedPassword }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Anuluj") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz", action: save)
                    .disabled(!canSave)
            }
        }
    }

    /// Switching to an own password needs one; an existing own password stays when the field is left empty.
    private var canSave: Bool { useShared || !password.isEmpty || !machine.usesSharedPassword }

    private func save() {
        guard canSave else { return }
        if let i = model.machines.firstIndex(where: { $0.id == machine.id }) {
            model.machines[i].usesSharedPassword = useShared
        }
        if !useShared && !password.isEmpty { model.setPassword(password, for: machine) }
        if useShared { model.setPassword("", for: machine) }
        dismiss()
    }
}

// MARK: - Access

struct AccessSettings: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var password = ""
    @ViewState private var confirm: ConfirmRequest?
    @ViewState private var keygenOutput = ""
    @ViewState private var keyRevision = 0

    var body: some View {
        Form {
            passwordSection
            keySection
            targetSection
            if let batch = model.lastBatch[.setup] {
                Section("Wynik ostatniej operacji") {
                    BatchResultsView(batch: batch)
                        .id(batch.id)
                }
            }
        }
        .formStyle(.grouped)
        .confirmation($confirm)
    }

    // MARK: Password

    var passwordSection: some View {
        Section {
            LabeledContent {
                if model.hasSharedPassword {
                    StatusText(text: "Zapisane w Pęku kluczy", symbol: "checkmark.circle.fill", color: .green)
                } else {
                    StatusText(text: "Nie zapisano", symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            } label: {
                SettingLabel(title: "Wspólne hasło administratora",
                             caption: "Hasło kont administratora na iMacach (np. imac07), które nie mają własnego hasła",
                             icon: "key.fill", color: .gray)
            }
            SecureField(text: $password,
                        prompt: Text(model.hasSharedPassword ? "Wpisz, aby zmienić" : "Wpisz hasło")) {
                Text(model.hasSharedPassword ? "Nowe hasło" : "Hasło")
            }
            .onSubmit(savePassword)
            HStack {
                Button(role: .destructive) {
                    confirm = ConfirmRequest(
                        title: "Usunąć hasło administratora z Pęku kluczy?",
                        message: "Bez hasła instalacje, aktualizacje i inne operacje wymagające uprawnień administratora przestaną działać, dopóki nie zapiszesz go ponownie.",
                        button: "Usuń hasło", targets: []) { model.setSharedPassword("") }
                } label: {
                    Label("Usuń hasło…", systemImage: "trash")
                }
                .disabled(!model.hasSharedPassword)
                .help("Usuwa zapisane hasło z Pęku kluczy tego Maca")
                Spacer()
                Button(action: savePassword) {
                    Label("Zapisz hasło", systemImage: "checkmark")
                }
                .disabled(password.isEmpty)
                .help("Zapisuje hasło bezpiecznie w Pęku kluczy tego Maca (Return)")
            }
        } header: {
            Text("Hasło administratora")
        } footer: {
            FormFooter("Potrzebne do instalacji, aktualizacji, podglądu ekranów i innych operacji wymagających uprawnień administratora (sudo), a także do pierwszego połączenia – zanim roześlesz klucz. Hasło jest przesyłane tylko szyfrowanym połączeniem i nigdy nie trafia do treści poleceń.")
        }
    }

    func savePassword() {
        guard !password.isEmpty else { return }
        model.setSharedPassword(password)
        password = ""
    }

    // MARK: Key

    var keySection: some View {
        let key = currentKey
        return Section {
            LabeledContent {
                if key != nil {
                    StatusText(text: "Gotowy", symbol: "checkmark.circle.fill", color: .green)
                } else {
                    StatusText(text: "Brak klucza", symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            } label: {
                SettingLabel(title: "Klucz logowania tego Maca",
                             caption: key.map(\.path) ?? "Utwórz go, aby łączyć się z iMacami bez wpisywania hasła",
                             icon: "key.horizontal.fill", color: .blue)
            }
            if let key {
                LabeledContent("Klucz publiczny") {
                    Text(SSHKeys.publicKey(for: key) ?? "(brak pliku .pub)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .help("Ta część klucza nie jest tajna – trafia na iMaki przy rozsyłaniu")
            }
            if key == nil || !defaultKeyExists {
                HStack {
                    Spacer()
                    Button {
                        Task {
                            let r = await SSHKeys.generate()
                            keygenOutput = (r.stdoutText + r.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
                            keyRevision += 1
                        }
                    } label: {
                        Label(key == nil ? "Utwórz klucz" : "Utwórz nowy klucz", systemImage: "plus.circle")
                    }
                    .help("Tworzy nowy klucz logowania (ed25519) w ~/.ssh na tym Macu, bez dodatkowego hasła klucza")
                }
            }
            if !keygenOutput.isEmpty {
                Text(keygenOutput)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Klucz logowania (SSH)")
        } footer: {
            FormFooter("Dzięki kluczowi aplikacja łączy się z iMacami bez wpisywania hasła. Wystarczy go raz rozesłać na komputery (niżej).")
        }
        .id(keyRevision)
    }

    private var currentKey: URL? { SSHKeys.currentPrivateKey(settings: model.settings) }

    /// `SSHKeys.generate` creates ~/.ssh/id_ed25519 and refuses when it already exists.
    private var defaultKeyExists: Bool {
        FileManager.default.fileExists(atPath: SSHKeys.sshDir.appendingPathComponent("id_ed25519").path)
    }

    // MARK: Targets

    var targetSection: some View {
        let selected = model.selectedMachines
        let offline = selected.filter { model.knownReachability($0).isUnreachable }
        return Section {
            LabeledContent {
                Text(selected.isEmpty ? "brak" : Polish.computers(selected.count))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(selected.map(\.name).joined(separator: ", "))
            } label: {
                SettingLabel(title: "Zaznaczone komputery",
                             caption: selected.isEmpty ? "Zaznacz komputery na liście obok"
                                 : offline.isEmpty ? nil
                                 : "W tym niedostępne przy ostatnim sprawdzeniu: \(offline.count) – te operacje i tak spróbują się z nimi połączyć",
                             icon: "checklist", color: .blue)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Spacer(minLength: 0); targetButtons }
                VStack(alignment: .trailing, spacing: 8) { targetButtons }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } header: {
            Text("Na zaznaczonych komputerach")
        } footer: {
            FormFooter("Rozesłanie klucza loguje się na każdy komputer raz hasłem administratora – potem aplikacja łączy się już kluczem.")
        }
    }

    @ViewBuilder var targetButtons: some View {
        TargetButton(title: "Sprawdź hasło administratora", icon: "checkmark.shield", prominent: false,
                     includeUnreachable: true) {
            model.runScript("Test sudo", on: model.selectedMachines, includeUnreachable: true) { _ in Scripts.sudoTest() }
        }
        TargetButton(title: "Sprawdź połączenie", icon: "network", prominent: false,
                     includeUnreachable: true) {
            model.runScript("Test połączenia", on: model.selectedMachines, includeUnreachable: true,
                            script: { _ in
                                RemoteScript("echo \"Połączono z $(scutil --get ComputerName) jako $(id -un)\"")
                            },
                            onResult: { m, r in model.recheckAfterLogin(m, r) })
        }
        TargetButton(title: "Roześlij klucz", icon: "paperplane", prominent: true, includeUnreachable: true) {
            model.distributeKey(model.selectedMachines)
        }
        .disabled(currentKey == nil)
    }
}

// MARK: - General

/// Konfiguracja › Ustawienia: every app setting on one page (the Settings window splits them into tabs).
struct GeneralSettings: View {
    var body: some View {
        ScrollViewReader { proxy in
            form
                .onSnapshotSubpage { if $0 == "general+end" { proxy.scrollTo("settingsWindow", anchor: .bottom) } }
        }
    }

    var form: some View {
        Form {
            StudentFolderSettings()
            ConnectionSettings()
            ScreenPreviewSettings()
            UpdateSettingsSection()
            AppFilesSettings()
            Section {
                LabeledContent {
                    SettingsLink {
                        Label("Otwórz okno Ustawień", systemImage: "macwindow")
                    }
                    .help("Otwiera te same ustawienia w osobnym oknie (⌘,)")
                } label: {
                    SettingLabel(title: "Okno Ustawień",
                                 caption: "Te same ustawienia otworzysz z każdego miejsca skrótem ⌘, (menu CMCR Manager › Ustawienia…)",
                                 icon: "gearshape.2", color: .gray)
                }
            }
            .id("settingsWindow")
        }
        .formStyle(.grouped)
    }
}

struct StudentFolderSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            TextField(text: $model.settings.studentUser, prompt: Text("student")) {
                SettingLabel(title: "Konto ucznia", caption: "Konto, na które logują się uczniowie",
                             icon: "person.fill", color: .blue)
            }
            TextField(text: $model.settings.sharedFolder, prompt: Text("/Users/student/Public/cmcr")) {
                SettingLabel(title: "Folder ucznia na iMacach",
                             caption: "Tu trafiają materiały i stąd zbierane są prace; {student} oznacza konto ucznia",
                             icon: "folder.fill", color: .cyan)
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Text(model.settings.localFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(model.settings.localFolder)
                    Button("Wybierz…") {
                        if let u = Pickers.folder() { model.settings.localFolder = u.path }
                    }
                    .help("Wybierz folder na tym Macu")
                }
            } label: {
                SettingLabel(title: "Folder na tym Macu", caption: "Zebrane prace i pliki do rozesłania",
                             icon: "macbook", color: .gray)
            }
        } header: {
            Text("Uczniowie i foldery")
        } footer: {
            FormFooter("Zgodne z cmcr-helpers: konto student, folder /Users/student/Public/cmcr na iMacach i ~/Public/cmcr na tym Macu.")
        }
    }
}

struct ConnectionSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(model.settings.identityFile.isEmpty ? "domyślny (~/.ssh)" : model.settings.identityFile)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(model.settings.identityFile.isEmpty ? "Pierwszy z ~/.ssh/id_ed25519, id_rsa, id_ecdsa" : model.settings.identityFile)
                    if !model.settings.identityFile.isEmpty {
                        Button {
                            model.settings.identityFile = ""
                        } label: {
                            Label("Użyj domyślnego klucza", systemImage: "xmark.circle.fill")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Użyj domyślnego klucza z ~/.ssh")
                    }
                    Button("Wybierz…") {
                        if let u = Pickers.files(allowFolders: false).first { model.settings.identityFile = u.path }
                    }
                    .help("Wybierz plik klucza prywatnego (bez rozszerzenia .pub)")
                }
            } label: {
                SettingLabel(title: "Klucz logowania", caption: "Zwykle zostaw domyślny",
                             icon: "key.horizontal.fill", color: .gray)
            }
            LabeledContent {
                NumberField(value: $model.settings.connectTimeout, range: 2...60, unit: "s", name: "Czas oczekiwania")
            } label: {
                SettingLabel(title: "Czas oczekiwania na połączenie",
                             caption: "Po tym czasie komputer, który nie odpowiada, jest uznawany za niedostępny",
                             icon: "timer", color: .orange)
            }
            LabeledContent {
                NumberField(value: $model.settings.maxParallel, range: 1...32, name: "Jednoczesne operacje")
            } label: {
                SettingLabel(title: "Komputery obsługiwane naraz",
                             caption: "Na ilu komputerach jednocześnie wykonywać polecenia i kopiować pliki",
                             icon: "square.stack.3d.up.fill", color: .indigo)
            }
            OptionToggle(title: "Szybsze połączenia", icon: "bolt.fill", color: .green,
                         detail: "Kolejne operacje na tym samym iMacu korzystają z jednego połączenia, więc podgląd ekranów i polecenia startują szybciej",
                         isOn: $model.settings.reuseConnections)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    CodeEditor(text: $model.settings.extraSSHOptions)
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        .accessibilityLabel("Dodatkowe opcje ssh")
                    Text("Po jednej w linii, np. ProxyJump=brama. Mają pierwszeństwo przed ustawieniami aplikacji.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } label: {
                SettingLabel(title: "Dodatkowe opcje połączenia", caption: "Dla administratorów sieci (opcje ssh -o)",
                             icon: "slider.horizontal.3", color: .gray)
            }
        } header: {
            Text("Połączenie z iMacami")
        }
    }
}

struct ScreenPreviewSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            OptionToggle(title: "Powiadamiaj o podglądzie", icon: "bell.badge.fill", color: .red,
                         detail: "Osoba przy komputerze dostaje powiadomienie, gdy zaczyna się podgląd jej ekranu",
                         isOn: $model.settings.notifyOnObserve)
            OptionToggle(title: "Tylko konta standardowe", icon: "person.badge.shield.checkmark.fill", color: .blue,
                         detail: "Ekrany kont administratorów nie są pokazywane",
                         isOn: $model.settings.observeOnlyStandardAccounts)
            TextField(text: $model.settings.observeAllowedUsers, prompt: Text("wszystkie")) {
                SettingLabel(title: "Dozwolone konta", caption: "Oddziel przecinkami, np. student; puste – wszystkie konta",
                             icon: "person.2.fill", color: .blue)
            }
        } header: {
            Text("Podgląd ekranów – prywatność")
        }
        Section {
            LabeledContent {
                NumberField(value: $model.settings.screenshotInterval, range: 3...300, unit: "s", name: "Odświeżanie")
            } label: {
                SettingLabel(title: "Odświeżanie obrazu", caption: "Co ile sekund pobierać nowy obraz ekranu",
                             icon: "arrow.clockwise", color: .teal)
            }
            LabeledContent {
                NumberField(value: $model.settings.screenshotMaxSize, range: 480...2560, step: 160, unit: "px", name: "Rozdzielczość")
            } label: {
                SettingLabel(title: "Największa rozdzielczość", caption: "Dłuższy bok obrazu; mniejsza – szybciej i mniej danych w sieci",
                             icon: "aspectratio.fill", color: .teal)
            }
            LabeledContent {
                NumberField(value: $model.settings.screenshotQuality, range: 20...95, step: 5, unit: "%", name: "Jakość obrazu")
            } label: {
                SettingLabel(title: "Jakość obrazu", caption: "Wyższa – ostrzejszy obraz, więcej danych (JPEG)",
                             icon: "photo.fill", color: .teal)
            }
        } header: {
            Text("Podgląd ekranów – obraz")
        }
    }
}

struct AppFilesSettings: View {
    var body: some View {
        Section {
            LabeledContent {
                Text(ConfigStore.directory.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(ConfigStore.directory.path)
            } label: {
                SettingLabel(title: "Konfiguracja", caption: "Lista komputerów, ustawienia i historia zadań",
                             icon: "folder.fill", color: .gray)
            }
            LabeledContent {
                Text(ConfigStore.logURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(ConfigStore.logURL.path)
            } label: {
                SettingLabel(title: "Dziennik działań", caption: "Co, kiedy i na których komputerach zostało zrobione",
                             icon: "doc.text.fill", color: .gray)
            }
            HStack {
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directory])
                } label: {
                    Label("Pokaż w Finderze", systemImage: "folder")
                }
                .help("Otwiera folder konfiguracji w Finderze")
            }
        } header: {
            Text("Pliki aplikacji")
        }
    }
}

// MARK: - Settings window (⌘,)

enum SettingsTab: String, CaseIterable {
    case general, connection, screens, updates
}

/// The standard Settings window; the same settings are also in Konfiguracja › Ustawienia.
struct AppSettingsWindow: View {
    @ViewState private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            pane { StudentFolderSettings(); AppFilesSettings() }
                .tabItem { Label("Ogólne", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            pane { ConnectionSettings() }
                .tabItem { Label("Połączenie", systemImage: "network") }
                .tag(SettingsTab.connection)
            pane { ScreenPreviewSettings() }
                .tabItem { Label("Podgląd ekranów", systemImage: "eye") }
                .tag(SettingsTab.screens)
            pane { UpdateSettingsSection() }
                .tabItem { Label("Uaktualnienia", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
        }
        .frame(width: 620)
        .onSnapshotSubpage { sub in
            if let t = SettingsTab(rawValue: sub) { tab = t }
        }
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }
}
