import Foundation

// MARK: - Energy schedule (pmset repeat)

/// Days as `pmset repeat` spells them: M T W R F S U (Monday…Sunday).
public enum Weekday: String, CaseIterable, Codable, Sendable, Comparable {
    case monday = "M", tuesday = "T", wednesday = "W", thursday = "R", friday = "F", saturday = "S", sunday = "U"

    public static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    public var shortLabel: String {
        switch self {
        case .monday: return "Pn"
        case .tuesday: return "Wt"
        case .wednesday: return "Śr"
        case .thursday: return "Cz"
        case .friday: return "Pt"
        case .saturday: return "So"
        case .sunday: return "Nd"
        }
    }

    public var label: String {
        switch self {
        case .monday: return "poniedziałek"
        case .tuesday: return "wtorek"
        case .wednesday: return "środa"
        case .thursday: return "czwartek"
        case .friday: return "piątek"
        case .saturday: return "sobota"
        case .sunday: return "niedziela"
        }
    }

    var order: Int { Weekday.allCases.firstIndex(of: self) ?? 0 }

    public static func < (a: Weekday, b: Weekday) -> Bool { a.order < b.order }

    /// `MTWRF` for a set of days, in calendar order.
    public static func pmsetString(_ days: Set<Weekday>) -> String {
        days.sorted().map(\.rawValue).joined()
    }

    /// Polish description: "dni robocze", "codziennie", "Pn, Śr, Pt".
    public static func describe(_ days: Set<Weekday>) -> String {
        if days.count == 7 { return "codziennie" }
        if days == workdays { return "dni robocze (Pn–Pt)" }
        if days == [.saturday, .sunday] { return "weekendy" }
        if days.isEmpty { return "żaden dzień" }
        return days.sorted().map(\.shortLabel).joined(separator: ", ")
    }
}

public struct ClockTime: Codable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(_ hour: Int, _ minute: Int) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    /// `HH:mm:ss` as required by `pmset repeat`.
    public var pmsetString: String { String(format: "%02d:%02d:00", hour, minute) }
    public var text: String { String(format: "%d:%02d", hour, minute) }

    /// Parses `7:45`, `07:45:00`, `7:45AM`, `6:00PM`.
    public static func parse(_ s: String) -> ClockTime? {
        var t = s.trimmingCharacters(in: .whitespaces).uppercased()
        var pm = false, am = false
        if t.hasSuffix("PM") { pm = true; t.removeLast(2) } else if t.hasSuffix("AM") { am = true; t.removeLast(2) }
        let parts = t.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else {
            return nil
        }
        var hour = h
        if pm && h < 12 { hour += 12 }
        if am && h == 12 { hour = 0 }
        return ClockTime(hour, m)
    }
}

/// One repeating power-on and one repeating power-off event (`pmset repeat` allows exactly one pair).
public struct EnergySchedule: Codable, Equatable, Sendable {
    public enum OnType: String, Codable, CaseIterable, Sendable {
        case wakeorpoweron, wake
        public var label: String {
            switch self {
            case .wakeorpoweron: return "Obudź lub włącz"
            case .wake: return "Tylko obudź z uśpienia"
            }
        }
    }

    public enum OffType: String, Codable, CaseIterable, Sendable {
        case sleep, shutdown
        public var label: String {
            switch self {
            case .sleep: return "Uśpij"
            case .shutdown: return "Wyłącz"
            }
        }
    }

