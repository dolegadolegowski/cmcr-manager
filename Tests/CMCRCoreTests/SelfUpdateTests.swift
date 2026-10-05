import CryptoKit
import Foundation
import Testing
@testable import CMCRCore

@Suite struct SemanticVersionTests {
    @Test func parsesCommonForms() throws {
        #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("v1.2") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion("2") == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion("1.2.3+45") == SemanticVersion("1.2.3"))
        #expect(SemanticVersion("1.0.0-beta.2")?.prerelease == ["beta", "2"])
        #expect(SemanticVersion(" 1.0.0\n")?.description == "1.0.0")
    }

    @Test(arguments: ["", "v", "1.2.3.4", "a.b.c", "1..2", "1.2.3-", "1.2.3-be@ta", "1.2.-3", "1.2.3-a..b", "١.٢.٣"])
    func rejectsInvalid(_ s: String) {
        #expect(SemanticVersion(s) == nil)
    }

    @Test func ordersLikeSemVer() throws {
        // Precedence example from semver.org §11.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "1.10.0", "2.0.0"].map { SemanticVersion($0)! }
        for i in 0..<(ordered.count - 1) {
            #expect(ordered[i] < ordered[i + 1], "\(ordered[i]) < \(ordered[i + 1])")
            #expect(!(ordered[i + 1] < ordered[i]))
        }
        #expect(ordered.shuffled().sorted() == ordered)
    }
}

@Suite struct ManifestTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    func manifest(_ edit: (inout UpdateManifest) -> Void = { _ in }) -> UpdateManifest {
        var m = UpdateManifest(schema: 1, bundleIdentifier: "pl.cmcr.manager", version: "1.2.0", build: "57", tag: "v1.2.0",
                               file: "CMCR-Manager-1.2.0.zip", size: 1234, sha256: String(repeating: "ab", count: 32),
                               minimumSystemVersion: "13.0", architectures: ["arm64", "x86_64"], notes: nil, publishedAt: nil)
        edit(&m)
        return m
    }

    func signed(_ data: Data, with k: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        Data(try (k ?? key).signature(for: data).base64EncodedString().utf8)
    }

    @Test func acceptsValidSignatureAndRotatedKeys() throws {
        let data = try JSONEncoder().encode(manifest())
        try UpdateVerifier.verifySignature(manifest: data, signature: try signed(data), trustedKeys: [publicKey])
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        try UpdateVerifier.verifySignature(manifest: data, signature: try signed(data), trustedKeys: ["bogus", other, publicKey])
    }

    @Test func rejectsTamperingWrongKeyAndGarbage() throws {
        var data = try JSONEncoder().encode(manifest())
        let sig = try signed(data)
        data[data.count / 2] ^= 0x01
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verifySignature(manifest: data, signature: sig, trustedKeys: [publicKey]) }
        let original = try JSONEncoder().encode(manifest())
        let foreign = try signed(original, with: Curve25519.Signing.PrivateKey())
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verifySignature(manifest: original, signature: foreign, trustedKeys: [publicKey]) }
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verifySignature(manifest: original, signature: Data("xyz".utf8), trustedKeys: [publicKey]) }
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verifySignature(manifest: original, signature: sig, trustedKeys: []) }
    }

    @Test func feedVerifiesBeforeParsing() throws {
        let feed = UpdateFeed(configuration: UpdateConfiguration(repository: "a/b", trustedPublicKeys: [publicKey], bundleIdentifier: "pl.cmcr.manager"),
                              userAgent: "test")
        let garbage = Data("not json".utf8)
        #expect(throws: UpdateError.badSignature) { _ = try feed.decodeVerified(garbage, signature: Data("AAAA".utf8)) }
        // Correctly signed but malformed → invalidManifest, only after the signature check.
        #expect(throws: (any Error).self) { _ = try feed.decodeVerified(garbage, signature: try signed(garbage)) }
        let good = try JSONEncoder().encode(manifest())
        #expect(try feed.decodeVerified(good, signature: try signed(good)) == manifest())
    }

    @Test func validatesAgainstAppAndRelease() throws {
        #expect(try UpdateVerifier.validate(manifest(), bundleIdentifier: "pl.cmcr.manager", releaseTag: "v1.2.0") == SemanticVersion("1.2.0"))
        #expect(throws: UpdateError.wrongApplication("x.y")) {
            try UpdateVerifier.validate(manifest { $0.bundleIdentifier = "x.y" }, bundleIdentifier: "pl.cmcr.manager", releaseTag: nil)
        }
        // A signed old manifest re-published under a newer tag must not pass.
        #expect(throws: UpdateError.versionMismatch(expected: "v9.9.9", found: "1.2.0")) {
            try UpdateVerifier.validate(manifest(), bundleIdentifier: "pl.cmcr.manager", releaseTag: "v9.9.9")
        }
        #expect(throws: (any Error).self) { try UpdateVerifier.validate(manifest { $0.tag = "v1.3.0" }, bundleIdentifier: "pl.cmcr.manager", releaseTag: nil) }
        #expect(throws: (any Error).self) { try UpdateVerifier.validate(manifest { $0.file = "../evil.zip" }, bundleIdentifier: "pl.cmcr.manager", releaseTag: nil) }
        #expect(throws: (any Error).self) { try UpdateVerifier.validate(manifest { $0.sha256 = String(repeating: "AB", count: 32) }, bundleIdentifier: "pl.cmcr.manager", releaseTag: nil) }
        #expect(throws: UpdateError.systemTooOld("99.0")) {
            try UpdateVerifier.validate(manifest { $0.minimumSystemVersion = "99.0" }, bundleIdentifier: "pl.cmcr.manager", releaseTag: nil)
        }
        let foreignArch = UpdateVerifier.hostArchitecture == "arm64" ? "x86_64" : "arm64"
        #expect(throws: UpdateError.unsupportedArchitecture([foreignArch])) {
            try UpdateVerifier.validate(manifest { $0.architectures = [foreignArch] }, bundleIdentifier: "pl.cmcr.manager", releaseTag: nil)
        }
    }

    @Test func checksArchiveSizeAndHash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.zip")
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        try payload.write(to: file)
        let hex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(try UpdateVerifier.sha256Hex(of: file) == hex)
        try UpdateVerifier.verifyArchive(file, manifest: manifest { $0.size = 5000; $0.sha256 = hex })
        #expect(throws: UpdateError.sizeMismatch(expected: 4999, actual: 5000)) {
            try UpdateVerifier.verifyArchive(file, manifest: manifest { $0.size = 4999; $0.sha256 = hex })
        }
        #expect(throws: UpdateError.hashMismatch) { try UpdateVerifier.verifyArchive(file, manifest: manifest { $0.size = 5000 }) }
    }
}

