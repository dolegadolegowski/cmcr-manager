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
        // Reported where it physically is (the walk resolves root's /tmp link first).
        let (_, o2, _) = try Self.bash("cmcr_user_link \(shQuote(viaTmp + "/link/sub/x"))", tmp: dir)
        #expect(o2 == dir.path + "/link\n")
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

    /// Runs `ln -P` (a hard link to the link itself, not to its target).
    static func hardLink(_ source: String, _ dest: String) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ln")
        p.arguments = ["-P", source, dest]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// A student can hard-link root's own links into their folder (macOS has no protected hard links). Owned by
    /// root, but in a folder the student controls: a relative target (MacOSX.sdk → MacOSX27.0.sdk) then names a
    /// sibling the student makes a link to another account, and "/Volumes/Macintosh HD" → / leads to the whole
    /// disk. Such a link must be refused like the student's own.
    @Test func hardLinkedRootLinksAreNotTrusted() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let victim = dir.appendingPathComponent("victim/Documents")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("tajne".utf8).write(to: victim.appendingPathComponent("praca.txt"))
        let pub = dir.appendingPathComponent("student/Public")
        try fm.createDirectory(at: pub, withIntermediateDirectories: true)
        var tried = 0
        let sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
        if let target = try? fm.destinationOfSymbolicLink(atPath: sdk), !target.hasPrefix("/"),
           try Self.hardLink(sdk, pub.appendingPathComponent("cmcr").path) {
            tried += 1
            try fm.createSymbolicLink(atPath: pub.appendingPathComponent(target).path, withDestinationPath: victim.path)
            let shared = pub.appendingPathComponent("cmcr").path
            let (s1, o1, e1) = try Self.bash("cmcr_pin_dir \(shQuote(shared)) && /bin/pwd -P", tmp: dir)
            #expect(s1 == 2 && !o1.contains("victim"), "\(o1)\(e1)")
            #expect(e1.contains(shared) && e1.contains("root") && e1.contains("kopia dowiązania systemowego"), "\(e1)")
            let (s2, o2, e2) = try Self.bash(Scripts.cleanFolder(shared).body, tmp: dir)
            #expect(s2 == 2, "\(o2)\(e2)")
            #expect(fm.fileExists(atPath: victim.appendingPathComponent("praca.txt").path))
        }
        if try Self.hardLink("/Volumes/Macintosh HD", pub.appendingPathComponent("dysk").path) {
            tried += 1
            let (s, o, e) = try Self.bash("cmcr_pin_dir \(shQuote(pub.path + "/dysk/Users")) && /bin/pwd -P", tmp: dir)
            #expect(s == 2 && o.isEmpty, "\(o)\(e)")
            // The original in /Volumes (root's folder) still works.
            let (s3, o3, _) = try Self.bash("cmcr_pin_dir '/Volumes/Macintosh HD/private/tmp' && /bin/pwd -P", tmp: dir)
            #expect(s3 == 0 && o3 == "/private/tmp\n")
        }
        #expect(tried > 0, "brak dowiązania systemowego do sprawdzenia")
    }

    /// The student swaps their folder and a link to another account back and forth (atomic rename) while root
    /// empties the folder. Checks that look up the path again can each see a different side; walking one folder
    /// at a time and comparing device:inode after every `cd` cannot be fooled (before: ~6% of runs wiped the
    /// victim).
    @Test func cleanFolderSurvivesSwapRace() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let victim = dir.appendingPathComponent("victim")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let pub = dir.appendingPathComponent("student/Public")
        try fm.createDirectory(at: pub.appendingPathComponent("cmcr"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: pub.appendingPathComponent("alt").path, withDestinationPath: victim.path)
        let swapper = Process()
        swapper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        swapper.arguments = ["-c", "import ctypes,sys,time\nc=ctypes.CDLL(None)\na,b=sys.argv[1].encode(),sys.argv[2].encode()\nend=time.time()+60\nwhile time.time()<end: c.renamex_np(a,b,2)",
                             pub.appendingPathComponent("cmcr").path, pub.appendingPathComponent("alt").path]
        try swapper.run()
        defer { swapper.terminate(); swapper.waitUntilExit() }
        let body = Scripts.cleanFolder(pub.appendingPathComponent("cmcr").path).body
        var wiped = 0
        for i in 0..<60 {
            let file = victim.appendingPathComponent("praca\(i).txt")
            try Data("tajne".utf8).write(to: file)
            let (_, out, _) = try Self.bash(body, tmp: dir)
            if !fm.fileExists(atPath: file.path) || out.contains("Wyczyszczono " + victim.path) { wiped += 1 }
        }
        #expect(wiped == 0)
    }

    /// With Gatekeeper switched off (spctl answers "override"), an application needs a certificate chain to
    /// Apple; an ad-hoc signature (or a self-made "Developer ID Application: …" certificate) is not enough.
    @Test func gatekeeperOffFallbackNeedsAppleChain() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let macos = dir.appendingPathComponent("Adhoc.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: macos.appendingPathComponent("Adhoc").path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", macos.appendingPathComponent("Adhoc").path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        let off = "spctl() { echo \"$4: accepted\"; echo 'override=security disabled'; }\n"
        let lib = "CMCR_ALLOW_UNSIGNED=0\n" + Scripts.installLibrary + "\n" + off
        let adhoc = dir.appendingPathComponent("Adhoc.app").path
        let (s1, _, e1) = try Self.bash(lib + "cmcr_verify_signature \(shQuote(adhoc)) execute", tmp: dir)
        #expect(s1 == 1 && e1.contains("brak ważnego podpisu"), "\(e1)")
        for app in ["/System/Applications/Calculator.app", "/System/Applications/TextEdit.app"]
        where FileManager.default.fileExists(atPath: app) {
            let (s2, o2, e2) = try Self.bash(lib + "cmcr_verify_signature \(shQuote(app)) execute", tmp: dir)
            #expect(s2 == 0 && o2.contains("Gatekeeper wyłączony"), "\(o2)\(e2)")
            break
        }
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
        #expect(remove.contains(#"CMCR_JAIL="$CMCR_PINNED"; CMCR_JAIL_ID="$CMCR_PINNED_ID""#))
        #expect(remove.contains(#"cmcr_guard_item "$rel""#))
        // Missing folders are created one at a time (never `mkdir -p` as root through the student's folders).
        #expect(push.contains(#"cmcr_walk "$REST" create "$OWNER""#))
        #expect(Scripts.prepareSharedFolder("/Users/student/Public/cmcr", owner: "student").body.contains(#"cmcr_pin_create "$DIR""#))
        #expect(Scripts.createStudentFolder("/Users/student/Public/cmcr", owner: "student").body.contains(#"cmcr_pin_create "$DIR""#))
        let mk = Scripts.makeDirectory("/Users/student/Desktop/a/b", asRoot: true, intermediate: true).body
        #expect(mk.contains(#"cmcr_walk "$REST" create "$OWN""#) && !mk.contains("chown -R"))
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
