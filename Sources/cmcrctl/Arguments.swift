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
            } else if arg.hasPrefix("-j"), arg.count > 2 {
                values["-j"] = String(arg.dropFirst(2))
            } else if arg.count > 1, arg.hasPrefix("-"), Int(arg) == nil {
                usageError("Nieznana opcja: \(arg) (argument zaczynający się od „-” podaj po --).")
            } else {
                positional.append(arg)
            }
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
