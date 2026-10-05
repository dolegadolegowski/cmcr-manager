import AppKit
import CMCRCore
import SwiftUI

// Building blocks of the screen preview shared by the "Podgląd ekranów" section, the screen wall window and
// the per-Mac windows.

// MARK: - Observation plumbing

private struct ScreenScopeKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// Window (or section) the screen tiles belong to; its visibility pauses them together.
    var screenScope: UUID? {
        get { self[ScreenScopeKey.self] }
        set { self[ScreenScopeKey.self] = newValue }
    }
}

extension View {
    /// Groups the screen tiles below: they pause while the window is hidden or minimized (and, with
    /// `pausesWhenInactive`, while the app is in the background).
    func screenScope(pausesWhenInactive: Bool, window: ((NSWindow) -> Void)? = nil) -> some View {
        modifier(ScreenScopeModifier(pausesWhenInactive: pausesWhenInactive, onWindow: window))
    }

    /// Keeps a live capture of `host` running while this view is on screen.
    func observeScreen(_ host: UUID, request: ScreenRequest) -> some View {
        modifier(ScreenObservation(host: host, request: request))
    }
}

private struct ScreenScopeModifier: ViewModifier {
    @EnvironmentObject var center: ScreenCenter
    let pausesWhenInactive: Bool
    let onWindow: ((NSWindow) -> Void)?
    @ViewState private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.screenScope, id)
            .background(WindowReader { window, visible in
                center.setScope(id, visible: visible)
                if let window { onWindow?(window) }
            })
            .onAppear { center.registerScope(id, pausesWhenInactive: pauses) }
            .onDisappear { center.removeScope(id) }
            .onChange(of: pauses) { _, value in center.registerScope(id, pausesWhenInactive: value) }
    }

    /// Off-screen snapshot windows never become active; their tiles keep running.
    private var pauses: Bool { pausesWhenInactive && !SnapshotRenderer.isActive }
}

private struct ScreenObservation: ViewModifier {
    @EnvironmentObject var center: ScreenCenter
    @Environment(\.screenScope) private var scope
    let host: UUID
    let request: ScreenRequest
    @ViewState private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if token == nil { token = center.register(host: host, request: request, scope: scope) }
            }
            .onDisappear {
                if let token { center.unregister(token) }
                token = nil
            }
            .onChange(of: request) { _, value in
                if let token { center.update(token, request: value) }
            }
            .onChange(of: host) { _, value in
                if let token { center.unregister(token) }
                token = center.register(host: value, request: request, scope: scope)
            }
    }
}

/// Reports the hosting NSWindow and whether it is actually visible (not occluded, minimized or closing).
struct WindowReader: NSViewRepresentable {
    var onChange: (NSWindow?, Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?, Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let window else {
                onChange?(nil, false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            ]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.report(closing: false) }
        }

        private func report(closing: Bool) {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
            onChange?(window, !closing && (visible || SnapshotRenderer.isActive))
        }
    }
}

// MARK: - Wording

func polishPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    if n == 1 { return one }
    let d = n % 10, t = n % 100
    return (2...4).contains(d) && !(12...14).contains(t) ? few : many
}

func ageText(_ age: TimeInterval) -> String {
    let s = max(0, Int(age))
    if s < 5 { return "teraz" }
    if s < 60 { return "\(s) s temu" }
    if s < 3600 { return "\(s / 60) min temu" }
    return "ponad godzinę temu"
}

extension ScreenFreshness {
    var color: Color {
        switch self {
        case .fresh: return .green
        case .stale: return .orange
        case .old: return .red
        }
    }
}

// MARK: - Picture

