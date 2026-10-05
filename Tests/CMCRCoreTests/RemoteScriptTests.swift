import Foundation
import Testing
@testable import CMCRCore

/// Runs scripts locally exactly as sshd would (`<login shell> -c remoteCommand()`), without ssh. `sudo` is a
/// shell function loaded through BASH_ENV that checks the password supplied by SUDO_ASKPASS and runs the
/// command as the current user, so nothing here can reach the real sudo: `guardFakes()` verifies that
/// before any wrapper is executed.
///
/// Foundation's Process passes argv and environment strings in decomposed form (NFD), so the expected
/// password is read from a file and non-ASCII text never travels in arguments.
@Suite struct RemoteScriptExecutionTests {
    static let password = "pä ss 'q' \"d\" $HOME \\ `x` ; zażółć 🍎"

    struct Sandbox {
        let dir: URL
        var log: URL { dir.appendingPathComponent("sudo.log") }

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-unit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fakes = #"""
            _t_log() { printf '%s\n' "$*" >> "$CMCR_T_LOG"; }
            sudo() {
              local askpass=0 nonint=0
              while [ $# -gt 0 ]; do
                case "$1" in
                  -A) askpass=1; shift ;; -n) nonint=1; shift ;;
                  -u|-g|-p|-C|-h) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;;
                esac
              done
              if [ $nonint = 1 ]; then echo "sudo: a password is required" >&2; return 1; fi
              if [ $askpass = 0 ]; then echo "sudo: a terminal is required to read the password" >&2; return 1; fi
              local pw
              pw="$("$SUDO_ASKPASS" "Password:")" || { echo "sudo: no password was provided" >&2; return 1; }
              if [ "$pw" != "$(cat "$CMCR_T_PWFILE")" ]; then
                _t_log "wrong password"
                echo "Sorry, try again." >&2; echo "sudo: 1 incorrect password attempt" >&2; return 1
              fi
              _t_log "sudo $*"
              CMCR_T_ROOT=1 SUDO_USER="$(id -un)" "$@"
            }
            export -f _t_log sudo
            """#
            try fakes.write(to: dir.appendingPathComponent("fakes.sh"), atomically: true, encoding: .utf8)
            try Data(RemoteScriptExecutionTests.password.utf8).write(to: dir.appendingPathComponent("password"))
        }

        var environment: [String: String] {
            ["BASH_ENV": dir.appendingPathComponent("fakes.sh").path, "CMCR_T_LOG": log.path,
             "CMCR_T_PWFILE": dir.appendingPathComponent("password").path]
        }

        func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

        /// The fake sudo must be what every bash (including a nested one, like the root re-exec) sees.
        func guardFakes() async -> Bool {
            let r = await ProcessRunner.run("/bin/bash", ["--noprofile", "--norc", "-c",
                                                          #"type -t sudo; /bin/bash --noprofile --norc -c 'type -t sudo'"#],
                                            environment: environment)
            return r.stdoutText == "function\nfunction\n"
        }

        func run(_ script: RemoteScript, stdin: String, shell: String = "/bin/sh") async -> CommandResult {
            await ProcessRunner.run(shell, ["-c", script.remoteCommand()],
                                    environment: environment, stdin: Data(stdin.utf8), timeout: 60)
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func passwordIsTheFirstLineOnly() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes(), "atrapa sudo nieaktywna – test przerwany")
        let r = await box.run(RemoteScript(#"printf '[%s]' "$CMCR_PW"; echo; cat"#), stdin: Self.password + "\nreszta wejścia\n")
        #expect(r.exitCode == 0)
        #expect(r.stdoutText == "[\(Self.password)]\nreszta wejścia\n")
    }

    @Test func libraryVariablesAndPrivateTempDirectory() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let body = #"""
        echo "admin=$CMCR_ADMIN_USER"
        echo "tmp=$CMCR_TMP"
        echo "mode=$(stat -f %Lp "$CMCR_TMP")"
        echo "askpass=$(stat -f %Lp "$CMCR_TMP/askpass")"
        type asroot as_console_user with_askpass is_admin_user >/dev/null && echo "functions=ok"
        """#
        let r = await box.run(RemoteScript(body), stdin: "x\n")
        let kv = Parsers.keyValues(r.stdoutText)
        #expect(r.exitCode == 0)
        #expect(kv["admin"] == NSUserName())
        #expect(kv["mode"] == "700")
        #expect(kv["askpass"] == "700")
        #expect(kv["functions"] == "ok")
        let tmp = try #require(kv["tmp"])
        #expect(tmp.hasPrefix("/tmp/cmcr."))
        #expect(!FileManager.default.fileExists(atPath: tmp), "katalog tymczasowy usunięty po zakończeniu")
    }

    @Test func rootModeReExecutesBodyThroughSudo() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let body = #"printf 'root=%s pw=[%s]\n' "${CMCR_T_ROOT:-0}" "$CMCR_PW"; echo "tmp=$CMCR_TMP"; asroot echo zagniezdzone"#
        let r = await box.run(RemoteScript(body, asRoot: true), stdin: Self.password + "\n")
        #expect(r.exitCode == 0, "\(r.stderrText)")
        #expect(r.stdoutText.contains("root=1 pw=[\(Self.password)]\n"))
        #expect(r.stdoutText.contains("zagniezdzone"))
        #expect(box.logText().contains("sudo /bin/bash --noprofile --norc -c"))
        let tmp = r.stdoutText.components(separatedBy: "tmp=").last?.components(separatedBy: "\n").first ?? ""
        #expect(tmp.hasPrefix("/tmp/cmcr.") && !FileManager.default.fileExists(atPath: tmp))
    }

    @Test func rootModeWithWrongPasswordDoesNotRunBody() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let r = await box.run(RemoteScript("echo nie-powinno", asRoot: true), stdin: "zle haslo\n")
        #expect(r.exitCode != 0)
        #expect(!r.stdoutText.contains("nie-powinno"))
        #expect(SSH.diagnose(r).1 == "Błędne hasło administratora (sudo).")
        #expect(box.logText().contains("wrong password"))
    }

    @Test func rootModeWithoutPasswordStopsBeforeSudo() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let r = await box.run(RemoteScript("echo nie-powinno", asRoot: true), stdin: "")
        #expect(r.exitCode == 91)
        #expect(r.stderrText.contains("Brak hasła administratora"))
        #expect(!r.stdoutText.contains("nie-powinno"))
        #expect(!box.logText().contains("sudo /bin/bash"))
    }

    @Test(arguments: [false, true])
    func exitCodesPassThrough(asRoot: Bool) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let seven = await box.run(RemoteScript("echo przed; exit 7", asRoot: asRoot), stdin: Self.password + "\n")
        #expect(seven.exitCode == 7)
        #expect(seven.stdoutText == "przed\n")
        let falseLast = await box.run(RemoteScript("true; false", asRoot: asRoot), stdin: Self.password + "\n")
        #expect(falseLast.exitCode == 1)
        let ok = await box.run(RemoteScript("false; true", asRoot: asRoot), stdin: Self.password + "\n")
        #expect(ok.exitCode == 0)
    }

    @Test func remoteCommandSurvivesLoginShells() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let script = RemoteScript(#"printf '%s|' "zażółć 🍎" "$CMCR_PW" "a'b\"c""#)
        #expect(script.remoteCommand().unicodeScalars.allSatisfy { $0.isASCII }, "argv musi być ASCII – Process zamienia tekst na NFD")
        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
            let r = await box.run(script, stdin: "hasło ąę x\n", shell: shell)
            #expect(r.stdout == Data("zażółć 🍎|hasło ąę x|a'b\"c|".utf8), "powłoka \(shell): \(r.stderrText)")
        }
    }

    @Test func heredocTerminatorInBodyIsHarmless() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try #require(await box.guardFakes())
        let body = "cat <<'EOF'\nCMCR_B\nCMCR_L\nEOF\necho koniec"
        let r = await box.run(RemoteScript(body), stdin: "\n")
        #expect(r.stdoutText == "CMCR_B\nCMCR_L\nkoniec\n")
    }
}

@Suite struct ShellQuotingTests {
    /// Deterministic generator so a failure is reproducible.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomStrings(count: Int) -> [String] {
        var rng = SplitMix(state: 2026)
        let pool: [Character] = Array(" \t\n'\"\\$`!*?[]{}()<>|&;#~%^=,.-_/:@+abcXYZ019ąćęłńóśźżĄŻ🍎✓€é") + ["e\u{301}", "\r\n"]
        var out = ["", "'", "''", "\\'", "'\\''", "$(id)", "`id`", "${HOME}", "-n", "--", "*", "\n", " lead", "trail "]
        for _ in 0..<count {
            let length = Int.random(in: 1...40, using: &rng)
            out.append(String((0..<length).map { _ in pool.randomElement(using: &rng)! }))
        }
        return out
    }

    @Test(arguments: ["/bin/bash", "/bin/sh", "/bin/zsh"])
    func roundTripsArbitraryStrings(shell: String) async throws {
        try #require(FileManager.default.isExecutableFile(atPath: shell))
        let strings = Self.randomStrings(count: 400)
        let script = strings.map { "printf '%s\\0' \(shQuote($0))" }.joined(separator: "\n")
        // On stdin: Process would decompose (NFD) non-ASCII text passed as an argument.
        let r = await ProcessRunner.run(shell, ["-s"], stdin: Data(script.utf8), timeout: 60)
        #expect(r.exitCode == 0, "\(r.stderrText)")
        let parts = r.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        #expect(parts.count == strings.count)
        for (got, want) in zip(parts, strings) where Data(got) != Data(want.utf8) {
            Issue.record("shQuote nie zachował wartości: \(want.debugDescription) → \(String(decoding: got, as: UTF8.self).debugDescription)")
        }
    }

    @Test func quotedValueIsOneWord() async {
        let r = await ProcessRunner.run("/bin/bash", ["--noprofile", "--norc", "-c",
                                                      "set -- \(shQuote("a b")) \(shQuote("")) \(shQuote("*")); echo $#"])
        #expect(r.stdoutText == "3\n")
    }
}

@Suite struct ScriptCatalogTests {
    @Test func everyBuilderPassesBashSyntaxCheck() async {
        let problems = await ScriptCatalog.syntaxCheck()
        #expect(problems.isEmpty, "\(problems.map(\.description).joined(separator: "\n"))")
    }

    @Test func catalogCoversEveryPowerActionAndUpdateVariant() {
        let names = Set(ScriptCatalog.samples.map(\.name))
        for action in PowerAction.allCases { #expect(names.contains("power(\(action.rawValue))")) }
        #expect(names.filter { $0.hasPrefix("installUpdates") }.count == 8)
        #expect(names.count == ScriptCatalog.samples.count, "nazwy próbek są unikalne")
    }

    @Test func syntaxCheckReportsBrokenScripts() async {
        let broken = [ScriptCatalog.Sample(name: "zepsuty", script: RemoteScript("if then fi"))]
        let problems = await ScriptCatalog.syntaxCheck(broken)
        #expect(problems.contains { $0.name == "zepsuty" && $0.mode == "treść" })
    }

    @Test func awkwardValuesAreQuotedNotInterpreted() {
        let rendered = Scripts.openURL(ScriptCatalog.awkward).body
        #expect(rendered.contains("TARGET=" + shQuote(ScriptCatalog.awkward)))
        let key = Scripts.distributeKey("ssh-ed25519 AAAA it's").body
        #expect(key.contains("KEY=" + shQuote("ssh-ed25519 AAAA it's")))
    }
}