    public var powerOnEnabled = true
    public var onType: OnType = .wakeorpoweron
    public var onDays: Set<Weekday> = Weekday.workdays
    public var onTime = ClockTime(7, 45)
    public var powerOffEnabled = true
    public var offType: OffType = .sleep
    public var offDays: Set<Weekday> = Weekday.workdays
    public var offTime = ClockTime(16, 30)

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = EnergySchedule()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        powerOnEnabled = try c.decodeIfPresent(Bool.self, forKey: .powerOnEnabled) ?? d.powerOnEnabled
        onType = (try? c.decodeIfPresent(OnType.self, forKey: .onType)) ?? d.onType
        onDays = try c.decodeIfPresent(Set<Weekday>.self, forKey: .onDays) ?? d.onDays
        onTime = try c.decodeIfPresent(ClockTime.self, forKey: .onTime) ?? d.onTime
        powerOffEnabled = try c.decodeIfPresent(Bool.self, forKey: .powerOffEnabled) ?? d.powerOffEnabled
        offType = (try? c.decodeIfPresent(OffType.self, forKey: .offType)) ?? d.offType
        offDays = try c.decodeIfPresent(Set<Weekday>.self, forKey: .offDays) ?? d.offDays
        offTime = try c.decodeIfPresent(ClockTime.self, forKey: .offTime) ?? d.offTime
    }

    /// Why the schedule cannot be applied, or nil.
    public var validationError: String? {
        if !powerOnEnabled && !powerOffEnabled { return "Włącz przynajmniej jedno zdarzenie (włączanie lub wyłączanie)." }
        if powerOnEnabled && onDays.isEmpty { return "Wybierz dni włączania." }
        if powerOffEnabled && offDays.isEmpty { return "Wybierz dni wyłączania." }
        return nil
    }

    /// Arguments for `pmset`, e.g. `repeat wakeorpoweron MTWRF 07:45:00 shutdown MTWRF 18:00:00`.
    public var pmsetArguments: [String]? {
        guard validationError == nil else { return nil }
        var a = ["repeat"]
        if powerOnEnabled { a += [onType.rawValue, Weekday.pmsetString(onDays), onTime.pmsetString] }
        if powerOffEnabled { a += [offType.rawValue, Weekday.pmsetString(offDays), offTime.pmsetString] }
        return a
    }

    public var summary: String {
        var parts: [String] = []
        if powerOnEnabled { parts.append("\(onType.label) o \(onTime.text) – \(Weekday.describe(onDays))") }
        if powerOffEnabled { parts.append("\(offType.label) o \(offTime.text) – \(Weekday.describe(offDays))") }
        return parts.isEmpty ? "brak" : parts.joined(separator: "; ")
    }
}

/// One line of `pmset -g sched` under "Repeating power events".
public struct RepeatingPowerEvent: Equatable, Sendable {
    public var type: String
    public var time: ClockTime?
    public var daysText: String

    public var isPowerOn: Bool { ["wake", "poweron", "wakepoweron", "wakeorpoweron"].contains(type) }

    public var typeLabel: String {
        switch type {
        case "wakepoweron", "wakeorpoweron": return "Obudź lub włącz"
        case "wake": return "Obudź"
        case "poweron": return "Włącz"
        case "sleep": return "Uśpij"
        case "shutdown": return "Wyłącz"
        case "restart": return "Uruchom ponownie"
        default: return type
        }
    }

    public var text: String { "\(typeLabel) o \(time?.text ?? "?") – \(daysText)" }
}

