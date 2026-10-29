import Foundation
import Testing

/// Every SF Symbol the app names must exist on its deployment target (macOS 14): a newer symbol is drawn as
/// empty space there, so a button or status loses its icon without any warning (AUDIT UI-20). Symbols Apple reserves
/// for its own products and features (apple.logo, safari, macbook…) must not be used for anything else (AUDIT UI-22).
/// The checks use the system's own tables (CoreGlyphs): the release that introduced every symbol, and the
/// restricted ones.
@Suite struct SymbolAvailabilityTests {
    static let resources = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/"
    static let table = URL(fileURLWithPath: resources + "name_availability.plist")
    static let restrictions = URL(fileURLWithPath: resources + "symbol_restrictions.strings")
    static let deploymentTarget = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    /// `systemImage: "…"`, `systemName: "…"`, `icon: "…"`, `symbol: "…"` and the string literals of a ternary or a
    /// `return` on such a line (`systemImage: on ? "a" : "b"`, `var icon: String { … return "a" }`) are `keyed`: they
    /// must be symbols. Any other literal on a line counts only when it is the name of a symbol (positional
    /// arguments such as `FormRowIcon("powerplug")` or `item("photo", …)`).
    static func symbolNames(in source: String) -> [(name: String, line: Int, keyed: Bool)] {
        let keyed = try! NSRegularExpression(pattern: #"(?:systemImage|systemName|icon|symbol)\s*:\s*[^,)\n]*"#)
        let literal = try! NSRegularExpression(pattern: #""([a-z0-9]+(?:\.[a-z0-9]+)*)""#)
        let returned = try! NSRegularExpression(pattern: #"^\s*(?:case [^:]+:\s*)?return\s+"([a-z0-9]+(?:\.[a-z0-9]+)*)""#)
        var out: [(String, Int, Bool)] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            var seen = Set<String>()
            for match in keyed.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let part = ns.substring(with: match.range) as NSString
                for lit in literal.matches(in: part as String, range: NSRange(location: 0, length: part.length)) {
                    let name = part.substring(with: lit.range(at: 1))
                    if seen.insert(name).inserted { out.append((name, index + 1, true)) }
                }
            }
            for match in returned.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                if seen.insert(name).inserted { out.append((name, index + 1, true)) }
            }
            // Other literals: dotted names anywhere, single words only as an argument of an icon-making call.
            let iconCall = line.range(of: #"(Icon|item|Label|Image)\("#, options: .regularExpression) != nil
            for lit in literal.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: lit.range(at: 1))
                guard name.contains(".") || iconCall else { continue }
                if seen.insert(name).inserted { out.append((name, index + 1, false)) }
            }
        }
        return out
    }

    /// The app's and the core library's sources (the core names icons for readiness checks, folders, lesson steps).
    static var appSources: [URL] {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        return ["CMCRManager", "CMCRCore"].flatMap { dir -> [URL] in
            let folder = sources.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            // The embedded setup script is bash text, not Swift UI code.
            return files.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SetupScriptTemplate.swift" }
        }.sorted { $0.path < $1.path }
    }

    /// Every symbol name in the sources with its place.
    static func allUses(known symbols: [String: String]) throws -> [(name: String, place: String)] {
        try appSources.flatMap { file in
            Self.symbolNames(in: try String(contentsOf: file, encoding: .utf8))
                // Words such as "brak" are not symbol names; a keyed name with a dot must be one.
                .filter { symbols[$0.name] != nil || ($0.keyed && $0.name.contains(".")) }
                .map { ($0.name, "\(file.lastPathComponent):\($0.line)") }
        }
    }

    static func version(_ text: String) -> OperatingSystemVersion {
        let p = text.split(separator: ".").map { Int($0) ?? 0 }
        return OperatingSystemVersion(majorVersion: p.first ?? 0, minorVersion: p.count > 1 ? p[1] : 0, patchVersion: 0)
    }

    static func isNewer(_ a: OperatingSystemVersion, than b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion) > (b.majorVersion, b.minorVersion)
    }

    @Test func everySymbolExistsOnTheDeploymentTarget() throws {
        let data = try Data(contentsOf: Self.table)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let symbols = try #require(plist["symbols"] as? [String: String])
        let releases = try #require(plist["year_to_release"] as? [String: [String: String]])
        #expect(Self.appSources.count > 40, "nie znaleziono źródeł aplikacji")
        let uses = try Self.allUses(known: symbols)
        for (name, place) in uses {
            guard let release = symbols[name] else {
                Issue.record("\(place): symbol „\(name)” nie istnieje w SF Symbols")
                continue
            }
            guard let macOS = releases[release]?["macOS"].map(Self.version) else {
                Issue.record("\(place): nieznane wydanie „\(release)” symbolu „\(name)”")
                continue
            }
            #expect(!Self.isNewer(macOS, than: Self.deploymentTarget),
                    "\(place): symbol „\(name)” jest dostępny dopiero od macOS \(macOS.majorVersion).\(macOS.minorVersion)")
        }
        #expect(uses.count > 150, "sprawdzono podejrzanie mało symboli (\(uses.count))")
    }

    /// `Label("Tytuł", systemImage: "symbol")` and `title: "Tytuł", icon: "symbol"` (TargetButton, PowerActionRow,
    /// OptionToggle…) pairs with a literal title, with their places.
    static func labels(in source: String, file: String) -> [(title: String, symbol: String, place: String)] {
        let pairs = [#"Label\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*systemImage:\s*"([^"]+)""#,
                     #"title:\s*"((?:[^"\\]|\\.)*)"\s*,\s*icon:\s*"([^"]+)""#].map { try! NSRegularExpression(pattern: $0) }
        var out: [(String, String, String)] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            for pair in pairs {
            for match in pair.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let title = ns.substring(with: match.range(at: 1))
                guard !title.contains("\\(") else { continue }
                out.append((title, ns.substring(with: match.range(at: 2)), "\(file):\(index + 1)"))
            }
            }
        }
        return out
    }

    /// One action – one symbol (AUDIT UI-08): a title has the same symbol wherever it appears. A filled variant
    /// marks the state the action turned on (the „Jako administrator” badge next to its toggle) and counts as the
    /// same symbol. Three titles name two different things: „Zamknij” (closing a message in this window and
    /// quitting an app on the iMacs), „Otwórz” (a folder in the browser and an address on the iMacs) and „Budzenie
    /// przez sieć” (the Obudź action and the Wake-on-LAN setting).
    @Test func oneTitleOneSymbol() throws {
        let twoActions: Set<String> = ["Zamknij", "Otwórz", "Budzenie przez sieć"]
        var byTitle: [String: [(symbol: String, place: String)]] = [:]
        for file in Self.appSources {
            for use in Self.labels(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent) {
                byTitle[use.title, default: []].append((use.symbol, use.place))
            }
        }
        #expect(byTitle.count > 150, "sprawdzono podejrzanie mało etykiet (\(byTitle.count))")
        func base(_ symbol: String) -> String { symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol }
        for (title, uses) in byTitle.sorted(by: { $0.key < $1.key }) where !twoActions.contains(title) {
            let symbols = Set(uses.map { base($0.symbol) })
            #expect(symbols.count == 1, "„\(title)” ma różne symbole: \(uses.map { "\($0.symbol) (\($0.place))" }.joined(separator: ", "))")
        }
    }

    /// Reading a file into the app and writing one out are opposite actions, so they never share a symbol
    /// (AUDIT UI-08: „Wczytaj listę z pliku…” and „Zapisz skrypt do pliku…” were both square.and.arrow.down).
    @Test func importAndSaveHaveDifferentSymbols() throws {
        var imports: [String: String] = [:], saves: [String: String] = [:]
        for file in Self.appSources {
            for use in Self.labels(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent) {
                if use.title.contains("z pliku") || use.title.hasPrefix("Wczytaj") || use.title.hasPrefix("Importuj") {
                    imports[use.symbol] = "„\(use.title)” (\(use.place))"
                } else if use.title.hasPrefix("Zapisz") || use.title.hasPrefix("Eksportuj") || use.title.contains("do pliku") {
                    saves[use.symbol] = "„\(use.title)” (\(use.place))"
                }
            }
        }
        #expect(!imports.isEmpty && saves.count >= 2, "nie znaleziono akcji wczytywania i zapisu")
        for (symbol, use) in imports {
            if let save = saves[symbol] {
                Issue.record("\(use) i \(save) mają ten sam symbol \(symbol)")
            }
        }
    }

    /// Saving to a file and exporting are one action with one symbol everywhere, square.and.arrow.up (AUDIT UI-27,
    /// UI-29: „Zapisz raport o komputerach (CSV)…” had tablecells while both „Eksportuj CSV…” had the save symbol).
    /// Two „Zapisz” titles keep something in the app instead of writing a file: the password (in the Keychain) and
    /// a snippet of the command editor.
    @Test func everySaveToAFileHasTheSaveSymbol() throws {
        let keptInTheApp: Set<String> = ["Zapisz hasło", "Zapisz jako fragment…"]
        var saves: [(title: String, symbol: String, place: String)] = []
        for file in Self.appSources {
            for use in Self.labels(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
            where !keptInTheApp.contains(use.title)
                && (use.title.hasPrefix("Zapisz") || use.title.hasPrefix("Eksportuj") || use.title.contains("do pliku")) {
                saves.append(use)
            }
        }
        #expect(saves.count >= 8, "sprawdzono podejrzanie mało akcji zapisu (\(saves.count))")
        for use in saves where use.symbol != "square.and.arrow.up" && use.symbol != "square.and.arrow.up.fill" {
            Issue.record("„\(use.title)” (\(use.place)) zapisuje plik, a ma symbol \(use.symbol) zamiast square.and.arrow.up")
        }
    }

    @Test func noSymbolReservedByAppleIsUsed() throws {
        let data = try Data(contentsOf: Self.table)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let symbols = try #require(plist["symbols"] as? [String: String])
        let reserved = try #require(NSDictionary(contentsOf: Self.restrictions) as? [String: String])
        #expect(reserved.count > 100)
        for (name, place) in try Self.allUses(known: symbols) where reserved[name] != nil {
            Issue.record("\(place): symbol „\(name)” jest zastrzeżony: \(reserved[name]!)")
        }
    }
}
