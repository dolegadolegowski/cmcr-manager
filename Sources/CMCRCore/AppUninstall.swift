import Foundation

/// One `CMCR:UN` record of `Scripts.uninstallApps`: `verb`, `what`, `path`, `detail` and any further fields.
public struct UninstallRecord: Hashable, Sendable {
    public enum Verb: String, Sendable {
        /// An app the run works on: detail = name, extra = [version, bundle id, KB, location].
        case target
        /// Dry run: would be removed (detail: KB for app/unity, the label for launchd items, the receipt for files).
        case plan
        /// Dry run: the app is running (detail: accounts, extra: PIDs) and would be quit.
        case running
        case removed, quit, forgot
        /// Left in place on purpose (detail: why; for `pkgfiles` the count, extra: examples separated by „|”).
        case kept
        /// The app itself was refused (protected, not in an allowed place).
        case refused
        case failed
        /// No such app (nothing to do).
        case missing
        case note
        /// Last record: detail = "removed kept failed planned refused dry planKB doneKB".
        case done
    }

    public var verb: Verb
    public var what: String
    public var path: String
    public var detail: String
    public var extra: [String]

    public init(verb: Verb, what: String, path: String, detail: String = "", extra: [String] = []) {
        self.verb = verb
        self.what = what
        self.path = path
        self.detail = detail
        self.extra = extra
    }

    /// Parses one output line; nil for anything that is not a record.
    public init?(line: Substring) {
        guard line.hasPrefix("CMCR:UN\t") else { return nil }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4, let verb = Verb(rawValue: f[1]) else { return nil }
        self.init(verb: verb, what: f[2], path: f[3], detail: f.count > 4 ? f[4] : "", extra: Array(f.dropFirst(5)))
    }

    var kb: Int64? { Int64(detail) }
}

/// Counts from the closing record.
public struct UninstallSummary: Hashable, Sendable {
    public var removed = 0, kept = 0, failed = 0, planned = 0, refused = 0
    public var dryRun = false
    public var plannedKB: Int64 = 0, removedKB: Int64 = 0

    public init() {}

    init?(_ record: UninstallRecord) {
        let n = record.detail.split(separator: " ").map { Int64($0) ?? 0 }
        guard record.verb == .done, n.count >= 8 else { return nil }
        removed = Int(n[0]); kept = Int(n[1]); failed = Int(n[2]); planned = Int(n[3]); refused = Int(n[4])
        dryRun = n[5] == 1; plannedKB = n[6]; removedKB = n[7]
    }
}

/// The result of one uninstall run on one Mac, and its text for people.
public struct UninstallReport: Sendable {
    public var records: [UninstallRecord] = []
    /// Lines that are not records (messages of the tools, the wrapper's errors).
    public var other: [String] = []
    public var summary: UninstallSummary?

    public init() {}

    public static func parse(_ text: String) -> UninstallReport {
        var report = UninstallReport()
        for line in text.split(whereSeparator: \.isNewline) {
            if let r = UninstallRecord(line: line) {
                if r.verb == .done { report.summary = UninstallSummary(r) } else { report.records.append(r) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                report.other.append(String(line))
            }
        }
        return report
    }

    /// Apps the run works on (target records), in order.
    public var targets: [UninstallRecord] { records.filter { $0.verb == .target } }
    public var refusals: [UninstallRecord] { records.filter { $0.verb == .refused } }
    public var failures: [UninstallRecord] { records.filter { $0.verb == .failed } }
    public var notes: [UninstallRecord] { records.filter { $0.verb == .note } }
    /// Dry run: what would go.
    public var planned: [UninstallRecord] { records.filter { $0.verb == .plan } }
    public var hasWork: Bool { !planned.isEmpty }

    /// The whole report as the Polish lines `line(_:)` gives, plus the other lines.
    public func text() -> String {
        var lines = records.compactMap(Self.line)
        lines += other
        if let summary { lines.append(Self.summaryLine(summary)) }
        return lines.joined(separator: "\n")
    }

    /// Converts the records in `text` to Polish lines; other lines stay as they are.
    public static func render(_ text: String) -> String {
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let r = UninstallRecord(line: line) {
                if let s = r.verb == .done ? UninstallSummary(r).map(summaryLine) : Self.line(r) { out.append(s) }
            } else {
                out.append(String(line))
            }
        }
        return out.joined(separator: "\n")
    }

    static func size(_ kb: Int64?) -> String? {
        guard let kb, kb > 0 else { return nil }
        return AppInventory.sizeText(kb)
    }

    static func noun(_ what: String) -> String {
        switch what {
        case "unity": return "edytor Unity (z modułami)"
        case "daemon": return "usługę systemową (LaunchDaemon)"
        case "agent": return "agenta (LaunchAgent)"
        case "uagent": return "agenta konta (LaunchAgent)"
        case "helper": return "program pomocniczy"
        case "pkgfile": return "plik pakietu"
        case "pkgdir": return "pusty folder pakietu"
        case "folder": return "pusty folder"
        case "receipt": return "pakiet"
        default: return "aplikację"
        }
    }

