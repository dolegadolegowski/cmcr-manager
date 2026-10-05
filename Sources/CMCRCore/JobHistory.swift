import Foundation
import SystemConfiguration

/// One finished job (one operation on one Mac) as written to the persistent job history.
public struct JobRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var batchID: UUID
    public var title: String
    public var section: String?
    /// Who ran it: local account @ this Mac's name.
    public var operatorName: String
    public var hostID: UUID
    public var host: String
    public var address: String
    /// succeeded | failed | cancelled | skipped
    public var state: String
    public var exitCode: Int32?
    public var batchStartedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date
    public var durationMs: Int?
    public var summary: String
    /// Full output, relative to the history directory.
    public var outputFile: String?
    public var outputBytes: Int

    public init(id: UUID, batchID: UUID, title: String, section: String?, operatorName: String, hostID: UUID,
                host: String, address: String, state: String, exitCode: Int32?, batchStartedAt: Date,
                startedAt: Date?, finishedAt: Date, summary: String, outputFile: String?, outputBytes: Int) {
        self.id = id
        self.batchID = batchID
        self.title = title
        self.section = section
        self.operatorName = operatorName
        self.hostID = hostID
        self.host = host
        self.address = address
        self.state = state
        self.exitCode = exitCode
        self.batchStartedAt = batchStartedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = startedAt.map { Int(finishedAt.timeIntervalSince($0) * 1000) }
        self.summary = summary
        self.outputFile = outputFile
        self.outputBytes = outputBytes
    }

    public var succeeded: Bool { state == "succeeded" }
}

/// Batch-level view over history records (one action on many Macs).
public struct HistoryBatch: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var section: String?
    public var startedAt: Date
    public var records: [JobRecord]

    public var succeeded: Int { records.filter(\.succeeded).count }
    public var failed: Int { records.filter { $0.state == "failed" }.count }
    public var finishedAt: Date { records.map(\.finishedAt).max() ?? startedAt }
}

/// Persistent audit trail: `history/jobs-YYYY-MM.jsonl` (one JSON object per job) plus the full output of every
/// job in `history/output/YYYY-MM-DD/<batch>/<host>-<job>.log`, under the configuration directory.
public enum JobHistory {
    public static var directory: URL { ConfigStore.directory.appendingPathComponent("history", isDirectory: true) }

    private static let queue = DispatchQueue(label: "pl.cmcr.manager.history")

    /// Computer name from the local configuration store (no DNS lookup, unlike `Host.current()`).
    public static let operatorName: String = {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        return "\(NSUserName())@\(computer)"
    }()

    static func monthFile(for date: Date, in dir: URL) -> URL {
        dir.appendingPathComponent("jobs-\(stamp(date, "yyyy-MM")).jsonl")
    }

    static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = precise.date(from: s) ?? plain.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Zła data: \(s)"))
            }
            return date
        }
        return d
    }

    /// One JSONL line (JSON never contains raw line breaks, so a record is always exactly one line).
    public static func encodeLine(_ record: JobRecord) throws -> Data {
        var data = try encoder().encode(record)
        data.append(0x0A)
        return data
    }

    /// Decodes JSONL, skipping blank or damaged lines (e.g. a write cut short by a crash).
    public static func decodeLines(_ data: Data) -> [JobRecord] {
        let d = decoder()
        return data.split(separator: 0x0A).compactMap { line in
            line.isEmpty ? nil : try? d.decode(JobRecord.self, from: Data(line))
        }
    }

    /// Relative path for the output of one job.
    public static func outputPath(batchID: UUID, batchStartedAt: Date, host: String, jobID: UUID) -> String {
        let safeHost = host.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" ? $0 : "_" }
        return "output/\(stamp(batchStartedAt, "yyyy-MM-dd"))/\(batchID.uuidString.prefix(8).lowercased())/"
            + "\(String(safeHost))-\(jobID.uuidString.prefix(8).lowercased()).log"
    }

    /// Writes the output file and appends the record. Synchronous; the app calls it through `record(_:output:)`.
    public static func write(_ record: JobRecord, output: String?, in dir: URL = directory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let output, let rel = record.outputFile {
            let url = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(output.utf8).write(to: url, options: .atomic)
        }
        let line = try encodeLine(record)
        let file = monthFile(for: record.finishedAt, in: dir)
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: file, options: .atomic)
        }
    }

    /// Queues `write` on a background serial queue (keeps disk I/O off the main thread, preserves order).
    public static func record(_ record: JobRecord, output: String?, in dir: URL = directory,
                              completion: (@Sendable (URL?) -> Void)? = nil) {
        queue.async {
            do {
                try write(record, output: output, in: dir)
                completion?(record.outputFile.map { dir.appendingPathComponent($0) })
            } catch {
                ConfigStore.log("Historia zadań: zapis nieudany – \(error.localizedDescription)")
                completion?(nil)
            }
        }
    }

    /// Newest records first, at most `limit`, reading month files from the newest.
    public static func load(limit: Int = 3000, in dir: URL = directory) -> [JobRecord] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("jobs-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var result: [JobRecord] = []
        for f in files {
            guard let data = try? Data(contentsOf: f) else { continue }
            result += decodeLines(data).sorted { $0.finishedAt > $1.finishedAt }
            if result.count >= limit { break }
        }
        return Array(result.sorted { $0.finishedAt > $1.finishedAt }.prefix(limit))
    }

    /// Groups records into batches, newest first.
    public static func batches(_ records: [JobRecord]) -> [HistoryBatch] {
        Dictionary(grouping: records, by: \.batchID).map { id, recs in
            let first = recs[0]
            return HistoryBatch(id: id, title: first.title, section: first.section, startedAt: first.batchStartedAt,
                                records: recs.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending })
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    public static func outputURL(for record: JobRecord, in dir: URL = directory) -> URL? {
        record.outputFile.map { dir.appendingPathComponent($0) }
    }

    /// Purges old history on the history queue (called at app start).
    public static func purgeInBackground(olderThan days: Int = 90) {
        queue.async { purge(olderThan: days) }
    }

    /// Removes output folders and month files older than `days`.
    public static func purge(olderThan days: Int, now: Date = Date(), in dir: URL = directory) {
        let fm = FileManager.default
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let dayCut = stamp(cutoff, "yyyy-MM-dd"), monthCut = stamp(cutoff, "yyyy-MM")
        let outDir = dir.appendingPathComponent("output")
        for name in (try? fm.contentsOfDirectory(atPath: outDir.path)) ?? [] where name.count == 10 && name < dayCut {
            try? fm.removeItem(at: outDir.appendingPathComponent(name))
        }
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("jobs-") && name.hasSuffix(".jsonl") {
            let month = String(name.dropFirst(5).prefix(7))
            if month.count == 7 && month < monthCut { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }
}
