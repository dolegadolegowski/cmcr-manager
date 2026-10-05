import CMCRCore
import SwiftUI

/// One row of the overview table: a Mac with its (possibly last-known) status, flattened for sorting.
struct DashboardRow: Identifiable {
    let machine: Machine
    let status: HostStatus
    let lastSeen: Date?
    let locked: Bool

    var id: UUID { machine.id }
    var name: String { machine.name }
    var account: String { machine.destination }
    /// The logged-in user is shown only while the Mac answers; for offline Macs it would be stale.
    var user: String { [.online, .checking].contains(status.reachability) ? (status.consoleUser ?? "") : "" }
    var os: String { status.osVersion ?? "" }
    var model: String { status.model ?? "" }
    var ip: String { status.ip ?? "" }
    var mac: String { status.preferredMAC ?? machine.macAddress }
    var uptime: Double { status.liveUptime ?? -1 }
    var freeGB: Double { status.freeDiskGB ?? -1 }
    var seen: Date { lastSeen ?? .distantPast }
    var note: String { status.message.isEmpty ? machine.notes : status.message }

    /// Online first, then states that need attention, unknown last.
    var stateRank: Int {
        switch status.reachability {
        case .online: return 0
        case .checking: return 1
        case .authFailed: return 2
        case .error: return 3
        case .offline: return 4
        case .unknown: return 5
        }
    }

