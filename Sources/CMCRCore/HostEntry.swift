import Foundation

/// Checks for host-list values typed on the command line (`cmcrctl hosts add`, `hosts generate`, `--mac`).
public enum HostEntry {
    public enum Kind: Sendable {
        /// Display name: shown in lists and matched by `HostSpec`, never passed to ssh.
        case name
        /// Account or address: becomes part of the ssh destination `user@address`.
        case sshPart
        /// Domain suffix of generated addresses; may be empty (bare host names).
        case domain
    }

    /// Characters OpenSSH refuses in a host name or user given on its command line; no working entry has them,
    /// and a shell would treat them as code (quotes, `$( )`, backticks, `;`, `|`…).
    public static let shellCharacters = CharacterSet(charactersIn: "'\"`$\\;&<>|(){}")

    /// Why `value` cannot be used, in Polish, or nil when it is fine.
    /// For ssh parts a space or control character would split or corrupt the destination, a leading `-` would be
    /// read by ssh as an option, an `@` would move the user/address boundary and shell characters are refused.
    public static func problem(_ value: String, as kind: Kind) -> String? {
        if value.isEmpty { return kind == .domain ? nil : "pusta wartość" }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "zawiera znak sterujący"
        }
        switch kind {
        case .name:
            if value.contains(",") { return "zawiera przecinek (oddziela komputery w wyborze 1,3)" }
            if value.hasPrefix("-") { return "zaczyna się od „-”" }
        case .sshPart, .domain:
            if value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
                return "zawiera spację"
            }
            if value.hasPrefix("-") { return "zaczyna się od „-” (ssh odczytałby to jako opcję)" }
            if value.contains("@") { return "zawiera „@”" }
            if let bad = value.unicodeScalars.first(where: { shellCharacters.contains($0) }) {
                return "zawiera niedozwolony znak „\(Character(bad))”"
            }
        }
        return nil
    }

    /// `aa:bb:cc:dd:ee:ff` from common spellings, including `arp -a`'s unpadded groups (`0:1b:…`);
    /// nil for an invalid address. With `:`/`-` separators exactly six groups are required, so a stray
    /// seventh group is not silently folded into the address.
    public static func normalizedMAC(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = trimmed.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        var bytes: [UInt8] = []
        if groups.count > 1 {
            guard groups.count == 6 else { return nil }
            for g in groups {
                guard (1...2).contains(g.count), g.allSatisfy(\.isHexDigit), let b = UInt8(g, radix: 16) else { return nil }
                bytes.append(b)
            }
        } else {
            let hex = Array(trimmed.filter { $0 != "." })
            guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
            for i in stride(from: 0, to: 12, by: 2) {
                guard let b = UInt8(String(hex[i...i + 1]), radix: 16) else { return nil }
                bytes.append(b)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

public extension Machine {
    /// Why ssh and scp must not be started for this entry, in Polish, or nil when it is fine. A hosts.json entry can
    /// come from an imported or hand-edited file: an account such as `-oProxyCommand=…` would be read by ssh as an
    /// option and run a command on this Mac, a space or `@` would move the destination elsewhere.
    var sshEntryProblem: String? {
        if let p = HostEntry.problem(user, as: .sshPart) { return "konto administratora – \(p)" }
        if let p = HostEntry.problem(address, as: .sshPart) { return "adres – \(p)" }
        if !HostValidation.portRange.contains(port) { return "port \(port) spoza zakresu 1–65535" }
        return nil
    }
}
