import Testing
@testable import CMCRCore

@Test func generatedHostsFollowCmcrHelpersNaming() {
    let hosts = Machine.generate()
    #expect(hosts.count == 15)
    #expect(hosts.first?.destination == "imac01@imac01.local")
    #expect(hosts.last?.number == 15)
}

@Test func shellQuotingSurvivesSingleQuotes() {
    #expect(shQuote("a'b") == "'a'\\''b'")
}
