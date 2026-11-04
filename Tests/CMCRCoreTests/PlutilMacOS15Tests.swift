import Foundation
import Testing
@testable import CMCRCore

/// On macOS 15 `plutil -extract KEY raw -o - FILE` prints „Could not extract value, error: No value at that key
/// path…” on stdout (exit 1) when the key is missing; macOS 26 and later print it on stderr. The fake below
/// reproduces macOS 15 on any Mac: the scripts must take a value only from a plutil that succeeded, never its error.
@Suite struct PlutilMacOS15Tests {
    static let macOS15 = #"plutil() { command plutil "$@" 2>&1; }"#

    /// Runs `RemoteScript.library`, the macOS 15 plutil and `script` in /bin/bash; returns stdout and stderr.
    static func bash(_ script: String, env: [String: String] = [:]) throws -> (out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["--noprofile", "--norc", "-c", RemoteScript.library + "\n" + macOS15 + "\n" + script]
        var e = ProcessInfo.processInfo.environment
        e.removeValue(forKey: "BASH_ENV")
        e.merge(env) { $1 }
        p.environment = e
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
    }

    /// A fresh folder in /private/tmp.
    static func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: "/private/tmp/cmcr-plutil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The part of `body` from the line that starts with `start` to the first `end` after it (both included).
    static func fragment(_ body: String, from start: String, to end: String) throws -> String {
        let a = try #require(body.range(of: start), "„\(start)” not in the script")
        let b = try #require(body.range(of: end, range: a.upperBound..<body.endIndex), "„\(end)” not after „\(start)”")
        return String(body[a.lowerBound..<b.upperBound])
    }

    /// setup.json written by an older setup script: no result, todo_count or schedule keys.
    static let oldMarker = #"{"schema": 1, "version": "1.0.0", "timestamp": "2026-09-01T07:00:00Z"}"#

    @Test func theFakeBehavesLikeMacOS15() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("setup.json")
        try Self.oldMarker.write(to: f, atomically: true, encoding: .utf8)
        let r = try Self.bash(#"v="$(plutil -extract result raw -o - "$F" 2>/dev/null)"; echo "rc=$? v=$v""#, env: ["F": f.path])
        #expect(r.out.hasPrefix("rc=1 v=") && r.out.contains("Could not extract value"), "\(r.out)")
    }