@Suite struct InstallerTests {
    @Test func helperScriptIsValidBash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString).sh")
        try UpdateInstaller.helperScript.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", url.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func classifiesInstallLocations() throws {
        #expect(InstallLocation.of(URL(fileURLWithPath: "/usr/local/bin/CMCRManager")) != .writable(URL(fileURLWithPath: "/usr/local/bin/CMCRManager")))
        if case .unsupported = InstallLocation.of(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/CMCR Manager.app")) {} else {
            Issue.record("translocated path must be unsupported")
        }
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)/CMCR Manager.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(InstallLocation.of(app) == .writable(app))
        if case .writable = InstallLocation.of(URL(fileURLWithPath: "/System/Applications/Calculator.app")) {
            Issue.record("/System/Applications must not be writable")
        }
    }

    @Test func appleScriptQuoting() {
        #expect(UpdateInstaller.appleScriptString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }

    @Test func privilegedScriptEmbedsHelper() throws {
        let r = UpdateInstaller.Request(archive: URL(fileURLWithPath: "/tmp/u.zip"), sha256: String(repeating: "a", count: 64),
                                        target: URL(fileURLWithPath: "/Applications/CMCR \"x\" Manager.app"),
                                        version: "1.2.0", bundleIdentifier: "pl.cmcr.manager", relaunch: true)
        let src = UpdateInstaller.privilegedAppleScript(r, prompt: "Hasło")
        #expect(src.hasPrefix("do shell script \""))
        #expect(src.hasSuffix("with prompt \"Hasło\" with administrator privileges"))
        let b64 = try #require(src.range(of: #"echo ([A-Za-z0-9+/=]+) \|"#, options: .regularExpression)).lowerBound
        let encoded = src[b64...].dropFirst(5).prefix { $0 != " " }
        #expect(Data(base64Encoded: String(encoded)).map { String(decoding: $0, as: UTF8.self) } == UpdateInstaller.helperScript)
    }

    @Test func requestArguments() {
        let r = UpdateInstaller.Request(archive: URL(fileURLWithPath: "/tmp/a b.zip"), sha256: "00", target: URL(fileURLWithPath: "/Applications/CMCR Manager.app"),
                                        version: "1.2.0", bundleIdentifier: "pl.cmcr.manager", relaunch: false)
        #expect(r.arguments.contains("--no-relaunch"))
        #expect(r.arguments[r.arguments.firstIndex(of: "--target")! + 1] == "/Applications/CMCR Manager.app")
        #expect(r.arguments[r.arguments.firstIndex(of: "--pid")! + 1] == String(ProcessInfo.processInfo.processIdentifier))
        #expect(r.arguments[r.arguments.firstIndex(of: "--confirm-timeout")! + 1] == "45")

        var cli = r
        cli.pid = nil
        cli.relaunch = true
        cli.confirmTimeout = 3
        #expect(!cli.arguments.contains("--pid"))
        #expect(!cli.arguments.contains("--no-relaunch"))
        #expect(cli.arguments[cli.arguments.firstIndex(of: "--confirm-timeout")! + 1] == "3")
    }

    @Test func helperRejectsBadArgumentsBeforeTouchingAnything() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-args-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("CMCR Manager.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", UpdateInstaller.helperScript, "cmcr-updater"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        let sha = String(repeating: "a", count: 64)
        #expect(try run(["--target", "relative/CMCR Manager.app", "--sha256", sha]) == 64)
        #expect(try run(["--target", dir.appendingPathComponent("Missing.app").path, "--sha256", sha]) == 64)
        #expect(try run(["--target", app.path, "--sha256", "not-a-hash"]) == 64)
        #expect(try run(["--target", app.path, "--bogus"]) == 64)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["CMCR Manager.app"])
    }
}