    /// One record for people; nil for records that only carry data.
    public static func line(_ r: UninstallRecord) -> String? {
        let sizeSuffix = size(r.kb).map { " (\($0))" } ?? ""
        switch r.verb {
        case .target:
            let version = r.extra.first.flatMap { $0.isEmpty ? nil : $0 }
            let bid = r.extra.count > 1 && !r.extra[1].isEmpty ? r.extra[1] : nil
            let kb = r.extra.count > 2 ? Int64(r.extra[2]) : nil
            let facts = [version, bid, size(kb)].compactMap { $0 }
            return "▸ \(r.detail)\(facts.isEmpty ? "" : " – " + facts.joined(separator: ", ")): \(r.path)"
        case .plan:
            switch r.what {
            case "app", "unity": return "  • Do usunięcia – \(noun(r.what)): \(r.path)\(sizeSuffix)"
            case "daemon", "agent", "uagent":
                return "  • Do usunięcia – \(noun(r.what)) \(r.detail) (najpierw zatrzymana): \(r.path)"
            case "receipt": return "  • Do wyrejestrowania – pakiet \(r.path) (pkgutil --forget)"
            default: return "  • Do usunięcia – \(noun(r.what)): \(r.path)"
            }
        case .running:
            let pids = r.extra.first.map { " (PID \($0))" } ?? ""
            return "  • Aplikacja jest uruchomiona – konto: \(r.detail)\(pids). Zostanie zamknięta przed usunięciem; niezapisana praca przepadnie."
        case .removed:
            switch r.what {
            case "daemon", "agent", "uagent": return "  ✔ Usunięto \(noun(r.what)) \(r.detail): \(r.path)"
            default: return "  ✔ Usunięto \(noun(r.what)): \(r.path)\(sizeSuffix)"
            }
        case .quit:
            let pids = r.extra.first.map { " (PID \($0))" } ?? ""
            return "  ✔ Zamknięto uruchomioną aplikację – konto: \(r.detail)\(pids)"
        case .forgot:
            return "  ✔ Wyrejestrowano pakiet \(r.path) (pkgutil --forget)"
        case .kept:
            switch r.what {
            case "pkgfiles":
                let n = Int(r.detail) ?? 0
                let examples = r.extra.first.map { $0.split(separator: "|").joined(separator: ", ") } ?? r.path
                return "  ↷ Zostaje \(Polish.count(n, "plik", "pliki", "plików")) pakietu poza aplikacją (np. \(examples)). "
                    + "Aby je usunąć: „Usuń także pliki pakietu” (cmcrctl: --with-package-files)."
            case "receipt": return "  ↷ Zostaje pakiet \(r.path) – \(r.detail)"
            default: return "  ↷ Zostaje \(noun(r.what)): \(r.path) – \(r.detail)"
            }
        case .refused:
            return "✘ Odmowa: \(r.path) – \(r.detail)"
        case .failed:
            if r.what == "receipt" { return "  ✘ Nie udało się wyrejestrować pakietu \(r.path): \(r.detail)" }
            return "  ✘ Nie udało się usunąć \(r.path): \(r.detail)"
        case .missing:
            return "• Nie znaleziono: \(r.path) – \(r.detail)"
        case .note:
            return "  ℹ︎ \(r.detail)"
        case .done:
            return UninstallSummary(r).map(summaryLine)
        }
    }

    /// The last line of a run (also the job's summary in Zadania).
    public static func summaryLine(_ s: UninstallSummary) -> String {
        var parts: [String] = []
        if s.dryRun {
            if s.planned == 0 && s.refused == 0 && s.failed == 0 { return "Podgląd: nic do usunięcia – nic nie zmieniono." }
            parts.append("do usunięcia \(Polish.count(s.planned, "element", "elementy", "elementów"))"
                         + (size(s.plannedKB).map { " (\($0))" } ?? ""))
        } else {
            parts.append("usunięto \(Polish.count(s.removed, "element", "elementy", "elementów"))"
                         + (size(s.removedKB).map { " (\($0))" } ?? ""))
        }
        if s.kept > 0 { parts.append("pozostawiono \(s.kept)") }
        if s.refused > 0 { parts.append("odmowa: \(s.refused)") }
        if s.failed > 0 { parts.append("błędy: \(s.failed)") }
        let text = parts.joined(separator: ", ")
        return (s.dryRun ? "Podgląd: " : "Wynik: ") + text + (s.dryRun ? " – nic jeszcze nie zmieniono." : ".")
    }

    /// Converts the records of a streamed run line by line (cmcrctl, the app's Zadania); a line split across chunks
    /// waits for its end. Not thread-safe: one renderer per Mac and channel use.
    public final class StreamRenderer: @unchecked Sendable {
        private var pending: [OutputChannel: Data] = [:]
        private let lock = NSLock()

        public init() {}

        public func feed(_ channel: OutputChannel, _ data: Data) -> Data {
            lock.lock()
            defer { lock.unlock() }
            var buffer = (pending[channel] ?? Data()) + data
            var out = Data()
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                out += Self.convert(Data(line)) + Data([0x0A])
                buffer = Data(buffer[buffer.index(after: nl)...])
            }
            pending[channel] = buffer
            return out
        }

        /// What is left after the last line break, converted.
        public func finish(_ channel: OutputChannel) -> Data {
            lock.lock()
            defer { lock.unlock() }
            let rest = pending[channel] ?? Data()
            pending[channel] = nil
            return rest.isEmpty ? Data() : Self.convert(rest)
        }

        static func convert(_ line: Data) -> Data {
            guard line.starts(with: Data("CMCR:UN\t".utf8)) else { return line }
            let text = String(decoding: line, as: UTF8.self)
            guard let r = UninstallRecord(line: Substring(text)) else { return line }
            let human = r.verb == .done ? UninstallSummary(r).map(UninstallReport.summaryLine) : UninstallReport.line(r)
            return Data((human ?? "").utf8)
        }

        /// Wraps an output callback: records arrive converted, everything else unchanged.
        public func wrap(_ output: @escaping Operations.Output) -> Operations.Output {
            { [self] channel, data in
                let converted = self.feed(channel, data)
                if !converted.isEmpty { output(channel, converted) }
            }
        }
    }
}
