import CMCRCore
import Foundation

/// File browser commands of `cmcrctl` (ls, mkdir, rm, rename, get, collect).
enum BrowseCLI {
    static let usage = """
      cmcrctl ls nr ścieżka [--all] [--root]    zawartość folderu na iMacu (--all: także ukryte)
      cmcrctl mkdir KOMP ścieżka [-p] [--root]  utwórz folder
      cmcrctl exists KOMP ścieżka [--root]      czy folder istnieje na komputerach
      cmcrctl rm KOMP ścieżka… [--dry-run] [--root]   usuń pliki/foldery (foldery systemowe są chronione)
      cmcrctl rename nr ścieżka nowa-nazwa [--root]   zmień nazwę pliku lub folderu
      cmcrctl get nr ścieżka… katalog [--root]  pobierz wybrane elementy (z jednego folderu)
      cmcrctl collect KOMP [--from folder] [--to katalog] [--no-date] [--clean] [--root]
                                                zbierz prace do <katalog>/<data godzina>/<host>
    """

    static let specs: [String: ModuleSpec] = [
        "ls": ModuleSpec(flags: ["--all", "--root"], maxPositional: 2),
        "exists": ModuleSpec(flags: ["--root"], maxPositional: 2, parallel: true),
        "mkdir": ModuleSpec(flags: ["-p", "--root"], maxPositional: 2, parallel: true),
        "rm": ModuleSpec(flags: ["--dry-run", "--root"], parallel: true),
        "rename": ModuleSpec(flags: ["--root"], maxPositional: 3),
        "get": ModuleSpec(flags: ["--root"]),
        "collect": ModuleSpec(flags: ["--no-date", "--clean", "--root"], values: ["--from", "--to"], maxPositional: 1,
                              parallel: true),
    ]

    struct Context {
        var settings: AppSettings
        var ssh: SSHSettings
    }

    /// Prints the failure of a browser script (on `io`, or straight to stderr); 0 or 1.
    static func report(_ r: CommandResult, _ io: HostIO? = nil) -> Int32 {
        guard !r.succeeded else { return ExitCode.success }
        let message = "✘ \(RemoteBrowseError.from(r).localizedDescription)"
        if let io { io.err(message) } else { Console.err(message) }
        return ExitCode.failure
    }

