import AppKit
import CMCRCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Allows running the bare executable (swift run) as a regular windowed app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Updater.shared.applicationDidLaunch()
        SnapshotRenderer.runIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Updater.shared.applicationWillTerminate()
    }

    /// Closing the window while jobs run keeps the app (and the jobs) going; a notification reports the end.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        (AppModel.shared?.runningJobCount ?? 0) == 0
    }
}

@main
struct CMCRManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        // The update helper runs a freshly downloaded build with this flag to check that it starts at all.
        if CommandLine.arguments.contains("--cmcr-self-test") {
            print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            exit(0)
        }
        Updater.confirmStart()       // before the model touches the Keychain (may wait in a dialog after an update)
        // Writing a password to an ssh that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("CMCR Manager", id: MainWindow.id) {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.screens)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            UpdateCommands()
            // Widok: refresh (like Reload in Safari) and Show/Hide Sidebar (⌃⌘S), which replaces the toolbar button.
            SidebarCommands()
            CommandGroup(before: .sidebar) {
                Button("Odśwież stan komputerów") { model.refreshStatus() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
            }
            // Edycja, next to "Zaznacz wszystko" (which keeps selecting text).
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Zaznacz wszystkie komputery") { model.selection = Set(model.machines.map(\.id)) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Zaznacz włączone komputery") { model.selectOnline() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Odznacz wszystkie komputery") { model.selection = [] }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Konfiguracja…") { model.section = .setup }
                    .keyboardShortcut(AppSection.setup.keyboardShortcut)
            }
            CommandMenu("Przejdź") {
                ForEach(AppSection.sidebar, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Button {
                                model.section = section
                            } label: {
                                Label(section.title, systemImage: section.icon)
                            }
                            .keyboardShortcut(section.keyboardShortcut)
                        }
                    }
                }
            }
            ScreenCommands(center: model.screens)
        }

        Window("Ściana ekranów", id: ScreenWallView.windowID) {
            ScreenWallView()
                .environmentObject(model)
                .environmentObject(model.screens)
        }
        .defaultSize(width: 1600, height: 1000)
        // Opened from ScreenCommands (with ⇧⌘E) instead of SwiftUI's own Window-menu item.
        .commandsRemoved()

        WindowGroup("Podgląd ekranu", id: ScreenWindowView.windowID, for: UUID.self) { $id in
            ScreenWindowView(machineID: id)
                .environmentObject(model)
                .environmentObject(model.screens)
        }
        .defaultSize(width: 1100, height: 720)
        .commandsRemoved()

        Settings {
            AppSettingsWindow()
                .environmentObject(model)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .safeAreaInset(edge: .bottom, spacing: 0) { UpdateBanner() }
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            MachineListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } detail: {
            DetailView()
        }
        .confirmation($model.retryConfirmation)
        .background(ToolbarTitlesShown())
        .updaterUI(model: model)
        .task {
            ClassroomModel.shared.attach(model)
            model.refreshStatus()
            // Keep the overview fresh in the background.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                model.refreshStatus(quietly: true)
            }
        }
        .modifier(ConfigIssuesAlert())
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.section) {
            ForEach(AppSection.sidebar, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sections) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        // With titles under every toolbar icon, the sidebar button's long title does not fit above the sidebar
        // and would end up in the overflow menu; Widok › Ukryj pasek boczny (⌃⌘S) does the same.
        .toolbar(removing: .sidebarToggle)
    }

    func row(_ s: AppSection) -> some View {
        Label(s.title, systemImage: s.icon)
            .badge(badge(for: s))
            .help(badgeHelp(for: s))
            .tag(s)
    }

    func badge(for s: AppSection) -> Int {
        switch s {
        case .jobs:
            return model.runningJobCount
        case .dashboard:
            return model.machines.filter {
                let r = model.status($0).reachability
                return r == .authFailed || r == .error
            }.count
        case .updates:
            return model.machines.filter { !(model.updates[$0.id]?.titles.isEmpty ?? true) }.count
        default:
            return 0
        }
    }

    /// What the section is for, its shortcut and, with a badge, what the number means.
    func badgeHelp(for s: AppSection) -> String {
        let n = badge(for: s)
        let base = "\(s.summary) (\(s.shortcutText))"
        guard n > 0 else { return base }
        switch s {
        case .jobs: return "\(base)\nW toku: \(Polish.jobs(n))"
        case .dashboard: return "\(base)\nWymaga uwagi (błąd logowania lub połączenia): \(Polish.computers(n))"
        case .updates: return "\(base)\nDostępne aktualizacje \(Polish.onComputers(n))"
        default: return base
        }
    }
}

