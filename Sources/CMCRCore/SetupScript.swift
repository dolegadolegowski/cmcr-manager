import Foundation

/// Options of the one-time root setup script (setup/cmcr-imac-setup.sh), chosen in
/// Konfiguracja › Przygotowanie iMaców or on the `cmcrctl setup` command line.
/// Stored as `setup-options.json` next to the other configuration files.
public struct SetupOptions: Codable, Equatable, Sendable {
    public enum SudoPolicy: String, Codable, CaseIterable, Sendable { case unchanged, passwordless, requirePassword }
    public enum UpdatePolicy: String, Codable, CaseIterable, Sendable { case unchanged, check, download, auto }
    public enum ScheduleMode: String, Codable, CaseIterable, Sendable { case unchanged, set, off }
    public enum ScheduleAction: String, Codable, CaseIterable, Sendable { case shutdown, sleep }

    public var installKey = true
    public var restrictSSH = true
    public var sshKeepAlive = true
    public var sshKeyOnly = false
    /// `from="…"` restriction of the manager key (addresses or patterns, comma separated).
    public var keyFrom = ""
    public var sharedACL = true
    public var enableVNC = false
    public var sudo: SudoPolicy = .unchanged
    /// Sets ComputerName/LocalHostName to the name from the host list ("auto" in a standalone copy).
    public var setHostname = false
    public var wakeOnLAN = true
    public var noSleep = false
    /// Display sleep in minutes; `nil` leaves it unchanged.
    public var displaySleepMinutes: Int?
    public var autoRestart = false
    public var scheduleMode: ScheduleMode = .unchanged
    /// pmset day letters: M T W R F S U.
    public var scheduleDays = "MTWRF"
    public var scheduleOn = "07:30"
    /// Empty = power on only.
    public var scheduleOff = "17:00"
    public var scheduleAction: ScheduleAction = .shutdown
    public var rosetta = false
    public var updates: UpdatePolicy = .unchanged
    public var fixFirewall = false

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field is optional, so options saved by an older version keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = SetupOptions()
        installKey = v(.installKey, d.installKey)
        restrictSSH = v(.restrictSSH, d.restrictSSH)
        sshKeepAlive = v(.sshKeepAlive, d.sshKeepAlive)
        sshKeyOnly = v(.sshKeyOnly, d.sshKeyOnly)
        keyFrom = v(.keyFrom, d.keyFrom)
        sharedACL = v(.sharedACL, d.sharedACL)
        enableVNC = v(.enableVNC, d.enableVNC)
        sudo = v(.sudo, d.sudo)
        setHostname = v(.setHostname, d.setHostname)
        wakeOnLAN = v(.wakeOnLAN, d.wakeOnLAN)
        noSleep = v(.noSleep, d.noSleep)
        displaySleepMinutes = (try? c.decodeIfPresent(Int.self, forKey: .displaySleepMinutes)) ?? nil
        autoRestart = v(.autoRestart, d.autoRestart)
        scheduleMode = v(.scheduleMode, d.scheduleMode)
        scheduleDays = v(.scheduleDays, d.scheduleDays)
        scheduleOn = v(.scheduleOn, d.scheduleOn)
        scheduleOff = v(.scheduleOff, d.scheduleOff)
        scheduleAction = v(.scheduleAction, d.scheduleAction)
        rosetta = v(.rosetta, d.rosetta)
        updates = v(.updates, d.updates)
        fixFirewall = v(.fixFirewall, d.fixFirewall)
    }

    /// Value of `--power-schedule`, or `nil` to leave the schedule as it is.
    public var powerScheduleArgument: String? {
        switch scheduleMode {
        case .unchanged: return nil
        case .off: return "off"
        case .set:
            let off = scheduleOff.trimmingCharacters(in: .whitespaces)
            return off.isEmpty ? "\(scheduleDays) \(scheduleOn)" : "\(scheduleDays) \(scheduleOn) \(off) \(scheduleAction.rawValue)"
        }
    }

    /// Same rules as the script's own validation, so the UI can explain problems before anything runs.
    public func validationError() -> String? {
        func validTime(_ t: String) -> Bool {
            let p = t.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 2, p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return false }
            return (0...23).contains(h) && (0...59).contains(m)
        }
        if scheduleMode == .set {
            if scheduleDays.isEmpty || !scheduleDays.allSatisfy({ "MTWRFSU".contains($0) }) {
                return "Harmonogram: wybierz co najmniej jeden dzień."
            }
            if !validTime(scheduleOn) { return "Harmonogram: godzina włączenia w formacie GG:MM." }
            if !scheduleOff.isEmpty && !validTime(scheduleOff) { return "Harmonogram: godzina wyłączenia w formacie GG:MM." }
        }
        let allowedFrom = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:/*?,!-")
        if keyFrom.unicodeScalars.contains(where: { !allowedFrom.contains($0) }) {
            return "Ograniczenie adresów klucza: dozwolone adresy, maski i wzorce (np. 192.168.1.0/24,*.local)."
        }
        if sshKeyOnly && !installKey {
            return "Logowanie wyłącznie kluczem wymaga instalacji klucza aplikacji – inaczej stracisz dostęp."
        }
        if let m = displaySleepMinutes, m < 0 { return "Uśpienie ekranu: liczba minut." }
        return nil
    }

    // MARK: Persistence

    public static var storeURL: URL { ConfigStore.directory.appendingPathComponent("setup-options.json") }

    public static func load() -> SetupOptions {
        guard let data = try? Data(contentsOf: storeURL),
              let o = try? JSONDecoder().decode(SetupOptions.self, from: data) else { return SetupOptions() }
        return o
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        if let data = try? enc.encode(self) { try? data.write(to: Self.storeURL, options: .atomic) }
    }
}

/// The one-time root setup script for managed iMacs.
///
/// The text is the repository file setup/cmcr-imac-setup.sh, embedded at development time by
/// scripts/embed-setup.sh (a unit test keeps both copies identical). The app runs it remotely as root
/// (`remote`) or saves a personalized copy to run at the computer with `sudo bash` (`standalone`).
public enum SetupScript {
    public enum Mode: String, Sendable { case apply, verify, dryRun }

    public static var template: String { SetupScriptTemplate.text }

    /// `CMCR_SETUP_VERSION` of the embedded script; written to the marker file on every iMac.
    public static let version: String = {
        for line in SetupScriptTemplate.text.split(separator: "\n", maxSplits: 40) where line.hasPrefix("CMCR_SETUP_VERSION=") {
            return line.dropFirst("CMCR_SETUP_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return "?"
    }()

    public static let fileName = "cmcr-imac-setup.sh"
    public static let markerPath = "/Library/Application Support/CMCR/setup.json"
    public static let reportBegin = "-----BEGIN CMCR SETUP JSON-----"
    public static let reportEnd = "-----END CMCR SETUP JSON-----"

    /// Exit codes of the script.
    public enum ExitCode {
        public static let stepFailed: Int32 = 1
        public static let badOptions: Int32 = 2
        public static let notRoot: Int32 = 3
        public static let unsupportedOS: Int32 = 4
    }

    /// The shared folder must live in a home folder or /Users/Shared (the script refuses anything else).
    public static func sharedFolderProblem(_ settings: AppSettings) -> String? {
        let path = settings.resolve(settings.sharedFolder)
        if path.contains("..") || path.contains("/./") || path.contains("{") {
            return "Folder współdzielony „\(path)” zawiera niedozwolone elementy (.., ./ lub {…})."
        }
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/Users/"), parts.count >= 3 else {
            return "Folder współdzielony „\(path)” musi leżeć w /Users/<konto>/… lub /Users/Shared/…"
        }
        return nil
    }

    /// Command-line flags for one host. Host-specific values (admin account, host name) come from the host list.
    public static func arguments(_ o: SetupOptions, host: Machine, settings: AppSettings,
                                 publicKey: String?, mode: Mode) -> [String] {
        var a = ["--admin", host.user, "--student", settings.studentUser,
                 "--shared-folder", settings.resolve(settings.sharedFolder), "--no-guide"]
        if o.installKey, let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            a += ["--pubkey", key]
        }
        if !o.keyFrom.isEmpty { a += ["--key-from", o.keyFrom] }
        if !o.restrictSSH { a.append("--no-ssh-acl") }
        if !o.sshKeepAlive { a.append("--no-ssh-tuning") }
        if o.sshKeyOnly { a.append("--ssh-key-only") }
        if !o.sharedACL { a.append("--no-shared-acl") }
        if o.enableVNC { a.append("--enable-vnc") }
        switch o.sudo {
        case .unchanged: break
        case .passwordless: a.append("--sudo-nopasswd")
        case .requirePassword: a.append("--no-sudo-nopasswd")
        }
        if o.setHostname { a += ["--hostname", host.name] }
        if !o.wakeOnLAN { a.append("--no-wol") }
        if o.noSleep { a.append("--no-sleep") }
        if let m = o.displaySleepMinutes { a += ["--display-sleep", String(m)] }
        if o.autoRestart { a.append("--autorestart") }
        if let s = o.powerScheduleArgument { a += ["--power-schedule", s] }
        if o.rosetta { a.append("--rosetta") }
        if o.updates != .unchanged { a += ["--updates", o.updates.rawValue] }
        if o.fixFirewall { a.append("--fix-firewall") }
        switch mode {
        case .apply: break
        case .verify: a.append("--verify")
        case .dryRun: a.append("--dry-run")
        }
        return a
    }

    /// Remote job: ships the script inline (base64 inside the body) and runs it as root through the
    /// RemoteScript root wrapper; the report is streamed and the script's exit code becomes the job's.
    public static func remote(_ o: SetupOptions, host: Machine, settings: AppSettings,
                              publicKey: String?, mode: Mode) -> RemoteScript {
        let b64 = Data(template.utf8).base64EncodedString()
        let args = arguments(o, host: host, settings: settings, publicKey: publicKey, mode: mode)
            .map(shQuote).joined(separator: " ")
        return RemoteScript(#"""
        F="$CMCR_TMP/\#(fileName)"
        printf '%s' '\#(b64)' | base64 -D > "$F" || { echo "Nie udało się zapisać skryptu konfiguracyjnego." >&2; exit 90; }
        /bin/bash --noprofile --norc "$F" \#(args)
        RC=$?
        rm -f "$F"
        exit $RC
        """#, asRoot: true)
    }

    /// Personalized copy for running at the computer (`sudo bash cmcr-imac-setup.sh`). Only the defaults
    /// block changes; the admin account defaults to whoever runs sudo (imacNN) and the host name to
    /// "auto" (that account's name), so one file fits every iMac.
    public static func standalone(_ o: SetupOptions, settings: AppSettings, publicKey: String?,
                                  date: Date = Date()) -> String {
        func q(_ s: String) -> String { shQuote(s) }
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        let key = o.installKey ? (publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let sudo: String
        switch o.sudo {
        case .unchanged: sudo = ""
        case .passwordless: sudo = "yes"
        case .requirePassword: sudo = "no"
        }
        let block = """
        # >>> CMCR-DEFAULTS – wygenerowane przez CMCR Manager \(ISO8601DateFormatter().string(from: date)) >>>
        OPT_PUBKEYS=\(q(key))
        OPT_ADMIN=''
        OPT_STUDENT=\(q(settings.studentUser))
        OPT_SHARED=\(q(settings.resolve(settings.sharedFolder)))
        OPT_SHARED_MODE='777'
        OPT_SHARED_ACL=\(b(o.sharedACL))
        OPT_SSH_ACL=\(b(o.restrictSSH))
        OPT_SSH_TUNING=\(b(o.sshKeepAlive))
        OPT_SSH_KEY_ONLY=\(b(o.sshKeyOnly))
        OPT_KEY_FROM=\(q(o.keyFrom))
        OPT_VNC=\(b(o.enableVNC))
        OPT_SUDO_NOPASSWD=\(q(sudo))
        OPT_HOSTNAME=\(q(o.setHostname ? "auto" : ""))
        OPT_WOL=\(b(o.wakeOnLAN))
        OPT_NO_SLEEP=\(b(o.noSleep))
        OPT_DISPLAY_SLEEP=\(q(o.displaySleepMinutes.map(String.init) ?? ""))
        OPT_AUTORESTART=\(b(o.autoRestart))
        OPT_POWER_SCHEDULE=\(q(o.powerScheduleArgument ?? ""))
        OPT_ROSETTA=\(b(o.rosetta))
        OPT_UPDATES=\(q(o.updates == .unchanged ? "" : o.updates.rawValue))
        OPT_FIX_FIREWALL=\(b(o.fixFirewall))
        OPT_GUIDE='auto'
        # <<< CMCR-DEFAULTS <<<
        """
        var lines = template.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("# >>> CMCR-DEFAULTS") }),
              let end = lines.firstIndex(where: { $0.hasPrefix("# <<< CMCR-DEFAULTS") }), end > start else {
            return template
        }
        lines.replaceSubrange(start...end, with: block.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    /// What to type in Terminal at the iMac after copying the file to the admin's Downloads folder.
    public static let localCommand = "sudo bash ~/Downloads/\(fileName)"
}

/// JSON report printed by the script between the BEGIN/END lines (same content as setup.json).
public struct SetupReport: Decodable, Sendable {
    public struct Step: Decodable, Sendable, Hashable {
        public var id: String
        /// ok, changed, pending, skipped, warn, todo, fail
        public var status: String
        public var message: String
    }

    public var schema: Int?
    public var version: String?
    public var mode: String?
    public var timestamp: String?
    public var host: String?
    public var os: String?
    public var arch: String?
    public var admin: String?
    public var keyFingerprints: String?
    public var ethernetMac: String?
    public var viaSsh: Bool?
    /// yes / no / unknown
    public var fdaRemote: String?
    /// yes / no / unknown
    public var screenCaptureRemote: String?
    public var filevault: String?
    /// ok / todo / pending / fail
    public var result: String?
    public var changedCount: Int?
    public var pendingCount: Int?
    public var todoCount: Int?
    public var failCount: Int?
    public var steps: [Step]

    public var manualSteps: [Step] { steps.filter { $0.status == "todo" } }
    public var failedSteps: [Step] { steps.filter { $0.status == "fail" } }

    public static func parse(_ output: String) -> SetupReport? {
        guard let a = output.range(of: SetupScript.reportBegin),
              let b = output.range(of: SetupScript.reportEnd, range: a.upperBound..<output.endIndex) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(SetupReport.self, from: Data(output[a.upperBound..<b.lowerBound].utf8))
    }

    /// One line for job summaries and the CLI.
    public var summary: String {
        let fails = failCount ?? 0, todo = todoCount ?? 0, pending = pendingCount ?? 0, changed = changedCount ?? 0
        if fails > 0 { return "Błędy: \(fails) – szczegóły w raporcie." }
        if pending > 0 {
            return "Do zmiany: \(polishCount(pending, "ustawienie", "ustawienia", "ustawień")) (tylko sprawdzenie – nic nie zmieniono)."
        }
        var parts = [changed > 0 ? "Zmieniono \(polishCount(changed, "ustawienie", "ustawienia", "ustawień"))"
                                 : "Bez zmian – wszystko było już skonfigurowane"]
        if todo > 0 { parts.append("kroki ręczne przy komputerze: \(todo)") }
        return parts.joined(separator: "; ") + "."
    }
}

/// „1 ustawienie”, „3 ustawienia”, „5 ustawień”.
func polishCount(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let word: String
    if n == 1 {
        word = one
    } else if (2...4).contains(n % 10) && !(12...14).contains(n % 100) {
        word = few
    } else {
        word = many
    }
    return "\(n) \(word)"
}

/// Parsed command line of `cmcrctl setup` and `cmcrctl setup-script`.
public struct SetupCommandLine: Sendable {
    public struct ParseError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public var options = SetupOptions()
    public var mode: SetupScript.Mode = .apply
    /// Key from `--pubkey`/`--pubkey-file`; `nil` = the app's current key.
    public var publicKey: String?
    /// Arguments that are not options (e.g. `all` or a host number).
    public var positional: [String] = []

    public static let optionsHelp = """
    Opcje konfiguracji (domyślnie: klucz aplikacji, SSH tylko dla administratorów, folder ucznia, Wake-on-LAN):
      --no-key                  nie instaluj klucza SSH aplikacji
      --pubkey "ssh-ed25519 …"  zainstaluj ten klucz zamiast klucza aplikacji (--pubkey-file PLIK)
      --key-from WZORCE         ogranicz klucz do adresów, np. 192.168.1.0/24
      --no-ssh-acl              nie ograniczaj SSH do administratorów
      --no-ssh-tuning           bez ustawień sshd (keepalive)
      --ssh-key-only            SSH wyłącznie kluczem (wyłącza logowanie hasłem)
      --no-shared-acl           folder ucznia bez dziedziczonych uprawnień ACL
      --enable-vnc              włącz Udostępnianie ekranu dla administratorów
      --sudo-nopasswd           sudo bez hasła (niezalecane); --no-sudo-nopasswd usuwa
      --hostname                ustaw nazwę komputera jak na liście (w pliku: nazwa konta admin.)
      --no-wol                  nie zmieniaj Wake-on-LAN
      --no-sleep                komputer nie usypia się
      --display-sleep MIN       uśpienie ekranu po MIN minutach
      --autorestart             włącz po zaniku zasilania
      --power-schedule "MTWRF 07:30 17:00 [shutdown|sleep]" | off
      --rosetta                 zainstaluj Rosetta 2
      --updates check|download|auto
      --fix-firewall            wyłącz „Blokuj wszystkie połączenia przychodzące”
      --verify                  tylko sprawdź (nic nie zmienia); --dry-run pokazuje też polecenia
    """

    public init() {}

    public init(parsing arguments: [String]) throws {
        var i = 0
        func value(_ flag: String) throws -> String {
            guard i + 1 < arguments.count else { throw ParseError(message: "Opcja \(flag) wymaga wartości.") }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--no-key": options.installKey = false
            case "--pubkey": publicKey = try value(a)
            case "--pubkey-file":
                let path = try value(a)
                guard let text = try? String(contentsOfFile: expandTilde(path), encoding: .utf8) else {
                    throw ParseError(message: "Nie można odczytać pliku \(path).")
                }
                publicKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "--key-from": options.keyFrom = try value(a)
            case "--no-ssh-acl": options.restrictSSH = false
            case "--no-ssh-tuning": options.sshKeepAlive = false
            case "--ssh-key-only": options.sshKeyOnly = true
            case "--no-shared-acl": options.sharedACL = false
            case "--enable-vnc": options.enableVNC = true
            case "--sudo-nopasswd": options.sudo = .passwordless
            case "--no-sudo-nopasswd": options.sudo = .requirePassword
            case "--hostname": options.setHostname = true
            case "--no-wol": options.wakeOnLAN = false
            case "--no-sleep": options.noSleep = true
            case "--display-sleep":
                let v = try value(a)
                guard let m = Int(v), m >= 0 else { throw ParseError(message: "--display-sleep: liczba minut.") }
                options.displaySleepMinutes = m
            case "--autorestart": options.autoRestart = true
            case "--power-schedule":
                try parseSchedule(try value(a))
            case "--rosetta": options.rosetta = true
            case "--updates":
                guard let u = SetupOptions.UpdatePolicy(rawValue: try value(a)), u != .unchanged else {
                    throw ParseError(message: "--updates: check, download lub auto.")
                }
                options.updates = u
            case "--fix-firewall": options.fixFirewall = true
            case "--verify": mode = .verify
            case "--dry-run": mode = .dryRun
            default:
                if a.hasPrefix("-") { throw ParseError(message: "Nieznana opcja: \(a)") }
                positional.append(a)
            }
            i += 1
        }
        if let problem = options.validationError() { throw ParseError(message: problem) }
    }

    private mutating func parseSchedule(_ v: String) throws {
        if v == "off" {
            options.scheduleMode = .off
            return
        }
        let p = v.split(separator: " ").map(String.init)
        guard (2...4).contains(p.count) else {
            throw ParseError(message: "--power-schedule: \"MTWRF 07:30 17:00 [shutdown|sleep]\" lub off.")
        }
        options.scheduleMode = .set
        options.scheduleDays = p[0]
        options.scheduleOn = p[1]
        options.scheduleOff = p.count > 2 ? p[2] : ""
        if p.count > 3 {
            guard let action = SetupOptions.ScheduleAction(rawValue: p[3]) else {
                throw ParseError(message: "--power-schedule: po godzinie wyłączenia shutdown lub sleep.")
            }
            options.scheduleAction = action
        }
    }
}
