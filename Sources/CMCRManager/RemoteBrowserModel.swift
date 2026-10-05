import AppKit
import CMCRCore
import SwiftUI

/// Browsing state of one remote folder on one Mac: used by the "Przeglądarka plików" section and by the
/// folder picker sheet. Listings run directly over SSH; changes (new folder, upload, delete…) are recorded as
/// jobs, so they show up in "Zadania" and in the action log.
@MainActor
final class RemoteBrowserModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(RemoteBrowseError)
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    unowned let app: AppModel

    @Published private(set) var hostID: UUID?
    /// Folder shown (placeholders resolved once loaded).
    @Published private(set) var path = ""
    @Published private(set) var listing: RemoteListing? { didSet { refilter() } }
    @Published private(set) var phase: Phase = .idle
    @Published var asRoot = false
    /// A folder the administrator may not read is opened again with sudo (when a password is stored).
    var autoElevate = true
    @Published var showHidden = false { didSet { refilter() } }
    @Published var search = "" { didSet { refilter() } }
    @Published var sortOrder = [KeyPathComparator(\RemoteEntry.name, comparator: .localizedStandard)] {
        didSet { refilter() }
    }
    /// Entries after the hidden/search filters, sorted, folders first (like Finder's "Keep folders on top").
    @Published private(set) var visibleEntries: [RemoteEntry] = []
    @Published var selection = Set<RemoteEntry.ID>()
    /// A change that is running right now ("Wysyłanie…").
    @Published private(set) var activity: String?
    /// Result of the last change.
    @Published var notice: Notice?
    /// Items saved by the last download.
    private(set) var lastDownload: [URL] = []

    private var history: [String] = []
    private var future: [String] = []
    private var loadHandle: ProcessHandle?
    private var generation = 0
    private var pendingSelection: String?

    init(app: AppModel) {
        self.app = app
    }

    var host: Machine? { hostID.flatMap { app.machine($0) } }

    var isLoading: Bool { phase == .loading }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }
    var canGoUp: Bool { !path.isEmpty && RemotePaths.parent(of: path) != path }

    private func refilter() {
        guard let l = listing else {
            visibleEntries = []
            return
        }
        var items = l.entries.filter { showHidden || !$0.isHidden }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { items = items.filter { $0.name.localizedStandardContains(q) } }
        items.sort(using: sortOrder)
        visibleEntries = items.filter(\.isFolder) + items.filter { !$0.isFolder }
    }

    var hiddenCount: Int { showHidden ? 0 : (listing?.entries.filter(\.isHidden).count ?? 0) }

    var selectedEntries: [RemoteEntry] {
        listing?.entries.filter { selection.contains($0.id) } ?? []
    }

    /// The current folder written with placeholders, so it means the same on every Mac.
    func portablePath(preferConsole: Bool = false) -> String {
        RemotePaths.tokenize(path, studentUser: app.settings.studentUser, consoleUser: listing?.consoleUser,
                             preferConsole: preferConsole, adminHome: listing?.adminHome)
    }

    // MARK: - Navigation

    /// First selected Mac that is online, otherwise the first selected one, otherwise any online Mac.
    func preferredHostID() -> UUID? {
        let online = { (m: Machine) in self.app.status(m).reachability == .online }
        let selected = app.selectedMachines
        return (selected.first(where: online) ?? selected.first ?? app.machines.first(where: online)
                ?? app.machines.first)?.id
    }

    /// Shows the same folder on another Mac.
    func setHost(_ id: UUID?) {
        guard id != hostID else { return }
        let carry = listing == nil ? path : portablePath()
        hostID = id
        history = []
        future = []
        listing = nil
        selection = []
        if !carry.isEmpty { load(carry) } else { phase = .idle }
    }

    func open(_ newPath: String, on id: UUID? = nil) {
        if let id, id != hostID {
            hostID = id
            history = []
            future = []
            listing = nil
        } else if !path.isEmpty, newPath != path {
            history.append(path)
            future = []
        }
        load(newPath)
    }

    func enter(_ entry: RemoteEntry) {
        guard entry.isFolder else { return }
        open(RemotePaths.join(path, entry.name))
    }

    func goBack() {
        guard let p = history.popLast() else { return }
        future.append(path)
        load(p)
    }

    func goForward() {
        guard let p = future.popLast() else { return }
        history.append(path)
        load(p)
    }

    func goUp() {
        guard canGoUp else { return }
        let current = RemotePaths.lastComponent(path)
        open(RemotePaths.parent(of: path))
        pendingSelection = current
    }

    func reload() {
        guard !path.isEmpty else { return }
        load(path, keepSelection: true)
    }

    func cancel() {
        loadHandle?.cancel()
    }

    private func load(_ requested: String, keepSelection: Bool = false) {
        if host == nil { hostID = preferredHostID() }
        guard let m = host else {
            phase = .idle
            return
        }
        loadHandle?.cancel()
        let handle = ProcessHandle()
        loadHandle = handle
        generation += 1
        let gen = generation
        let target = app.settings.resolve(requested)
        if target != path { listing = nil }
        path = target
        phase = .loading
        if !keepSelection { selection = [] }
        let password = app.password(for: m)
        let settings = app.sshSettings
        let root = asRoot
        Task {
            let result = await Operations.browse(target, on: m, asRoot: root, password: password, settings: settings,
                                                 handle: handle)
            guard gen == self.generation else { return }
            switch result {
            case .success(let l):
                self.listing = l
                self.path = l.path
                self.phase = .loaded
                let names = Set(l.entries.map(\.id))
                if let p = self.pendingSelection, names.contains(p) { self.selection = [p] }
                self.selection.formIntersection(names)
                self.pendingSelection = nil
            case .failure(.cancelled):
                self.phase = self.listing == nil ? .idle : .loaded
            case .failure(.accessDenied) where !root && self.autoElevate && !(password ?? "").isEmpty:
                self.asRoot = true
                self.load(target, keepSelection: keepSelection)
            case .failure(let e):
                self.listing = nil
                self.phase = .failed(e)
            }
        }
    }

    // MARK: - Changes

    /// sudo is used when the folder belongs to someone else, so new files get that owner instead of the admin.
    private func needsRoot(_ l: RemoteListing, entries: [RemoteEntry] = []) -> Bool {
        asRoot || l.asRoot || !l.writable || l.owner != l.adminUser || entries.contains { $0.owner != l.adminUser }
    }

    private func runChange(_ title: String, on m: Machine, activity text: String,
                           operation: @escaping @MainActor (Job) async -> CommandResult,
                           done: (@MainActor (Bool) -> Void)? = nil) {
        activity = text
        notice = nil
        app.runBatch(title, on: [m], section: .browser, operation: { _, job in
            await operation(job)
        }, completion: { batch in
            self.activity = nil
            let job = batch.jobs.first
            let ok = job?.state == .succeeded
            let summary = job?.summary ?? ""
            self.notice = Notice(text: ok ? (summary.isEmpty || summary == "OK" ? "Gotowe." : summary)
                                          : (summary.isEmpty ? "Operacja nie powiodła się." : summary),
                                 isError: !ok)
            done?(ok)
            if m.id == self.hostID { self.reload() }
        })
    }

    func makeFolder(named name: String) {
        guard let m = host, let l = listing, RemotePaths.isValidName(name) else { return }
        let target = RemotePaths.join(l.path, name)
        let root = needsRoot(l)
        pendingSelection = name
        runChange("Nowy folder: \(target)", on: m, activity: "Tworzenie folderu „\(name)”…") { job in
            await self.app.ssh(Scripts.makeDirectory(target, asRoot: root), on: m, job: job)
        }
    }

    func rename(_ entry: RemoteEntry, to newName: String) {
        guard let m = host, let l = listing, RemotePaths.isValidName(newName), newName != entry.name else { return }
        let source = RemotePaths.join(l.path, entry.name)
        let root = needsRoot(l, entries: [entry])
        pendingSelection = newName
        runChange("Zmiana nazwy: \(entry.name) → \(newName)", on: m, activity: "Zmiana nazwy…") { job in
            await self.app.ssh(Scripts.renameItem(source, to: newName, asRoot: root), on: m, job: job)
        }
    }

    func delete(_ entries: [RemoteEntry]) {
        guard let m = host, let l = listing, !entries.isEmpty else { return }
        let paths = entries.map { RemotePaths.join(l.path, $0.name) }
        let root = needsRoot(l, entries: entries)
        let what = entries.count == 1 ? "„\(entries[0].name)”" : "\(entries.count) elementów"
        runChange("Usuń \(what) z \(l.path)", on: m, activity: "Usuwanie \(what)…") { job in
            await self.app.ssh(Scripts.deleteItems(paths, asRoot: root), on: m, job: job)
        }
    }

    /// Downloads entries into a local folder and shows them in Finder.
    func download(_ entries: [RemoteEntry], to directory: URL) {
        guard let m = host, let l = listing, !entries.isEmpty else { return }
        let names = entries.map(\.name)
        let root = asRoot || l.asRoot
        let what = entries.count == 1 ? "„\(entries[0].name)”" : "\(entries.count) elementów"
        lastDownload = []
        runChange("Pobierz \(what) z \(m.name)", on: m, activity: "Pobieranie \(what)…", operation: { job in
            let (r, saved) = await Operations.download(names, in: l.path, from: m, into: directory, asRoot: root,
                                                       password: self.app.password(for: m),
                                                       settings: self.app.sshSettings, handle: job.handle,
                                                       onOutput: OutputSink(job).callback)
            self.lastDownload = saved
            return r
        }, done: { _ in
            if !self.lastDownload.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(self.lastDownload) }
        })
    }

    /// Uploads local files into the current folder (or into one of its subfolders).
    func upload(_ urls: [URL], into subfolder: RemoteEntry? = nil) {
        guard let m = host, let l = listing, !urls.isEmpty else { return }
        let destination = subfolder.map { RemotePaths.join(l.path, $0.name) } ?? l.path
        let ownerName = subfolder?.owner ?? l.owner
        let groupName = subfolder?.group ?? l.group
        let owner = ownerName == l.adminUser || ownerName.isEmpty ? "" : "\(ownerName):\(groupName)"
        let root = asRoot || !owner.isEmpty || !l.writable
        let what = urls.count == 1 ? "„\(urls[0].lastPathComponent)”" : "\(urls.count) elementów"
        runChange("Wyślij \(what) → \(m.name):\(destination)", on: m, activity: "Wysyłanie \(what)…") { job in
            switch await Payload.make(urls) {
            case .failure(let e):
                return .failure(e.localizedDescription)
            case .success(let payload):
                defer { try? FileManager.default.removeItem(at: payload) }
                return await Operations.push(payload: payload, to: m, destination: destination, owner: owner, mode: "",
                                             asRoot: root, password: self.app.password(for: m),
                                             settings: self.app.sshSettings, handle: job.handle,
                                             onOutput: OutputSink(job).callback)
            }
        }
    }

    /// Names of `urls` that already exist in the current folder (would be replaced by an upload).
    func conflicts(for urls: [URL]) -> [String] {
        let names = Set(listing?.entries.map(\.name) ?? [])
        return urls.map(\.lastPathComponent).filter { names.contains($0) }
    }
}
