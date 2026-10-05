import CMCRCore
import Foundation

/// What a module command (lesson, lock, rm, install, …) accepts. These commands parse their own options,
/// with the same rules as `Arguments.expect` for the core commands: an option the command does not use or a
/// surplus argument is a usage error (exit 2) before any Mac is contacted.
struct ModuleSpec {
    var flags: Set<String> = []
    /// Options followed by a value (`--message "…"` or `--message=…`).
    var values: Set<String> = []
    /// Positional arguments after the command word; nil = any number.
    var maxPositional: Int?
    /// Runs on several Macs through `runHosts`: accepts `-j N` and `--prefix`.
    var parallel = false
}

/// Arguments of one module command, parsed by `ModuleArguments.parse`.
struct ModuleArguments {
    let command: String
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var jobs: Int?
    var prefix = false
    var yes = false

    subscript(_ index: Int) -> String? { index < positional.count ? positional[index] : nil }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ option: String) -> String? { values[option] }
    var root: Bool { has("--root") }

    /// `--name N` given as a whole number in `range`, or nil when the option is absent.
    func int(_ option: String, in range: ClosedRange<Int>) -> Int? {
        guard let raw = values[option] else { return nil }
        guard let n = Int(raw), range.contains(n) else {
            moduleUsageError(command, "\(option): oczekiwano liczby \(range.lowerBound)–\(range.upperBound), podano „\(raw)”.")
        }
        return n
    }

    /// `--help`/`-h` anywhere before `--`, or `help` as the only argument: show the command's help instead of
    /// running it (a module command without a host list would otherwise run on every Mac).
    static func wantsHelp(_ args: [String]) -> Bool {
        let options = args.prefix { $0 != "--" }
        return options.contains("--help") || options.contains("-h") || args == ["help"]
    }

    /// Exits with code 2 on anything `spec` does not allow.
    static func parse(_ command: String, _ args: [String], _ spec: ModuleSpec) -> ModuleArguments {
        var a = ModuleArguments(command: command)
        var i = 0
        func reject(_ option: String) -> Never {
            if knownOptions.contains(option) {
                moduleUsageError(command, "Opcja \(option) nie dotyczy polecenia \(command).")
            }
            moduleUsageError(command, "Nieznana opcja: \(option) (argument zaczynający się od „-” podaj po --).")
        }
        while i < args.count {
            let arg = args[i]
            i += 1
            if arg == "--" {
                a.positional += args[i...]
                break
            }
            let (name, inline) = splitOption(arg)
            if arg == "--yes" || arg == "-y" {
                a.yes = true
            } else if spec.flags.contains(arg) {
                a.flags.insert(arg)
            } else if spec.values.contains(name) {
                if let inline {
                    a.values[name] = inline
                } else {
                    guard i < args.count else { moduleUsageError(command, "Brak wartości dla \(name).") }
                    a.values[name] = args[i]
                    i += 1
                }
            } else if name == "-j" || name == "--jobs" || (arg.hasPrefix("-j") && arg.count > 2
                                                              && arg.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber })) {
                guard spec.parallel else { reject("-j") }
                let raw: String
                if let inline { raw = inline } else if arg.count > 2 && !arg.hasPrefix("--") { raw = String(arg.dropFirst(2)) } else {
                    guard i < args.count else { moduleUsageError(command, "Brak wartości dla \(name).") }
                    raw = args[i]
                    i += 1
                }
                guard let n = Int(raw), n >= 1 else { moduleUsageError(command, "-j: oczekiwano liczby ≥ 1, podano „\(raw)”.") }
                a.jobs = n
            } else if arg == "--prefix" {
                guard spec.parallel else { reject(arg) }
                a.prefix = true
            } else if Arguments.looksLikeOption(arg) {
                reject(name)
            } else {
                a.positional.append(arg)
            }
        }
        if let max = spec.maxPositional, a.positional.count > max {
            moduleUsageError(command, "Nadmiarowy argument „\(a.positional[max])” w poleceniu \(command). Kilka komputerów "
                             + "podaj razem (1,3 lub 1-5), a tekst ze spacjami – w cudzysłowie.")
        }
        return a
    }

    /// `--opt=value` → ("--opt", "value"); anything else → (arg, nil).
    private static func splitOption(_ arg: String) -> (String, String?) {
        guard arg.hasPrefix("-"), let eq = arg.firstIndex(of: "=") else { return (arg, nil) }
        return (String(arg[..<eq]), String(arg[arg.index(after: eq)...]))
    }

    /// Options of any cmcrctl command: these get "does not apply to this command" instead of "unknown".
    static let knownOptions: Set<String> = Arguments.flags.union(Arguments.valueOptions).union([
        "--message", "--mode", "--minutes", "--buttons", "--timeout", "--on", "--off", "--on-type", "--off-type",
        "--no-autorestart", "--no-womp", "--name", "--update-list", "--warn", "--no-wait", "--all", "-p", "--from",
        "--to", "--no-date", "--clean", "--frames", "--interval", "--size", "--display", "--notified-user",
    ])
}

/// Prints the problem and where to find help, exits with code 2.
func moduleUsageError(_ command: String, _ message: String) -> Never {
    Console.err(message)
    Console.err("Pomoc: cmcrctl \(command) --help")
    exit(ExitCode.usage)
}

/// Help of one command: its lines from the usage texts, plus the rules shared by the module commands.
func commandHelp(_ command: String, spec: ModuleSpec? = nil) -> String {
    var lines: [String] = []
    for text in [usage, ExtraCommands.usage] {
        let all = text.components(separatedBy: "\n")
        var i = 0
        while i < all.count {
            let line = all[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let body = trimmed.hasPrefix("cmcrctl ") ? String(trimmed.dropFirst("cmcrctl ".count)) : trimmed
            guard line.hasPrefix(" "), body == command || body.hasPrefix(command + " ") else { i += 1; continue }
            let indent = line.prefix { $0 == " " }.count
            lines.append("  cmcrctl " + body)
            i += 1
            // Continuation lines: indented deeper, not another command.
            while i < all.count {
                let next = all[i]
                let nextIndent = next.prefix { $0 == " " }.count
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                guard !nextTrimmed.isEmpty, nextIndent > indent + 2, !nextTrimmed.hasPrefix("cmcrctl ") else { break }
                lines.append("  " + String(repeating: " ", count: max(0, nextIndent - indent)) + nextTrimmed)
                i += 1
            }
        }
    }
    guard !lines.isEmpty else { return fullUsage }
    var help = "Użycie:\n" + lines.joined(separator: "\n") + "\n\n"
    help += "KOMP: all | numer z nazwy (4 → imac04) | lista (1,3,7) | zakres (1-5) | pozycja na liście (@2) | nazwa.\n"
    help += "Bez KOMP polecenie, które coś zmienia, działa na wszystkich komputerach tylko w terminalu; w skryptach "
        + "trzeba podać KOMP, np. all.\n"
    if let spec, spec.parallel {
        help += "-j N, --prefix: N komputerów naraz (wyniki w kolejności listy), nazwa komputera przed każdym wierszem.\n"
    }
    help += "--yes, -y: bez pytania o potwierdzenie (bez terminala wymagane przy poleceniach, które o nie pytają).\n"
    help += "Kody wyjścia: 0 – sukces, 1 – błąd na co najmniej jednym komputerze, 2 – błędne użycie (nic nie wykonano).\n"
    help += "Wszystkie polecenia: cmcrctl --help"
    return help
}
