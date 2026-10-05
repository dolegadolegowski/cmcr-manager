import Foundation

/// Collects text streamed from background threads so that the UI takes it over in batches (at most once
/// per flush interval) instead of once per pipe chunk.
public final class OutputCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var scheduled = false

    public init() {}

    /// Adds text. Returns true when the caller has to schedule a `drain()` – i.e. for the first text that
    /// arrives after the previous drain; later chunks ride along with the already scheduled one.
    @discardableResult
    public func add(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        pending += text
        if scheduled { return false }
        scheduled = true
        return true
    }

    /// Takes everything collected so far and re-arms scheduling.
    public func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = pending
        pending = ""
        scheduled = false
        return text
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty
    }
}

/// Keeps the last non-blank line of a growing log without rescanning the whole text on every append.
public struct LastLineTracker: Sendable {
    /// Text after the last line break (a line still being written, e.g. a progress indicator).
    private var partial = ""
    private var lastComplete = ""
    public private(set) var lastLine = ""

    static let maxPartial = 4096

    public init() {}

    public mutating func consume(_ text: String) {
        guard !text.isEmpty else { return }
        let combined = partial + text
        if let cut = combined.lastIndex(where: \.isNewline) {
            let complete = combined[..<cut]
            partial = String(combined[combined.index(after: cut)...])
            if let line = complete.split(whereSeparator: \.isNewline).last(where: { !Self.isBlank($0) }) {
                lastComplete = line.trimmingCharacters(in: .whitespaces)
            }
        } else {
            partial = combined
        }
        if partial.utf8.count > Self.maxPartial { partial = String(partial.suffix(Self.maxPartial / 2)) }
        lastLine = Self.isBlank(Substring(partial)) ? lastComplete : partial.trimmingCharacters(in: .whitespaces)
    }

    public mutating func reset() { self = LastLineTracker() }

    private static func isBlank(_ s: Substring) -> Bool { s.allSatisfy(\.isWhitespace) }
}

/// Text that keeps only the newest part once it grows past `limit` UTF-8 bytes.
public struct BoundedText: Sendable {
    public static let marker = "…(początek wyniku pominięty – zachowano tylko ostatnią część)…\n"

    public let limit: Int
    public private(set) var text = ""
    /// Incremented whenever the beginning of the text is dropped (views that append incrementally reload).
    public private(set) var generation = 0

    public init(limit: Int) { self.limit = max(64, limit) }

    public mutating func append(_ s: String) {
        text += s
        if text.utf8.count > limit { keepLast(limit / 2) }
    }

    /// Drops everything but the last `bytes` UTF-8 bytes (cut on a character boundary).
    public mutating func keepLast(_ bytes: Int, marker: String = BoundedText.marker) {
        let u = text.utf8
        guard u.count > bytes else { return }
        var cut = u.index(u.endIndex, offsetBy: -bytes)
        // Never start inside a multi-byte sequence.
        while cut < u.endIndex, u[cut] & 0xC0 == 0x80 { cut = u.index(after: cut) }
        text = marker + String(decoding: u[cut...], as: UTF8.self)
        generation += 1
    }

    public mutating func replace(with s: String) {
        text = s
        generation += 1
    }
}