public enum PowerScheduleParser {
    /// Parses the "Repeating power events" block of `pmset -g sched`.
    public static func repeating(_ text: String) -> [RepeatingPowerEvent] {
        var events: [RepeatingPowerEvent] = []
        var inRepeating = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Repeating power events") { inRepeating = true; continue }
            if line.hasSuffix("power events:") || line.hasPrefix("CMCR:") { inRepeating = false; continue }
            guard inRepeating, let at = line.range(of: " at ") else { continue }
            let type = String(line[..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = line[at.upperBound...].split(separator: " ", maxSplits: 1).map(String.init)
            guard let timeToken = rest.first else { continue }
            let days = rest.count > 1 ? describeDays(rest[1]) : ""
            events.append(RepeatingPowerEvent(type: type, time: ClockTime.parse(timeToken), daysText: days))
        }
        return events
    }

    /// Translates pmset's day descriptions ("weekdays only", "every day", "MWF", "Some days: MTW").
    static func describeDays(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let lower = s.lowercased()
        if lower.contains("every day") { return "codziennie" }
        if lower.contains("weekdays") { return "dni robocze (Pn–Pt)" }
        if lower.contains("weekends") { return "weekendy" }
        let token = s.split(separator: " ").last.map(String.init) ?? s
        if !token.isEmpty, token.allSatisfy({ "MTWRFSU".contains($0) }) {
            let days = Set(token.compactMap { Weekday(rawValue: String($0)) })
            return Weekday.describe(days)
        }
        return s
    }

    /// `key=value` lines printed after `CMCR:POLICY` by `Scripts.energyScheduleStatus()`.
    public static func policy(_ text: String) -> [String: String] {
        guard let r = text.range(of: "CMCR:POLICY") else { return [:] }
        return Parsers.keyValues(String(text[r.upperBound...]))
    }
}

// MARK: - Lesson routines

/// What happens when the teacher clicks "Rozpocznij zajęcia".
public struct LessonStartConfig: Codable, Equatable, Sendable {
    public enum Destination: String, Codable, CaseIterable, Sendable {
        case sharedFolder, studentDesktop
        public var label: String {
            switch self {
            case .sharedFolder: return "Folder cmcr ucznia"
            case .studentDesktop: return "Biurko ucznia"
            }
        }
    }

    public var wake = true
    public var wakeWaitMinutes = 3
    public var sendMaterials = false
    public var materialsFolder = ""
    public var destination: Destination = .sharedFolder
    public var openApps = false
    public var apps = ""
    public var greet = true
    public var greetingTitle = "Dzień dobry!"
    public var greetingText = "Zaczynamy zajęcia. Materiały znajdziesz w folderze cmcr."
    public var greetingAsDialog = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = LessonStartConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wake = try c.decodeIfPresent(Bool.self, forKey: .wake) ?? d.wake
        wakeWaitMinutes = try c.decodeIfPresent(Int.self, forKey: .wakeWaitMinutes) ?? d.wakeWaitMinutes
        sendMaterials = try c.decodeIfPresent(Bool.self, forKey: .sendMaterials) ?? d.sendMaterials
        materialsFolder = try c.decodeIfPresent(String.self, forKey: .materialsFolder) ?? d.materialsFolder
        destination = (try? c.decodeIfPresent(Destination.self, forKey: .destination)) ?? d.destination
        openApps = try c.decodeIfPresent(Bool.self, forKey: .openApps) ?? d.openApps
        apps = try c.decodeIfPresent(String.self, forKey: .apps) ?? d.apps
        greet = try c.decodeIfPresent(Bool.self, forKey: .greet) ?? d.greet
        greetingTitle = try c.decodeIfPresent(String.self, forKey: .greetingTitle) ?? d.greetingTitle
        greetingText = try c.decodeIfPresent(String.self, forKey: .greetingText) ?? d.greetingText
        greetingAsDialog = try c.decodeIfPresent(Bool.self, forKey: .greetingAsDialog) ?? d.greetingAsDialog
    }

    public var appList: [String] { LessonStartConfig.splitList(apps) }

