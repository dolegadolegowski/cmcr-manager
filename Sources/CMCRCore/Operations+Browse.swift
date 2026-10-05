import Foundation

/// Remote file browser and "Zbierz prace" operations shared by the app and `cmcrctl`.
public extension Operations {

    /// Lists a remote folder (used for browsing, so it is not recorded as a job).
    static func browse(_ path: String, on host: Machine, asRoot: Bool, password: String?, settings: SSHSettings,
                       handle: ProcessHandle? = nil, timeout: TimeInterval = 45) async -> Result<RemoteListing, RemoteBrowseError> {
        let r = await SSH.run(Scripts.listDirectory(path, asRoot: asRoot), on: host, password: password,
                              settings: settings, timeout: timeout, handle: handle)
        guard r.succeeded else { return .failure(RemoteBrowseError.from(r)) }
        guard let listing = Parsers.remoteListing(r.stdout) else {
            return .failure(.failed("Komputer zwrócił nieczytelną listę plików."))
        }
        return .success(listing)
    }

    /// Whether `path` exists as a folder on `host` (quick check used by the folder picker).
    static func folderPresence(_ path: String, on host: Machine, asRoot: Bool, password: String?,
                               settings: SSHSettings, timeout: TimeInterval = 20) async -> FolderPresence {
        let r = await SSH.run(Scripts.folderPresence(path, asRoot: asRoot), on: host, password: password,
                              settings: settings, timeout: timeout)
        guard r.succeeded else {
            switch RemoteBrowseError.from(r) {
            case .noConsoleUser: return .noConsoleUser
            case .unreachable: return .unreachable
            case let e: return .failed(e.localizedDescription)
            }
        }
        switch r.stdoutText.components(separatedBy: "CMCR-FOLDER ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
        case "yes": return .exists
        case "no": return .missing
        case "file": return .notFolder
        default: return .unknown
        }
    }

