import Foundation

// The socket protocol `CMCRA1` (docs/screen-agent.md › Protokół gniazda): one request line per connection, the agent
// answers and closes. Fields are separated by a single space; text that comes from people or apps travels in
// base64 (`Base64Field`), so a field never contains a space or a line break.

/// A malformed request or reply.
public struct ProtocolError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Text fields on the wire. An empty text is sent as `-` (an empty field cannot be told apart from a double space);
/// decoding accepts base64 with or without padding and refuses anything that is not UTF-8.
public enum Base64Field {
    public static func encode(_ text: String) -> String {
        text.isEmpty ? "-" : Data(text.utf8).base64EncodedString()
    }

    public static func decode(_ field: String) -> String? {
        if field.isEmpty || field == "-" { return "" }
        var s = field
        guard s.utf8.allSatisfy({ isBase64Character($0) }) else { return nil }
        if s.count % 4 == 1 { return nil }
        if s.count % 4 != 0 { s += String(repeating: "=", count: 4 - s.count % 4) }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isBase64Character(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 43 || c == 47 || c == 61
    }
}

/// Text printed by the client and parsed line by line by the preview script: control characters (line breaks,
/// tabs…) become spaces, so an app or account name can never start a line of its own (e.g. a fake `SHOT`).
public enum LineText {
    public static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                out.append(" ")
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// Which displays a capture covers. Numbers are those of `screencapture -D`: 1 is the main display, the others
/// follow in `CGGetActiveDisplayList` order (`ImageMath.orderedDisplays`).
public enum DisplaySelection: Equatable, Hashable, Sendable {
    case main
    case all
    case number(Int)

    public init?(token: String) {
        switch token {
        case "main": self = .main
        case "all": self = .all
        default:
            guard token.count == 1, let n = Int(token), (1...AgentInfo.maxDisplays).contains(n) else { return nil }
            self = .number(n)
        }
    }

    public var token: String {
        switch self {
        case .main: return "main"
        case .all: return "all"
        case .number(let n): return String(n)
        }
    }

    /// The display numbers to capture out of `displayCount` connected ones; `nil` when the requested display is
    /// not there (or there is none at all).
    public func numbers(displayCount: Int) -> [Int]? {
        let count = min(displayCount, AgentInfo.maxDisplays)
        guard count > 0 else { return nil }
        switch self {
        case .main: return [1]
        case .all: return Array(1...count)
        case .number(let n): return n <= count ? [n] : nil
        }
    }
}

/// A request from the client.
public enum AgentRequest: Equatable, Sendable {
    case ping
    case capture(maxSide: Int, quality: Int, display: DisplaySelection)
    case notice(title: String, text: String)
    case front
    case requestPermission

    /// The request line, without its line feed.
    public var line: String {
        let p = AgentInfo.protocolVersion
        switch self {
        case .ping: return "\(p) PING"
        case let .capture(maxSide, quality, display): return "\(p) CAPTURE \(maxSide) \(quality) \(display.token)"
        case let .notice(title, text): return "\(p) NOTICE \(Base64Field.encode(title)) \(Base64Field.encode(text))"
        case .front: return "\(p) FRONT"
        case .requestPermission: return "\(p) REQUEST-PERMISSION"
        }
    }