    static func splitList(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// What happens when the teacher clicks "Zakończ zajęcia".
public struct LessonEndConfig: Codable, Equatable, Sendable {
    public enum PowerChoice: String, Codable, CaseIterable, Sendable {
        case none, sleep, shutdown
        public var label: String {
            switch self {
            case .none: return "Pozostaw włączone"
            case .sleep: return "Uśpij"
            case .shutdown: return "Wyłącz"
            }
        }
    }

    public var warn = false
    public var warnMinutes = 2
    public var warnText = "Za chwilę koniec zajęć – zapisz pracę w folderze cmcr."
    public var collect = true
    public var collectLabel = ""
    public var quitApps = false
    public var quitAllApps = true
    public var apps = ""
    public var cleanShared = false
    public var cleanDownloads = false
    public var logout = false
    public var power: PowerChoice = .none

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = LessonEndConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warn = try c.decodeIfPresent(Bool.self, forKey: .warn) ?? d.warn
        warnMinutes = try c.decodeIfPresent(Int.self, forKey: .warnMinutes) ?? d.warnMinutes
        warnText = try c.decodeIfPresent(String.self, forKey: .warnText) ?? d.warnText
        collect = try c.decodeIfPresent(Bool.self, forKey: .collect) ?? d.collect
        collectLabel = try c.decodeIfPresent(String.self, forKey: .collectLabel) ?? d.collectLabel
        quitApps = try c.decodeIfPresent(Bool.self, forKey: .quitApps) ?? d.quitApps
        quitAllApps = try c.decodeIfPresent(Bool.self, forKey: .quitAllApps) ?? d.quitAllApps
        apps = try c.decodeIfPresent(String.self, forKey: .apps) ?? d.apps
        cleanShared = try c.decodeIfPresent(Bool.self, forKey: .cleanShared) ?? d.cleanShared
        cleanDownloads = try c.decodeIfPresent(Bool.self, forKey: .cleanDownloads) ?? d.cleanDownloads
        logout = try c.decodeIfPresent(Bool.self, forKey: .logout) ?? d.logout
        power = (try? c.decodeIfPresent(PowerChoice.self, forKey: .power)) ?? d.power
    }

    public var appList: [String] { LessonStartConfig.splitList(apps) }

    /// True when the routine deletes files or ends the session (needs an explicit confirmation).
    public var isDisruptive: Bool { (cleanShared && collect) || cleanDownloads || logout || power != .none || quitApps }
}

public enum AttentionMode: String, Codable, CaseIterable, Sendable {
    case automatic, lockScreen, overlay
    public var label: String {
        switch self {
        case .automatic: return "Automatycznie"
        case .lockScreen: return "Blokada systemowa (LockScreen)"
        case .overlay: return "Komunikat na pełnym ekranie"
        }
    }
}

/// Settings of the "Zajęcia" section, stored in classroom.json next to hosts.json.
public struct ClassroomConfig: Codable, Equatable, Sendable {
    public var start = LessonStartConfig()
    public var end = LessonEndConfig()
    public var lockMessage = "Proszę patrzeć na tablicę"
    public var lockMode: AttentionMode = .automatic
    public var autoUnlockMinutes = 30
    public var schedule = EnergySchedule()
    public var autoRestartAfterPowerLoss = true
    public var wakeOnLAN = true
    public var lastQuestion = ""
    public var questionButtons = ""
    /// Answer with buttons (`questionButtons`) instead of a text field; the button names stay saved either way.
    public var questionWithButtons = false
    public var questionTimeoutMinutes = 2
    /// Dashboard table column layout (visibility, order, widths) as encoded by SwiftUI.
    public var dashboardTableState = ""
    public var lastAppVersionQuery = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = ClassroomConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = (try? c.decodeIfPresent(LessonStartConfig.self, forKey: .start)) ?? d.start
        end = (try? c.decodeIfPresent(LessonEndConfig.self, forKey: .end)) ?? d.end
        lockMessage = try c.decodeIfPresent(String.self, forKey: .lockMessage) ?? d.lockMessage
        lockMode = (try? c.decodeIfPresent(AttentionMode.self, forKey: .lockMode)) ?? d.lockMode
        autoUnlockMinutes = try c.decodeIfPresent(Int.self, forKey: .autoUnlockMinutes) ?? d.autoUnlockMinutes
        schedule = (try? c.decodeIfPresent(EnergySchedule.self, forKey: .schedule)) ?? d.schedule
        autoRestartAfterPowerLoss = try c.decodeIfPresent(Bool.self, forKey: .autoRestartAfterPowerLoss) ?? d.autoRestartAfterPowerLoss
        wakeOnLAN = try c.decodeIfPresent(Bool.self, forKey: .wakeOnLAN) ?? d.wakeOnLAN
        lastQuestion = try c.decodeIfPresent(String.self, forKey: .lastQuestion) ?? d.lastQuestion
        questionButtons = try c.decodeIfPresent(String.self, forKey: .questionButtons) ?? d.questionButtons
        questionWithButtons = try c.decodeIfPresent(Bool.self, forKey: .questionWithButtons) ?? !questionButtons.isEmpty
        questionTimeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .questionTimeoutMinutes) ?? d.questionTimeoutMinutes
        dashboardTableState = try c.decodeIfPresent(String.self, forKey: .dashboardTableState) ?? d.dashboardTableState
        lastAppVersionQuery = try c.decodeIfPresent(String.self, forKey: .lastAppVersionQuery) ?? d.lastAppVersionQuery
    }

    /// The macOS dialog shows at most this many buttons.
    public static let maxQuestionButtons = 3

    /// Button names entered as a comma-separated list.
    public var questionButtonList: [String] {
        questionButtons.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Last-known state

/// A host status as saved between runs (status-cache.json).
public struct HostSnapshot: Codable, Equatable, Sendable {
    public var reachability: Reachability
    public var message: String
    public var info: [String: String]
    public var updatedAt: Date?
    /// Last time the Mac answered over SSH.
    public var lastSeen: Date?

    public init(reachability: Reachability, message: String, info: [String: String], updatedAt: Date?, lastSeen: Date?) {
        self.reachability = reachability
        self.message = message
        self.info = info
        self.updatedAt = updatedAt
        self.lastSeen = lastSeen
    }

    public init(_ status: HostStatus, lastSeen: Date?) {
        self.init(reachability: status.reachability, message: status.message, info: status.info,
                  updatedAt: status.updatedAt, lastSeen: lastSeen)
    }

    /// Restored status: hardware and network information is kept, the reachability is unknown until the next
    /// check and the logged-in user and boot time (both stale by then) are dropped.
    public var restored: HostStatus {
        var st = HostStatus()
        st.reachability = .unknown
        st.info = info
        st.info["console"] = nil
        st.info["boot"] = nil
        st.updatedAt = updatedAt
        return st
    }
}

extension HostStatus {
    /// Uptime only while the Mac answers: for a Mac that is off, "now minus last boot" keeps growing.
    private var answersNow: Bool { reachability == .online || reachability == .checking }
    public var liveUptimeText: String? { answersNow ? uptimeText : nil }
    public var liveUptime: TimeInterval? { answersNow ? bootDate.map { Date().timeIntervalSince($0) } : nil }
}

public enum ClassroomStore {
    static var configURL: URL { ConfigStore.directory.appendingPathComponent("classroom.json") }
    static var cacheURL: URL { ConfigStore.directory.appendingPathComponent("status-cache.json") }

    public static func loadConfig() -> ClassroomConfig {
        guard let data = try? Data(contentsOf: configURL),
              let c = try? JSONDecoder().decode(ClassroomConfig.self, from: data) else { return ClassroomConfig() }
        return c
    }

    public static func saveConfig(_ c: ClassroomConfig) { write(c, to: configURL) }

    public static func loadSnapshots() -> [UUID: HostSnapshot] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL),
              let raw = try? dec.decode([String: HostSnapshot].self, from: data) else { return [:] }
        var out: [UUID: HostSnapshot] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k) { out[id] = v } }
        return out
    }

    public static func saveSnapshots(_ snapshots: [UUID: HostSnapshot]) {
        var raw: [String: HostSnapshot] = [:]
        for (k, v) in snapshots { raw[k.uuidString] = v }
        write(raw, to: cacheURL, dates: .iso8601)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL,
                                            dates: JSONEncoder.DateEncodingStrategy = .deferredToDate) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = dates
        if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Computer names

