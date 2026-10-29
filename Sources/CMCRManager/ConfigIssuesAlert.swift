import AppKit
import CMCRCore
import SwiftUI

/// The alerts of the main window: a password that could not be saved in the Keychain (only the main window sets
/// passwords), and – as in every window, by the one the user works in – the notices and the configuration problems
/// (`noticeAlert`).
struct ConfigIssuesAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ViewState private var showsSample = false

    /// Keychain Access, to unlock the "login" keychain (nil when macOS does not have it).
    private var keychainAccess: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess")
    }

    func body(content: Content) -> some View {
        content.alert("Problem z Pękiem kluczy", isPresented: Binding(
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
    /// Shows `model.notice` and `model.configIssues` when this window is the one the user works in (`NoticeAlert`).
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
            .modifier(ConfigIssuesNotice(window: WeakWindow(mine), visible: visible))
    }
}

/// `model.configIssues` – hosts.json or settings.json found damaged at start or by a save after a hand edit,
/// classroom.json that could not be read – shown like a notice, by the one window the user works in (`NoticeWindows`).
/// Before, only the main window had this alert: with the Screen Wall alone on a projector the warning waited until
/// the main window was opened again (AUDIT REV-66). Part of `NoticeAlert`, in the same windows.
/// The alert shows the problems found when it opened (`ConfigIssuesBatch`) and removes only them: one found while it
/// is open – AppKit does not update the text of an open alert – is shown by the next alert, not removed unseen
/// (AUDIT REV-67).
struct ConfigIssuesNotice: ViewModifier {
    @EnvironmentObject var model: AppModel
    /// The window of `NoticeAlert`.
    let window: WeakWindow
    /// Whether that window is on screen: a change shows a warning that waited for an open window.
    let visible: Bool

    private func isPresenter(_ batch: ConfigIssuesBatch) -> Bool {
        guard let mine = window.window else { return false }
        return NoticeWindows.shared.presenter(for: batch) === mine
    }

    private func dismiss(_ batch: ConfigIssuesBatch) {
        if let rest = NoticeWindows.shared.dismiss(batch, from: model.configIssues) { model.configIssues = rest }
    }

    func body(content: Content) -> some View {
        let batch = window.window == nil ? nil : NoticeWindows.shared.configIssues(for: model.configIssues)
        content.alert("Nie udało się wczytać części konfiguracji", isPresented: Binding(
            get: { batch.map { isPresenter($0) } ?? false },
            // Only the window that shows the warning dismisses it, as with a notice.
            set: { if !$0, let batch, isPresenter(batch) { dismiss(batch) } }
        ), presenting: batch) { batch in
            Button("Pokaż pliki w Finderze") {
                NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directory])
                dismiss(batch)
            }
            Button("OK", role: .cancel) { dismiss(batch) }
        } message: { batch in
            Text(batch.issues.joined(separator: "\n\n")
                 + "\n\nSprawdź listę komputerów i ustawienia w dziale Konfiguracja.")
        }
    }
}

/// The configuration problems one alert shows: `model.configIssues` as they were when it opened, with an id of its
/// own – every alert is placed anew by `NoticeWindows`, also one with the same text as an earlier one (AUDIT REV-68).
struct ConfigIssuesBatch: Equatable {
    let id = UUID()
    let issues: [String]
}

struct WeakWindow {
    weak var window: NSWindow?
    init(_ window: NSWindow? = nil) { self.window = window }
}

/// The windows that can show a notice (`NoticeAlert`) and the one chosen for the current notice and for the current
/// configuration problems.
@MainActor
final class NoticeWindows {
    static let shared = NoticeWindows()
    /// What a window shows for the model: `model.notice` or `model.configIssues`, each chosen on its own.
    enum Kind { case notice, configIssues }
    private var windows: [WeakWindow] = []
    private var chosen: [Kind: (id: AnyHashable, window: WeakWindow)] = [:]
    /// The configuration problems the alert shows now, until it is dismissed.
    private var shownIssues: ConfigIssuesBatch?

    func register(_ window: NSWindow) {
        windows.removeAll { $0.window == nil }
        if !windows.contains(where: { $0.window === window }) { windows.append(WeakWindow(window)) }
    }

    /// The window that shows `notice`, chosen once per notice (it stays there while that window is open).
    func presenter(for notice: AppNotice) -> NSWindow? {
        presenter(.notice, id: notice.id)
    }

    /// What the alert with the configuration problems shows for `issues` (`model.configIssues`): the problems it
    /// shows already – a problem found meanwhile waits for the next alert (AUDIT REV-67) – else all of them.
    func configIssues(for issues: [String]) -> ConfigIssuesBatch? {
        if let shown = shownIssues, shown.issues.contains(where: issues.contains) { return shown }
        chosen[.configIssues] = nil
        shownIssues = issues.isEmpty ? nil : ConfigIssuesBatch(issues: issues)
        return shownIssues
    }

    /// The window that shows `batch` of configuration problems, chosen once per batch as for a notice; none once the
    /// batch was dismissed (its alert closing after „OK”).
    func presenter(for batch: ConfigIssuesBatch) -> NSWindow? {
        guard shownIssues?.id == batch.id else { return nil }
        return presenter(.configIssues, id: batch.id)
    }

    /// `batch` was dismissed („OK”, „Pokaż pliki w Finderze”): what is left of `issues` – the problems found while it
    /// was open, for the next alert – or nil when it was dismissed already. The window chosen for it is forgotten: the
    /// next alert, also with the same text, is shown by the window the user works in then (AUDIT REV-68).
    func dismiss(_ batch: ConfigIssuesBatch, from issues: [String]) -> [String]? {
        guard shownIssues?.id == batch.id else { return nil }
        shownIssues = nil
        chosen[.configIssues] = nil
        return issues.filter { !batch.issues.contains($0) }
    }

    /// The window that shows the message `id` of `kind`, chosen once per message (it stays there while that window is
    /// open). A notice and the configuration problems may be in different windows.
    func presenter(_ kind: Kind, id: AnyHashable) -> NSWindow? {
        windows.removeAll { $0.window == nil }
        let open = windows.compactMap(\.window).filter(\.isVisible)
        if let c = chosen[kind], c.id == id, let w = c.window.window, open.contains(where: { $0 === w }) {
            return w
        }
        let w = Self.pick(open, key: NSApp.keyWindow.map(Self.owner), main: NSApp.mainWindow.map(Self.owner),
                          frontToBack: NSApp.orderedWindows)
        chosen[kind] = w.map { (id, WeakWindow($0)) }
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
