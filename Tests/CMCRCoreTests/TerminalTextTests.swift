import Foundation
import Testing
@testable import CMCRCore

/// Remote text shown by cmcrctl in a terminal must not be able to drive the terminal (finding
/// terminal-escape-passthrough): ESC/OSC/CSI sequences, carriage returns and C1 controls are made visible.
@Suite struct TerminalTextTests {
    @Test func escapeLeavesPrintableTextAlone() {
        for s in ["zażółć gęślą jaźń.txt", "Notatki – lekcja 3 (wersja 2).pages", "", "a b", "§ ° « » ś ě"] {
            #expect(TerminalText.escape(s) == s)
        }
    }

    @Test func escapeMakesControlCharactersVisible() {
        #expect(TerminalText.escape("a\u{1B}]0;OWNED\u{07}\u{1B}[2Jz") == "a\\x1B]0;OWNED\\x07\\x1B[2Jz")
        #expect(TerminalText.escape("cr\rSPOOF") == "cr\\rSPOOF")
        #expect(TerminalText.escape("nowa\nlinia\tz tabem") == "nowa\\nlinia\\tz tabem")
        #expect(TerminalText.escape("c1\u{9B}31mred") == "c1\\x9B31mred")
        #expect(TerminalText.escape("del\u{7F}") == "del\\x7F")
        #expect(TerminalText.escape("nul\u{0}") == "nul\\x00")
        #expect(TerminalText.escape("abc\u{202E}gnp.exe") == "abc\\u{202E}gnp.exe")
    }

    @Test func escapeBackslash() {
        #expect(TerminalText.escape("a\\nb") == "a\\\\nb")
        #expect(TerminalText.escape("C:\\x", keepBackslash: true) == "C:\\x")
        #expect(TerminalText.escape("C:\\x\u{1B}", keepBackslash: true) == "C:\\x\\x1B")
    }

    func filtered(_ chunks: [[UInt8]]) -> String {
        var f = TerminalText.StreamFilter()
        var out = Data()
        for c in chunks { out += f.filter(Data(c)) }
        out += f.finish()
        return String(decoding: out, as: UTF8.self)
    }

    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func filterPassesTextUnchanged() {
        let text = "== imac01 ==\nzażółć gęślą jaźń\tkolumna\r\nkoniec ś ě § °\n"
        var f = TerminalText.StreamFilter()
        let out = f.filter(Data(text.utf8)) + f.finish()
        #expect(out == Data(text.utf8))
    }

    @Test func filterNeutralisesEscapeSequences() {
        let out = filtered([bytes("a\u{1B}]0;T\u{07}b\u{1B}[2J\u{08}\u{7F}\n")])
        #expect(out == "a^[]0;T^Gb^[[2J^H^?\n")
        #expect(!out.utf8.contains(0x1B))
    }

    @Test func filterLoneCarriageReturn() {
        #expect(filtered([bytes("cr\rSPOOF\r\n")]) == "cr^MSPOOF\r\n")
        // CR LF split across chunks stays CR LF; a CR at the very end becomes ^M.
        #expect(filtered([bytes("a\r"), bytes("\nb")]) == "a\r\nb")
        #expect(filtered([bytes("a\r"), bytes("b")]) == "a^Mb")
        #expect(filtered([bytes("50%\r")]) == "50%^M")
    }

    @Test func filterC1ControlsAlsoAcrossChunks() {
        #expect(filtered([[0x63, 0x31, 0xC2, 0x9B] + bytes("31mred")]) == "c1M-^[31mred")
        #expect(filtered([[0x63, 0xC2], [0x9B, 0x41]]) == "cM-^[A")
        // 0xC2 followed by a printable continuation (§ = C2 A7) and ś (C5 9B, 9B as a continuation byte) pass.
        #expect(filtered([[0xC2], [0xA7]]) == "§")
        #expect(filtered([bytes("ś")]) == "ś")
    }
}