public enum ComputerNames {
    /// Bonjour name (LocalHostName) derived from a display name: ASCII letters, digits and hyphens, max 63.
    /// "Pracownia 3/iMac ą" → "Pracownia-3-iMac-a".
    public static func localHostName(from name: String) -> String {
        let folded = name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "Ł", with: "L")
        var out = ""
        for ch in folded {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else if ch == "-" || ch == " " || ch == "_" || ch == "." || ch == "/" {
                if !out.isEmpty && !out.hasSuffix("-") { out.append("-") }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(63))
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    public static func isValidLocalHostName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 63 && !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// New SSH address after a rename: only `.local` (Bonjour) addresses follow the name.
    public static func addressAfterRename(_ address: String, localHostName: String) -> String? {
        let lower = address.lowercased()
        guard lower.hasSuffix(".local") else { return nil }
        return "\(localHostName).local"
    }
}

// MARK: - Answers ("Zapytaj uczniów")

public struct StudentAnswer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case answered, timedOut, cancelled, noUser }
    public var kind: Kind
    public var button: String
    public var text: String
    public var user: String

    /// Parses the `CMCR:` lines printed by `Scripts.ask`.
    public static func parse(_ output: String) -> StudentAnswer? {
        var user = ""
        var result: StudentAnswer?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("CMCR:USER:") { user = String(line.dropFirst("CMCR:USER:".count)) }
            else if line.hasPrefix("CMCR:ANSWER:") {
                let payload = String(line.dropFirst("CMCR:ANSWER:".count))
                let parts = payload.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                result = StudentAnswer(kind: .answered, button: parts.first ?? "", text: parts.count > 1 ? parts[1] : "", user: "")
            } else if line == "CMCR:TIMEOUT" { result = StudentAnswer(kind: .timedOut, button: "", text: "", user: "") }
            else if line == "CMCR:CANCELLED" { result = StudentAnswer(kind: .cancelled, button: "", text: "", user: "") }
            else if line == "CMCR:NO_USER" { result = StudentAnswer(kind: .noUser, button: "", text: "", user: "") }
        }
        result?.user = user
        return result
    }

    public var displayText: String {
        switch kind {
        case .answered:
            if text.isEmpty { return button }
            return text
        case .timedOut: return "brak odpowiedzi (minął czas)"
        case .cancelled: return "okno zamknięte bez odpowiedzi"
        case .noUser: return "nikt nie jest zalogowany"
        }
    }
}

