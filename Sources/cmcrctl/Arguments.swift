import Foundation

/// Command line split into positional arguments, boolean flags and options with values.
/// Flags may appear anywhere; everything after `--` is positional.
struct Arguments: Sendable {
    static let flags: Set<String> = [
        "--root", "--force", "--restart", "--download", "--recommended", "--notification", "--json", "--prefix",
        "--dry-run", "--append", "--replace", "--yes", "-y", "--help", "-h",
    ]
    static let valueOptions: Set<String> = ["-j", "--jobs", "--host", "--port", "--mac", "--start", "--count", "--digits", "--domain"]

    var positional: [String] = []
    var present: Set<String> = []
    var values: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            i += 1
            if arg == "--" {
                positional += argv[i...]
                break
            }
            if Self.flags.contains(arg) {
                present.insert(arg)
            } else if Self.valueOptions.contains(arg) {
                guard i < argv.count else { usageError("Brak wartości dla \(arg).") }
                values[arg] = argv[i]
                i += 1
            } else if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "="),
                      Self.valueOptions.contains(String(arg[..<eq])) {
                values[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
            } else if arg.hasPrefix("-j"), arg.count > 2, arg.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) {
                values["-j"] = String(arg.dropFirst(2))
            } else if Self.looksLikeOption(arg) {
                usageError("Nieznana opcja: \(arg) (argument zaczynający się od „-” podaj po --).")
            } else {
                positional.append(arg)
            }
        }
    }

    /// `-x`, `--name` or `--name=value`. Text such as "-5 minut", "- przerwa" or "-3" stays positional.
    static func looksLikeOption(_ arg: String) -> Bool {
        let name = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let body = name.hasPrefix("--") ? name.dropFirst(2) : name.hasPrefix("-") ? name.dropFirst() : ""
        guard let first = body.first, first.isASCII, first.isLetter else { return false }
        return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static let aliases = ["--jobs": "-j", "-y": "--yes", "-h": "--help"]

    /// Rejects options the command does not use and surplus positional arguments (`positional` counts the
    /// command word), so a misplaced `--host 4` or an extra `5` never silently changes which Macs are used.
    /// `--yes` is accepted everywhere: it only skips confirmations.
    func expect(_ command: String, options allowed: Set<String> = [], positional max: Int) {
        let accepted = Set(allowed.map { Self.aliases[$0] ?? $0 }).union(["--yes", "--help"])
        for name in present.union(values.keys).sorted() where !accepted.contains(Self.aliases[name] ?? name) {
            usageError("Opcja \(name) nie dotyczy polecenia \(command).")
        }
        if positional.count > max {
            usageError("Nadmiarowy argument „\(positional[max])” w poleceniu \(command). Kilka komputerów podaj razem "
                       + "(1,3 lub 1-5), a tekst ze spacjami – w cudzysłowie.")
        }
    }

    func has(_ flag: String) -> Bool { present.contains(flag) }

    func value(_ option: String) -> String? { values[option] }

    subscript(_ index: Int) -> String? { index < positional.count ? positional[index] : nil }

    func int(_ option: String, in range: ClosedRange<Int>) -> Int? {
        guard let raw = value(option) else { return nil }
        guard let n = Int(raw), range.contains(n) else {
            usageError("\(option): oczekiwano liczby \(range.lowerBound)–\(range.upperBound), podano „\(raw)”.")
        }
        return n
    }

    /// `-j N` / `--jobs N` / `-jN`.
    var jobs: Int? {
        if let j = values["-j"] ?? values["--jobs"] {
            guard let n = Int(j), n >= 1 else { usageError("-j: oczekiwano liczby ≥ 1, podano „\(j)”.") }
            return n
        }
        return nil
    }

    var yes: Bool { has("--yes") || has("-y") }
}
