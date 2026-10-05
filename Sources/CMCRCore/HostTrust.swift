import Foundation

/// Which iMac keys the app trusts, and the first-contact flow that adds one.
///
/// Every ssh/scp connection checks the Mac's host key strictly (`StrictHostKeyChecking=yes`) against the trusted
/// known_hosts files: the app's own `known_hosts` in the configuration folder, plus `~/.ssh/known_hosts` (read
/// only – keys accepted before this check existed, or confirmed in Terminal). With `UserKnownHostsFile` in the
/// extra ssh options those files are used instead.
///
/// A Mac whose key is not trusted is refused during the key exchange – before any login – so neither the admin
/// password (stdin, askpass) nor a command or a download reaches a device that only claims its name (Bonjour
/// `.local` names are not authenticated). A new or changed key is trusted only after the user saw its
/// fingerprint and confirmed it: `scan` fetches the key without any credential, `trust` stores exactly that key.
public enum HostTrust {
    /// One host key, as a known_hosts line.
    public struct Key: Sendable, Hashable {
        /// "ED25519", "ECDSA", "RSA".
        public var type: String
        /// "SHA256:…"
        public var fingerprint: String
        /// The known_hosts line (`name keytype base64`); empty for keys read from the trusted files.
        public var line: String

        public init(type: String, fingerprint: String, line: String = "") {
            self.type = type
            self.fingerprint = fingerprint
            self.line = line
        }
    }

    /// The key a Mac presents compared with what is trusted for it.
    public enum State: Sendable, Equatable {
        /// The presented key is trusted already.
        case trusted
        /// Nothing is trusted for this Mac yet (first contact).
        case new
        /// Another key is trusted: the Mac was reinstalled or replaced – or something else answers in its name.
        case changed(previous: [Key])
    }

    public struct Scan: Sendable {
        public var host: Machine
        /// What the Mac presented now.
        public var keys: [Key] = []
        /// What is trusted for its name.
        public var trusted: [Key] = []
        public var error: String?

        public var state: State? {
            guard !keys.isEmpty else { return nil }
            if trusted.isEmpty { return .new }
            let known = Set(trusted.map(\.fingerprint))
            return keys.contains { known.contains($0.fingerprint) } ? .trusted : .changed(previous: trusted)
        }
    }

    /// Why a connection was refused by the host key check, read from ssh's error output.
    public enum Refusal: Sendable, Equatable {
        /// No trusted key for this Mac yet.
        case unknown
        /// A different key is trusted for this Mac.
        case changed
    }

    // MARK: - Trusted files

    /// The app's own list of trusted iMac keys (follows `CMCR_CONFIG_DIR`).
    public static var appKnownHostsFile: URL { ConfigStore.directory.appendingPathComponent("known_hosts") }

    /// Keys accepted before strict checking existed, or confirmed by the user in Terminal; read, never added to.
    public static var legacyKnownHostsFile: String { expandTilde("~/.ssh/known_hosts") }

    /// Files ssh checks host keys against; the first one receives newly trusted keys.
    public static func files(_ s: SSHSettings) -> [String] {
        let custom = SSH.knownHostsFiles(s)
        if !custom.isEmpty { return custom }
        return [appKnownHostsFile.path, legacyKnownHostsFile]
    }

    /// `UserKnownHostsFile` value: every path quoted (the default folder is "Application Support") and `%`
    /// doubled (ssh expands %-tokens in it).
    static func optionValue(_ files: [String]) -> String {
        files.map { path in
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "%", with: "%%")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }

    /// Options every connection uses (the user's own options come first and still win).
    static func strictOptions(_ s: SSHSettings, mode: String = "yes") -> [String] {
        ["-o", "StrictHostKeyChecking=\(mode)", "-o", "UserKnownHostsFile=\(optionValue(files(s)))",
         "-o", "UpdateHostKeys=no"]
    }

    /// The name ssh uses for the Mac in known_hosts (`HostKeyAlias` from the extra options, when set).
    public static func knownHostsName(_ host: Machine, settings s: SSHSettings? = nil) -> String {
        if let alias = s.flatMap({ option("HostKeyAlias", in: $0) }) { return alias }
        let address = host.address.lowercased()
        return host.port == 22 ? address : "[\(address)]:\(host.port)"
    }