// MARK: - App versions

public struct AppVersionInfo: Equatable, Sendable {
    public var path: String
    public var version: String
    public var build: String

    /// Parses `CMCR:APP:<path>\t<version>\t<build>` lines printed by `Scripts.appVersion`.
    public static func parse(_ output: String) -> [AppVersionInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            guard raw.hasPrefix("CMCR:APP:") else { return nil }
            let parts = raw.dropFirst("CMCR:APP:".count).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let path = parts.first, !path.isEmpty else { return nil }
            return AppVersionInfo(path: path, version: parts.count > 1 ? parts[1] : "",
                                  build: parts.count > 2 ? parts[2] : "")
        }
    }
}

// MARK: - CSV

public enum CSV {
    /// Separator used by default: semicolon, which Excel with Polish regional settings opens into columns.
    public static let defaultSeparator: Character = ";"

    public static func escape(_ field: String, separator: Character = defaultSeparator) -> String {
        let needsQuotes = field.contains(separator) || field.contains("\"") || field.contains("\n")
            || field.contains("\r") || field.hasPrefix(" ") || field.hasSuffix(" ")
        let body = field.replacingOccurrences(of: "\"", with: "\"\"")
        return needsQuotes ? "\"\(body)\"" : body
    }

    /// RFC 4180 style text with CRLF line ends; `bom` adds the UTF-8 byte order mark Excel needs for "ą, ę".
    public static func render(_ rows: [[String]], separator: Character = defaultSeparator, bom: Bool = true) -> String {
        let body = rows.map { $0.map { escape($0, separator: separator) }.joined(separator: String(separator)) }
            .joined(separator: "\r\n")
        return (bom ? "\u{FEFF}" : "") + body + "\r\n"
    }
}

// MARK: - Inventory report

public struct InventoryColumn: Sendable {
    public let id: String
    public let title: String
    public let value: @Sendable (Machine, HostStatus, Date?) -> String

    public init(_ id: String, _ title: String, _ value: @escaping @Sendable (Machine, HostStatus, Date?) -> String) {
        self.id = id
        self.title = title
        self.value = value
    }
}

