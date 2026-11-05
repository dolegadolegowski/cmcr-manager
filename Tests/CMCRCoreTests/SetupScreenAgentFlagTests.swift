import Foundation
import Testing
@testable import CMCRCore

/// `--screen-agent` / `--no-screen-agent` of `cmcrctl setup` (SetupOptions.screenAgent): an app and cmcrctl option –
/// the agent ships inside the app, so the bash script must never see it (docs/screen-agent.md).
@Suite struct SetupScreenAgentFlagTests {
    let host = Machine(name: "imac07", address: "imac07.local", user: "imac07")

    @Test func flagIsParsed() throws {
        // On by default, also when the app last had it switched off: installing the same version changes nothing.
        var saved = SetupOptions()
        saved.screenAgent = false
        #expect(try SetupCommandLine(parsing: ["all"], saved: saved).options.screenAgent)
        let off = try SetupCommandLine(parsing: ["3", "--no-screen-agent", "--verify"], saved: SetupOptions())
        #expect(!off.options.screenAgent)
        #expect(off.mode == .verify && off.positional == ["3"])
        #expect(try SetupCommandLine(parsing: ["--no-screen-agent", "--screen-agent"], saved: SetupOptions()).options.screenAgent)
        // A configuration option: `readiness` refuses it like the others.
        #expect(off.configurationFlags == ["--no-screen-agent"])
        #expect(SetupCommandLine.optionsHelp.contains("--no-screen-agent"))
        #expect(SetupCommandLine.optionsHelp.contains("--screen-agent"))
    }

    @Test func scriptNeverSeesTheFlag() {
        var on = SetupOptions()
        on.screenAgent = true
        var off = on
        off.screenAgent = false
        let settings = AppSettings()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for mode in [SetupScript.Mode.apply, .verify, .dryRun] {
            let a = SetupScript.arguments(on, host: host, settings: settings, publicKey: nil, mode: mode)
            #expect(a == SetupScript.arguments(off, host: host, settings: settings, publicKey: nil, mode: mode))
            #expect(!a.contains { $0.lowercased().contains("agent") }, "\(a)")
            #expect(SetupScript.remote(on, host: host, settings: settings, publicKey: nil, mode: mode).body
                    == SetupScript.remote(off, host: host, settings: settings, publicKey: nil, mode: mode).body)
        }
        let standalone = SetupScript.standalone(on, settings: settings, publicKey: nil, date: date)
        #expect(standalone == SetupScript.standalone(off, settings: settings, publicKey: nil, date: date))
        let defaults = standalone.components(separatedBy: "\n").filter { $0.hasPrefix("OPT_") }
        #expect(!defaults.isEmpty)
        #expect(!defaults.contains { $0.uppercased().contains("AGENT") }, "\(defaults)")
    }

    @Test func savedOptionsKeepTheChoice() throws {
        var o = SetupOptions()
        o.screenAgent = false
        let back = try JSONDecoder().decode(SetupOptions.self, from: JSONEncoder().encode(o))
        #expect(!back.screenAgent)
        // Options saved before the agent existed: it is installed.
        #expect(try JSONDecoder().decode(SetupOptions.self, from: Data(#"{"installKey":false}"#.utf8)).screenAgent)
    }
}
