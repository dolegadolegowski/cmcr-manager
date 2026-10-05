import AppKit
import CMCRCore
import SwiftUI

/// Windows of the screen preview, so the app can tell them apart from the main window.
@MainActor
enum ScreenWindowRegistry {
    private static var windows: [ObjectIdentifier] = []

    static func add(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if !windows.contains(id) { windows.append(id) }
    }

    static func contains(_ window: NSWindow) -> Bool { windows.contains(ObjectIdentifier(window)) }
}

/// Which Macs the screen wall shows (independent of the selection in the main window).
enum ScreenWallSource: String, CaseIterable, Identifiable {
    case all, selected, online, withUser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Wszystkie komputery"
        case .selected: return "Zaznaczone w oknie głównym"
        case .online: return "Tylko włączone"
        case .withUser: return "Z zalogowanym użytkownikiem"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "desktopcomputer"
        case .selected: return "checklist"
        case .online: return "power"
        case .withUser: return "person.crop.rectangle"
        }
    }
}

/// Refresh interval picker shared by the section and the wall.
struct ScreenRefreshMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var center: ScreenCenter
    @Binding var interval: Int
    var backgroundToggle: Binding<Bool>?

    static let choices = [3, 5, 10, 30, 60]

    var body: some View {
        Menu {
            Picker("Odświeżanie", selection: $interval) {
                Text("Jak w Konfiguracji (co \(model.settings.screenshotInterval) s)").tag(0)
                Divider()
                ForEach(Self.choices, id: \.self) { s in Text("Co \(s) s").tag(s) }
            }
            .pickerStyle(.inline)
            Divider()
            if let backgroundToggle {
                Toggle("Odświeżaj także, gdy aplikacja jest w tle", isOn: backgroundToggle)
            }
            Toggle("Wstrzymaj cały podgląd", isOn: $center.paused)
        } label: {
            Label(center.paused ? "Wstrzymano" : "Co \(interval == 0 ? model.settings.screenshotInterval : interval) s",
                  systemImage: center.paused ? "pause.circle" : "timer")
        }
        .fixedSize()
        .help("Jak często odświeżać obrazy; wstrzymanie zatrzymuje wszystkie połączenia podglądu")
    }
}

// MARK: - Screen wall window

/// Resizable window with all observed screens – suited to full screen on a second display.
struct ScreenWallView: View {
    static let windowID = "screen-wall"

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var center: ScreenCenter
    @Environment(\.openWindow) private var openWindow
    @AppStorage("screenWall.source") private var source: ScreenWallSource = .all
    @AppStorage("screenWall.layout") private var layout: ScreenGridLayout = .fit
    @AppStorage("screenWall.tileWidth") private var tileWidth: Double = 360
    @AppStorage("screenWall.interval") private var interval = 0
    @AppStorage("screenWall.labels") private var showLabels = true
    @AppStorage("screenWall.background") private var refreshInBackground = true
    @ViewState private var search = ""
    @ViewState private var selection: Set<UUID> = []
    @ViewState private var composing = false
    @ViewState private var window: NSWindow?

