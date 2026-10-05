import Foundation
import Testing
@testable import CMCRCore

@Suite struct UTF8StreamDecoderTests {
    static let samples = ["zażółć gęślą jaźń", "🍎 Jabłko", "👩‍👩‍👧 rodzina", "e\u{301}", "ascii only", "✓ ok\n✗ błąd\n", "中文"]

    @Test(arguments: samples)
    func everySplitPointReassembles(text: String) {
        let bytes = Data(text.utf8)
        for cut in 0...bytes.count {
            let d = UTF8StreamDecoder()
            let joined = d.decode(bytes.prefix(cut)) + d.decode(bytes.suffix(from: cut))
            #expect(joined == text, "podział po \(cut) bajtach")
            #expect(!joined.contains("\u{FFFD}"))
        }
    }

    @Test(arguments: samples)
    func byteByByte(text: String) {
        let d = UTF8StreamDecoder()
        var out = ""
        var emittedPartial = false
        for b in Data(text.utf8) {
            let piece = d.decode(Data([b]))
            if piece.contains("\u{FFFD}") { emittedPartial = true }
            out += piece
        }
        #expect(out == text)
        #expect(!emittedPartial)
    }

    @Test func incompleteTailIsHeldBack() {
        let d = UTF8StreamDecoder()
        let apple = Data("🍎".utf8)
        #expect(d.decode(Data("a".utf8) + apple.prefix(3)) == "a")
        #expect(d.decode(apple.suffix(1)) == "🍎")
    }

    @Test func completePrefixLength() {
        let ż = Data("ż".utf8) // C5 BC
        #expect(UTF8StreamDecoder.completePrefixLength(Data()) == 0)
        #expect(UTF8StreamDecoder.completePrefixLength(Data("ab".utf8)) == 2)
        #expect(UTF8StreamDecoder.completePrefixLength(Data("a".utf8) + ż.prefix(1)) == 1)
        #expect(UTF8StreamDecoder.completePrefixLength(Data("a".utf8) + ż) == 3)
    }

    @Test func invalidBytesDoNotStallTheStream() {
        let d = UTF8StreamDecoder()
        let first = d.decode(Data([0x80, 0x80, 0x41]))
        #expect(first.hasSuffix("A"))
        #expect(d.decode(Data("ok".utf8)) == "ok")
    }
}
