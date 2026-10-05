import CMCRCore
import Foundation

/// File browser commands of `cmcrctl` (ls, mkdir, rm, rename, get, collect).
enum BrowseCLI {
    static let usage = """
      cmcrctl ls nr ścieżka [--all] [--root]    zawartość folderu na iMacu (--all: także ukryte)
      cmcrctl mkdir all|nr ścieżka [-p] [--root]   utwórz folder
      cmcrctl exists all|nr ścieżka [--root]   czy folder istnieje na komputerach
      cmcrctl rm all|nr ścieżka… [--dry-run] [--root]   usuń pliki/foldery (foldery systemowe są chronione)
      cmcrctl rename nr ścieżka nowa-nazwa [--root]   zmień nazwę
      cmcrctl get nr ścieżka… katalog [--root]  pobierz wybrane elementy (z jednego folderu)
      cmcrctl collect all|nr [--from folder] [--to katalog] [--no-date] [--clean] [--root]
                                                zbierz prace do <katalog>/<data godzina>/<host>
    """

    static let commands: Set<String> = ["ls", "exists", "mkdir", "rm", "rename", "get", "collect"]

    struct Context {
        var settings: AppSettings
        var sshSettings: SSHSettings
        var root: Bool
        var select: (String?) -> [Machine]
    }