@Suite struct ReleaseConfigurationTests {
    /// Repository root, from this file's location (Tests/CMCRCoreTests/…).
    var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @Test func versionFileIsSemanticVersion() throws {
        let text = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = try #require(SemanticVersion(text))
        #expect(version.description == text)
    }

    @Test func embeddedKeysFailClosed() throws {
        let config = UpdateConfiguration(repository: UpdateKeys.repository, trustedPublicKeys: UpdateKeys.trustedPublicKeys,
                                         bundleIdentifier: "pl.cmcr.manager")
        #expect(UpdateKeys.repository.split(separator: "/").count == 2)
        if UpdateKeys.trustedPublicKeys.contains(where: { $0.contains("PLACEHOLDER") }) {
            #expect(!config.isConfigured)
        }
        // Whatever the embedded keys are, a signature made with a fresh random key never verifies.
        let data = Data("{\"schema\":1}".utf8)
        let signature = Data(try Curve25519.Signing.PrivateKey().signature(for: data).base64EncodedString().utf8)
        #expect(throws: UpdateError.badSignature) {
            try UpdateVerifier.verifySignature(manifest: data, signature: signature, trustedKeys: UpdateKeys.trustedPublicKeys)
        }
    }

    @Test func feedRefusesToRunWithoutTrustedKey() async {
        let feed = UpdateFeed(configuration: UpdateConfiguration(repository: "a/b", trustedPublicKeys: ["PLACEHOLDER"],
                                                                 bundleIdentifier: "pl.cmcr.manager",
                                                                 apiBase: URL(string: "http://127.0.0.1:9")!),
                              userAgent: "test")
        await #expect(throws: UpdateError.notConfigured) {
            _ = try await feed.check(current: SemanticVersion("1.0.0"), includePrereleases: false, cache: nil)
        }
    }
}
