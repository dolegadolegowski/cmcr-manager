import Foundation
import Testing
@testable import CMCRCore

@Suite struct HostSpecTests {
    /// A lab with a gap (imac04 removed) and a host without a number.
    let hosts: [Machine] = Machine.generate(count: 6).filter { $0.name != "imac04" }
        + [Machine(name: "nauczyciel", address: "teacher.local", user: "admin")]

    func names(_ spec: String) throws -> [String] { try HostSpec.select(spec, from: hosts).map(\.name) }

    @Test func allVariants() throws {
        for spec in ["all", "ALL", "wszystkie", "*", " all "] {
            #expect(try names(spec).count == hosts.count)
        }
    }

    @Test func numberMatchesNameNotListPosition() throws {
        #expect(try names("5") == ["imac05"])
        #expect(try names("05") == ["imac05"])
        // Position 4 is imac05 – a missing number must never fall back to the list index.
        #expect(throws: HostSpec.SelectionError.notFound(["4"])) { try names("4") }
        #expect(throws: HostSpec.SelectionError.notFound(["99"])) { try names("99") }
    }

    @Test func listsRangesAndPositions() throws {
        #expect(try names("1,3") == ["imac01", "imac03"])
        #expect(try names("3, 1 ,3") == ["imac01", "imac03"])
        #expect(try names("2-5") == ["imac02", "imac03", "imac05"])
        #expect(try names("@4") == ["imac05"])
        #expect(try names("@6") == ["nauczyciel"])
        #expect(try names("6,@1") == ["imac01", "imac06"])
    }

    @Test func namesAddressesAndAccounts() throws {
        #expect(try names("imac02") == ["imac02"])
        #expect(try names("IMAC02") == ["imac02"])
        #expect(try names("imac03.local") == ["imac03"])
        #expect(try names("admin") == ["nauczyciel"])
        #expect(try names("admin@teacher.local") == ["nauczyciel"])
        #expect(try names("nauczyciel,1") == ["imac01", "nauczyciel"])
    }

    @Test func anyUnknownPartFailsTheWholeSelection() {
        #expect(throws: HostSpec.SelectionError.notFound(["imac09", "@8"])) { try names("1,imac09,@8") }
        #expect(throws: HostSpec.SelectionError.notFound(["7-9"])) { try names("7-9") }
        #expect(throws: HostSpec.SelectionError.notFound(["5-2"])) { try names("5-2") }
        #expect(throws: HostSpec.SelectionError.notFound(["@0"])) { try names("@0") }
    }

    /// An unquoted `#2` is a shell comment in scripts, so `#` is not a position marker; a quoted one is an
    /// error that points to `@2` instead of silently matching something.
    @Test func hashIsNotAPosition() {
        #expect(throws: HostSpec.SelectionError.notFound(["#2"])) { try names("#2") }
        let message = HostSpec.SelectionError.notFound(["#2"]).localizedDescription
        #expect(message.contains("@2"))
        #expect(!HostSpec.SelectionError.notFound(["9"]).localizedDescription.contains("@2"))
    }

    @Test func emptyInputs() {
        #expect(throws: HostSpec.SelectionError.empty) { try names("  ") }
        #expect(throws: HostSpec.SelectionError.empty) { try names(",,") }
        #expect(throws: HostSpec.SelectionError.emptyList) { try HostSpec.select("1", from: []) }
    }

    @Test func errorsArePolish() {
        let message = HostSpec.SelectionError.notFound(["9"]).localizedDescription
        #expect(message.contains("Nie znaleziono komputera: 9"))
    }
}
