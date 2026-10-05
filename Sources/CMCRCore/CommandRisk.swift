import Foundation

/// Recognises shell commands that delete data or restart/shut down Macs, so the app can ask before running
/// them as root on a whole classroom.
public enum CommandRisk {
    private static let patterns: [(regex: String, label: String)] = [
        (#"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\b"#, "usuwanie folderów (rm -r)"),
        (#"\bdiskutil\b"#, "operacje na dyskach (diskutil)"),
        (#"\bdscl\s+\S+\s+-delete\b"#, "usuwanie kont lub ustawień (dscl -delete)"),
        (#"\bsysadminctl\b.*-deleteUser\b"#, "usuwanie konta (sysadminctl -deleteUser)"),
        (#"\b(shutdown|reboot|halt)\b"#, "wyłączenie lub restart"),
        (#"\bpmset\b"#, "ustawienia zasilania (pmset)"),
        (#"\blaunchctl\s+(bootout|unload|disable)\b"#, "wyłączanie usług (launchctl)"),
        (#"\b(newfs\w*|mkfs\w*)\b"#, "formatowanie"),
        (#"\bdd\s+[^|;]*\bof="#, "zapis bezpośrednio na urządzenie (dd)"),
        (#"\bkillall\b"#, "zamykanie procesów (killall)"),
    ]

    /// Human-readable descriptions of the risky operations found in `script` (empty when none).
    public static func risks(in script: String) -> [String] {
        patterns.compactMap { p in
            script.range(of: p.regex, options: .regularExpression) != nil ? p.label : nil
        }
    }

    /// Whether the script runs (entirely or partly) with root privileges.
    public static func usesRoot(_ script: String, asRoot: Bool) -> Bool {
        asRoot || script.range(of: #"\b(asroot|sudo)\b"#, options: .regularExpression) != nil
    }
}
