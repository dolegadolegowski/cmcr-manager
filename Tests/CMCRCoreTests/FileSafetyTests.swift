import Foundation
import Testing
@testable import CMCRCore

/// Root file operations must not follow links a user planted, and installers need a valid Apple signature.
/// The shell helpers run here for real, but only inside a private folder in /private/tmp.
@Suite struct FileSafetyTests {
    /// Runs `RemoteScript.library` plus `script` in /bin/bash; returns exit status, stdout and stderr.
    static func bash(_ script: String, tmp: URL) throws -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["--noprofile", "--norc", "-c", RemoteScript.library + "\n" + script]
        var env = ProcessInfo.processInfo.environment
        env["CMCR_TMP"] = tmp.path
        env.removeValue(forKey: "BASH_ENV")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// A fresh folder in /private/tmp (cleanFolder only works below /Users, /tmp and /Volumes).
    static func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: "/private/tmp/cmcr-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func userLinksAreFoundButRootLinksAreFollowed() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("real/sub"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: dir.appendingPathComponent("real").path)
        // /tmp is root's own link to /private/tmp: allowed.
        let viaTmp = "/tmp/" + dir.lastPathComponent
        let (s1, o1, _) = try Self.bash("cmcr_user_link \(shQuote(viaTmp + "/real/sub/x")) || echo none", tmp: dir)
        #expect(s1 == 0 && o1 == "none\n")
        let (_, o2, _) = try Self.bash("cmcr_user_link \(shQuote(viaTmp + "/link/sub/x"))", tmp: dir)
        #expect(o2 == viaTmp + "/link\n")
        let (s3, _, e3) = try Self.bash("cmcr_pin_dir \(shQuote(viaTmp + "/link/sub"))", tmp: dir)
        #expect(s3 == 2 && e3.contains("Odmowa") && e3.contains("dowiązanie symboliczne"))
        let (s4, o4, _) = try Self.bash("cmcr_pin_dir \(shQuote(viaTmp + "/real/sub")) && echo \"$CMCR_PINNED|$(/bin/pwd -P)\"", tmp: dir)
        let physical = dir.path + "/real/sub"
        #expect(s4 == 0 && o4 == "\(physical)|\(physical)\n")
        let (s5, _, _) = try Self.bash("cmcr_pin_dir \(shQuote(dir.path + "/nie-ma"))", tmp: dir)
        #expect(s5 == 1)
    }

    /// Lesson end ("Wyczyść folder ucznia") as root: the student swapped the shared folder for a link to another
    /// account's folder. Before the fix the victim's files were deleted.
    @Test func cleanFolderRefusesStudentPlantedLink() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let victim = dir.appendingPathComponent("victim/Documents")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("tajne".utf8).write(to: victim.appendingPathComponent("praca.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("student/Public"), withIntermediateDirectories: true)
        let shared = dir.appendingPathComponent("student/Public/cmcr")
        try fm.createSymbolicLink(atPath: shared.path, withDestinationPath: victim.path)
        for dry in [false, true] {
            let (status, out, err) = try Self.bash(Scripts.cleanFolder(shared.path, dryRun: dry).body, tmp: dir)
            #expect(status == 2, "\(out)\(err)")
            #expect(err.contains("Odmowa") && err.contains(shared.path))
            #expect(!out.contains("praca.txt"))
            #expect(fm.fileExists(atPath: victim.appendingPathComponent("praca.txt").path))
        }
        // An ordinary folder is still emptied.
        let normal = dir.appendingPathComponent("normal")
        try fm.createDirectory(at: normal.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: normal.appendingPathComponent("sub/x"))
        let (status, out, err) = try Self.bash(Scripts.cleanFolder(normal.path).body, tmp: dir)
        #expect(status == 0, "\(out)\(err)")
        #expect(try fm.contentsOfDirectory(atPath: normal.path).isEmpty)
    }

    @Test func fileScriptsUsePinnedFolders() {
        let push = Scripts.pushFinalize(remoteTar: "/tmp/x.tar", destination: "/Users/student/Public/cmcr", owner: "student",
                                        mode: "777", asRoot: true).body
        #expect(push.contains(#"cmcr_user_link "$DEST""#) && push.contains(#"cmcr_pin_dir "$P""#))
        // Owner and mode are set on the unpacked copy in the private temp folder, never recursively in place.
        #expect(push.contains(#"STAGE="$(mktemp -d "$CMCR_TMP/push.XXXXXX")""#))
        #expect(push.contains(#"chown -R "$OWNER" "$item""#) && !push.contains(#"chown -R "$OWNER" "$t""#))
        #expect(!push.contains(#"chmod -R "$MODE" "$t""#))
        #expect(Scripts.pullArchive(source: "/Users/student/Public/cmcr", asRoot: true).body.contains(#"cmcr_pin_dir "$SRC""#))
        let remove = Scripts.removeCollected(in: "/Users/student/Public/cmcr", files: [], folders: [], asRoot: true).body
        #expect(remove.contains(#"CMCR_JAIL="$CMCR_PINNED""#))
        #expect(Scripts.prepareSharedFolder("/Users/student/Public/cmcr", owner: "student").body.contains("chmod 777 ."))
    }

    @Test func downloadsNeedHTTPS() {
        #expect(Scripts.isSecureDownloadURL("https://example.com/Instalator.pkg"))
        #expect(Scripts.isSecureDownloadURL("HTTPS://example.com/a.dmg?x=1"))
        #expect(Scripts.isSecureDownloadURL("file:///tmp/a.pkg"))
        #expect(!Scripts.isSecureDownloadURL("http://example.com/a.pkg"))
        #expect(!Scripts.isSecureDownloadURL("ftp://example.com/a.pkg"))
        #expect(!Scripts.isSecureDownloadURL("https://"))
        #expect(!Scripts.isSecureDownloadURL("example.com/a.pkg"))
        let body = Scripts.installFromURL("https://example.com/a.pkg").body
        // Redirects may not fall back to plain http.
        #expect(body.contains("--proto '=https,file' --proto-redir '=https'"))
        #expect(body.contains("https://?*|file://*) ;;"))
    }

    @Test func checksumIsNormalisedAndPinned() {
        let sum = String(repeating: "Ab", count: 32)
        #expect(Scripts.normalizedSHA256(sum) == String(repeating: "ab", count: 32))
        #expect(Scripts.normalizedSHA256(" " + sum + "\n") == String(repeating: "ab", count: 32))
        #expect(Scripts.normalizedSHA256("abc") == nil)
        #expect(Scripts.normalizedSHA256(String(repeating: "g", count: 64)) == nil)
        let body = Scripts.installFromURL("https://example.com/a.pkg", sha256: sum).body
        #expect(body.contains("SHA='\(String(repeating: "ab", count: 32))'"))
        #expect(Scripts.installFromURL("https://example.com/a.pkg").body.contains("SHA=''"))
    }

    @Test func unsignedInstallersNeedExplicitPermission() {
        for script in [Scripts.installPayload(remoteTar: "/tmp/x.tar"), Scripts.installFromURL("https://example.com/a.pkg")] {
            #expect(script.body.hasPrefix("CMCR_ALLOW_UNSIGNED=0\n"))
            #expect(script.asRoot)
        }
        #expect(Scripts.installPayload(remoteTar: "/tmp/x.tar", allowUnsigned: true).body.hasPrefix("CMCR_ALLOW_UNSIGNED=1\n"))
        #expect(Scripts.installFromURL("https://e.com/a.pkg", allowUnsigned: true).body.hasPrefix("CMCR_ALLOW_UNSIGNED=1\n"))
        let lib = Scripts.installLibrary
        #expect(lib.contains(#"cmcr_verify_signature "$1" install || return 1"#))
        #expect(lib.contains(#"cmcr_verify_signature "$src" execute || return 1"#))
        #expect(lib.contains("spctl --assess --type"))
        #expect(!lib.contains("-allowUntrusted"))
    }

    /// The Gatekeeper check against the real `spctl`: an unsigned package is refused, and accepted only with
    /// the teacher's explicit permission.
    @Test func unsignedPackageIsRefusedByGatekeeper() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root/x")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("plik"))
        let pkg = dir.appendingPathComponent("Test.pkg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkgbuild")
        p.arguments = ["--quiet", "--root", dir.appendingPathComponent("root").path, "--identifier", "pl.cmcr.unit",
                       "--version", "1", "--install-location", "/tmp/cmcr-unit-never", pkg.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "pkgbuild niedostępny")
        let check = "cmcr_verify_signature \(shQuote(pkg.path)) install"
        let (refused, _, err) = try Self.bash("CMCR_ALLOW_UNSIGNED=0\n" + Scripts.installLibrary + "\n" + check, tmp: dir)
        #expect(refused == 1 && err.contains("brak podpisu") && err.contains("--allow-unsigned"), "\(err)")
        let (allowed, _, warn) = try Self.bash("CMCR_ALLOW_UNSIGNED=1\n" + Scripts.installLibrary + "\n" + check, tmp: dir)
        #expect(allowed == 0 && warn.contains("instaluję mimo to"), "\(warn)")
    }
}
