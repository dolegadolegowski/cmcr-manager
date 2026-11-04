import CMCRCore
import Foundation

// `apps installed` (the inventory) and `uninstall` – the terminal side of Aplikacje › Zainstalowane aplikacje.
extension CLI {
    static let inventoryTimeout: TimeInterval = 120

    /// `apps installed [KOMP] [--receipts] [--system] [--json]`: only reads, so no list = every Mac (like status).
    func installedApps() async -> Int32 {
        args.expect("apps", options: Self.parallel.union(["--receipts", "--system", "--json"]), positional: 3)
        let list = targets(args[2], defaultAll: true)
        let json = args.has("--json"), receipts = args.has("--receipts"), system = args.has("--system")
        let ssh = sshSettings()
        let script = Scripts.appInventory(studentUser: settings.studentUser, receipts: receipts)
        let results = ResultBox(count: list.count)
        let makeHeader = header
        let codes = await runHosts(list, jobs: args.jobs ?? max(1, settings.maxParallel), prefixLines: json ? false : prefixLines) { io in
            let r = await SSH.run(script, on: io.host, password: Keychain.password(for: io.host), settings: ssh,
                                  timeout: Self.inventoryTimeout)
            results.set(io.index, r)
            if json { return r.succeeded ? ExitCode.success : ExitCode.failure }
            io.out(makeHeader(io.host))
            guard r.succeeded else { return io.report(r) }
            for line in Self.inventoryLines(AppInventory.parse(r.stdoutText), system: system, receipts: receipts) {
                io.out(line)
            }
            return ExitCode.success
        }
        if json {
            let rows: [[String: Any]] = zip(list, results.all()).map { h, r in
                var row: [String: Any] = ["name": h.name, "destination": h.destination]
                guard let r, r.succeeded else {
                    row["error"] = r.map { SSH.diagnose($0).1 } ?? "Brak wyniku."
                    return row
                }
                let inv = AppInventory.parse(r.stdoutText)
                row["complete"] = inv.complete
                row["mdm"] = inv.mdmEnrolled.map { $0 as Any } ?? NSNull()
                row["apps"] = inv.apps.filter { system || $0.kind != .system }.map(Self.json)
                if receipts {
                    row["packages"] = inv.packages.map { p -> [String: Any] in
                        var d: [String: Any] = ["id": p.id, "version": p.version, "location": p.location]
                        if let t = p.installed { d["installed"] = ISO8601DateFormatter().string(from: t) }
                        return d
                    }
                }
                return row
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                Console.write(.stdout, data + Data("\n".utf8))
            }
        }
        return combine(codes)
    }

    static func json(_ app: InstalledApp) -> [String: Any] {
        // A missing version (neither CFBundleShortVersionString nor CFBundleVersion) is null, not "".
        var d: [String: Any] = ["name": app.name, "path": app.path, "bundleID": app.bundleID,
                                "version": app.version.isEmpty ? NSNull() : app.version as Any,
                                "kind": app.kind.rawValue, "location": app.location, "receipts": app.receipts,
                                "removable": app.isRemovable]
        if let kb = app.sizeKB { d["sizeKB"] = kb }
        if let why = app.reasonNotRemovable { d["notRemovable"] = why }
        return d
    }

    /// One app per line: name, version, size, bundle id, path and – when it is special – its kind.
    static func inventoryLines(_ inv: HostInventory, system: Bool, receipts: Bool) -> [String] {
        func esc(_ s: String) -> String { TerminalText.escape(s, keepBackslash: true) }
        var lines: [String] = []
        let shown = inv.apps.filter { system || $0.kind != .system }
        if !shown.isEmpty {
            lines.append("  " + pad("Aplikacja", 28) + " " + pad("Wersja", 14) + " " + pad("Rozmiar", 9, right: true) + "  "
                         + pad("Identyfikator", 36) + " Ścieżka")
        }
        for app in shown {
            var line = "  " + pad(esc(app.name), 28) + " " + pad(esc(app.versionText), 14) + " "
                + pad(AppInventory.sizeText(app.sizeKB), 9, right: true) + "  " + pad(esc(app.bundleID.isEmpty ? "—" : app.bundleID), 36)
                + " " + esc(app.path)
            if !app.kindLabel.isEmpty { line += "  [\(app.kindLabel)\(app.isRemovable ? "" : ", nie do odinstalowania")]" }
            lines.append(line)
        }
        if shown.isEmpty { lines.append("  (brak aplikacji)") }
        let hidden = inv.apps.count - shown.count
        if hidden > 0 {
            lines.append("  (+ \(plural(hidden, "aplikacja", "aplikacje", "aplikacji")) systemowe macOS – pokaż: --system)")
        }
        if receipts {
            lines.append("  Pakiety instalacyjne spoza Apple (pkgutil): \(inv.packages.count)")
            for p in inv.packages {
                let date = p.installed.map { $0.formatted(date: .numeric, time: .omitted) } ?? ""
                lines.append("    " + pad(esc(p.id), 52) + " " + pad(esc(p.version), 16) + " " + date)
            }
        }
        if inv.mdmEnrolled == true {
            lines.append("  MDM: komputer jest zarządzany przez MDM – aplikacje z MDM mogą wrócić po odinstalowaniu.")
        }
        if !inv.complete { lines.append("  ⚠︎ Lista może być niepełna (skrypt nie zakończył się).") }
        return lines
    }