public enum InventoryReport {
    static func dateText(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "pl_PL")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    public static let columns: [InventoryColumn] = [
        InventoryColumn("name", "Nazwa") { m, _, _ in m.name },
        InventoryColumn("address", "Adres") { m, _, _ in m.address },
        InventoryColumn("account", "Konto SSH") { m, _, _ in m.user },
        InventoryColumn("state", "Stan") { _, s, _ in s.reachability.label },
        InventoryColumn("lastSeen", "Ostatnio widziany") { _, _, seen in dateText(seen) },
        InventoryColumn("computerName", "Nazwa komputera (macOS)") { _, s, _ in s.info["name"] ?? "" },
        InventoryColumn("user", "Zalogowany użytkownik") { _, s, _ in s.consoleUser ?? "" },
        InventoryColumn("os", "macOS") { _, s, _ in [s.osVersion, s.info["build"]].compactMap { $0 }.joined(separator: " ") },
        InventoryColumn("model", "Model") { _, s, _ in s.model ?? "" },
        InventoryColumn("chip", "Procesor") { _, s, _ in s.info["chip"] ?? "" },
        InventoryColumn("memory", "Pamięć (GB)") { _, s, _ in s.info["mem"] ?? "" },
        InventoryColumn("serial", "Numer seryjny") { _, s, _ in s.info["serial"] ?? "" },
        InventoryColumn("ip", "IP") { _, s, _ in s.ip ?? "" },
        InventoryColumn("mac", "MAC") { m, s, _ in s.info["mac_ethernet"].flatMap { $0.isEmpty ? nil : $0 } ?? s.mac ?? m.macAddress },
        InventoryColumn("uptime", "Czas pracy") { _, s, _ in s.liveUptimeText ?? "" },
        InventoryColumn("diskFree", "Wolne miejsce (GB)") { _, s, _ in s.freeDiskGB.map { String(format: "%.0f", $0) } ?? "" },
        InventoryColumn("diskTotal", "Pojemność dysku (GB)") { _, s, _ in s.totalDiskGB.map { String(format: "%.0f", $0) } ?? "" },
        InventoryColumn("filevault", "FileVault") { _, s, _ in s.info["fv"] ?? s.info["filevault"] ?? "" },
        InventoryColumn("notes", "Uwagi") { m, s, _ in [m.notes, s.message].filter { !$0.isEmpty }.joined(separator: " | ") },
    ]

    public static func rows(machines: [Machine], status: (Machine) -> HostStatus, lastSeen: (Machine) -> Date?,
                            columns: [InventoryColumn] = columns) -> [[String]] {
        [columns.map(\.title)] + machines.map { m in
            let st = status(m)
            let seen = lastSeen(m)
            return columns.map { $0.value(m, st, seen) }
        }
    }
}

public extension HostStatus {
    /// Free space on the system volume in GB (from `disk=<total KB> <free KB>`).
    var freeDiskGB: Double? { diskParts?.free }
    var totalDiskGB: Double? { diskParts?.total }

    private var diskParts: (total: Double, free: Double)? {
        guard let parts = info["disk"]?.split(separator: " "), parts.count == 2,
              let total = Double(parts[0]), let free = Double(parts[1]), total > 0 else { return nil }
        return (total / 1_048_576, free / 1_048_576)
    }

    /// Ethernet MAC when the status script reports it (`mac_ethernet=`), otherwise the default-route MAC.
    var preferredMAC: String? {
        if let e = info["mac_ethernet"], !e.isEmpty { return e }
        return mac
    }

    /// FileVault state when known: `true` on, `false` off, nil unknown.
    var fileVaultOn: Bool? {
        guard let v = (info["fv"] ?? info["filevault"])?.lowercased(), !v.isEmpty else { return nil }
        if v.contains("off") || v == "no" || v == "false" || v == "0" { return false }
        if v.contains("on") || v == "yes" || v == "true" || v == "1" { return true }
        return nil
    }
}
