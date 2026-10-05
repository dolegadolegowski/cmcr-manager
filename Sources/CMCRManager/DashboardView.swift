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
    @AppStorage("dashboardInspector") private var showInspector = false

    var body: some View {
        VStack(spacing: 0) {
            if PasswordBanner.isNeeded(model) { PasswordBanner() }
            VStack(alignment: .leading, spacing: 14) {
                TargetHeader(section: .dashboard,
                             subtitle: "Kliknij kafelek, aby zaznaczyć pasujące komputery. Dwukrotne kliknięcie wiersza pokazuje szczegóły komputera.")
                tiles
                VStack(alignment: .leading, spacing: 6) {
                    table
                    statusLine
                }
            }
            .padding(20)
        }
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
        let all = Group {
            tile("Włączone", "\(online.count) z \(rows.count)", "checkmark", .green, online,
                 help: "Zaznacz komputery, które są włączone i odpowiadają")
            tile("Niedostępne", "\(offline.count)", "moon.zzz.fill", .gray, offline,
                 help: "Zaznacz komputery, które nie odpowiadają – są wyłączone lub uśpione (np. aby je obudzić)")
            tile("Zalogowani uczniowie", "\(users.count)", "person.2.fill", .blue, users,
                 help: "Zaznacz komputery, przy których ktoś jest zalogowany")
            tile("Wymaga uwagi", "\(problems.count)", "exclamationmark.triangle.fill",
                 problems.isEmpty ? .gray : .orange, problems,
                 help: "Zaznacz komputery z błędem logowania lub połączenia")
            tile("Mało miejsca na dysku", "\(lowDisk.count)", "externaldrive.fill",
                 lowDisk.isEmpty ? .gray : .orange, lowDisk,
                 help: "Zaznacz komputery, na których zostało mniej niż \(Int(DashboardRow.lowDiskGB)) GB wolnego miejsca")
        }
        // One row when there is room; with the inspector open in a small window, two or three rows.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { all }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) { all }
        }
    }

    func tile(_ title: String, _ value: String, _ icon: String, _ color: Color, _ rows: [DashboardRow],
              help: String) -> some View {
        let ids = Set(rows.map(\.id))
        return StatTile(title: title, value: value, icon: icon, color: color,
                        active: !ids.isEmpty && ids == model.selection, help: help) {
            model.selection = ids
        }
    }

    /// When the overview was last checked; it refreshes by itself every 2 minutes.
    var statusLine: some View {
        let checking = model.machines.contains { model.status($0).reachability == .checking }
        let refreshed = model.machines.compactMap { model.status($0).updatedAt }.max()
        let time = refreshed?.formatted(date: .omitted, time: .shortened) ?? ""
        return HStack(spacing: 6) {
            if checking {
                ProgressView().controlSize(.mini)
                Text("Sprawdzanie stanu komputerów…")
            } else if refreshed != nil {
                Image(systemName: "clock").accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    Text("Stan z godz. \(time) – odświeżany automatycznie co 2 minuty")
                    Text("Stan z godz. \(time)")
                }
            } else {
                Text("Stan nie był jeszcze sprawdzany")
            }
            Spacer(minLength: 8)
            Text("Komputery: \(model.machines.count)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Kliknij „Odśwież” na pasku narzędzi (⌘R), aby sprawdzić stan teraz")
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
        TableColumn("Komputer", value: \.name) { row in
            Text(row.name).fontWeight(.medium).lineLimit(1)
        }
        .width(min: 60, ideal: 75)
        .customizationID("name")
        TableColumn("Stan", value: \.stateRank) { row in
            HStack(spacing: 5) {
                StatusDot(reachability: row.status.reachability)
                Text(row.status.reachability.displayName).lineLimit(1)
                if row.locked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Ekran zablokowany (tryb uwagi)")
                        .accessibilityLabel("Ekran zablokowany")
                }
            }
        }
        .width(min: 95, ideal: 115)
        .customizationID("state")
        TableColumn("Zalogowany", value: \.user) { row in
            Text(row.user.isEmpty ? "—" : row.user).lineLimit(1)
        }
        .width(min: 70, ideal: 85)
        .customizationID("user")
        TableColumn("Wolne miejsce", value: \.freeGB) { row in
            DiskCell(status: row.status)
        }
        .width(min: 90, ideal: 100)
        .customizationID("disk")
        TableColumn("macOS", value: \.os) { row in
            Text(row.os.isEmpty ? "—" : row.os)
        }
        .width(min: 45, ideal: 55)
        .customizationID("os")
    }

    /// Hidden at first, so the default columns (with Uwagi) fit a 1180 pt window; the inspector shows all of these,
    /// and a right-click on the table header adds them to the table.
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>>
    var detailColumns: some Column {
        TableColumn("Ostatnio widziany", value: \.seen) { row in
            LastSeenText(row: row)
        }
        .width(min: 80, ideal: 105)
        .customizationID("lastSeen")
        .defaultVisibility(.hidden)
        TableColumn("Włączony od", value: \.uptime) { row in
            Text(row.status.liveUptimeText ?? "—").lineLimit(1)
        }
        .width(min: 60, ideal: 75)
        .customizationID("uptime")
        .defaultVisibility(.hidden)
        TableColumn("Adres IP", value: \.ip) { row in
            Text(row.ip.isEmpty ? "—" : row.ip).font(.body.monospacedDigit())
        }
        .width(min: 80, ideal: 105)
        .customizationID("ip")
        .defaultVisibility(.hidden)
        TableColumn("Adres MAC", value: \.mac) { row in
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
        TableColumn("Konto administratora", value: \.account) { row in
            Text(row.account)
        }
        .width(min: 120, ideal: 160)
        .customizationID("account")
        .defaultVisibility(.hidden)
        TableColumn("Uwagi", value: \.note) { row in
            Text(row.note)
                .lineLimit(1)
                .foregroundStyle(row.status.message.isEmpty ? Color.secondary : Color.orange)
                .help(row.note)
        }
        .width(min: 80)
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

/// Clickable summary tile (laid out like the smart lists in Reminders): a number that selects the matching Macs.
struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    /// The tile's Macs are exactly the checked ones.
    var active = false
    var help: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(color.gradient))
                    Spacer(minLength: 2)
                    Text(value)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minWidth: 100, idealWidth: 108, maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background.secondary)))
            .overlay(shape.strokeBorder(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                        lineWidth: active ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint(help)
        .accessibilityAddTraits(active ? .isSelected : [])
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