    /// Parses a request line (strict: this is what the agent accepts from root).
    public static func parse(_ line: String) throws -> AgentRequest {
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let version = f.first, version == AgentInfo.protocolVersion else {
            throw ProtocolError("nieobsługiwana wersja protokołu (oczekiwano \(AgentInfo.protocolVersion))")
        }
        guard f.count >= 2 else { throw ProtocolError("brak polecenia") }
        func expect(_ n: Int) throws {
            guard f.count == n else { throw ProtocolError("nieprawidłowa liczba pól polecenia \(f[1])") }
        }
        switch f[1] {
        case "PING":
            try expect(2); return .ping
        case "FRONT":
            try expect(2); return .front
        case "REQUEST-PERMISSION":
            try expect(2); return .requestPermission
        case "CAPTURE":
            try expect(5)
            guard let maxSide = strictInt(f[2]), AgentInfo.maxSideRange.contains(maxSide) else {
                throw ProtocolError("nieprawidłowy rozmiar zrzutu: \(f[2])")
            }
            guard let quality = strictInt(f[3]), AgentInfo.qualityRange.contains(quality) else {
                throw ProtocolError("nieprawidłowa jakość JPEG: \(f[3])")
            }
            guard let display = DisplaySelection(token: f[4]) else { throw ProtocolError("nieprawidłowy ekran: \(f[4])") }
            return .capture(maxSide: maxSide, quality: quality, display: display)
        case "NOTICE":
            try expect(4)
            guard let title = Base64Field.decode(f[2]), let text = Base64Field.decode(f[3]) else {
                throw ProtocolError("nieprawidłowy tekst komunikatu (base64)")
            }
            return .notice(title: title, text: text)
        default:
            throw ProtocolError("nieznane polecenie: \(f[1].prefix(40))")
        }
    }
}

/// Decimal digits only (no sign, no spaces, no leading `+`), at most 9 of them.
public func strictInt(_ s: String) -> Int? {
    guard !s.isEmpty, s.count <= 9, s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    return Int(s)
}

/// Result of a notice.
public enum NoticeResult: String, Sendable, CaseIterable {
    /// The panel is on screen.
    case shown
    /// It could not be put on screen (or the session is not the one at the screen).
    case hidden
    /// The screen is locked or asleep: nobody would see it.
    case locked
}

/// Error codes of `ERR <kod> <b64 opis>`.
public enum AgentErrorCode: String, Sendable, CaseIterable {
    case noperm, locked, notconsole, asleep, nodisplay, failed
    case `protocol`

    /// Exit code of the client for this error (docs/screen-agent.md › Klient).
    public var clientExitCode: Int32 {
        switch self {
        case .noperm: return AgentInfo.ClientCode.noPermission
        case .locked: return AgentInfo.ClientCode.locked
        case .notconsole, .asleep, .nodisplay: return AgentInfo.ClientCode.noImage
        case .failed: return AgentInfo.ClientCode.captureFailed
        case .protocol: return AgentInfo.ClientCode.protocolError
        }
    }

    /// Exit code for an `ERR` code that may come from a newer agent.
    public static func clientExitCode(for code: String) -> Int32 {
        AgentErrorCode(rawValue: code)?.clientExitCode ?? AgentInfo.ClientCode.other
    }
}

/// What `PING` reports.
public struct AgentStatus: Equatable, Sendable {
    public var version: String
    public var permissionGranted: Bool
    public var locked: Bool
    public var onConsole: Bool
    public var asleep: Bool
    public var user: String

    public init(version: String = AgentInfo.version, permissionGranted: Bool, locked: Bool, onConsole: Bool,
                asleep: Bool, user: String) {
        self.version = version
        self.permissionGranted = permissionGranted
        self.locked = locked
        self.onConsole = onConsole
        self.asleep = asleep
        self.user = user
    }

    var fields: String {
        "perm=\(permissionGranted ? "granted" : "denied") locked=\(locked ? 1 : 0) console=\(onConsole ? 1 : 0) asleep=\(asleep ? 1 : 0)"
    }
}

/// Header of one captured display: `IMG <n> <width> <height> <bytes>`, followed by exactly `bytes` bytes of JPEG.
public struct ImageHeader: Equatable, Sendable {
    public var display: Int
    public var width: Int
    public var height: Int
    public var byteCount: Int

    public init(display: Int, width: Int, height: Int, byteCount: Int) {
        self.display = display
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }

    public var line: String { "IMG \(display) \(width) \(height) \(byteCount)" }

    public static func parse(_ line: String) throws -> ImageHeader {
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, f[0] == "IMG", let n = strictInt(f[1]), let w = strictInt(f[2]), let h = strictInt(f[3]),
              let bytes = strictInt(f[4]) else {
            throw ProtocolError("nieprawidłowy nagłówek obrazu")
        }
        guard (1...AgentInfo.maxDisplays).contains(n), w > 0, h > 0, bytes > 0, bytes <= AgentInfo.maxImageBytes else {
            throw ProtocolError("nieprawidłowe wartości nagłówka obrazu")
        }
        return ImageHeader(display: n, width: w, height: h, byteCount: bytes)
    }
}

/// The first line of an answer.
public enum AgentReply: Equatable, Sendable {
    case ping(AgentStatus)
    /// `count` image headers follow.
    case capture(count: Int, frontApp: String)
    case notice(NoticeResult)
    case front(String)
    case permission(granted: Bool)
    /// `code` stays a string: a newer agent may send a code this client does not know.
    case error(code: String, message: String)