    static let lowDiskGB = 15.0
    var lowDisk: Bool { freeGB >= 0 && freeGB < Self.lowDiskGB }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @ViewState private var sortOrder = [KeyPathComparator(\DashboardRow.name, comparator: .localizedStandard)]
    @ViewState private var columns = TableColumnCustomization<DashboardRow>()
    @ViewState private var columnsLoaded = false
    @ViewState private var showRename = false
    @ViewState private var showVersions = false
    @SceneStorage("dashboard.inspector") private var showInspector = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TargetHeader(section: .dashboard,
                         subtitle: "Stan pracowni. Kliknij kafelek, aby zaznaczyć pasujące komputery; dwuklik w tabeli otwiera szczegóły.")
            tiles
            table
        }
        .padding(20)
        .inspector(isPresented: $showInspector) {
            HostInspector()
                .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                screenSharingButton
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Szczegóły", systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showInspector ? "Ukryj panel szczegółów (⌥⌘I)" : "Pokaż szczegóły i notatki zaznaczonego komputera (⌥⌘I)")
                moreMenu
            }
        }
        .sheet(isPresented: $showRename) { RenameComputersSheet() }
        .sheet(isPresented: $showVersions) { AppVersionsSheet() }
        .onAppear(perform: loadColumns)
        .onChange(of: columns) { _, new in saveColumns(new) }
    }

    // MARK: Toolbar

    /// Terminal and Screen Sharing open one window per Mac, so they act on at most this many selected Macs.
    static let windowLimit = 4

    var windowTargets: (machines: [Machine], note: String) {
        let selected = model.selectedMachines
        let note = selected.count > Self.windowLimit ? " Otworzy się okno dla pierwszych \(Self.windowLimit) z \(selected.count) zaznaczonych." : ""
        return (Array(selected.prefix(Self.windowLimit)), note)
    }

    var screenSharingButton: some View {
        let targets = windowTargets
        return Button {
            targets.machines.forEach(model.openScreenSharing)
        } label: {
            Label("Steruj ekranem", systemImage: "rectangle.on.rectangle")
        }
        .disabled(targets.machines.isEmpty)
        .help("Przejmij mysz i klawiaturę zaznaczonego komputera w aplikacji Udostępnianie ekranu.\(targets.note)")
    }

    var moreMenu: some View {
        let targets = windowTargets
        return Menu {
            Section("Zaznaczone komputery") {
                Button {
                    model.section = .screens
                } label: {
                    Label("Podgląd ekranów", systemImage: "eye")
                }
                Button {
                    targets.machines.forEach(model.openTerminal)
                } label: {
                    Label("Otwórz w Terminalu (dla zaawansowanych)", systemImage: "terminal")
                }
                .help("Sesja SSH w aplikacji Terminal.\(targets.note)")
                Button {
                    showRename = true
                } label: {
                    Label("Zmień nazwy komputerów…", systemImage: "pencil")
                }
            }
            .disabled(model.selection.isEmpty)
            Section("Raporty") {
                Button {
                    classroom.exportInventory(model)
                } label: {
                    Label("Zapisz raport o komputerach (CSV)…", systemImage: "tablecells")
                }
                Button {
                    showVersions = true
                } label: {
                    Label("Porównaj wersje aplikacji…", systemImage: "app.badge.checkmark")
                }
            }
        } label: {
            Label("Więcej", systemImage: "ellipsis.circle")
        }
        .help("Więcej działań: Terminal, zmiana nazw komputerów, raporty")
    }

    // MARK: Tiles

    var tiles: some View {
        let rows = self.rows
        let online = rows.filter { $0.status.reachability == .online }
        let offline = rows.filter { $0.status.reachability == .offline }
        let users = rows.filter { !$0.user.isEmpty && $0.status.reachability == .online }
        let problems = rows.filter { [.authFailed, .error].contains($0.status.reachability) }
        let lowDisk = rows.filter(\.lowDisk)
        let checking = rows.contains { $0.status.reachability == .checking }
        let refreshed = rows.compactMap(\.status.updatedAt).max()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
            StatTile(title: "Online", value: "\(online.count)/\(rows.count)", icon: "checkmark.circle.fill", color: .green,
                     help: "Zaznacz komputery online") { select(online) }
            StatTile(title: "Wyłączone lub uśpione", value: "\(offline.count)", icon: "moon.zzz.fill", color: .gray,
                     help: "Zaznacz komputery, które nie odpowiadają (np. aby je obudzić)") { select(offline) }
            StatTile(title: "Zalogowani uczniowie", value: "\(users.count)", icon: "person.2.fill", color: .blue,
                     help: "Zaznacz komputery z zalogowanym użytkownikiem") { select(users) }
            StatTile(title: "Wymaga uwagi", value: "\(problems.count)", icon: "exclamationmark.triangle.fill",
                     color: problems.isEmpty ? .secondary : .orange,
                     help: "Zaznacz komputery z błędem logowania lub połączenia") { select(problems) }
            StatTile(title: "Mało miejsca (<\(Int(DashboardRow.lowDiskGB)) GB)", value: "\(lowDisk.count)",
                     icon: "externaldrive.badge.exclamationmark", color: lowDisk.isEmpty ? .secondary : .orange,
                     help: "Zaznacz komputery, na których kończy się miejsce na dysku") { select(lowDisk) }
            StatTile(title: checking ? "Sprawdzanie…" : "Ostatnie odświeżenie",
                     value: refreshed.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—",
                     icon: "arrow.clockwise", color: .secondary, busy: checking,
                     help: "Odśwież stan wszystkich komputerów (⌘R)") { model.refreshStatus() }
        }
    }

    func select(_ rows: [DashboardRow]) {
        model.selection = Set(rows.map(\.id))
    }

    // MARK: Table

    var rows: [DashboardRow] {
        model.machines.map { m in
            DashboardRow(machine: m, status: model.status(m), lastSeen: classroom.lastSeen[m.id],
                         locked: classroom.isLocked(m.id))
        }
    }

    typealias Column = TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>>

    var table: some View {
        Table(rows.sorted(using: sortOrder), selection: $model.selection, sortOrder: $sortOrder,
              columnCustomization: $columns) {
            mainColumns
            detailColumns
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let m = model.machine(id) {
                Button("Pokaż szczegóły") {
                    model.selection = [id]
                    showInspector = true
                }
                Divider()
                MachineContextMenu(machine: m)
            }
        } primaryAction: { ids in
            if let id = ids.first {
                model.selection = [id]
                showInspector = true
            }
        }
    }

    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>>
    var mainColumns: some Column {
        TableColumn("Stan", value: \.stateRank) { row in
            HStack(spacing: 6) {
                StatusDot(reachability: row.status.reachability)
                Text(row.status.reachability.label)
                if row.locked {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Ekran zablokowany (tryb uwagi)")
                }
            }
        }
        .width(min: 90, ideal: 110)
        .customizationID("state")
        TableColumn("Nazwa", value: \.name) { row in
            Text(row.name).fontWeight(.medium)
        }
        .width(min: 70, ideal: 90)
        .customizationID("name")
        TableColumn("Zalogowany", value: \.user) { row in
            Text(row.user.isEmpty ? "—" : row.user)
        }
        .width(min: 70, ideal: 90)
        .customizationID("user")
        TableColumn("macOS", value: \.os) { row in
            Text(row.os.isEmpty ? "—" : row.os)
        }
        .width(min: 50, ideal: 60)
        .customizationID("os")
        TableColumn("Wolne miejsce", value: \.freeGB) { row in
            DiskCell(status: row.status)
        }
        .width(min: 90, ideal: 120)
        .customizationID("disk")
        TableColumn("Czas pracy", value: \.uptime) { row in
            Text(row.status.liveUptimeText ?? "—")
        }
        .width(min: 60, ideal: 80)
        .customizationID("uptime")
        TableColumn("Ostatnio widziany", value: \.seen) { row in
            LastSeenText(row: row)
        }
        .width(min: 90, ideal: 120)
        .customizationID("lastSeen")
    }

    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>>
    var detailColumns: some Column {
        TableColumn("IP", value: \.ip) { row in
            Text(row.ip.isEmpty ? "—" : row.ip).font(.body.monospacedDigit())
        }
        .width(min: 80, ideal: 105)
        .customizationID("ip")
        TableColumn("MAC", value: \.mac) { row in
            Text(row.mac.isEmpty ? "—" : row.mac).font(.body.monospaced())
        }
        .width(min: 120, ideal: 140)
        .customizationID("mac")
        .defaultVisibility(.hidden)
        TableColumn("Model", value: \.model) { row in
            Text(row.model.isEmpty ? "—" : row.model)
        }
        .width(min: 70, ideal: 90)
        .customizationID("model")
        .defaultVisibility(.hidden)
        TableColumn("Konto SSH", value: \.account) { row in
            Text(row.account)
        }
        .width(min: 120, ideal: 160)
        .customizationID("account")
        .defaultVisibility(.hidden)
        TableColumn("Uwagi", value: \.note) { row in
            Text(row.note)
                .foregroundStyle(row.status.message.isEmpty ? Color.secondary : Color.orange)
                .help(row.note)
        }
        .customizationID("notes")
    }

    // MARK: Column layout persistence

    func loadColumns() {
        guard !columnsLoaded else { return }
        columnsLoaded = true
        let state = classroom.config.dashboardTableState
        guard !state.isEmpty, let data = Data(base64Encoded: state),
              let saved = try? JSONDecoder().decode(TableColumnCustomization<DashboardRow>.self, from: data) else { return }
        columns = saved
    }

    func saveColumns(_ value: TableColumnCustomization<DashboardRow>) {
        guard columnsLoaded, let data = try? JSONEncoder().encode(value) else { return }
        let encoded = data.base64EncodedString()
        if classroom.config.dashboardTableState != encoded { classroom.config.dashboardTableState = encoded }
    }
}

/// Clickable summary tile: shows a number and selects the matching Macs.
struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var busy = false
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon).font(.title2).foregroundStyle(color)
                    }
                }
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.title2.weight(.semibold).monospacedDigit())
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct DiskCell: View {
    let status: HostStatus

    var body: some View {
        if let free = status.freeDiskGB, let total = status.totalDiskGB, total > 0 {
            HStack(spacing: 6) {
                Gauge(value: max(0, total - free), in: 0...total) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(free < DashboardRow.lowDiskGB ? .orange : .accentColor)
                    .frame(width: 44)
                Text(String(format: "%.0f GB", free))
                    .monospacedDigit()
                    .foregroundStyle(free < DashboardRow.lowDiskGB ? .orange : .primary)
            }
            .help(String(format: "Wolne %.0f z %.0f GB", free, total))
        } else {
            Text("—")
        }
    }
}

struct LastSeenText: View {
    let row: DashboardRow

    var body: some View {
        if row.status.reachability == .online {
            Text("teraz").foregroundStyle(.secondary)
        } else if let seen = row.lastSeen {
            Text(seen, format: .relative(presentation: .named))
                .help(seen.formatted(date: .abbreviated, time: .shortened))
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