extension AppSection {
    /// Sidebar groups in display order; the Przejdź menu numbers the sections (⌘1…⌘0) in the same order.
    static let sidebar: [(title: String, sections: [AppSection])] = [
        ("Pracownia", [.dashboard, .classroom, .screens, .power]),
        ("Pliki i programy", [.files, .browser, .apps, .install, .updates]),
        ("Administracja", [.jobs, .commands, .setup]),
    ]

    static var sidebarOrder: [AppSection] { sidebar.flatMap(\.sections) }

    /// What the section is for, in one sentence (sidebar tooltip).
    var summary: String {
        switch self {
        case .dashboard: return "Stan wszystkich komputerów w pracowni"
        case .classroom: return "Rozpoczęcie i zakończenie lekcji, blokada ekranów, pytania do uczniów"
        case .screens: return "Podgląd ekranów uczniów na żywo"
        case .power: return "Wiadomości, wylogowanie, uśpienie, ponowne uruchomienie i wyłączanie"
        case .files: return "Wysyłanie materiałów i zbieranie prac uczniów"
        case .browser: return "Przeglądanie plików na jednym komputerze, jak w Finderze"
        case .apps: return "Uruchamianie i zamykanie aplikacji na komputerach"
        case .install: return "Instalowanie programów na komputerach"
        case .updates: return "Aktualizacje systemu macOS i programów"
        case .jobs: return "Wyniki i historia wszystkich działań"
        case .commands: return "Polecenia Terminala dla zaawansowanych"
        case .setup: return "Lista komputerów, hasła, ustawienia i przygotowanie iMaców"
        }
    }

    /// Every section has a shortcut, numbered in sidebar order: ⌘1…⌘9 and ⌘0 for the first ten, then ⇧⌘P for
    /// Polecenia (like a command palette) and ⌘, for Konfiguracja (like Settings in every Mac app; also in the
    /// application menu).
    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .setup: return KeyboardShortcut(",", modifiers: .command)
        case .commands: return KeyboardShortcut("p", modifiers: [.command, .shift])
        default:
            let numbered = Self.sidebarOrder.filter { $0 != .setup && $0 != .commands }
            let index = numbered.firstIndex(of: self) ?? 0
            assert(numbered.count <= 10, "Only ten sections can have ⌘ + digit")
            return KeyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command)
        }
    }

    /// The shortcut as shown in menus, e.g. "⌘2", "⇧⌘P".
    var shortcutText: String {
        let s = keyboardShortcut
        return (s.modifiers.contains(.shift) ? "⇧" : "") + "⌘" + String(s.key.character).uppercased()
    }
}