/// The captured screen on a dark background, or a clear explanation why there is none.
struct ScreenPicture: View {
    @ObservedObject var feed: ScreenFeed
    var large = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.92))
            if let image = feed.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(large ? 40 : 12)
            }
        }
    }

    @ViewBuilder var placeholder: some View {
        if let issue = feed.issue {
            // Small tiles drop the explanation (it stays in the tooltip) rather than clipping it.
            ViewThatFits(in: .vertical) {
                issueView(issue, details: true)
                issueView(issue, details: false)
                Image(systemName: issue.symbol).font(.title2)
            }
        } else {
            switch feed.phase {
            case .paused:
                status("pause.circle", "Podgląd wstrzymany")
            case .offline:
                status("wifi.slash", "Komputer nie odpowiada")
            case .waiting(let until):
                status("clock.arrow.circlepath", "Ponowna próba \(until.formatted(date: .omitted, time: .shortened))")
            case .idle, .connecting, .live:
                VStack(spacing: 8) {
                    ProgressView().controlSize(large ? .regular : .small).tint(.white)
                    Text(feed.phase == .live ? "Oczekiwanie na obraz…" : "Łączenie…")
                        .font(large ? .body : .caption)
                }
            }
        }
    }

    private func issueView(_ issue: ScreenIssue, details: Bool) -> some View {
        VStack(spacing: large ? 10 : 6) {
            Image(systemName: issue.symbol)
                .font(large ? .system(size: 44) : .title2)
            Text(issue.title)
                .font(large ? .title3.weight(.semibold) : .callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if details {
                Text(issue.message)
                    .font(large ? .body : .caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: large ? 560 : nil)
            }
        }
    }

    private func status(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(large ? .system(size: 40) : .title2)
            Text(text).font(large ? .title3 : .caption).multilineTextAlignment(.center)
        }
    }
}

/// Small capsule with the age of the image (green = current, orange = late, red = old).
struct FreshnessBadge: View {
    @ObservedObject var feed: ScreenFeed

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder func content(now: Date) -> some View {
        if case .paused = feed.phase {
            badge("pause.fill", "Wstrzymano", .secondary)
                .help("Podgląd wstrzymany – okno jest ukryte, aplikacja w tle albo podgląd zatrzymano ręcznie.")
        } else if feed.phase == .connecting && feed.image == nil {
            EmptyView()
        } else if let fresh = feed.freshness(at: now), let t = feed.confirmedAt {
            badge("circle.fill", ageText(now.timeIntervalSince(t)), fresh.color)
                .help(fresh == .fresh ? "Obraz aktualny (odświeżany co \(feed.interval) s)."
                      : "Obraz nieaktualny – ostatnie potwierdzenie \(t.formatted(date: .omitted, time: .standard)).")
        }
    }

    private func badge(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 7)).foregroundStyle(color)
            Text(text).font(.caption2.monospacedDigit())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

// MARK: - Actions

/// Things a teacher can do with an observed Mac.
@MainActor
struct ScreenActions {
    let model: AppModel
    let center: ScreenCenter
    let openWindow: OpenWindowAction

    func openInWindow(_ m: Machine) {
        openWindow(id: ScreenWindowView.windowID, value: m.id)
    }

    func sleepDisplay(_ targets: [Machine]) {
        model.runScript(PowerAction.displaySleep.label, on: targets, section: .screens) { _ in Scripts.power(.displaySleep) }
    }

    func screenSharing(_ m: Machine) {
        model.openScreenSharing(m)
    }

    func showApps(_ m: Machine) {
        model.selection = [m.id]
        model.section = .apps
        MainWindow.bringToFront(openWindow)
    }

    func refresh(_ targets: [Machine]) {
        center.refresh(targets.map(\.id))
    }

    func save(_ feed: ScreenFeed, of m: Machine) {
        guard let image = feed.image, let data = ScreenImage.encode(image) else {
            NSSound.beep()
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        guard let url = Pickers.save(name: "\(m.name) \(stamp).jpg") else { return }
        do {
            try data.write(to: url)
        } catch {
            NSSound.beep()
        }
    }
}

enum MainWindow {
    static let id = "main"

    /// Shows the main window (opening a new one when it was closed).
    @MainActor static func bringToFront(_ openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = NSApp.windows.filter {
            $0.canBecomeMain && !ScreenWindowRegistry.contains($0) && ($0.isVisible || $0.isMiniaturized)
        }
        if let main = candidates.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) ?? candidates.first {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: id)
        }
    }
}

