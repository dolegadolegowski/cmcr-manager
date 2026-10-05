import AppKit
import CMCRCore
import SwiftUI

enum ScreenGridLayout: String, CaseIterable, Identifiable {
    case fit, adaptive, two, three, four, five, six

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Dopasuj do okna"
        case .adaptive: return "Własny rozmiar"
        case .two: return "2 kolumny"
        case .three: return "3 kolumny"
        case .four: return "4 kolumny"
        case .five: return "5 kolumn"
        case .six: return "6 kolumn"
        }
    }

    var symbol: String {
        switch self {
        case .fit: return "aspectratio"
        case .adaptive: return "slider.horizontal.3"
        case .two: return "square.grid.2x2"
        case .three: return "square.grid.3x3"
        default: return "square.grid.4x3.fill"
        }
    }

    var fixedColumns: Int? {
        switch self {
        case .fit, .adaptive: return nil
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .five: return 5
        case .six: return 6
        }
    }
}

/// Grid of live screens with keyboard navigation (arrows, space/return to enlarge, Esc) and an in-place zoom.
struct ScreenGrid: View {
    @EnvironmentObject var center: ScreenCenter
    let machines: [Machine]
    var layout: ScreenGridLayout = .fit
    var tileWidth: Double = 320
    var interval = 0
    var showLabels = true
    var selection: Binding<Set<UUID>>?
    @ViewState private var focused: UUID?
    @ViewState private var zoomed: UUID?
    @ViewState private var columnCount = 1
    @FocusState private var hasFocus: Bool

    static let spacing: Double = 10
    static let padding: Double = 14