    /// Value of an option in the extra ssh options (`Name=value` or `Name value`); the first one wins, as in ssh.
    static func option(_ name: String, in s: SSHSettings) -> String? {
        for option in s.extraOptions {
            let parts = option.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " })
            guard parts.count == 2, parts[0].lowercased() == name.lowercased() else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Recognising refusals

    public static func refusal(_ r: CommandResult) -> Refusal? {
        let e = r.stderrText.lowercased()
        if e.contains("remote host identification has changed") || e.contains("has changed and you have requested strict checking") {
            return .changed
        }
        if e.contains("host key is known for") && e.contains("you have requested strict checking") {
            return .unknown
        }
        if e.contains("host key verification failed") { return .unknown }
        return nil
    }

    // MARK: - Scanning and trusting

    /// Fetches the key the Mac presents now, with every authentication method switched off: nothing but the
    /// key exchange happens, so no password or key signature is sent. Goes through the same ssh options as the
    /// real sessions (ProxyJump, port, algorithms), with connection sharing off so the key is really exchanged.
    public static func scan(_ host: Machine, settings s: SSHSettings) async -> Scan {
        var result = Scan(host: host)
        result.trusted = await trustedKeys(for: host, settings: s)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cmcr-hostkey-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            result.error = "Nie można utworzyć katalogu tymczasowego: \(error.localizedDescription)"
            return result
        }
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("known_hosts")
        fm.createFile(atPath: file.path, contents: nil)
        // The scan's own options go first, so that they win over the user's extra options.
        var args = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(optionValue([file.path]))",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HashKnownHosts=no",
            "-o", "UpdateHostKeys=no",
            "-o", "BatchMode=yes",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "GSSAPIAuthentication=no",
            "-o", "HostbasedAuthentication=no",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=\(s.connectTimeout)",
        ]
        // Real sessions prefer the key types that are trusted already; ask for the same one.
        let preferred = Self.algorithms(for: result.trusted.map(\.type))
        if !preferred.isEmpty { args += ["-o", "HostKeyAlgorithms=^" + preferred.joined(separator: ",")] }
        args += s.extraOptions.flatMap { ["-o", $0] }
        args += ["-T", "-p", String(host.port), host.destination, "true"]
        let r = await ProcessRunner.run(SSH.sshPath, args, environment: ["SSH_ASKPASS_REQUIRE": "never"],
                                        stdin: Data(), timeout: TimeInterval(s.connectTimeout + 15))
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.isEmpty {
            let (_, message) = SSH.diagnose(r)
            result.error = r.timedOut ? "Komputer nie odpowiada (wyłączony lub poza siecią)." : message
            return result
        }
        let listing = await ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-f", file.path], timeout: 15)
        let fingerprints = parseFingerprintListing(listing.stdoutText)
        guard fingerprints.count == lines.count else {
            result.error = "Nie udało się odczytać odcisku klucza: \(listing.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))"
            return result
        }
        result.keys = zip(lines, fingerprints).map { line, fp in Key(type: fp.type, fingerprint: fp.fingerprint, line: line) }
        return result
    }

    /// Keys trusted for the Mac's name in any of the trusted files.
    public static func trustedKeys(for host: Machine, settings s: SSHSettings) async -> [Key] {
        var keys: [Key] = []
        for path in files(s) where FileManager.default.fileExists(atPath: path) {
            let r = await ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-F", knownHostsName(host, settings: s), "-f", path], timeout: 15)
            for key in parseFoundListing(r.stdoutText) where !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// Trusts exactly the keys in `scan` (the ones the user saw): the Mac's old entries are removed from every
    /// trusted file, the new lines go to the first one, and the shared connection is closed so the next session
    /// checks the key again.
    public static func trust(_ scan: Scan, settings s: SSHSettings) async -> CommandResult {
        let host = scan.host
        let name = knownHostsName(host, settings: s).lowercased()
        let lines = scan.keys.map(\.line).filter { line in
            line.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() == name } ?? false
        }
        guard !lines.isEmpty, lines.count == scan.keys.count else {
            return .failure("Brak klucza do zapisania dla \(host.name).", code: 1)
        }
        let removed = await forget(host, settings: s)
        guard removed.exitCode == 0 else { return removed }
        let target = URL(fileURLWithPath: files(s)[0])
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            let existing = (try? Data(contentsOf: target)) ?? Data()
            try handle.seekToEnd()
            var text = lines.joined(separator: "\n") + "\n"
            if let last = existing.last, last != 0x0A { text = "\n" + text }
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            return .failure("Nie można zapisać klucza w \(target.path): \(error.localizedDescription)", code: 1)
        }
        ConfigStore.log("Zaufano kluczowi komputera \(host.name) (\(host.address)): "
                        + scan.keys.map { "\($0.type) \($0.fingerprint)" }.joined(separator: ", "))
        return CommandResult(exitCode: 0, stdout: Data("Zaufano kluczowi \(host.name).\n".utf8))
    }

    /// Removes the Mac's keys from every trusted file and closes its shared connection.
    public static func forget(_ host: Machine, settings s: SSHSettings) async -> CommandResult {
        await SSH.closeMaster(host, settings: s)
        let name = knownHostsName(host, settings: s)
        var result = CommandResult(exitCode: 0)
        for path in files(s) where FileManager.default.fileExists(atPath: path) {
            // Only files that know the Mac are rewritten (ssh-keygen -R leaves a .old copy next to them).
            let found = await ProcessRunner.run("/usr/bin/ssh-keygen", ["-F", name, "-f", path], timeout: 15)
            guard found.exitCode == 0, !found.stdout.isEmpty else { continue }
            let r = await ProcessRunner.run("/usr/bin/ssh-keygen", ["-R", name, "-f", path], timeout: 15)
            result.stdout += r.stdout
            result.stderr += r.stderr
            if r.exitCode != 0 { result.exitCode = r.exitCode }
        }
        return result
    }

    // MARK: - Parsing

    /// `ssh-keygen -l -f file`: "256 SHA256:abc… [host]:port (ED25519)".
    static func parseFingerprintListing(_ text: String) -> [(type: String, fingerprint: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let fp = parts.first(where: { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }),
                  let last = parts.last, last.hasPrefix("("), last.hasSuffix(")") else { return nil }
            return (String(last.dropFirst().dropLast()), String(fp))
        }
    }

    /// `ssh-keygen -l -F name -f file`: "# Host … found: line 1" and "name ED25519 SHA256:abc…".
    static func parseFoundListing(_ text: String) -> [Key] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let i = parts.firstIndex(where: { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }),
                  i > 0 else { return nil }
            return Key(type: String(parts[i - 1]), fingerprint: String(parts[i]))
        }
    }

    /// Host key algorithms for key types, in ssh's names.
    static func algorithms(for types: [String]) -> [String] {
        var out: [String] = []
        for type in types {
            let names: [String]
            switch type.uppercased() {
            case "ED25519": names = ["ssh-ed25519"]
            case "ECDSA": names = ["ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]
            case "RSA": names = ["rsa-sha2-512", "rsa-sha2-256"]
            default: names = []
            }
            for n in names where !out.contains(n) { out.append(n) }
        }
        return out
    }
}
