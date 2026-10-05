import AppKit
import CMCRCore
import SwiftUI

/// Details of the single selected Mac, shown in the dashboard's inspector.
struct HostInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared

    var body: some View {
        if model.selection.count == 1, let id = model.selection.first, let m = model.machine(id) {
            details(m)
        } else {
            ContentUnavailableView(model.selection.isEmpty ? "Nie zaznaczono komputera" : "Zaznaczono \(model.selection.count) \(Plural.computers(model.selection.count))",
                                   systemImage: "sidebar.trailing",
                                   description: Text("Zaznacz jeden komputer w tabeli, aby zobaczyć jego szczegóły i notatki."))
        }
    }

    func details(_ m: Machine) -> some View {
        let st = model.status(m)
        return Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.name).font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            StatusDot(reachability: st.reachability)
                            Text(st.reachability.label).foregroundStyle(.secondary)
                        }
                        Text(m.destination).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if !st.message.isEmpty {
                    Label(st.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Stan") {
                LabeledContent("Zalogowany", value: st.consoleUser ?? "nikt")
                LabeledContent("macOS", value: [st.osVersion, st.info["build"].map { "(\($0))" }].compactMap { $0 }.joined(separator: " ").ifEmpty("—"))
                LabeledContent("Model", value: st.model ?? "—")
                if let chip = st.info["chip"], !chip.isEmpty { LabeledContent("Procesor", value: chip) }
                if let mem = st.info["mem"], !mem.isEmpty { LabeledContent("Pamięć", value: "\(mem) GB") }
                LabeledContent("Czas pracy", value: st.uptimeText ?? "—")
                LabeledContent("Ostatnio widziany") {
                    if st.reachability == .online {
                        Text("teraz")
                    } else if let seen = classroom.lastSeen[m.id] {
                        Text(seen.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("—")
                    }
                }
                if let checked = st.updatedAt {
                    LabeledContent("Sprawdzono", value: checked.formatted(date: .omitted, time: .shortened))
                }
            }

            if let free = st.freeDiskGB, let total = st.totalDiskGB, total > 0 {
                Section("Dysk") {
                    Gauge(value: total - free, in: 0...total) {
                        Text("Zajęte")
                    } currentValueLabel: {
                        Text(String(format: "%.0f GB wolne z %.0f GB", free, total))
                    }
                    .tint(free < DashboardRow.lowDiskGB ? .orange : .accentColor)
                }
            }

            Section("Sieć") {
                CopyRow(title: "IP", value: st.ip)
                CopyRow(title: "MAC (Wake-on-LAN)", value: classroom.wakeMACs(m, status: st).first)
                if let lhn = classroom.names[m.id]?.localHostName, !lhn.isEmpty {
                    CopyRow(title: "Nazwa w sieci", value: "\(lhn).local")
                }
            }

            Section("Bezpieczeństwo i zasilanie") {
                LabeledContent("FileVault") {
                    switch st.fileVaultOn ?? classroom.fileVault[m.id] {
                    case .some(true): Label("włączony", systemImage: "lock.shield").foregroundStyle(.orange)
                    case .some(false): Text("wyłączony")
                    case .none: Text("nie sprawdzono").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Harmonogram") {
                    Text(scheduleText(m)).multilineTextAlignment(.trailing)
                }
                if classroom.isLocked(m.id), let lock = classroom.locks[m.id] {
                    LabeledContent("Tryb uwagi", value: "\(lock.label) od \(lock.since.formatted(date: .omitted, time: .shortened))")
                }
                HStack {
                    Spacer()
                    Button("Sprawdź") {
                        classroom.checkFileVault(model, [m])
                        classroom.loadSchedules(model, [m])
                        classroom.loadNames(model, [m])
                    }
                    .controlSize(.small)
                    .help("Odczytaj FileVault, harmonogram zasilania i nazwę w sieci")
                }
            }

            Section("Notatki") {
                TextField("Notatki", text: notes(m), prompt: Text("np. uszkodzona mysz, stanowisko przy oknie"), axis: .vertical)
                    .lineLimit(2...6)
                    .labelsHidden()
            }

            Section("Działania") {
                InspectorAction(title: "Sesja SSH w Terminalu", icon: "terminal") { model.openTerminal(m) }
                InspectorAction(title: "Udostępnianie ekranu (VNC)", icon: "rectangle.on.rectangle") { model.openScreenSharing(m) }
                InspectorAction(title: "Podgląd ekranu", icon: "eye") {
                    model.selection = [m.id]
                    model.section = .screens
                }
                InspectorAction(title: "Obudź (Wake-on-LAN)", icon: "sunrise") { model.wake([m]) }
                InspectorAction(title: "Odśwież stan", icon: "arrow.clockwise") { model.refreshStatus([m]) }
            }
        }
        .formStyle(.grouped)
    }

    func scheduleText(_ m: Machine) -> String {
        guard let info = classroom.schedules[m.id] else { return "nie sprawdzono" }
        if let e = info.error { return e }
        return info.events.isEmpty ? "brak" : info.events.map(\.text).joined(separator: "\n")
    }

    func notes(_ m: Machine) -> Binding<String> {
        Binding(
            get: { model.machine(m.id)?.notes ?? "" },
            set: { value in
                if let i = model.machines.firstIndex(where: { $0.id == m.id }), model.machines[i].notes != value {
                    model.machines[i].notes = value
                }
            })
    }
}