    private var machines: [Machine] {
        let base: [Machine]
        switch source {
        case .all: base = model.machines
        case .selected: base = model.selectedMachines
        case .online: base = model.machines.filter { model.status($0).reachability == .online }
        case .withUser:
            base = model.machines.filter { m in
                model.status(m).consoleUser != nil || center.feed(for: m.id).user != nil
            }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { m in
            let feed = center.feed(for: m.id)
            return [m.name, m.address, feed.user ?? model.status(m).consoleUser ?? "", feed.frontApp ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var selectedMachines: [Machine] { machines.filter { selection.contains($0.id) } }

    var body: some View {
        let list = machines
        Group {
            if list.isEmpty {
                emptyState
            } else {
                ScreenGrid(machines: list, layout: layout, tileWidth: tileWidth, interval: interval,
                           showLabels: showLabels, selection: $selection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { ScreenBatchBanner().padding(16) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ScreenRestrictionsBar()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
        .toolbar { toolbar }
        .searchable(text: $search, placement: .toolbar, prompt: "Komputer, użytkownik, aplikacja")
        .navigationTitle("Ściana ekranów")
        .navigationSubtitle("\(list.count) \(polishPlural(list.count, "komputer", "komputery", "komputerów")) · \(source.label.lowercased())")
        .screenScope(pausesWhenInactive: !refreshInBackground) { w in
            ScreenWindowRegistry.add(w)
            if window !== w { window = w }
        }
        .sheet(isPresented: $composing) { MessageComposer(targets: selectedMachines) }
        .onChange(of: list.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .frame(minWidth: 640, minHeight: 420)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker(selection: $source) {
                ForEach(ScreenWallSource.allCases) { s in Label(s.label, systemImage: s.symbol).tag(s) }
            } label: {
                Label("Komputery", systemImage: source.symbol)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Które komputery pokazać na ścianie")
        }
        if !selection.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { composing = true } label: {
                    Label("Wiadomość (\(selection.count))", systemImage: "text.bubble")
                }
                .help("Wyślij wiadomość na zaznaczone ekrany (zaznaczaj z ⌘)")
                Button {
                    ScreenActions(model: model, center: center, openWindow: openWindow).sleepDisplay(selectedMachines)
                } label: {
                    Label("Uśpij ekrany (\(selection.count))", systemImage: "moon.zzz")
                }
                .help("Wygasza monitory zaznaczonych komputerów")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(selection: $layout) {
                ForEach(ScreenGridLayout.allCases) { l in Label(l.label, systemImage: l.symbol).tag(l) }
            } label: {
                Label("Układ", systemImage: layout.symbol)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Układ ekranów: dopasowany do okna, według rozmiaru kafelka albo stała liczba kolumn")
            if layout == .adaptive {
                Slider(value: $tileWidth, in: 220...900) {
                    Text("Rozmiar kafelków")
                } minimumValueLabel: {
                    Image(systemName: "square.grid.3x3")
                } maximumValueLabel: {
                    Image(systemName: "square")
                }
                .frame(width: 170)
                .help("Rozmiar kafelków")
            }
            ScreenRefreshMenu(interval: $interval, backgroundToggle: $refreshInBackground)
            Toggle(isOn: $showLabels) { Label("Podpisy", systemImage: "text.below.photo") }
                .toggleStyle(.button)
                .help("Pokaż nazwę komputera, użytkownika i aplikację na kafelkach")
            Button {
                center.refresh(machines.map(\.id))
            } label: {
                Label("Odśwież teraz", systemImage: "arrow.clockwise")
            }
            .help("Pobierz nowe obrazy ze wszystkich widocznych komputerów")
            Button {
                (window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
            } label: {
                Label("Pełny ekran", systemImage: "arrow.up.left.and.arrow.down.right.rectangle")
            }
            .help("Pełny ekran – np. na drugim monitorze lub projektorze (⌃⌘F)")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView {
                Label(source == .selected ? "Nie zaznaczono komputerów" : "Brak komputerów do pokazania",
                      systemImage: "rectangle.split.3x3")
            } description: {
                Text(source == .selected
                     ? "Zaznacz komputery na liście w oknie głównym albo pokaż wszystkie."
                     : "Żaden komputer nie spełnia wybranego warunku (\(source.label.lowercased())). Odśwież stan komputerów albo pokaż wszystkie.")
            } actions: {
                Button("Pokaż wszystkie komputery") { source = .all }
                    .buttonStyle(.borderedProminent)
                Button("Odśwież stan komputerów") { model.refreshStatus() }
            }
        }
    }
}

// MARK: - Window of one Mac

/// One Mac in its own resizable window, refreshed faster; several can be open side by side.
struct ScreenWindowView: View {
    static let windowID = "screen-window"

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var center: ScreenCenter
    let machineID: UUID?

    var body: some View {
        if let id = machineID, let m = model.machine(id) {
            ScreenWindowContent(machine: m, feed: center.feed(for: m.id))
        } else {
            ContentUnavailableView("Nie ma takiego komputera", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                   description: Text("Ten komputer usunięto z listy w Konfiguracji."))
                .frame(minWidth: 420, minHeight: 300)
        }
    }
}

private struct ScreenWindowContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var center: ScreenCenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayScale) private var displayScale
    let machine: Machine
    @ObservedObject var feed: ScreenFeed
    @ViewState private var alwaysOnTop = false
    @ViewState private var window: NSWindow?
    @ViewState private var composing = false
    @ViewState private var width: Double = 1000

    private var actions: ScreenActions { ScreenActions(model: model, center: center, openWindow: openWindow) }

    var body: some View {
        ScreenPicture(feed: feed, large: true)
            .overlay(alignment: .topTrailing) { FreshnessBadge(feed: feed).padding(10) }
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            })
            .observeScreen(machine.id, request: ScreenRequest(
                pixels: ScreenLayout.captureSize(points: width, scale: displayScale,
                                                 cap: max(1600, model.settings.screenshotMaxSize)),
                interval: max(2, model.settings.screenshotInterval / 2)))
            .overlay(alignment: .bottom) { ScreenBatchBanner().padding(16) }
            .toolbar { toolbar }
            .navigationTitle(machine.name)
            .navigationSubtitle(subtitle)
            .screenScope(pausesWhenInactive: false) { w in
                ScreenWindowRegistry.add(w)
                if window !== w {
                    window = w
                    w.level = alwaysOnTop ? .floating : .normal
                }
            }
            .onChange(of: alwaysOnTop) { _, onTop in window?.level = onTop ? .floating : .normal }
            .frame(minWidth: 480, minHeight: 320)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Ekran \(machine.name)")
    }

    private var subtitle: String {
        if let issue = feed.issue { return issue.title }
        return [feed.user.map { "użytkownik \($0)" }, feed.frontApp].compactMap { $0 }.joined(separator: " · ")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Ekran", selection: Binding(get: { center.display(for: machine.id) },
                                                   set: { center.setDisplay($0, for: machine.id) })) {
                    Text(ScreenDisplay.main.label).tag(ScreenDisplay.main)
                    Text(ScreenDisplay.all.label).tag(ScreenDisplay.all)
                    if feed.displayCount > 1 {
                        Divider()
                        ForEach(1...feed.displayCount, id: \.self) { n in
                            Text(ScreenDisplay.number(n).label).tag(ScreenDisplay.number(n))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(center.display(for: machine.id).label, systemImage: "display.2")
            }
            .fixedSize()
            .help("Który monitor tego komputera pokazywać")
            Toggle(isOn: $alwaysOnTop) { Label("Zawsze na wierzchu", systemImage: "pin") }
                .toggleStyle(.button)
                .help("Utrzymuj to okno nad innymi oknami")
            Button { composing = true } label: { Label("Wiadomość", systemImage: "text.bubble") }
                .help("Wyślij wiadomość na ten ekran")
                .popover(isPresented: $composing, arrowEdge: .bottom) { MessageComposer(targets: [machine]) }
            Button { actions.sleepDisplay([machine]) } label: { Label("Uśpij ekran", systemImage: "moon.zzz") }
                .help("Wygasza monitor tego komputera (uczeń wybudzi go myszą lub klawiaturą)")
            Button { actions.screenSharing(machine) } label: {
                Label("Udostępnianie ekranu", systemImage: "rectangle.on.rectangle")
            }
            .help("Otwórz Udostępnianie ekranu (VNC) – pełny podgląd i sterowanie, jeśli są włączone na tym Macu")
            Menu {
                ScreenMoreMenuItems(machine: machine, feed: feed, actions: actions)
            } label: {
                Label("Więcej", systemImage: "ellipsis.circle")
            }
            .help("Więcej działań")
        }
    }
}

// MARK: - Entry points

/// Opens the screen wall window.
struct OpenScreenWallButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: ScreenWallView.windowID)
        } label: {
            Label("Ściana ekranów", systemImage: "rectangle.split.3x3")
        }
        .help("Otwórz ścianę ekranów w osobnym oknie (⇧⌘E)")
    }
}

/// "Okno" menu items of the screen preview.
struct ScreenCommands: Commands {
    @ObservedObject var center: ScreenCenter

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            OpenScreenWallButton()
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Toggle("Wstrzymaj podgląd ekranów", isOn: $center.paused)
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
        }
    }
}

/// Context-menu item for a Mac in the host list.
struct OpenScreenWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    let machine: Machine

    var body: some View {
        Button("Podgląd ekranu w nowym oknie") {
            openWindow(id: ScreenWindowView.windowID, value: machine.id)
        }
    }
}