    var body: some View {
        GeometryReader { geo in
            let inner = CGSize(width: max(0, geo.size.width - 2 * Self.padding),
                               height: max(0, geo.size.height - 2 * Self.padding))
            let cols = columns(for: inner)
            let width = layout == .fit
                ? ScreenLayout.fitTileWidth(count: machines.count, columns: cols, width: inner.width,
                                            height: inner.height, spacing: Self.spacing)
                : ScreenLayout.tileWidth(columns: cols, width: inner.width, spacing: Self.spacing)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: Self.spacing), count: cols),
                              spacing: Self.spacing) {
                        ForEach(machines) { m in
                            ScreenTile(machine: m, feed: center.feed(for: m.id), width: width, interval: interval,
                                       showLabels: showLabels, isFocused: hasFocus && focused == m.id,
                                       isSelected: selection?.wrappedValue.contains(m.id) ?? false,
                                       onZoom: { zoom(m.id) })
                                .id(m.id)
                                .gesture(TapGesture(count: 2).onEnded { zoom(m.id) })
                                .simultaneousGesture(TapGesture().onEnded { click(m.id) })
                        }
                    }
                    .padding(Self.padding)
                    // "Dopasuj do okna" never scrolls: the screens sit in the middle instead of leaving an empty
                    // band at the bottom of the window.
                    .frame(maxWidth: .infinity, minHeight: layout == .fit ? geo.size.height : nil)
                }
                .onChange(of: focused) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            .onAppear { columnCount = cols }
            .onChange(of: cols) { _, value in columnCount = value }
        }
        .focusable()
        .focused($hasFocus)
        .focusEffectDisabled()
        .onMoveCommand(perform: move)
        .onKeyPress(.space) { toggleZoom() }
        .onKeyPress(.return) { toggleZoom() }
        .onCommand(#selector(NSStandardKeyBindingResponding.selectAll(_:))) {
            selection?.wrappedValue = Set(machines.map(\.id))
        }
        .onExitCommand {
            if zoomed != nil {
                zoomed = nil
            } else {
                selection?.wrappedValue = []
            }
        }
        .overlay {
            if let id = zoomed, let m = machines.first(where: { $0.id == id }) {
                ZoomedScreen(machine: m, feed: center.feed(for: m.id), position: position(of: id),
                             onClose: { zoomed = nil }, onStep: step)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: zoomed)
        .task {
            // Start-up hook for scripted UI checks: CMCR_ZOOM_FIRST_SCREEN=1 enlarges the first screen.
            if ProcessInfo.processInfo.environment["CMCR_ZOOM_FIRST_SCREEN"] == "1", let first = machines.first {
                zoom(first.id)
            }
        }
        .onChange(of: machines.map(\.id)) { _, ids in
            if let z = zoomed, !ids.contains(z) { zoomed = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ekrany komputerów")
    }

    private func columns(for size: CGSize) -> Int {
        let n = max(1, machines.count)
        switch layout {
        case .fit:
            return ScreenLayout.fitColumns(count: n, width: size.width, height: size.height, spacing: Self.spacing)
        case .adaptive:
            return min(n, ScreenLayout.adaptiveColumns(width: size.width, minTileWidth: tileWidth, spacing: Self.spacing))
        default:
            return layout.fixedColumns ?? 3
        }
    }

    private func click(_ id: UUID) {
        hasFocus = true
        focused = id
        guard let selection else { return }
        if NSEvent.modifierFlags.contains(.command) {
            if selection.wrappedValue.contains(id) { selection.wrappedValue.remove(id) } else { selection.wrappedValue.insert(id) }
        } else {
            selection.wrappedValue = [id]
        }
    }

    private func zoom(_ id: UUID) {
        focused = id
        hasFocus = true
        zoomed = id
    }

    private func toggleZoom() -> KeyPress.Result {
        if zoomed != nil {
            zoomed = nil
            return .handled
        }
        guard let id = focused ?? machines.first?.id else { return .ignored }
        zoom(id)
        return .handled
    }

    private func position(of id: UUID) -> (index: Int, count: Int) {
        ((machines.firstIndex { $0.id == id } ?? 0) + 1, machines.count)
    }

    private func step(_ delta: Int) {
        guard let id = zoomed, let i = machines.firstIndex(where: { $0.id == id }), !machines.isEmpty else { return }
        let next = machines[(i + delta + machines.count) % machines.count].id
        zoomed = next
        focused = next
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !machines.isEmpty else { return }
        if zoomed != nil {
            switch direction {
            case .left, .up: step(-1)
            case .right, .down: step(1)
            @unknown default: break
            }
            return
        }
        guard let current = focused, let i = machines.firstIndex(where: { $0.id == current }) else {
            focused = machines.first?.id
            return
        }
        var next = i
        switch direction {
        case .left: next = i - 1
        case .right: next = i + 1
        case .up: next = i - columnCount
        case .down: next = i + columnCount
        @unknown default: break
        }
        focused = machines[min(machines.count - 1, max(0, next))].id
    }
}

/// One screen enlarged over the grid (no sheet: the rest of the window keeps working).
struct ZoomedScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var center: ScreenCenter
    @Environment(\.openWindow) private var openWindow
    let machine: Machine
    @ObservedObject var feed: ScreenFeed
    let position: (index: Int, count: Int)
    let onClose: () -> Void
    let onStep: (Int) -> Void
    @ViewState private var composing = false

    var body: some View {
        let actions = ScreenActions(model: model, center: center, openWindow: openWindow)
        VStack(spacing: 10) {
            // Titled buttons next to the name, under it in narrower windows, icons only as the last resort.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading
                    buttons(actions).labelStyle(.titleAndIcon)
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    HStack {
                        Spacer(minLength: 0)
                        buttons(actions).labelStyle(.titleAndIcon)
                    }
                }
                HStack(spacing: 10) {
                    heading
                    buttons(actions).labelStyle(.iconOnly)
                }
            }
            .popover(isPresented: $composing, arrowEdge: .bottom) { MessageComposer(targets: [machine]) }
            .controlSize(.regular)
            ScreenPicture(feed: feed, large: true)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) { FreshnessBadge(feed: feed).padding(8) }
                .observeScreen(machine.id, request: ScreenRequest(
                    pixels: max(1600, model.settings.screenshotMaxSize),
                    interval: max(2, model.settings.screenshotInterval / 2)))
                .onTapGesture(count: 2, perform: onClose)
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var heading: some View {
        HStack(spacing: 10) {
            ScreenTitle(machine: machine, feed: feed)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text("\(position.index) z \(position.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Który to komputer z widocznych; strzałki przechodzą do kolejnych")
        }
    }

    private func buttons(_ actions: ScreenActions) -> some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { onStep(-1) } label: { Label("Poprzedni", systemImage: "chevron.left") }
                    .help("Poprzedni komputer (←)")
                Button { onStep(1) } label: { Label("Następny", systemImage: "chevron.right") }
                    .help("Następny komputer (→)")
            }
            .fixedSize()
            Button { composing = true } label: { Label("Wyślij wiadomość", systemImage: "text.bubble") }
                .help("Wyślij wiadomość na ten ekran")
            Button { actions.sleepDisplay([machine]) } label: { Label("Uśpij ekran", systemImage: "moon") }
                .help("Wygasza monitor tego komputera (uczeń obudzi go myszą lub klawiaturą)")
            Button { actions.openInWindow(machine) } label: { Label("Otwórz w oknie", systemImage: "macwindow.badge.plus") }
                .help("Otwórz ten ekran w osobnym oknie – można je zostawić obok innych okien")
            Button(action: onClose) { Label("Zamknij", systemImage: "xmark") }
                .help("Wróć do wszystkich ekranów (Esc)")
        }
        .fixedSize()
    }
}

/// Name, user and frontmost application of an observed Mac.
struct ScreenTitle: View {
    let machine: Machine
    @ObservedObject var feed: ScreenFeed

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(machine.name).font(.title2.weight(.semibold))
            if let user = feed.user {
                Label(user, systemImage: "person.fill").foregroundStyle(.secondary)
            }
            if let app = feed.frontApp {
                Label(app, systemImage: "macwindow").foregroundStyle(.secondary)
                    .help("Aplikacja na pierwszym planie")
            }
            if let issue = feed.issue {
                let calm = issue.isIdle || issue.isOffline
                Label(issue.title, systemImage: calm ? issue.displaySymbol : "exclamationmark.triangle.fill")
                    .foregroundStyle(calm ? Color.secondary : Color.orange)
                    .help(issue.message)
            }
        }
        .lineLimit(1)
    }
}