    /// Runs a browser command (`arguments` without the command word).
    static func run(_ command: String, _ arguments: [String], _ ctx: Context) async -> Int32 {
        let a = ModuleArguments.parse(command, arguments, specs[command] ?? ModuleSpec())
        let s = ctx.settings, ssh = ctx.ssh, asRoot = a.root
        func path(_ p: String) -> String { s.resolve(p) }
        func use(_ text: String) -> Never { moduleUsageError(command, "Użycie: \(text)") }

        switch command {
        case "ls":
            guard a.positional.count == 2 else { use("cmcrctl ls nr ścieżka [--all] [--root]") }
            let h = ModuleHosts.one(a[0], command, usage: "Użycie: cmcrctl ls nr ścieżka – podaj jeden komputer.")
            let result = await Operations.browse(path(a.positional[1]), on: h, asRoot: asRoot,
                                                 password: Keychain.password(for: h), settings: ssh)
            switch result {
            case .failure(let e):
                Console.err("✘ \(e.localizedDescription)")
                return ExitCode.failure
            case .success(let listing):
                printListing(listing, showHidden: a.has("--all"))
                return ExitCode.success
            }

        case "exists":
            guard a.positional.count == 2 else { use("cmcrctl exists KOMP ścieżka [--root]") }
            let list = legacyCLI.targets(a[0])
            let p = path(a.positional[1])
            return await eachHost(list, a, header: false) { io in
                let presence = await Operations.folderPresence(p, on: io.host, asRoot: asRoot,
                                                               password: Keychain.password(for: io.host), settings: ssh)
                io.out("\(io.host.name): \(presence.label)")
                return presence == .exists ? ExitCode.success : ExitCode.failure
            }

        case "mkdir":
            guard a.positional.count == 2 else { use("cmcrctl mkdir KOMP ścieżka [-p] [--root]") }
            let list = legacyCLI.targets(a[0])
            let p = path(a.positional[1]), intermediate = a.has("-p")
            return await eachHost(list, a) { io in
                let r = await SSH.run(Scripts.makeDirectory(p, asRoot: asRoot, intermediate: intermediate), on: io.host,
                                      password: Keychain.password(for: io.host), settings: ssh, onOutput: io.stream)
                return report(r, io)
            }

        case "rm":
            guard a.positional.count >= 2 else { use("cmcrctl rm KOMP ścieżka… [--dry-run] [--root]") }
            let list = legacyCLI.targets(a[0])
            let items = a.positional.dropFirst().map(path)
            let dryRun = a.has("--dry-run")
            if !dryRun {
                let what = items.count == 1 ? items[0] : plural(items.count, "element", "elementy", "elementów")
                CLI.confirm("Usunąć \(what) na: \(ModuleHosts.names(list))?", yes: a.yes)
            }
            return await eachHost(list, a) { io in
                let r = await SSH.run(Scripts.deleteItems(items, asRoot: asRoot, dryRun: dryRun), on: io.host,
                                      password: Keychain.password(for: io.host), settings: ssh, onOutput: io.stream)
                return report(r, io)
            }

        case "rename":
            guard a.positional.count == 3 else { use("cmcrctl rename nr ścieżka nowa-nazwa [--root]") }
            let h = ModuleHosts.one(a[0], command, usage: "Użycie: cmcrctl rename nr ścieżka nowa-nazwa – podaj jeden komputer.")
            let r = await SSH.run(Scripts.renameItem(path(a.positional[1]), to: a.positional[2], asRoot: asRoot), on: h,
                                  password: Keychain.password(for: h), settings: ssh, onOutput: Console.printer)
            return report(r)

        case "get":
            guard a.positional.count >= 3 else { use("cmcrctl get nr ścieżka… katalog-lokalny [--root]") }
            let h = ModuleHosts.one(a[0], command, usage: "Użycie: cmcrctl get nr ścieżka… katalog – podaj jeden komputer.")
            let items = a.positional[1..<(a.positional.count - 1)].map { RemotePaths.normalize(path($0)) }
            let folders = Set(items.map(RemotePaths.parent(of:)))
            guard folders.count == 1, let folder = folders.first else {
                moduleUsageError(command, "Wszystkie pobierane elementy muszą być w jednym folderze.")
            }
            let local = URL(fileURLWithPath: expandTilde(a.positional[a.positional.count - 1]), isDirectory: true)
            let (r, _) = await Operations.download(items.map(RemotePaths.lastComponent), in: folder, from: h, into: local,
                                                   asRoot: asRoot, password: Keychain.password(for: h),
                                                   settings: ssh, onOutput: Console.printer)
            return report(r)

        case "collect":
            guard a.positional.count == 1 else {
                use("cmcrctl collect KOMP [--from folder] [--to katalog] [--no-date] [--clean] [--root]")
            }
            let list = legacyCLI.targets(a[0])
            let prefs = FilesPreferences.load()
            let source = path(a.value("--from") ?? s.sharedFolder)
            let folder = Operations.collectionFolder(base: a.value("--to") ?? prefs.collectBase(s),
                                                     timestamped: !a.has("--no-date") && prefs.collectTimestamped)
            let clean = a.has("--clean")
            if clean {
                CLI.confirm("Zebrać prace z \(source) i usunąć zebrane pliki z komputerów: \(ModuleHosts.names(list))?",
                            yes: a.yes)
            }
            Console.out("Zbieranie prac z \(source) do \(folder.path)")
            return await eachHost(list, a) { io in
                let (r, _) = await Operations.collect(source: source, from: io.host, into: folder, name: io.host.name,
                                                      asRoot: asRoot, cleanAfter: clean,
                                                      password: Keychain.password(for: io.host), settings: ssh,
                                                      onOutput: io.stream)
                return report(r, io)
            }

        default:
            moduleUsageError(command, fullUsage)
        }
    }

    /// Names, owners and link targets come from the iMac: escaped, so a file name cannot drive the terminal
    /// or break the one-entry-per-line layout (also when the output goes to a file).
    static func printListing(_ l: RemoteListing, showHidden: Bool) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let esc = { TerminalText.escape($0) }
        Console.out("\(esc(l.path))  (właściciel \(esc(l.owner)):\(esc(l.group)), zapis: \(l.writable ? "tak" : "nie")\(l.asRoot ? ", jako root" : ""))")
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
            var name = esc(e.name)
            if e.isFolder { name += "/" }
            if let target = e.linkTarget { name += " -> " + esc(target) }
            Console.out("\(type) \(e.permissionString)  \(esc(e.owner).padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(repeating: " ", count: max(0, 10 - size.count)))\(size)  \(f.string(from: e.modified))  \(name)")
        }
        let hidden = l.entries.count - visible.count
        var footer = "\(visible.count) \(Operations.plural(visible.count, "element", "elementy", "elementów"))"
        if hidden > 0 { footer += ", ukryte: \(hidden) (pokaż: --all)" }
        if l.truncated { footer += ", pokazano \(l.entries.count) z \(l.total)" }
        Console.out(footer)
    }
}