/// Icon buttons shown over a tile while the pointer is on it.
struct ScreenActionBar: View {
    let machine: Machine
    @ObservedObject var feed: ScreenFeed
    let actions: ScreenActions
    var onZoom: (() -> Void)?
    var onMessage: () -> Void

    var body: some View {
        let bar = HStack(spacing: 2) {
            if let onZoom {
                icon("arrow.up.left.and.arrow.down.right", "Powiększ (spacja)", action: onZoom)
            }
            icon("macwindow.badge.plus", "Otwórz w nowym oknie") { actions.openInWindow(machine) }
            icon("text.bubble", "Wyślij wiadomość", action: onMessage)
            icon("moon.zzz", "Uśpij ekran") { actions.sleepDisplay([machine]) }
            icon("rectangle.on.rectangle", "Udostępnianie ekranu (VNC) – pełny podgląd i sterowanie") { actions.screenSharing(machine) }
            Menu {
                ScreenMoreMenuItems(machine: machine, feed: feed, actions: actions)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Więcej działań")
            .accessibilityLabel("Więcej działań")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .buttonStyle(.borderless)
        if #available(macOS 26, *) {
            bar.glassEffect(.regular, in: .capsule)
        } else {
            bar.background(.regularMaterial, in: Capsule())
        }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Less frequent actions (the "…" menu and the end of the context menu).
struct ScreenMoreMenuItems: View {
    let machine: Machine
    @ObservedObject var feed: ScreenFeed
    let actions: ScreenActions

    var body: some View {
        Button { actions.refresh([machine]) } label: { Label("Odśwież teraz", systemImage: "arrow.clockwise") }
        Button { actions.save(feed, of: machine) } label: { Label("Zapisz zrzut ekranu…", systemImage: "square.and.arrow.down") }
            .disabled(feed.image == nil)
        ScreenDisplayPicker(machine: machine, feed: feed, center: actions.center)
        Divider()
        Button { actions.showApps(machine) } label: { Label("Aplikacje…", systemImage: "square.grid.2x2") }
        Button { actions.model.openTerminal(machine) } label: { Label("Sesja SSH w Terminalu", systemImage: "terminal") }
    }
}

/// Which monitor of a Mac with several displays to show.
struct ScreenDisplayPicker: View {
    let machine: Machine
    @ObservedObject var feed: ScreenFeed
    @ObservedObject var center: ScreenCenter

    var body: some View {
        Picker(selection: Binding(get: { center.display(for: machine.id) },
                                  set: { center.setDisplay($0, for: machine.id) })) {
            Text(ScreenDisplay.main.label).tag(ScreenDisplay.main)
            Text(ScreenDisplay.all.label).tag(ScreenDisplay.all)
            if feed.displayCount > 1 {
                Divider()
                ForEach(1...feed.displayCount, id: \.self) { n in
                    Text(ScreenDisplay.number(n).label).tag(ScreenDisplay.number(n))
                }
            }
        } label: {
            Label("Monitor", systemImage: "display.2")
        }
        .help("Który monitor tego komputera pokazywać (gdy ma ich kilka)")
    }
}

// MARK: - Tile

struct ScreenTile: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var center: ScreenCenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayScale) private var displayScale
    let machine: Machine
    @ObservedObject var feed: ScreenFeed
    /// Width of the tile in points (sets the requested image size).
    let width: Double
    var interval = 0
    var showLabels = true
    var isFocused = false
    var isSelected = false
    var onZoom: (() -> Void)?
    @ViewState private var hovering = false
    @ViewState private var composing = false

    private var actions: ScreenActions { ScreenActions(model: model, center: center, openWindow: openWindow) }

    var body: some View {
        ScreenPicture(feed: feed)
            .overlay(alignment: .bottom) { if showLabels { labels } }
            .overlay(alignment: .topTrailing) { FreshnessBadge(feed: feed).padding(6) }
            .overlay(alignment: .topLeading) {
                if hovering {
                    ScreenActionBar(machine: machine, feed: feed, actions: actions, onZoom: onZoom,
                                    onMessage: { composing = true })
                        .padding(6)
                        .transition(.opacity)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                // Re-evaluated periodically: an image that stops being confirmed turns the border orange.
                TimelineView(.periodic(from: .now, by: 2)) { context in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(borderColor(at: context.date), lineWidth: borderWidth)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
            .observeScreen(machine.id, request: ScreenRequest(
                pixels: ScreenLayout.captureSize(points: width, scale: displayScale, cap: model.settings.screenshotMaxSize),
                interval: interval))
            .popover(isPresented: $composing, arrowEdge: .bottom) { MessageComposer(targets: [machine]) }
            .contextMenu {
                if let onZoom {
                    Button { onZoom() } label: { Label("Powiększ", systemImage: "arrow.up.left.and.arrow.down.right") }
                }
                Button { actions.openInWindow(machine) } label: { Label("Otwórz w nowym oknie", systemImage: "macwindow.badge.plus") }
                Button { composing = true } label: { Label("Wyślij wiadomość…", systemImage: "text.bubble") }
                Button { actions.sleepDisplay([machine]) } label: { Label("Uśpij ekran", systemImage: "moon.zzz") }
                Button { actions.screenSharing(machine) } label: { Label("Udostępnianie ekranu (VNC)", systemImage: "rectangle.on.rectangle") }
                Divider()
                ScreenMoreMenuItems(machine: machine, feed: feed, actions: actions)
            }
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Powiększ") { onZoom?() }
            .accessibilityAction(named: "Otwórz w nowym oknie") { actions.openInWindow(machine) }
            .accessibilityAction(named: "Wyślij wiadomość") { composing = true }
            .accessibilityAction(named: "Uśpij ekran") { actions.sleepDisplay([machine]) }
    }

    private var labels: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(width < 260 ? .callout.weight(.semibold) : .headline)
                    .lineLimit(1)
                if let issue = feed.issue, !issue.isIdle, feed.image != nil {
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if feed.user != nil || feed.frontApp != nil {
                    HStack(spacing: 8) {
                        if let user = feed.user {
                            Label(user, systemImage: "person.fill").lineLimit(1).layoutPriority(1)
                        }
                        if let app = feed.frontApp, width >= 240 {
                            Label(app, systemImage: "macwindow").lineLimit(1)
                        }
                    }
                }
            }
            .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 7)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }

    private func borderColor(at now: Date) -> Color {
        if isFocused || isSelected { return .accentColor }
        if let issue = feed.issue, !issue.isIdle { return feed.image == nil ? .red.opacity(0.8) : .orange }
        if let f = feed.freshness(at: now), f != .fresh, feed.image != nil { return .orange }
        return Color.primary.opacity(0.12)
    }

    private var borderWidth: Double {
        if isFocused { return 3 }
        if isSelected { return 2.5 }
        if let issue = feed.issue, !issue.isIdle { return 2 }
        return 1
    }

    private var helpText: String {
        var parts = [machine.name]
        if let user = feed.user { parts.append("użytkownik: \(user)") }
        if let app = feed.frontApp { parts.append("na pierwszym planie: \(app)") }
        if let issue = feed.issue { parts.append(issue.message) }
        parts.append("Kliknij dwukrotnie, aby powiększyć.")
        return parts.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var parts = ["Ekran \(machine.name)"]
        if let user = feed.user { parts.append("użytkownik \(user)") }
        if let app = feed.frontApp { parts.append("na pierwszym planie \(app)") }
        if let issue = feed.issue {
            parts.append(issue.title)
        } else if let t = feed.confirmedAt {
            parts.append("obraz \(ageText(Date().timeIntervalSince(t)))")
        } else {
            parts.append(feed.statusText)
        }
        return parts.joined(separator: ", ")
    }
}
