import AppKit
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

// App-model tests for the review findings of group G1 (REV-xx in AUDIT.md). Each test reproduces the reported problem.

@MainActor
@Suite(.serialized, .enabled(if: AppTestEnvironment.isIsolated, "uruchamiaj przez scripts/test.sh (izolowana konfiguracja)"))
struct RevG1AppTests {
    /// AUDIT REV-05: hosts.json edited by hand while the app runs and left invalid was replaced by the app's next save
    /// (here: an edit in the list) without a word; its original survived only in a .bak nothing pointed to.
    @Test func replacingADamagedListWrittenOutsideIsReported() throws {
        let a = AppTestEnvironment.closedHost("imac01"), b = AppTestEnvironment.closedHost("imac02")
        let model = AppTestEnvironment.makeModel([a, b])
        model.configIssues = []
        model.notice = nil
        let file = ConfigStore.directory.appendingPathComponent("hosts.json")
        let text = try #require(String(data: JSONEncoder().encode([a, b]), encoding: .utf8))
        // A pasted entry without the comma before it.
        try Data((String(text.dropLast()) + #" {"address":"imac16.local"}]"#).utf8).write(to: file)

        model.machines[0].notes = "przy oknie"
        #expect(model.machines.map(\.name) == ["imac01", "imac02"])
        let issue = try #require(model.configIssues.first, "uszkodzona lista zastąpiona bez ostrzeżenia")
        #expect(issue.contains("zmieniona poza aplikacją"), "\(issue)")
        #expect(issue.contains("hosts.json.") && issue.contains(".bak"), "\(issue)")
        #expect(model.notice == nil, "zapis się udał – to nie jest błąd zapisu")
        #expect(try JSONDecoder().decode([Machine].self, from: Data(contentsOf: file)) == model.machines)

        // Reported once: the next change saves without a new warning.
        model.configIssues = []
        model.machines[1].notes = "przy drzwiach"
        #expect(model.configIssues.isEmpty)
    }
}