    /// Downloads items of one remote folder into `localDirectory`. Existing local items are never overwritten:
    /// copies get a " (2)", " (3)"… suffix. Returns the saved items (also after a partial failure).
    static func download(_ names: [String], in folder: String, from host: Machine, into localDirectory: URL,
                         asRoot: Bool, password: String?, settings: SSHSettings, handle: ProcessHandle? = nil,
                         onOutput: Output? = nil) async -> (result: CommandResult, saved: [URL]) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-get-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tmp) }
        onOutput?(.stdout, Data("→ Pobieranie \(names.count == 1 ? "„\(names[0])”" : "\(names.count) elementów") z \(folder)…\n".utf8))
        let r = await SSH.run(Scripts.archiveItems(in: folder, names: names, asRoot: asRoot), on: host,
                              password: password, settings: settings, stdoutFile: tmp, handle: handle, onOutput: onOutput)
        // tar reports unreadable files with exit code 1 but still sends everything else.
        let partial = !r.succeeded && r.exitCode == 1 && Payload.size(of: tmp) > 0 && !r.cancelled && !r.timedOut
        guard r.succeeded || partial else { return (r, []) }
        let (error, saved) = await extract(tmp, into: localDirectory)
        for url in saved { onOutput?(.stdout, Data("✔ \(url.path)\n".utf8)) }
        if let error { return (error, saved) }
        return (partial ? r : CommandResult(exitCode: 0, stderr: r.stderr), saved)
    }

    /// "Zbierz prace": copies the contents of a remote folder into `<folder>/<name>` (a new folder, never merged
    /// with earlier collections). With `cleanAfter`, the collected files that are still unchanged on the Mac are
    /// then deleted there (see `Scripts.removeCollected`), so work saved in the meantime survives.
    /// Returns the local folder with the collected work.
    static func collect(source: String, from host: Machine, into folder: URL, name: String, asRoot: Bool,
                        cleanAfter: Bool, password: String?, settings: SSHSettings, handle: ProcessHandle? = nil,
                        onOutput: Output? = nil) async -> (result: CommandResult, folder: URL?) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cmcr-collect-\(UUID().uuidString).tar")
        defer { try? fm.removeItem(at: tmp) }
        let r = await SSH.run(Scripts.pullArchive(source: source, asRoot: asRoot), on: host, password: password,
                              settings: settings, stdoutFile: tmp, handle: handle, onOutput: onOutput)
        guard r.succeeded else { return (r, nil) }

        let staging = folder.appendingPathComponent(".cmcr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return (.failure("Nie można utworzyć \(folder.path): \(error.localizedDescription)"), nil)
        }
        let x = await ProcessRunner.run("/usr/bin/tar", ["-xf", tmp.path, "-C", staging.path])
        guard x.succeeded else {
            try? fm.removeItem(at: staging)
            return (x, nil)
        }
        let items = ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? []).sorted()
        if items.isEmpty {
            try? fm.removeItem(at: staging)
            rmdir(folder.path)  // only when no other Mac has written into it
            onOutput?(.stdout, Data("Folder \(source) jest pusty – nic do zebrania.\n".utf8))
            return (CommandResult(exitCode: 0), nil)
        }
        let dest = uniqueURL(folder.appendingPathComponent(name, isDirectory: true))
        do {
            try fm.moveItem(at: staging, to: dest)
            // The archive's "./" entry carries the remote folder's mode (e.g. 0700); make the copy browsable.
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {
            try? fm.removeItem(at: staging)
            return (.failure("Nie można zapisać w \(dest.path): \(error.localizedDescription)"), nil)
        }
        let (files, bytes) = contentSummary(dest)
        onOutput?(.stdout, Data("✔ Zebrano \(files) \(plural(files, "plik", "pliki", "plików")) (\(bytes.formatted(.byteCount(style: .file)))) → \(dest.path)\n".utf8))

        guard cleanAfter else { return (CommandResult(exitCode: 0), dest) }
        onOutput?(.stdout, Data("→ Czyszczenie: usuwanie zebranych plików z \(source)…\n".utf8))
        let (collected, folders) = collectedContents(dest)
        // The script travels on the ssh command line, so very large collections are cleaned in parts.
        let chunks = stride(from: 0, to: max(collected.count, 1), by: 800).map {
            Array(collected[$0..<min($0 + 800, collected.count)])
        }
        for (index, chunk) in chunks.enumerated() {
            let last = index == chunks.count - 1
            let c = await SSH.run(Scripts.removeCollected(in: source, files: chunk, folders: last ? folders : [],
                                                          asRoot: true),
                                  on: host, password: password, settings: settings, handle: handle, onOutput: onOutput)
            if !c.succeeded { return (c, dest) }
        }
        return (CommandResult(exitCode: 0), dest)
    }

    /// Files (with the size and time they were collected with) and folders below `root`, folders deepest first.
    static func collectedContents(_ root: URL) -> (files: [CollectedFile], folders: [String]) {
        var files: [CollectedFile] = []
        var folders: [String] = []
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return ([], []) }
        while let rel = e.nextObject() as? String {
            guard let attrs = e.fileAttributes, let type = attrs[.type] as? FileAttributeType else { continue }
            switch type {
            case .typeDirectory:
                folders.append(rel)
            case .typeRegular, .typeSymbolicLink:
                let date = attrs[.modificationDate] as? Date ?? .distantPast
                files.append(CollectedFile(path: rel, modified: Int(date.timeIntervalSince1970.rounded(.down)),
                                           size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                           isLink: type == .typeSymbolicLink))
            default:
                continue
            }
        }
        folders.sort { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            return da != db ? da > db : a < b
        }
        return (files, folders)
    }

    /// `<base>/<yyyy-MM-dd HH.mm>` – the folder one "Zbierz prace" run writes into (one subfolder per Mac).
    static func collectionFolder(base: String, date: Date = Date(), timestamped: Bool = true) -> URL {
        let root = URL(fileURLWithPath: expandTilde(base), isDirectory: true)
        guard timestamped else { return root }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return root.appendingPathComponent(f.string(from: date), isDirectory: true)
    }

    /// Unpacks an archive into `directory` without overwriting anything that is already there.
    /// Returns the failure (if any) and the items saved before it.
    static func extract(_ archive: URL, into directory: URL) async -> (error: CommandResult?, saved: [URL]) {
        let fm = FileManager.default
        let staging = directory.appendingPathComponent(".cmcr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return (.failure("Nie można utworzyć \(directory.path): \(error.localizedDescription)"), [])
        }
        defer { try? fm.removeItem(at: staging) }
        let x = await ProcessRunner.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])
        guard x.succeeded else { return (x, []) }
        var saved: [URL] = []
        for name in ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? []).sorted() {
            let dest = uniqueURL(directory.appendingPathComponent(name))
            do {
                try fm.moveItem(at: staging.appendingPathComponent(name), to: dest)
                saved.append(dest)
            } catch {
                return (.failure("Nie można zapisać \(dest.path): \(error.localizedDescription)"), saved)
            }
        }
        return (nil, saved)
    }

    /// `url` itself, or the first free `name (2).ext`, `name (3).ext`… next to it.
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        func taken(_ u: URL) -> Bool { (try? fm.attributesOfItem(atPath: u.path)) != nil }
        guard taken(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// Number of files and their total size below `url`.
    static func contentSummary(_ url: URL) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let item as URL in e {
                guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(v.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }

    /// Polish plural: 1 plik, 2 pliki, 5 plików, 22 pliki, 12 plików.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if n == 1 { return one }
        let d = n % 10, dd = n % 100
        return (2...4).contains(d) && !(12...14).contains(dd) ? few : many
    }
}