    static let printer: Operations.Output = { channel, data in
        (channel == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(data)
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func report(_ r: CommandResult) -> Int32 {
        if !r.succeeded {
            let e = RemoteBrowseError.from(r)
            error("✘ \(e.localizedDescription)")
        }
        return r.succeeded ? 0 : (r.exitCode == 0 ? 1 : r.exitCode)
    }

    /// Runs a browser command; `nil` when `command` is not one of them.
    static func run(_ command: String, _ arguments: [String], _ ctx: Context) async -> Int32? {
        guard commands.contains(command) else { return nil }
        var args = Array(arguments.dropFirst())
        var flags = Set<String>()
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--from" || a == "--to", i + 1 < args.count {
                options[a] = args[i + 1]
                args.removeSubrange(i...(i + 1))
            } else if ["--all", "-p", "--clean", "--no-date", "--dry-run"].contains(a) {
                flags.insert(a)
                args.remove(at: i)
            } else {
                i += 1
            }
        }
        let s = ctx.settings
        func path(_ p: String) -> String { s.resolve(p) }

        switch command {
        case "ls":
            guard args.count >= 2, let h = ctx.select(args[0]).first else { error("Użycie: cmcrctl ls nr ścieżka"); return 2 }
            let result = await Operations.browse(path(args[1]), on: h, asRoot: ctx.root,
                                                 password: Keychain.password(for: h), settings: ctx.sshSettings)
            switch result {
            case .failure(let e):
                error("✘ \(e.localizedDescription)")
                return 1
            case .success(let listing):
                printListing(listing, showHidden: flags.contains("--all"))
                return 0
            }

        case "exists":
            guard args.count >= 2 else { error("Użycie: cmcrctl exists all|nr ścieżka"); return 2 }
            let hosts = ctx.select(args[0])
            var missing = 0
            for h in hosts {
                let p = await Operations.folderPresence(path(args[1]), on: h, asRoot: ctx.root,
                                                        password: Keychain.password(for: h), settings: ctx.sshSettings)
                if p != .exists { missing += 1 }
                print("\(h.name): \(p.label)")
            }
            return missing == 0 ? 0 : 1

        case "mkdir":
            guard args.count >= 2 else { error("Użycie: cmcrctl mkdir all|nr ścieżka"); return 2 }
            var status: Int32 = 0
            for h in ctx.select(args[0]) {
                print("\(h.name):")
                let r = await SSH.run(Scripts.makeDirectory(path(args[1]), asRoot: ctx.root, intermediate: flags.contains("-p")),
                                      on: h, password: Keychain.password(for: h), settings: ctx.sshSettings, onOutput: printer)
                status = max(status, report(r))
            }
            return status

        case "rm":
            guard args.count >= 2 else { error("Użycie: cmcrctl rm all|nr ścieżka…"); return 2 }
            var status: Int32 = 0
            for h in ctx.select(args[0]) {
                print("\(h.name):")
                let r = await SSH.run(Scripts.deleteItems(args.dropFirst().map(path), asRoot: ctx.root,
                                                                      dryRun: flags.contains("--dry-run")), on: h,
                                      password: Keychain.password(for: h), settings: ctx.sshSettings, onOutput: printer)
                status = max(status, report(r))
            }
            return status

        case "rename":
            guard args.count == 3, let h = ctx.select(args[0]).first else {
                error("Użycie: cmcrctl rename nr ścieżka nowa-nazwa"); return 2
            }
            let r = await SSH.run(Scripts.renameItem(path(args[1]), to: args[2], asRoot: ctx.root), on: h,
                                  password: Keychain.password(for: h), settings: ctx.sshSettings, onOutput: printer)
            return report(r)

        case "get":
            guard args.count >= 3, let h = ctx.select(args[0]).first else {
                error("Użycie: cmcrctl get nr ścieżka… katalog-lokalny"); return 2
            }
            let items = args[1..<(args.count - 1)].map { RemotePaths.normalize(path($0)) }
            let folders = Set(items.map(RemotePaths.parent(of:)))
            guard folders.count == 1, let folder = folders.first else {
                error("Wszystkie pobierane elementy muszą być w jednym folderze."); return 2
            }
            let local = URL(fileURLWithPath: expandTilde(args[args.count - 1]), isDirectory: true)
            let (r, _) = await Operations.download(items.map(RemotePaths.lastComponent), in: folder, from: h, into: local,
                                                   asRoot: ctx.root, password: Keychain.password(for: h),
                                                   settings: ctx.sshSettings, onOutput: printer)
            return report(r)

        case "collect":
            guard args.count >= 1 else { error("Użycie: cmcrctl collect all|nr"); return 2 }
            let prefs = FilesPreferences.load()
            let source = path(options["--from"] ?? s.sharedFolder)
            let folder = Operations.collectionFolder(base: options["--to"] ?? prefs.collectBase(s),
                                                     timestamped: !flags.contains("--no-date") && prefs.collectTimestamped)
            print("Zbieranie prac z \(source) do \(folder.path)")
            var status: Int32 = 0
            for h in ctx.select(args[0]) {
                print("\(h.name):")
                let (r, _) = await Operations.collect(source: source, from: h, into: folder, name: h.name, asRoot: ctx.root,
                                                      cleanAfter: flags.contains("--clean"),
                                                      password: Keychain.password(for: h), settings: ctx.sshSettings,
                                                      onOutput: printer)
                status = max(status, report(r))
            }
            return status

        default:
            return nil
        }
    }

    static func printListing(_ l: RemoteListing, showHidden: Bool) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        print("\(l.path)  (właściciel \(l.owner):\(l.group), zapis: \(l.writable ? "tak" : "nie")\(l.asRoot ? ", jako root" : ""))")
        let visible = l.entries
            .filter { showHidden || !$0.isHidden }
            .sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        for e in visible {
            let type: String
            switch e.kind {
            case .directory: type = "d"
            case .symlink: type = "l"
            case .file: type = "-"
            case .other: type = "?"
            }
            let size = e.kind == .file ? String(e.size) : "-"
            var name = e.name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
            if e.isFolder { name += "/" }
            if let target = e.linkTarget { name += " -> " + target }
            print("\(type) \(e.permissionString)  \(e.owner.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(repeating: " ", count: max(0, 10 - size.count)))\(size)  \(f.string(from: e.modified))  \(name)")
        }
        let hidden = l.entries.count - visible.count
        var footer = "\(visible.count) \(Operations.plural(visible.count, "element", "elementy", "elementów"))"
        if hidden > 0 { footer += ", ukryte: \(hidden) (pokaż: --all)" }
        if l.truncated { footer += ", pokazano \(l.entries.count) z \(l.total)" }
        print(footer)
    }
}
