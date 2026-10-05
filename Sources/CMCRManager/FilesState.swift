import AppKit
import CMCRCore
import SwiftUI

/// Permissions applied to pushed files. Symbolic modes: `X` makes folders traversable without turning every
/// plain file into an executable.
enum PushMode: String, CaseIterable, Identifiable {
    case keep = ""
    case everyone = "a=rwX"
    case readOnly = "u=rwX,go=rX"
    case ownerOnly = "u=rwX,go="

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keep: return "Bez zmian"
        case .everyone: return "Wszyscy mogą czytać i zmieniać (jak cmcr-push)"
        case .readOnly: return "Inni mogą tylko czytać"
        case .ownerOnly: return "Tylko właściciel"
        }
    }
}

/// State of the Files section and the file browser. Lives in `AppModel`, so nothing is lost when the user
/// switches to another section and back.
@MainActor
final class FilesState: ObservableObject {
    unowned let app: AppModel

    // Push
    @Published var destination = ""
    @Published var owner: OwnerChoice = .student
    @Published var customOwner = ""
    @Published var mode: PushMode = .everyone
    @Published var pushAsRoot = true
    @Published var showAdvanced = false

    // Collect
    @Published var collectSource = ""
    @Published var collectAsRoot = false
    @Published var collectClean = false
    @Published var lastCollection: URL?

    // Clean / browse
    @Published var cleanPath = ""

    @Published var prefs: FilesPreferences {
        didSet { if prefs != oldValue { prefs.save() } }
    }

    /// The "Przeglądarka plików" section.
    lazy var browser = RemoteBrowserModel(app: app)

    init(app: AppModel) {
        self.app = app
        prefs = FilesPreferences.load()
        let shared = RemotePaths.tokenize(app.settings.sharedFolder, studentUser: app.settings.studentUser)
        collectSource = shared
        cleanPath = shared
        useDestination(shared, remember: false)
    }

    /// Owner or permissions were chosen by hand: typing a new path keeps them.
    private var accessChosenByHand = false

    /// Sets the push destination together with the owner and permissions that suit it.
    func useDestination(_ path: String, remember: Bool = true) {
        let p = RemotePaths.tokenize(path, studentUser: app.settings.studentUser)
        destination = p
        accessChosenByHand = false
        applyDefaults(for: p)
        if remember { prefs.remember(p) }
    }

    /// The path typed in "Zaawansowane".
    func editDestination(_ path: String) {
        destination = path
        if !accessChosenByHand { applyDefaults(for: RemotePaths.tokenize(path, studentUser: app.settings.studentUser)) }
    }

    func setOwner(_ choice: OwnerChoice) {
        owner = choice
        accessChosenByHand = true
    }

    func setMode(_ newMode: PushMode) {
        mode = newMode
        accessChosenByHand = true
    }

    private func applyDefaults(for path: String) {
        let defaults = Self.pushDefaults(for: path, settings: app.settings)
        owner = defaults.owner
        mode = defaults.mode
        // The administrator's own home is the only place that never needs sudo.
        pushAsRoot = !path.hasPrefix("~")
    }

    func rememberFolder(_ path: String) { prefs.remember(path) }

    static func pushDefaults(for path: String, settings s: AppSettings) -> (owner: OwnerChoice, mode: PushMode) {
        let shared = RemotePaths.tokenize(s.sharedFolder, studentUser: s.studentUser)
        if path == shared { return (.student, .everyone) }
        if path == "/Users/Shared" || path.hasPrefix("/Users/Shared/") { return (.keep, .everyone) }
        if path == RemotePaths.student || path.hasPrefix(RemotePaths.student + "/") { return (.student, .keep) }
        if path == RemotePaths.console || path.hasPrefix(RemotePaths.console + "/") { return (.console, .keep) }
        if path == "/Applications" || path.hasPrefix("/Applications/") { return (.admin, .keep) }
        return (.keep, .keep)
    }

    var collectBase: String {
        get { prefs.collectBase(app.settings) }
        set { prefs.collectFolder = newValue == RemotePaths.join(app.settings.localFolder, "zebrane") ? "" : newValue }
    }

    /// Where the next "Zbierz prace" run would write (shown as an example to the teacher).
    var nextCollectionExample: String {
        let folder = Operations.collectionFolder(base: collectBase, timestamped: prefs.collectTimestamped)
        let host = app.selectedMachines.first?.name ?? "imac01"
        let base = RemotePaths.lastComponent(collectBase)
        return prefs.collectTimestamped ? "\(base)/\(folder.lastPathComponent)/\(host)/…" : "\(base)/\(host)/…"
    }

    // MARK: - Actions

    func push(to targets: [Machine]) {
        app.pushFiles(app.pushItems, destination: destination, owner: app.ownerString(owner, custom: customOwner),
                      mode: mode.rawValue, asRoot: pushAsRoot || owner != .keep, on: targets)
        prefs.remember(destination)
    }

    /// "Zbierz prace": `<base>/<date time>/<host>` for every target, optionally emptying the source afterwards.
    func collect(from targets: [Machine]) {
        guard !targets.isEmpty else { return }
        let source = app.settings.resolve(collectSource)
        let folder = Operations.collectionFolder(base: collectBase, timestamped: prefs.collectTimestamped)
        let asRoot = collectAsRoot
        let clean = collectClean
        lastCollection = folder
        prefs.remember(collectSource)
        let title = clean ? "Zbierz prace i wyczyść: \(source)" : "Zbierz prace: \(source)"
        app.runBatch(title, on: targets, section: .files) { m, job in
            let (r, _) = await Operations.collect(source: source, from: m, into: folder, name: m.name, asRoot: asRoot,
                                                  cleanAfter: clean, password: self.app.password(for: m),
                                                  settings: self.app.sshSettings, handle: job.handle,
                                                  onOutput: OutputSink(job).callback)
            return r
        }
    }

    func revealLastCollection() {
        let url = lastCollection.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? URL(fileURLWithPath: expandTilde(collectBase), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Opens the file browser section on `path` (first selected Mac).
    func browse(_ path: String) {
        browser.open(path, on: app.selectedMachines.first?.id ?? browser.hostID)
        app.section = .browser
    }
}
