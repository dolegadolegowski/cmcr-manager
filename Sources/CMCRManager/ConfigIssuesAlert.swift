import AppKit
import CMCRCore
import SwiftUI

/// Tells the user at start that hosts.json or settings.json was damaged and where the original was kept,
/// and that a password could not be saved in the Keychain.
struct ConfigIssuesAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ViewState private var showsSample = false

    /// Keychain Access, to unlock the "login" keychain (nil when macOS does not have it).
    private var keychainAccess: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess")
    }

    func body(content: Content) -> some View {
        content.alert("Nie udało się wczytać części konfiguracji", isPresented: Binding(
            get: { !model.configIssues.isEmpty },
            set: { if !$0 { model.configIssues = [] } }
        )) {
            Button("Pokaż pliki w Finderze") {
                NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directory])
                model.configIssues = []
            }
            Button("OK", role: .cancel) { model.configIssues = [] }
        } message: {
            Text(model.configIssues.joined(separator: "\n\n")
                 + "\n\nSprawdź listę komputerów i ustawienia w dziale Konfiguracja.")
        }
        .alert("Problem z Pękiem kluczy", isPresented: Binding(
            get: { model.keychainError != nil },
            set: { if !$0 { model.keychainError = nil } }
        )) {
            if let app = keychainAccess {
                Button("Otwórz Dostęp do pęku kluczy") {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                    model.keychainError = nil
                }
            }
            Button("OK", role: .cancel) { model.keychainError = nil }
        } message: {
            Text(model.keychainError ?? "")
        }
        .noticeAlert()
        .onSnapshotSubpage { sub in
            // Sample texts, only for the UI snapshots (see SnapshotRenderer); removed again with the sub-page.
            switch sub {
            case "configissues":
                model.configIssues = ["Lista komputerów (hosts.json) jest uszkodzona – wczytano listę domyślną. Oryginał zachowano jako hosts.json.20261028-081500.bak w \(ConfigStore.directory.path)."]
                showsSample = true
            case "keychain":
                model.keychainError = "Nie udało się zapisać hasła w Pęku kluczy. Sprawdź, czy pęk kluczy „login” jest odblokowany (aplikacja Dostęp do pęku kluczy), i spróbuj ponownie."
                showsSample = true
            default:
                if showsSample {
                    model.configIssues = []
                    model.keychainError = nil
                    showsSample = false
                }
            }
        }
    }
}

extension View {
    /// Shows `model.notice` when this window is the one the user works in (`NoticeAlert`).
    func noticeAlert(showsToasts: Bool = false) -> some View {
        modifier(NoticeAlert(showsToasts: showsToasts))
    }
}

/// An alert with `model.notice` – what could not be done and why. Every window that can raise a notice has it: the
/// main window, the Screen Wall, the screen windows and Ustawienia. Only one of them shows a notice, the one the
/// user works in (`NoticeWindows`): with the main window closed and the Screen Wall left on a projector, a failed
/// screenshot save or Screen Sharing tunnel is not lost, and does not pop up later in the main window
/// (AUDIT REV-13, REV-22).
struct NoticeAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    /// Short messages without a batch („Łączenie z … przez szyfrowany tunel SSH…”) also appear here while this is
    /// the key window – for the screen windows; the main window has its own (ActionToastOverlay in DetailView).
    var showsToasts = false
    @ViewState private var window = WeakWindow()
    /// Changes when the window comes on screen, so that a notice waiting for an open window is shown then.
    @ViewState private var onScreen = false

    private var isPresenter: Bool {
        guard let notice = model.notice, let mine = window.window else { return false }
        return NoticeWindows.shared.presenter(for: notice) === mine
    }

    func body(content: Content) -> some View {
        // Read here, so that the window found (or coming on screen) updates the alert below.
        let mine = window.window
        let visible = onScreen
        content
            .background(WindowReader { w, shown in
                guard let w else { return }
                NoticeWindows.shared.register(w)
                if window.window !== w { window = WeakWindow(w) }
                if onScreen != shown { onScreen = shown }
            })
            .overlay(alignment: .top) {
                if visible, showsToasts, let toast = model.toast, toast.batchID == nil, mine?.isKeyWindow == true {
                    ActionToastOverlay().padding(.top, 12)
                }
            }
            .alert(model.notice?.title ?? "", isPresented: Binding(
                get: { isPresenter },
                // Only the window that shows the notice dismisses it: another one may be closing an older alert.
                set: { if !$0 && isPresenter { model.notice = nil } }
            )) {
                Button("OK", role: .cancel) { model.notice = nil }
            } message: {
                Text(model.notice?.message ?? "")
            }
    }
}

struct WeakWindow {
    weak var window: NSWindow?
    init(_ window: NSWindow? = nil) { self.window = window }
}

/// The windows that can show a notice (`NoticeAlert`) and the one chosen for the current notice.
@MainActor
final class NoticeWindows {
    static let shared = NoticeWindows()
    private var windows: [WeakWindow] = []
    private var chosen: (notice: UUID, window: WeakWindow)?

    func register(_ window: NSWindow) {
        windows.removeAll { $0.window == nil }
        if !windows.contains(where: { $0.window === window }) { windows.append(WeakWindow(window)) }
    }

    /// The window that shows `notice`, chosen once per notice (it stays there while that window is open).
    func presenter(for notice: AppNotice) -> NSWindow? {
        windows.removeAll { $0.window == nil }
        let open = windows.compactMap(\.window).filter(\.isVisible)
        if let chosen, chosen.notice == notice.id, let w = chosen.window.window, open.contains(where: { $0 === w }) {
            return w
        }
        let w = Self.pick(open, key: NSApp.keyWindow.map(Self.owner), main: NSApp.mainWindow.map(Self.owner),
                          frontToBack: NSApp.orderedWindows)
        chosen = w.map { (notice.id, WeakWindow($0)) }
        return w
    }

    /// The window a sheet, a panel or a child window belongs to.
    static func owner(_ window: NSWindow) -> NSWindow {
        var w = window
        while let up = w.sheetParent ?? w.parent { w = up }
        return w
    }

    /// Of the `open` windows that can show a notice: the key window (where the user acts), else the main window
    /// (the key one may be a save panel that has just closed), else the front-most one.
    static func pick<W: AnyObject>(_ open: [W], key: W?, main: W?, frontToBack: [W]) -> W? {
        func isOpen(_ w: W?) -> Bool { w.map { w in open.contains { $0 === w } } ?? false }
        if isOpen(key) { return key }
        if isOpen(main) { return main }
        return frontToBack.first { isOpen($0) } ?? open.first
    }
}