    /// `uninstall APLIKACJA… KOMP [--dry-run] [--with-package-files]`. At a terminal (without --yes) the dry run is
    /// shown first and the question asked after it; scripts need --yes. --dry-run only shows, changes nothing.
    func uninstall() async -> Int32 {
        let use = "Użycie: cmcrctl uninstall APLIKACJA… KOMP [--dry-run] [--with-package-files]\n"
            + "APLIKACJA: nazwa (Blender) albo ścieżka (/Applications/Blender.app, /Users/{student}/Applications/Gra.app, "
            + "/Applications/Unity/Hub/Editor/6000.3.7f1)."
        args.expect("uninstall", options: Self.parallel.union(["--dry-run", "--with-package-files"]), positional: .max)
        let pos = args.positional
        guard pos.count >= 3 else { usageError(use) }
        let apps = pos[1..<(pos.count - 1)].map(settings.resolve)
        for a in apps where a.contains("/") && !a.hasPrefix("/") {
            usageError("Ścieżka aplikacji musi zaczynać się od / (podano: \(a)).\n" + use)
        }
        let list = targets(pos.last)
        let pkg = args.has("--with-package-files")
        if args.has("--dry-run") { return await runUninstall(on: list, apps, dryRun: true, packageFiles: pkg) }
        var versions = ""
        if !args.yes && isatty(STDIN_FILENO) != 0 {
            Console.err("Podgląd – na komputerach nic jeszcze nie zostało zmienione:")
            let preview = ResultBox(count: list.count)
            _ = await runUninstall(on: list, apps, dryRun: true, packageFiles: pkg, results: preview)
            // Which version goes where, in the question itself (the preview may have scrolled away).
            let reports = zip(list, preview.all()).compactMap { h, r in r.map { (h.name, UninstallReport.parse($0.stdoutText)) } }
            let lines = UninstallReport.versionLines(reports)
            if !lines.isEmpty { versions = " Wersje: " + lines.map { TerminalText.escape($0) }.joined(separator: "; ") + "." }
        }
        let what = apps.count == 1 ? apps[0] : "\(apps.count) aplikacje (\(apps.joined(separator: ", ")))"
        confirm("Odinstalować \(what) na: \(names(list))?\(versions) Uruchomiona aplikacja zostanie zamknięta – niezapisana praca przepadnie.")
        logAction(list)
        return await runUninstall(on: list, apps, dryRun: false, packageFiles: pkg)
    }

    func runUninstall(on list: [Machine], _ apps: [String], dryRun: Bool, packageFiles: Bool,
                      results: ResultBox? = nil) async -> Int32 {
        let ssh = sshSettings()
        let script = Scripts.uninstallApps(apps, studentUser: settings.studentUser, dryRun: dryRun, packageFiles: packageFiles)
        let makeHeader = header
        let codes = await runHosts(list, jobs: args.jobs ?? 1, prefixLines: prefixLines) { io in
            io.out(makeHeader(io.host))
            let renderer = UninstallReport.StreamRenderer()
            let output = renderer.wrap(io.stream)
            let password = Keychain.password(for: io.host)
            // The real run is a registered job: Ctrl-C stops it on the iMac too (Interruption).
            let r = dryRun
                ? await SSH.run(script, on: io.host, password: password, settings: ssh, timeout: Self.inventoryTimeout,
                                onOutput: output)
                : await Interruption.shared.run(script, on: io.host, password: password, settings: ssh, onOutput: output)
            for channel in [OutputChannel.stdout, .stderr] {
                let rest = renderer.finish(channel)
                if !rest.isEmpty { io.write(channel, rest + Data("\n".utf8)) }
            }
            results?.set(io.index, r)
            return io.report(r)
        }
        return combine(codes)
    }
}
