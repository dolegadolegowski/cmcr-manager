import AppKit
import CMCRCore
import SwiftUI

/// Details of the single selected Mac, shown in the dashboard's inspector.
struct HostInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared

    var body: some View {
        if let m = model.inspectedMachine {
            details(m)
        } else {
            let n = max(model.highlightedMachines.count, model.selection.count)
            ContentUnavailableView(n == 0 ? "Nie wybrano komputera" : "Wybrane: \(Polish.computers(n))",
                                   systemImage: "info.circle",
                                   description: Text("Kliknij jeden komputer w tabeli, aby zobaczyć jego szczegóły i notatki."))
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
                            Text(st.reachability.displayName).foregroundStyle(.secondary)
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
                LabeledContent("Zalogowany", value: st.consoleUser ?? (st.reachability == .online ? "nikt" : "—"))
                LabeledContent("macOS", value: [st.osVersion, st.info["build"].map { "(\($0))" }].compactMap { $0 }.joined(separator: " ").ifEmpty("—"))
                LabeledContent("Model", value: st.model ?? "—")
                if let chip = st.info["chip"], !chip.isEmpty { LabeledContent("Procesor", value: chip) }
                if let mem = st.info["mem"], !mem.isEmpty { LabeledContent("Pamięć", value: "\(mem) GB") }
                LabeledContent("Włączony od", value: st.liveUptimeText ?? "—")
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
                        Text(String(format: "Wolne: %.0f z %.0f GB", free, total))
                    }
                    .tint(free < DashboardRow.lowDiskGB ? .orange : .accentColor)
                }
            }

            Section("Sieć") {
                CopyRow(title: "Adres IP", value: st.ip)
                CopyRow(title: "Adres MAC", value: classroom.wakeMACs(m, status: st).first)
                if let lhn = classroom.names[m.id]?.localHostName, !lhn.isEmpty {
                    CopyRow(title: "Nazwa w sieci", value: "\(lhn).local")
                }
            }

            Section("Bezpieczeństwo i zasilanie") {
                LabeledContent("Szyfrowanie dysku") {
                    switch st.fileVaultOn ?? classroom.fileVault[m.id] {
                    case .some(true): Label("włączone (FileVault)", systemImage: "lock.doc").foregroundStyle(.orange)
                    case .some(false): Text("wyłączone")
                    case .none: Text(classroom.fileVaultErrors[m.id] ?? "nie sprawdzono").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Harmonogram zasilania") {
                    Text(scheduleText(m)).multilineTextAlignment(.trailing)
                }
                if classroom.isLocked(m.id), let lock = classroom.locks[m.id] {
                    LabeledContent("Tryb uwagi", value: "\(lock.label) od \(lock.since.formatted(date: .omitted, time: .shortened))")
                }
                HStack {
                    Spacer()
                    Button {
                        classroom.checkFileVault(model, [m])
                        classroom.loadSchedules(model, [m])
                        classroom.loadNames(model, [m])
                    } label: {
                        Label("Sprawdź teraz", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Odczytaj szyfrowanie dysku (FileVault), harmonogram zasilania i nazwę w sieci")
                }
            }

            Section("Notatki") {
                TextField("Notatki", text: notes(m), prompt: Text("np. uszkodzona mysz, stanowisko przy oknie"), axis: .vertical)
                    .lineLimit(2...6)
                    .labelsHidden()
            }

            Section("Działania") {
                InspectorAction(title: "Podgląd ekranu", icon: "eye",
                                help: "Pokaż ekran tego komputera na żywo (bez sterowania)") {
                    model.selection = [m.id]
                    model.section = .screens
                }
                InspectorAction(title: "Steruj ekranem", icon: "rectangle.on.rectangle",
                                help: "Otwórz aplikację Udostępnianie ekranu i przejmij mysz i klawiaturę") { model.openScreenSharing(m) }
                InspectorAction(title: "Obudź komputer", icon: "sunrise",
                                help: "Wyślij sygnał budzenia (Wake-on-LAN) – działa, gdy komputer jest uśpiony") { model.wake([m]) }
                InspectorAction(title: "Odśwież stan", icon: "arrow.clockwise",
                                help: "Sprawdź jeszcze raz ten komputer") { model.refreshStatus([m]) }
                InspectorAction(title: "Sesja SSH w Terminalu", icon: "terminal",
                                help: "Sesja SSH w aplikacji Terminal (dla zaawansowanych)") { model.openTerminal(m) }
            }
        }
        .formStyle(.grouped)
    }

    func scheduleText(_ m: Machine) -> String {
        Self.scheduleText(checked: classroom.schedules[m.id], status: model.status(m))
    }

    /// The answer of „Sprawdź teraz” first. Until then the regular status already tells the repeating events
    /// (AUDIT KOM-10): pmset's lines joined with "; ", shown in the same Polish words as after the check. The status
    /// always reports the key, so an empty value means no schedule („brak”); only a status without it (none yet,
    /// or from an older version) is „nie sprawdzono” (AUDIT REV-21).
    static func scheduleText(checked info: ScheduleInfo?, status: HostStatus) -> String {
        if let info {
            if let e = info.error { return e }
            return info.events.isEmpty ? "brak" : info.events.map(\.text).joined(separator: "\n")
        }
        guard let raw = status.info["power_schedule"] else { return "nie sprawdzono" }
        if raw.isEmpty { return "brak" }
        let lines = raw.replacingOccurrences(of: "; ", with: "\n")
        let events = PowerScheduleParser.repeating("Repeating power events:\n" + lines)
        // A line pmset words differently than expected is shown as it is rather than dropped.
        return events.isEmpty ? lines : events.map(\.text).joined(separator: "\n")
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
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
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
            Label("Zmień nazwy komputerów", systemImage: "pencil")
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
                    if !ComputerNames.isValidLocalHostName(e.localHostName) {
                        Label("niepoprawna nazwa", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else if let owner = takenBy[e.localHostName.lowercased()] {
                        Label("\(e.localHostName).local ma już \(owner)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .help("Ten adres ma już inny komputer z listy – dwa komputery nie mogą mieć tego samego adresu w sieci")
                    } else if duplicates.contains(e.localHostName.lowercased()) {
                        Label("\(e.localHostName).local powtarza się", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .help("Dwa komputery nie mogą mieć tego samego adresu w sieci")
                    } else if let other = stillHeld[e.id] {
                        // The whole order, the same as cmcrctl gives (AUDIT REV-63).
                        Label("\(e.localHostName).local ma jeszcze \(other.name)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .help("Ten adres ma teraz \(other.name), którego nazwa też jest zmieniana – macOS nadałby jednemu z nich inny adres. "
                                  + RenamePlan.advice(for: e.machine, stillHeld: stillHeld, newNames: newNames, in: .app))
                    } else {
                        Text("\(e.localHostName).local").font(.body.monospaced())
                            .foregroundStyle(isUnchanged(e) ? .secondary : .primary)
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
                .disabled(changes.isEmpty || !duplicates.isEmpty || !stillHeld.isEmpty
                          || entries.contains { !ComputerNames.isValidLocalHostName($0.localHostName) })
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

    /// `.local` names (lowercased) given to more than one of the Macs, or already used by another Mac on the list;
    /// Bonjour would rename the extra ones (imac04-2) and the updated list would point at the other Mac. The same rule
    /// as `cmcrctl rename KOMP` (RenamePlan.repeatedNames, AUDIT REV-62).
    var duplicates: Set<String> {
        RenamePlan.repeatedNames(entries.map(\.localHostName))
            .union(Set(entries.map { $0.localHostName.lowercased() }).intersection(takenBy.keys))
    }

    /// `.local` names of the Macs that are not renamed here (from their addresses, their names on the list and the
    /// names read from them), with the Mac that has the name (AUDIT KOM-15, REV-58).
    var takenBy: [String: String] {
        Self.namesTaken(by: model.machines, renaming: Set(entries.map(\.id)),
                        readNames: classroom.names.mapValues(\.localHostName))
    }

    /// Renamed Macs whose new `.local` name another Mac renamed here still has now (its address or the name read from
    /// it), with that Mac: a renumbering or a swap, renamed one Mac at a time (AUDIT REV-52, REV-63). The renames run
    /// at once.
    var stillHeld: [UUID: Machine] {
        RenamePlan.namesStillHeld(changes.map { RenamePlan.Rename(machine: $0.machine, localHostName: $0.localHostName) },
                                  currentNames: classroom.names.mapValues(\.localHostName))
    }

    /// The name typed for each Mac, for the advice on the order.
    var newNames: [UUID: String] {
        Dictionary(entries.map { ($0.id, $0.newName.trimmingCharacters(in: .whitespaces)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The same rule as `cmcrctl rename KOMP` (AUDIT REV-58); the app also knows the names read from the iMacs.
    static func namesTaken(by machines: [Machine], renaming: Set<UUID>, readNames: [UUID: String]) -> [String: String] {
        RenamePlan.namesTaken(by: machines, renaming: renaming, readNames: readNames)
    }

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
        } else if let error = classroom.nameErrors[e.id] {
            Label("nie odczytano", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(error)
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
        if !r.pending.isEmpty { return "Sprawdzanie… (pozostało: \(r.pending.count))" }
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