/// The target set: Macs checked here are what every action runs on. The list's own (highlight) selection is
/// transient and only picks rows for the context menu, so clicking a row never replaces the checked targets.
struct MachineListView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var highlighted: Set<UUID> = []
    @ViewState private var query = HostQuery()
    @ViewState private var naming: GroupNaming?
    @AppStorage("hostListSortByStatus") private var sortByStatus = false
    @AppStorage("hostListDetailed") private var detailed = false

    struct GroupNaming: Identifiable {
        let id = UUID()
        var ids: Set<UUID> = []
        var renaming: String?
    }

    var visible: [Machine] {
        let list = query.apply(to: model.machines, status: model.status)
        guard sortByStatus else { return list }
        return list.enumerated().sorted { a, b in
            let ra = rank(model.status(a.element).reachability), rb = rank(model.status(b.element).reachability)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    func rank(_ r: Reachability) -> Int {
        switch r {
        case .error, .authFailed: return 0
        case .online: return 1
        case .checking: return 2
        case .unknown: return 3
        case .offline: return 4
        }
    }

    var body: some View {
        let visible = self.visible
        List(selection: $highlighted) {
            ForEach(visible) { m in
                MachineRow(machine: m, status: model.status(m), detailed: detailed, isTarget: isTarget(m.id))
                    .tag(m.id)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            MachineContextMenu(ids: ids) { naming = GroupNaming(ids: ids) }
        } primaryAction: { ids in
            toggleTargets(ids)
        }
        .onKeyPress(.space) {
            guard !highlighted.isEmpty else { return .ignored }
            toggleTargets(highlighted)
            return .handled
        }
        .overlay {
            if visible.isEmpty {
                if model.machines.isEmpty {
                    ContentUnavailableView {
                        Label("Brak komputerów", systemImage: "desktopcomputer")
                    } description: {
                        Text("Dodaj iMaki w Konfiguracji › Komputery.")
                    } actions: {
                        Button("Otwórz konfigurację") { model.section = .setup }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Nic nie pasuje", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Żaden komputer nie spełnia warunków wyszukiwania lub filtra.")
                    } actions: {
                        Button("Wyczyść filtr") { query = HostQuery() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header(visible) }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(visible) }
        .sheet(item: $naming) { n in
            GroupNameSheet(title: n.renaming == nil ? "Nowa grupa (\(Polish.computers(n.ids.count)))" : "Zmień nazwę grupy",
                           initial: n.renaming ?? "") { name in
                if let old = n.renaming {
                    HostGroups.rename(old, to: name, in: &model.machines)
                    if query.group == old { query.group = name }
                } else {
                    HostGroups.add(name, to: n.ids, in: &model.machines)
                }
            }
        }
    }

    func isTarget(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.selection.contains(id) },
                set: { on in if on { model.selection.insert(id) } else { model.selection.remove(id) } })
    }

    /// Double-click, Return or Space on highlighted rows: check them, or uncheck them when all are checked.
    func toggleTargets(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: model.selection) {
            model.selection.subtract(ids)
        } else {
            model.selection.formUnion(ids)
        }
    }

    // MARK: Header: search, filter, groups, select visible

    func header(_ visible: [Machine]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                NativeSearchField(prompt: "Szukaj komputera lub ucznia", text: $query.text)
                    .help("Szukaj po nazwie komputera, adresie, grupie lub nazwie zalogowanego użytkownika")
                filterMenu
            }
            if !model.groups.isEmpty { groupChips }
            HStack(spacing: 6) {
                Toggle(sources: visible.map { isTarget($0.id) }, isOn: \.self) {
                    Text(query.isActive ? "Zaznacz widoczne" : "Zaznacz wszystkie")
                }
                .toggleStyle(.checkbox)
                .disabled(visible.isEmpty)
                .help("Zaznacza lub odznacza wszystkie komputery widoczne na liście")
                Spacer()
                if query.isActive {
                    Text("\(visible.count) z \(model.machines.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Wyczyść filtr") { query = HostQuery() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    var filterMenu: some View {
        let filtered = query.status != .all || query.group != nil
        return Menu {
            Picker("Pokaż", selection: $query.status) {
                ForEach(HostStatusFilter.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            if !model.groups.isEmpty {
                Picker("Grupa", selection: $query.group) {
                    Text("Wszystkie grupy").tag(String?.none)
                    ForEach(model.groups, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            }
            Picker("Kolejność", selection: $sortByStatus) {
                Text("Według nazwy").tag(false)
                Text("Według stanu (problemy na górze)").tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Pokaż szczegóły w wierszach", isOn: $detailed)
        } label: {
            Label("Filtr", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help(filtered ? "Filtr włączony: \(query.status.displayName)\(query.group.map { ", grupa \($0)" } ?? "")"
                       : "Filtruj i sortuj listę komputerów")
    }

    /// Filters the list by group (it does not check anything; the context menu of a group can).
    var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Pokaż:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                chip("Wszystkie", selected: query.group == nil) { query.group = nil }
                ForEach(model.groups, id: \.self) { g in
                    chip(g, selected: query.group.map { $0.caseInsensitiveCompare(g) == .orderedSame } ?? false) {
                        query.group = query.group == g ? nil : g
                    }
                    .contextMenu {
                        Button("Zaznacz komputery z grupy") { model.selectGroup(g) }
                        Button("Dodaj grupę do zaznaczenia") { model.selectGroup(g, adding: true) }
                        Divider()
                        Button("Zmień nazwę…") { naming = GroupNaming(renaming: g) }
                        Button("Usuń grupę", role: .destructive) {
                            HostGroups.remove(g, from: Set(model.machines.map(\.id)), in: &model.machines)
                            if query.group == g { query.group = nil }
                        }
                    }
                }
            }
        }
    }

    func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Wszystkie" ? "Pokaż wszystkie grupy" : "Pokaż grupę \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title == "Wszystkie" ? "Pokaż na liście komputery ze wszystkich grup"
                                   : "Pokaż na liście tylko grupę „\(title)”. Prawy przycisk: zaznacz jej komputery.")
    }

    // MARK: Footer: counts and selection menu

    func footer(_ visible: [Machine]) -> some View {
        let online = model.machines.filter { model.status($0).reachability == .online }.count
        let visibleIDs = Set(visible.map(\.id))
        let hidden = model.selection.subtracting(visibleIDs).count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Zaznaczone: \(model.selection.count) z \(model.machines.count) · włączone: \(online)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer()
                Menu("Zaznacz") { SelectionMenuItems() }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Szybkie zaznaczanie: wszystkie, włączone, grupa, odwrócenie")
            }
            if hidden > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash").accessibilityHidden(true)
                    Text("Zaznaczone, ale ukryte przez filtr: \(hidden)")
                    Spacer()
                    Button("Pokaż") { query = HostQuery() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension HostStatusFilter {
    /// The filter's name in the window ("Włączone", like everywhere else; the CLI keeps "online").
    var displayName: String { self == .online ? "Włączone" : label }
}

/// "Zaznacz" menu items (footer menu and empty-area context menu).
struct SelectionMenuItems: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button("Wszystkie") { model.selection = Set(model.machines.map(\.id)) }
        Button("Włączone") { model.selectOnline() }
        Button("Odwróć zaznaczenie") { model.invertSelection() }
        if !model.groups.isEmpty {
            Menu("Grupa") {
                ForEach(model.groups, id: \.self) { g in
                    Button(g) { model.selectGroup(g) }
                }
            }
        }
        Divider()
        Button("Żadne") { model.selection = [] }
    }
}

struct MachineRow: View {
    @EnvironmentObject var model: AppModel
    let machine: Machine
    let status: HostStatus
    var detailed = false
    @Binding var isTarget: Bool
    @ViewState private var dropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Zaznacz \(machine.name)", isOn: $isTarget)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(isTarget ? "Zaznaczony – działania obejmą ten komputer" : "Zaznacz, aby działania objęły ten komputer")
            HStack(spacing: 8) {
                StatusDot(reachability: status.reachability)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(machine.name).fontWeight(.medium).lineLimit(1)
                        if !machine.groups.isEmpty {
                            Text(machine.groups.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if detailed {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let user = status.consoleUser {
                    Label(user, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .help("Zalogowany użytkownik: \(user)")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.accentColor, lineWidth: dropTargeted ? 2 : 0))
        .help(status.message.isEmpty ? machine.destination : "\(machine.destination)\n\(status.message)")
        .dropDestination(for: URL.self) { urls, _ in
            model.dropFiles(urls, on: machine)
        } isTargeted: { dropTargeted = $0 }
    }

    var subtitle: String {
        switch status.reachability {
        case .online:
            return [status.osVersion.map { "macOS \($0)" }, status.ip].compactMap { $0 }.joined(separator: " · ")
        case .unknown, .checking:
            return machine.address
        default:
            return status.message.isEmpty ? status.reachability.displayName : status.message
        }
    }

    var accessibilityText: String {
        var parts = [machine.name, status.reachability.displayName]
        parts.append(status.consoleUser.map { "zalogowany \($0)" } ?? "nikt nie jest zalogowany")
        if !machine.groups.isEmpty { parts.append("grupy: \(machine.groups.joined(separator: ", "))") }
        if !status.message.isEmpty, status.reachability != .online { parts.append(status.message) }
        return parts.joined(separator: ", ")
    }
}

/// Context menu of the host list: acts on every highlighted row (or on the clicked row outside them).
struct MachineContextMenu: View {
    @EnvironmentObject var model: AppModel
    let ids: Set<UUID>
    /// Shows "Nowa grupa…" in the Grupy submenu when set.
    var newGroup: (() -> Void)?

    init(ids: Set<UUID>, newGroup: (() -> Void)? = nil) {
        self.ids = ids
        self.newGroup = newGroup
    }

    init(machine: Machine) { self.init(ids: [machine.id]) }

    var body: some View {
        let targets = model.machines.filter { ids.contains($0.id) }
        if targets.isEmpty {
            SelectionMenuItems()
        } else {
            Text(targets.count == 1 ? targets[0].name : Polish.computers(targets.count))
            Button {
                model.refreshStatus(targets)
            } label: {
                Label("Odśwież stan", systemImage: "arrow.clockwise")
            }
            if ids.isSubset(of: model.selection) {
                Button {
                    model.selection.subtract(ids)
                } label: {
                    Label("Odznacz", systemImage: "square")
                }
            } else {
                Button {
                    model.selection.formUnion(ids)
                } label: {
                    Label("Zaznacz", systemImage: "checkmark.square")
                }
            }
            if ids != model.selection {
                Button {
                    model.selection = ids
                } label: {
                    Label(targets.count == 1 ? "Zaznacz tylko ten" : "Zaznacz tylko te", systemImage: "checklist")
                }
            }
            Divider()
            Button {
                if model.selection != ids { model.selection = ids }
                model.section = .screens
            } label: {
                Label("Podgląd ekranu", systemImage: "eye")
            }
            if targets.count == 1 {
                OpenScreenWindowMenuItem(machine: targets[0])
            }
            Button {
                targets.prefix(4).forEach(model.openScreenSharing)
            } label: {
                Label(targets.count > 4 ? "Steruj ekranem (pierwsze 4)" : "Steruj ekranem (Udostępnianie ekranu)",
                      systemImage: "rectangle.on.rectangle")
            }
            Button {
                targets.prefix(4).forEach(model.openTerminal)
            } label: {
                Label(targets.count > 4 ? "Otwórz w Terminalu (pierwsze 4)" : "Otwórz w Terminalu (SSH)",
                      systemImage: "terminal")
            }
            Divider()
            Button {
                model.wake(targets)
            } label: {
                Label(targets.count == 1 ? "Obudź komputer" : "Obudź komputery", systemImage: "sunrise")
            }
            Menu {
                GroupMembershipMenu(ids: ids, newGroup: newGroup)
            } label: {
                Label("Grupy", systemImage: "tag")
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targets.map(\.destination).joined(separator: "\n"), forType: .string)
            } label: {
                Label(targets.count == 1 ? "Kopiuj adres" : "Kopiuj adresy", systemImage: "doc.on.doc")
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // A plain stack (not a safe-area inset): sections with a table ignore top insets, and the banner would cover
        // their header. Sections with an inspector show the banner in their main column themselves.
        VStack(spacing: 0) {
            if PasswordBanner.isNeeded(model), !PasswordBanner.notAbove.contains(model.section ?? .dashboard) {
                PasswordBanner()
            }
            section
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.section?.title ?? "CMCR Manager")
        .overlay(alignment: .bottom) { ActionToastOverlay() }
        // Declared after the section's own items, so the window-wide ones stay at the trailing end.
        .overlay { Color.clear.allowsHitTesting(false).toolbar { MainToolbar() } }
    }

    @ViewBuilder var section: some View {
        Group {
            switch model.section ?? .dashboard {
            case .dashboard: DashboardView()
            case .commands: CommandsView()
            case .files: FilesView()
            case .browser: RemoteBrowserView()
            case .apps: AppsView()
            case .install: InstallView()
            case .updates: UpdatesView()
            case .screens: ScreensView()
            case .power: PowerView()
            case .jobs: JobsView()
            case .setup: SetupView()
            case .classroom: ClassroomView()
            }
        }
    }
}

/// Scrollable page container used by the action sections.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