private struct CopyRow: View {
    let title: String
    let value: String?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value ?? "—").font(.body.monospacedDigit()).textSelection(.enabled)
                if let value, !value.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Label("Kopiuj", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Kopiuj \(title)")
                }
            }
        }
    }
}

private struct InspectorAction: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Rename computers

struct RenameComputersSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @Environment(\.dismiss) private var dismiss
    @ViewState private var entries: [Entry] = []
    @ViewState private var updateList = true

    struct Entry: Identifiable {
        let machine: Machine
        var newName: String
        var id: UUID { machine.id }
        var localHostName: String { ComputerNames.localHostName(from: newName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Zmień nazwy komputerów", systemImage: "character.cursor.ibeam")
                .font(.title3.weight(.semibold))
            Text("Na każdym Macu zostanie ustawiona nazwa komputera, nazwa w sieci (adres .local) i nazwa hosta. Domyślnie to nazwy z listy w aplikacji – pozwala to też naprawić konflikty nazw (np. imac04-2.local).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Table($entries) {
                TableColumn("Komputer") { $e in Text(e.machine.name).fontWeight(.medium) }
                    .width(min: 70, ideal: 90)
                TableColumn("Obecnie") { $e in currentText(e) }
                    .width(min: 140, ideal: 190)
                TableColumn("Nowa nazwa") { $e in
                    TextField("Nowa nazwa", text: $e.newName).labelsHidden()
                }
                .width(min: 120, ideal: 150)
                TableColumn("Nowy adres") { $e in
                    if ComputerNames.isValidLocalHostName(e.localHostName) {
                        Text("\(e.localHostName).local").font(.body.monospaced())
                            .foregroundStyle(isUnchanged(e) ? .secondary : .primary)
                    } else {
                        Label("niepoprawna nazwa", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                .width(min: 140, ideal: 170)
            }
            .frame(minHeight: 220)
            Toggle("Zaktualizuj nazwy i adresy na liście komputerów w aplikacji", isOn: $updateList)
            Label("Adres .local komputera zmieni się na nowy. Bez aktualizacji listy aplikacja nie połączy się z nim pod starym adresem. Zmiana w sieci może potrwać do minuty.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Przywróć nazwy z listy") {
                    for i in entries.indices { entries[i].newName = entries[i].machine.name }
                }
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Zmień nazwy (\(changes.count))") {
                    classroom.rename(model, changes.map {
                        ClassroomModel.RenameEntry(machine: $0.machine, computerName: $0.newName.trimmingCharacters(in: .whitespaces),
                                                   localHostName: $0.localHostName)
                    }, updateList: updateList)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(changes.isEmpty || entries.contains { !ComputerNames.isValidLocalHostName($0.localHostName) })
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .onAppear {
            let targets = model.selectedMachines
            entries = targets.map { Entry(machine: $0, newName: $0.name) }
            classroom.loadNames(model, targets)
        }
    }

    var changes: [Entry] { entries.filter { !isUnchanged($0) } }

    func isUnchanged(_ e: Entry) -> Bool {
        guard let cur = classroom.names[e.id] else { return false }
        return cur.computerName == e.newName && cur.localHostName == e.localHostName
    }

    @ViewBuilder func currentText(_ e: Entry) -> some View {
        if let cur = classroom.names[e.id] {
            let conflict = cur.localHostName.range(of: #"-\d+$"#, options: .regularExpression) != nil
                && cur.localHostName != e.localHostName
            HStack(spacing: 4) {
                Text("\(cur.computerName) · \(cur.localHostName).local")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Nazwa komputera: \(cur.computerName)\nAdres: \(cur.localHostName).local\nHostName: \(cur.hostName.isEmpty ? "nie ustawiono" : cur.hostName)")
                if conflict {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("Możliwy konflikt nazw w sieci (macOS dopisał numer)")
                }
            }
        } else {
            Text(model.status(e.machine).reachability == .online ? "sprawdzanie…" : "niedostępny")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - App versions

struct AppVersionsSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var onlyDifferences = false

    struct Row: Identifiable {
        let machine: Machine
        let version: String
        let build: String
        let path: String
        let state: State
        var id: UUID { machine.id }
        enum State { case same, different, missing, error, pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Wersje aplikacji", systemImage: "app.badge.checkmark")
                .font(.title3.weight(.semibold))
            HStack {
                TextField("Aplikacja", text: $name, prompt: Text("np. Unity Hub, Google Chrome"))
                    .onSubmit(check)
                AppNameMenu { name = $0 }
                Button(action: check) {
                    Label("Sprawdź", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(model.selection.isEmpty ? "Sprawdzi wszystkie komputery" : "Sprawdzi zaznaczone komputery (\(model.selection.count))")
            }
            if let result = classroom.appVersions {
                HStack {
                    Text(summary(result)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Tylko różnice", isOn: $onlyDifferences)
                }
                Table(visibleRows(result)) {
                    TableColumn("Komputer") { r in Text(r.machine.name).fontWeight(.medium) }
                        .width(min: 70, ideal: 90)
                    TableColumn("Wersja") { r in versionText(r) }
                        .width(min: 90, ideal: 120)
                    TableColumn("Kompilacja") { r in Text(r.build).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 80)
                    TableColumn("Położenie") { r in
                        Text(r.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(r.path)
                    }
                }
                .frame(minHeight: 240)
            } else {
                ContentUnavailableView("Wpisz nazwę aplikacji",
                                       systemImage: "app.dashed",
                                       description: Text("Porównasz wersję tej aplikacji na wszystkich (lub zaznaczonych) komputerach – np. przed lekcją z Unity."))
                    .frame(minHeight: 240)
            }
            HStack {
                Button {
                    if let r = classroom.appVersions { classroom.exportCSV(csvRows(r), suggestedName: "wersje-\(r.appName).csv") }
                } label: {
                    Label("Eksportuj CSV…", systemImage: "square.and.arrow.up")
                }
                .disabled(classroom.appVersions == nil)
                Spacer()
                Button("Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { if name.isEmpty { name = classroom.config.lastAppVersionQuery } }
    }

    var targets: [Machine] { model.selection.isEmpty ? model.machines : model.selectedMachines }

    func check() {
        classroom.queryAppVersions(model, name: name, targets.filter { model.status($0).reachability != .offline })
    }

    func rows(_ r: AppVersionsResult) -> [Row] {
        let common = mostCommonVersion(r)
        return targets.compactMap { m -> Row? in
            if r.pending.contains(m.id) { return Row(machine: m, version: "", build: "", path: "", state: .pending) }
            if let e = r.errors[m.id] { return Row(machine: m, version: e, build: "", path: "", state: .error) }
            guard let list = r.results[m.id] else { return nil }
            guard let first = list.first else { return Row(machine: m, version: "", build: "", path: "", state: .missing) }
            let state: Row.State = first.version == common ? .same : .different
            return Row(machine: m, version: first.version, build: first.build,
                       path: list.map(\.path).joined(separator: ", "), state: state)
        }
    }

    func visibleRows(_ r: AppVersionsResult) -> [Row] {
        let all = rows(r)
        return onlyDifferences ? all.filter { $0.state != .same } : all
    }

    func mostCommonVersion(_ r: AppVersionsResult) -> String? {
        let versions = r.results.values.compactMap { $0.first?.version }
        let counts = Dictionary(versions.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { a, b in a.value == b.value ? a.key.localizedStandardCompare(b.key) == .orderedAscending : a.value < b.value }?.key
    }

    func summary(_ r: AppVersionsResult) -> String {
        let all = rows(r)
        if !r.pending.isEmpty { return "Sprawdzanie… (\(r.pending.count) pozostało)" }
        let missing = all.filter { $0.state == .missing }.count
        let different = all.filter { $0.state == .different }.count
        var parts: [String] = []
        if let common = mostCommonVersion(r) { parts.append("Najczęstsza wersja: \(common)") }
        if different > 0 { parts.append("inna wersja: \(different)") }
        if missing > 0 { parts.append("brak aplikacji: \(missing)") }
        return parts.isEmpty ? "Brak wyników." : parts.joined(separator: " · ")
    }

    @ViewBuilder func versionText(_ r: Row) -> some View {
        switch r.state {
        case .pending: ProgressView().controlSize(.small)
        case .same: Text(r.version.isEmpty ? "?" : r.version)
        case .different: Label(r.version.isEmpty ? "?" : r.version, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .missing: Label("brak", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .error: Text(r.version).foregroundStyle(.secondary).lineLimit(1).help(r.version)
        }
    }

    func csvRows(_ r: AppVersionsResult) -> [[String]] {
        [["Komputer", "Aplikacja", "Wersja", "Kompilacja", "Położenie", "Uwagi"]] + rows(r).map { row in
            let note: String
            switch row.state {
            case .same: note = ""
            case .different: note = "inna wersja"
            case .missing: note = "brak aplikacji"
            case .error: note = row.version
            case .pending: note = "nie sprawdzono"
            }
            let version = row.state == .error ? "" : row.version
            return [row.machine.name, r.appName, version, row.build, row.path, note]
        }
    }
}