    @Test func libraryHelperReturnsOnlyValuesPlutilFound() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.json")
        try #"{"version": "1.4.0", "todo_count": 0, "empty": "", "list": [{"id": "android"}]}"#
            .write(to: f, atomically: true, encoding: .utf8)
        let r = try Self.bash(#"""
        for k in version todo_count empty result list.0.id list.0.parent list.1.id; do
          v="$(cmcr_plist "$F" "$k")"; printf '%s=[%s] rc=%s\n' "$k" "$v" "$?"
        done
        printf 'nofile=[%s]\n' "$(cmcr_plist "$F.missing" version)"
        """#, env: ["F": f.path])
        #expect(r.out == """
            version=[1.4.0] rc=0
            todo_count=[0] rc=0
            empty=[] rc=0
            result=[] rc=0
            list.0.id=[android] rc=0
            list.0.parent=[] rc=0
            list.1.id=[] rc=0
            nofile=[]

            """, "\(r.out)")
        #expect(r.err.isEmpty, "\(r.err)")
    }

    /// The status script's setup lines against an older marker: missing keys stay empty, so the app shows no
    /// result and no to-do count instead of plutil's error.
    @Test func statusLeavesMissingSetupKeysEmpty() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("setup.json")
        try Self.oldMarker.write(to: f, atomically: true, encoding: .utf8)
        let path = #"SJ="/Library/Application Support/CMCR/setup.json""#
        let part = try Self.fragment(Scripts.status().body, from: path, to: "\nfi\n")
            .replacingOccurrences(of: path, with: #"SJ="$TEST_SJ""#)
        #expect(!part.contains("plutil"), "status reads setup.json through cmcr_plist")
        let r = try Self.bash(part, env: ["TEST_SJ": f.path])
        #expect(r.out == "setup_version=1.0.0\nsetup_result=\nsetup_time=2026-09-01T07:00:00Z\nsetup_todo=\n", "\(r.out)")
        var status = HostStatus()
        status.info = Parsers.keyValues(r.out)
        #expect(status.setupVersion == "1.0.0")
        #expect(status.setupResult == nil)
        #expect(status.setupTodo == nil)
    }

    /// The readiness check's setup lines: a marker without a timestamp must not put plutil's error into the
    /// „Skonfigurowano skryptem CMCR…” text.
    @Test func readinessLeavesMissingSetupKeysEmpty() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cmcr = dir.appendingPathComponent("Library/Application Support/CMCR")
        try FileManager.default.createDirectory(at: cmcr, withIntermediateDirectories: true)
        try #"{"schema": 1, "version": "1.0.0"}"#
            .write(to: cmcr.appendingPathComponent("setup.json"), atomically: true, encoding: .utf8)
        let body = Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr", publicKey: nil).body
        let part = try Self.fragment(body, from: #"MK="$R/Library/Application Support/CMCR/setup.json""#, to: "\nfi\n")
        #expect(!part.contains("plutil"), "readiness reads setup.json through cmcr_plist")
        let r = try Self.bash(#"kv() { printf '%s=%s\n' "$1" "$2"; }"# + "\n" + part, env: ["R": dir.path])
        #expect(r.out == "setup=1.0.0\nsetup_result=\nsetup_time=\n", "\(r.out)")
        let report = ReadinessReport.parse(r.out, student: "student", sharedFolder: "/Users/student/Public/cmcr",
                                           expectedVersion: "1.0.0")
        #expect(report[.setup].state == .ok)
        #expect(report[.setup].detail == "Skonfigurowano skryptem CMCR 1.0.0.", "\(report[.setup].detail)")
    }

    /// Hub's modules.json gives a top-level module no "parent" and may leave "selected" out: those fields stay empty.
    @Test func unityModuleListKeepsMissingFieldsEmpty() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"""
        [{"id": "android", "selected": true},
         {"id": "android-sdk-ndk-tools", "parent": "android", "selected": false},
         {"id": "ios"}]
        """#.write(to: dir.appendingPathComponent("modules.json"), atomically: true, encoding: .utf8)
        let list = dir.appendingPathComponent("m.tsv")
        let r = try Self.bash(Scripts.unityCompleteness + "\ncmcr_unity_read; cat \"$MODLIST\"",
                              env: ["ED": dir.path, "MODLIST": list.path])
        #expect(r.out == "android\t\ttrue\nandroid-sdk-ndk-tools\tandroid\tfalse\nios\t\t\n", "\(r.out)")
        #expect(r.err.isEmpty, "\(r.err)")
    }

    /// The setup script reads its marker (the power schedule it set) through plist_get.
    @Test func setupScriptReadsItsMarkerThroughPlistGet() throws {
        let t = SetupScriptTemplate.text
        let def = try #require(t.split(separator: "\n").first { $0.hasPrefix("plist_get() {") }.map(String.init))
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("setup.json")
        try Self.oldMarker.write(to: f, atomically: true, encoding: .utf8)
        let r = try Self.bash(def + "\n" + #"""
        printf 'version=[%s]\n' "$(plist_get "$F" version)"
        printf 'power_schedule=[%s]\n' "$(plist_get "$F" power_schedule)"
        printf 'nofile=[%s]\n' "$(plist_get "$F.missing" power_schedule_sched)"
        """#, env: ["F": f.path])
        #expect(r.out == "version=[1.0.0]\npower_schedule=[]\nnofile=[]\n", "\(r.out)")
        // Every other plutil -extract in the script belongs to the screen-capture consent block (cmcr_sc_*).
        let others = t.split(separator: "\n").filter { $0.contains("plutil -extract") && !$0.contains("cmcr_sc_as") }
        #expect(others == [Substring(def)], "\(others)")
        for key in ["power_schedule", "power_schedule_sched"] {
            #expect(t.contains("\"$(plist_get \"$MARKER\" \(key))\""))
        }
    }

    /// The Swift scripts read plist and JSON values only through cmcr_plist; the Unity loop keeps plutil because
    /// its exit code ends the loop.
    @Test func scriptsReadValuesThroughTheLibraryHelper() {
        #expect(!Scripts.status().body.contains("plutil"))
        #expect(!Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr", publicKey: nil).body
            .components(separatedBy: "\n").contains { $0.contains("plutil -extract") && !$0.contains("cmcr_sc_as") })
        let unity = Scripts.unityCompleteness.components(separatedBy: "\n").filter { $0.contains("plutil") }
        #expect(unity == [#"  while id="$(plutil -extract "$i.id" raw -o - "$ED/modules.json" 2>/dev/null)"; do"#], "\(unity)")
    }
}