/// Result of `Operations.folderPresence`.
public enum FolderPresence: Equatable, Sendable {
    case exists, missing, notFolder
    /// No permission to look (e.g. a private folder checked without sudo).
    case unknown
    case noConsoleUser, unreachable
    case failed(String)

    public var label: String {
        switch self {
        case .exists: return "jest"
        case .missing: return "brak folderu"
        case .notFolder: return "to plik, nie folder"
        case .unknown: return "brak dostępu"
        case .noConsoleUser: return "nikt nie jest zalogowany"
        case .unreachable: return "niedostępny"
        case .failed(let m): return m
        }
    }
}

/// Preferences of the Files section and the file browser (stored next to settings.json).
public struct FilesPreferences: Codable, Equatable, Sendable {
    /// Local folder for collected work; empty means `<local folder>/zebrane`.
    public var collectFolder = ""
    /// Each collection goes into its own `<date time>` subfolder.
    public var collectTimestamped = true
    public var downloadFolder = "~/Downloads"
    public var recentRemoteFolders: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = FilesPreferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collectFolder = try c.decodeIfPresent(String.self, forKey: .collectFolder) ?? d.collectFolder
        collectTimestamped = try c.decodeIfPresent(Bool.self, forKey: .collectTimestamped) ?? d.collectTimestamped
        downloadFolder = try c.decodeIfPresent(String.self, forKey: .downloadFolder) ?? d.downloadFolder
        recentRemoteFolders = try c.decodeIfPresent([String].self, forKey: .recentRemoteFolders) ?? d.recentRemoteFolders
    }

    static var url: URL { ConfigStore.directory.appendingPathComponent("files.json") }

    public static func load() -> FilesPreferences {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(FilesPreferences.self, from: data) else { return FilesPreferences() }
        return p
    }

    public func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    public func collectBase(_ s: AppSettings) -> String {
        collectFolder.isEmpty ? RemotePaths.join(s.localFolder, "zebrane") : collectFolder
    }

    /// Remembers a remote folder in "Ostatnio używane" (newest first, at most 8).
    public mutating func remember(_ path: String) {
        guard !path.isEmpty else { return }
        recentRemoteFolders.removeAll { $0 == path }
        recentRemoteFolders.insert(path, at: 0)
        if recentRemoteFolders.count > 8 { recentRemoteFolders.removeLast(recentRemoteFolders.count - 8) }
    }
}
