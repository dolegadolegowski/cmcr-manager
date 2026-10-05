import Foundation

/// Untrusted text from the iMacs (file names, command output, students' answers, app versions) shown in a
/// terminal. Control characters there are commands for the terminal: ESC sequences change the window title,
/// clear the screen or recolour text, a carriage return overwrites what is already on the line. A student who
/// names a file `a␛]0;…␇␛[2J` could hide or forge `cmcrctl` output. These helpers make such characters
/// visible instead; Polish letters and every other printable character stay as they are.
///
/// The app shows remote text in SwiftUI views, which never interpret escape sequences, so only the command
/// line uses this.
public enum TerminalText {
    /// One-line display form of a single value (a name, a path, an answer): line breaks, tabs, carriage
    /// returns and other C0/DEL/C1 control characters become `\n`, `\t`, `\r`, `\x1B`…, the bidirectional
    /// overrides (U+202A–U+202E, U+2066–U+2069) become `\u{202E}`…, and `\` becomes `\\` (unless
    /// `keepBackslash`), so an escaped value can always be told apart from a literal one.
    public static func escape(_ text: String, keepBackslash: Bool = false) -> String {
        guard text.unicodeScalars.contains(where: { needsEscape($0) || (!keepBackslash && $0 == "\\") }) else {
            return text
        }
        var out = String.UnicodeScalarView()
        func append(_ s: String) { out.append(contentsOf: s.unicodeScalars) }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5C: append(keepBackslash ? "\\" : "\\\\")
            case 0x0A: append("\\n")
            case 0x09: append("\\t")
            case 0x0D: append("\\r")
            case 0x00...0x1F, 0x7F...0x9F: append(String(format: "\\x%02X", scalar.value))
            case 0x202A...0x202E, 0x2066...0x2069: append(String(format: "\\u{%04X}", scalar.value))
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// Filter for a byte stream (remote stdout/stderr) written to a terminal, like `cat -v`: line feeds,
    /// tabs and CR LF pairs pass, every other C0 control byte becomes `^X` (ESC → `^[`, BEL → `^G`, a lone
    /// carriage return → `^M`), DEL becomes `^?` and a UTF-8 encoded C1 control (U+0080–U+009F, e.g. the
    /// one-character CSI U+009B) becomes `M-^X`. Everything else – UTF-8 text included – is passed unchanged.
    ///
    /// Output arrives in arbitrary chunks, so a trailing CR (maybe the start of CR LF) or 0xC2 (maybe the
    /// start of a C1 control) is held back until the next chunk; `finish()` returns what is still held.
    public struct StreamFilter: Sendable {
        private var pending: [UInt8] = []

        public init() {}

        public mutating func filter(_ data: Data) -> Data {
            guard !data.isEmpty else { return Data() }
            let input = pending + [UInt8](data)
            pending = []
            var out = [UInt8]()
            out.reserveCapacity(input.count + 8)
            var i = 0
            while i < input.count {
                let byte = input[i]
                switch byte {
                case 0x0A, 0x09:
                    out.append(byte)
                case 0x0D:
                    guard i + 1 < input.count else {
                        pending = [byte]
                        return Data(out)
                    }
                    if input[i + 1] == 0x0A { out.append(byte) } else { out += [0x5E, 0x4D] }  // ^M
                case 0x00...0x1F:
                    out += [0x5E, byte + 0x40]  // ^@ … ^_
                case 0x7F:
                    out += [0x5E, 0x3F]  // ^?
                case 0xC2:
                    guard i + 1 < input.count else {
                        pending = [byte]
                        return Data(out)
                    }
                    let next = input[i + 1]
                    if (0x80...0x9F).contains(next) {
                        out += [0x4D, 0x2D, 0x5E, next - 0x80 + 0x40]  // M-^X
                        i += 2
                        continue
                    }
                    out.append(byte)
                default:
                    out.append(byte)
                }
                i += 1
            }
            return Data(out)
        }

        /// The bytes still held back at the end of the stream, made safe.
        public mutating func finish() -> Data {
            defer { pending = [] }
            switch pending {
            case [0x0D]: return Data([0x5E, 0x4D])
            default: return Data(pending)
            }
        }
    }
}