    public static func error(_ code: AgentErrorCode, _ message: String) -> AgentReply {
        .error(code: code.rawValue, message: message)
    }

    public var line: String {
        switch self {
        case .ping(let s): return "OK PING \(s.version) \(s.fields) user=\(Base64Field.encode(s.user))"
        case let .capture(count, front): return "OK CAPTURE \(count) \(Base64Field.encode(front))"
        case .notice(let r): return "OK NOTICE \(r.rawValue)"
        case .front(let name): return "OK FRONT \(Base64Field.encode(name))"
        case .permission(let granted): return "OK PERMISSION \(granted ? "granted" : "denied")"
        case let .error(code, message): return "ERR \(code) \(Base64Field.encode(message))"
        }
    }

    /// Parses the first line of an answer. Tolerant where a newer agent may add something (extra `PING` fields,
    /// unknown error codes, a missing error text), strict about what the client relies on.
    public static func parse(_ line: String) throws -> AgentReply {
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let head = f.first else { throw ProtocolError("pusta odpowiedź") }
        if head == "ERR" {
            guard f.count >= 2, !f[1].isEmpty else { throw ProtocolError("odpowiedź ERR bez kodu") }
            let message = f.count >= 3 ? (Base64Field.decode(f[2]) ?? f[2...].joined(separator: " ")) : ""
            return .error(code: f[1], message: message)
        }
        guard head == "OK", f.count >= 3 else { throw ProtocolError("nieznana odpowiedź: \(line.prefix(60))") }
        switch f[1] {
        case "PING":
            var values: [String: String] = [:]
            for field in f.dropFirst(3) {
                guard let eq = field.firstIndex(of: "=") else { continue }
                values[String(field[..<eq])] = String(field[field.index(after: eq)...])
            }
            guard !f[2].isEmpty, let perm = values["perm"], perm == "granted" || perm == "denied" else {
                throw ProtocolError("niepełna odpowiedź PING")
            }
            return .ping(AgentStatus(version: f[2], permissionGranted: perm == "granted",
                                     locked: values["locked"] == "1", onConsole: values["console"] != "0",
                                     asleep: values["asleep"] == "1",
                                     user: values["user"].flatMap(Base64Field.decode) ?? ""))
        case "CAPTURE":
            guard f.count == 4, let count = strictInt(f[2]), (1...AgentInfo.maxDisplays).contains(count),
                  let front = Base64Field.decode(f[3]) else {
                throw ProtocolError("nieprawidłowa odpowiedź CAPTURE")
            }
            return .capture(count: count, frontApp: front)
        case "NOTICE":
            guard let r = NoticeResult(rawValue: f[2]) else { throw ProtocolError("nieprawidłowa odpowiedź NOTICE") }
            return .notice(r)
        case "FRONT":
            guard f.count == 3, let name = Base64Field.decode(f[2]) else {
                throw ProtocolError("nieprawidłowa odpowiedź FRONT")
            }
            return .front(name)
        case "PERMISSION":
            guard f[2] == "granted" || f[2] == "denied" else { throw ProtocolError("nieprawidłowa odpowiedź PERMISSION") }
            return .permission(granted: f[2] == "granted")
        default:
            throw ProtocolError("nieznana odpowiedź: \(line.prefix(60))")
        }
    }
}

/// Lines the client prints for the preview script (docs/screen-agent.md › Klient).
public enum ClientOutput {
    public static func agent(_ s: AgentStatus) -> String {
        "AGENT \(LineText.clean(s.version)) \(s.fields) user=\(LineText.clean(s.user))"
    }
    public static func front(_ name: String) -> String { "FRONT \(LineText.clean(name))" }
    public static func shot(_ h: ImageHeader, path: String) -> String {
        "SHOT \(h.display) \(h.width) \(h.height) \(h.byteCount) \(LineText.clean(path))"
    }
    public static func notice(_ r: NoticeResult) -> String { "NOTICE \(r.rawValue)" }
    public static func permission(granted: Bool) -> String { "PERMISSION \(granted ? "granted" : "denied")" }
    public static func error(_ code: String, _ message: String) -> String {
        let m = LineText.clean(message)
        return m.isEmpty ? "ERR \(LineText.clean(code))" : "ERR \(LineText.clean(code)) \(m)"
    }
}
