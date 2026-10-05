import Foundation
import Testing
@testable import CMCRCore

/// Builds a listing stream the way `Scripts.listDirectory` prints it.
private func stream(_ tokens: [String], end: Bool = true) -> Data {
    var d = Data()
    for t in tokens + (end ? ["END"] : []) {
        d.append(Data(t.utf8))
        d.append(0)
    }
    return d
}

private let header = ["CMCR-LISTING", "1", "PATH", "/Users/student/Desktop", "REAL", "/Users/student/Desktop",
                      "WRITABLE", "1", "USER", "imac01", "EUID", "501", "CONSOLE", "student",
                      "HOME", "/Users/imac01", "TOTAL", "6", "SELF", "student", "staff", "755"]

private func entry(_ type: String, _ name: String, size: String = "0", mode: String = "644", flags: String = "-",
                   isDir: String = "0", target: String = "") -> [String] {
    ["ENTRY", type, size, "1759650000", "student", "staff", mode, flags, isDir, name, target]
}

@Test func listingParserKeepsAwkwardNamesIntact() throws {
    let data = stream(header
        + entry("Directory", "folder ze spacją", mode: "755", isDir: "1")
        + entry("Regular File", "nowa\nlinia.txt", size: "12")
        + entry("Regular File", "z\ttabem i ENTRY.txt", size: "3")
        + entry("Regular File", "zażółć gęślą jaźń 😀.txt", size: "1000")
        + entry("Symbolic Link", "link do folderu", mode: "755", isDir: "1", target: "folder ze spacją")
        + entry("Regular File", ".ukryty", flags: "-"))
    let l = try #require(Parsers.remoteListing(data))
    #expect(l.path == "/Users/student/Desktop")
    #expect(l.writable)
    #expect(l.owner == "student" && l.group == "staff" && l.permissions == 0o755)
    #expect(l.adminUser == "imac01" && l.adminHome == "/Users/imac01" && l.consoleUser == "student")
    #expect(!l.asRoot)
    #expect(l.complete && !l.truncated)
    #expect(l.entries.map(\.name) == ["folder ze spacją", "nowa\nlinia.txt", "z\ttabem i ENTRY.txt",
                                      "zażółć gęślą jaźń 😀.txt", "link do folderu", ".ukryty"])
    let file = l.entries[3]
    #expect(file.kind == .file && file.size == 1000 && file.permissionString == "rw-r--r--")
    #expect(file.modified == Date(timeIntervalSince1970: 1_759_650_000))
    let link = l.entries[4]
    #expect(link.kind == .symlink && link.linkTarget == "folder ze spacją" && link.isFolder)
    #expect(l.entries[0].isFolder && !l.entries[0].isHidden)
    #expect(l.entries[5].isHidden)
}

@Test func listingParserHandlesFlagsPackagesRootAndTruncation() throws {
    var h = header
    h[h.firstIndex(of: "EUID")! + 1] = "0"
    h[h.firstIndex(of: "TOTAL")! + 1] = "5000"
    h[h.firstIndex(of: "CONSOLE")! + 1] = ""
    let data = stream(h
        + entry("Directory", "Library", mode: "700", flags: "hidden", isDir: "1")
        + entry("Directory", "Keynote.app", mode: "755", isDir: "1")
        + entry("Symbolic Link", "zepsuty", target: "/nie/ma")
        + entry("Fifo File", "potok"))
    let l = try #require(Parsers.remoteListing(data))
    #expect(l.asRoot)
    #expect(l.consoleUser == nil)
    #expect(l.truncated && l.total == 5000)
    #expect(l.entries[0].isHidden && l.entries[0].flags == ["hidden"] && l.entries[0].isFolder)
    #expect(l.entries[1].isPackage && !l.entries[1].isFolder)
    #expect(l.entries[2].kind == .symlink && !l.entries[2].isFolder && l.entries[2].linkTarget == "/nie/ma")
    #expect(l.entries[3].kind == .other)
}

@Test func listingParserDetectsCutOffAndGarbage() {
    let cut = Parsers.remoteListing(stream(header + entry("Regular File", "a.txt") + ["ENTRY", "Regular File", "1"], end: false))
    #expect(cut?.complete == false)
    #expect(cut?.entries.map(\.name) == ["a.txt"])
    #expect(Parsers.remoteListing(Data("total 0\ndrwxr-xr-x  2 root  wheel  64 .\n".utf8)) == nil)
    #expect(Parsers.remoteListing(Data()) == nil)
    // Noise before the marker (e.g. a login banner) is skipped.
    var noisy = Data("Witaj!\n".utf8)
    noisy.append(0)
    noisy.append(stream(header))
    #expect(Parsers.remoteListing(noisy)?.path == "/Users/student/Desktop")
}

@Test func browseErrorsMapExitCodes() {
    func r(_ code: Int32, _ err: String) -> CommandResult { CommandResult(exitCode: code, stderr: Data(err.utf8)) }
    #expect(RemoteBrowseError.from(r(61, "CMCR:NOT_FOUND\nFolder nie istnieje: /x\n")) == .notFound("Folder nie istnieje: /x"))
    #expect(RemoteBrowseError.from(r(64, "CMCR:PRIVACY\nmacOS blokuje\n")) == .privacyDenied("macOS blokuje"))
    #expect(RemoteBrowseError.from(r(65, "CMCR:REFUSED\nOdmowa: x\n")) == .refused("Odmowa: x"))
    #expect(RemoteBrowseError.from(r(3, "CMCR:NO_CONSOLE\nNikt\n")) == .noConsoleUser)
    #expect(RemoteBrowseError.from(r(255, "ssh: Could not resolve hostname imac99.local")).isUnreachable)
    if case .authentication = RemoteBrowseError.from(r(255, "imac01@imac01.local: Permission denied (publickey).")) {} else {
        Issue.record("permission denied should be an authentication error")
    }
    if case .authentication = RemoteBrowseError.from(r(91, "Brak hasła administratora")) {} else {
        Issue.record("missing sudo password should be an authentication error")
    }
    #expect(RemoteBrowseError.from(CommandResult(exitCode: -1, cancelled: true)) == .cancelled)
}

private extension RemoteBrowseError {
    var isUnreachable: Bool { if case .unreachable = self { return true } else { return false } }
}

@Test func pathsAreTokenizedForEveryMac() {
    #expect(RemotePaths.tokenize("/Users/student/Desktop/Projekty", studentUser: "student") == "/Users/{student}/Desktop/Projekty")
    #expect(RemotePaths.tokenize("/Users/student", studentUser: "student") == "/Users/{student}")
    #expect(RemotePaths.tokenize("/Users/students/x", studentUser: "student") == "/Users/students/x")
    #expect(RemotePaths.tokenize("/Users/jan/Desktop/", studentUser: "student", consoleUser: "jan",
                                 preferConsole: true) == "/Users/{console}/Desktop")
    #expect(RemotePaths.tokenize("/Users/jan/Desktop", studentUser: "student", consoleUser: "jan") == "/Users/jan/Desktop")
    #expect(RemotePaths.tokenize("/Users/imac04/Downloads", studentUser: "student",
                                 adminHome: "/Users/imac04") == "~/Downloads")
    #expect(RemotePaths.tokenize("/Users/Shared", studentUser: "student") == "/Users/Shared")
    #expect(RemotePaths.resolve("/Users/{console}/Desktop", studentUser: "student", consoleUser: "jan",
                                adminHome: nil) == "/Users/jan/Desktop")
    #expect(RemotePaths.resolve("~/Desktop", studentUser: "s", consoleUser: nil, adminHome: "/Users/imac01") == "/Users/imac01/Desktop")
    #expect(RemotePaths.resolveLocal("/Users/{student}/Public", studentUser: "uczen") == "/Users/uczen/Public")
}

@Test func pathHelpers() {
    #expect(RemotePaths.normalize("/Users//student/Desktop/") == "/Users/student/Desktop")
    #expect(RemotePaths.normalize("/") == "/")
    #expect(RemotePaths.normalize("~/") == "~")
    #expect(RemotePaths.join("/", "Users") == "/Users")
    #expect(RemotePaths.join("/Users/student/", "nowa\nlinia") == "/Users/student/nowa\nlinia")
    #expect(RemotePaths.parent(of: "/Users/student") == "/Users")
    #expect(RemotePaths.parent(of: "/Users") == "/")
    #expect(RemotePaths.parent(of: "/") == "/")
    #expect(RemotePaths.lastComponent("/Users/student/Desktop") == "Desktop")
    #expect(RemotePaths.breadcrumbs("/Users/student").map(\.path) == ["/", "/Users", "/Users/student"])
    #expect(RemotePaths.isValidName("Nowy folder ą"))
    #expect(!RemotePaths.isValidName("a/b"))
    #expect(!RemotePaths.isValidName(".."))
    #expect(!RemotePaths.isValidName(""))
}

@Test func friendlyNamesForFavourites() {
    var s = AppSettings()
    s.studentUser = "student"
    s.sharedFolder = "/Users/student/Public/cmcr"
    #expect(RemotePaths.friendlyName("/Users/{student}/Desktop", settings: s).title == "Biurko ucznia")
    #expect(RemotePaths.friendlyName("/Users/student/Desktop/Projekty/2025", settings: s).title == "Biurko ucznia › Projekty › 2025")
    #expect(RemotePaths.friendlyName("/Users/student/Public/cmcr", settings: s).title == "Folder cmcr ucznia")
    #expect(RemotePaths.friendlyName("/Users/{student}/Public", settings: s).title == "Katalog domowy ucznia › Public")
    #expect(RemotePaths.friendlyName("/Users/{console}/Desktop", settings: s).title == "Biurko zalogowanego użytkownika")
    #expect(RemotePaths.friendlyName("~/Downloads", settings: s).title == "Katalog domowy administratora › Downloads")
    #expect(RemotePaths.friendlyName("/Applications", settings: s).title == "Programy")
    #expect(RemotePaths.friendlyName("/opt/lab", settings: s).title == "lab")
    #expect(RemotePaths.friendlyName("", settings: s).icon == "questionmark.folder")
    #expect(RemotePaths.favorites(s).first?.path == "/Users/{student}/Public/cmcr")
}

@Test func browseScriptsQuoteEveryValue() {
    let evil = "/Users/student/Desktop/'; rm -rf / #$(reboot)"
    for script in [Scripts.listDirectory(evil, asRoot: false), Scripts.makeDirectory(evil, asRoot: true),
                   Scripts.renameItem(evil, to: "x'y", asRoot: false), Scripts.deleteItems([evil, "/tmp/a"], asRoot: true),
                   Scripts.archiveItems(in: "/tmp", names: [evil], asRoot: false),
                   Scripts.removeCollected(in: evil, files: [CollectedFile(path: evil, modified: 1, size: 2)],
                                           folders: [evil], asRoot: true),
                   Scripts.folderPresence(evil, asRoot: false)] {
        #expect(script.body.contains(shQuote(evil)))
    }
    #expect(Scripts.deleteItems(["/tmp/a"], asRoot: true).asRoot)
    #expect(Scripts.deleteItems(["/tmp/a"], asRoot: false, dryRun: true).body.contains("Zostałoby usunięte"))
}

@Test func browseScriptsAreValidBash() async {
    let scripts = [Scripts.listDirectory("/Users/{console}/Desktop", asRoot: false),
                   Scripts.makeDirectory("~/a b", asRoot: true, intermediate: true),
                   Scripts.renameItem("/tmp/a", to: "b", asRoot: false),
                   Scripts.deleteItems(["/tmp/a", "/tmp/b\nc"], asRoot: true, dryRun: true),
                   Scripts.archiveItems(in: "/tmp", names: ["a", "b c"], asRoot: false),
                   Scripts.removeCollected(in: "/Users/{student}/Public/cmcr",
                                           files: [CollectedFile(path: "a/b\nc.txt", modified: 1_759_650_000, size: 3),
                                                   CollectedFile(path: "link", modified: 0, size: 0, isLink: true)],
                                           folders: ["a"], asRoot: true),
                   Scripts.removeCollected(in: "/tmp/x", files: [], folders: [], asRoot: false),
                   Scripts.folderPresence("/Users/{console}/Desktop", asRoot: true)]
    for s in scripts {
        let r = await ProcessRunner.run("/bin/bash", ["-n", "-c", s.render()])
        #expect(r.succeeded, "bash -n: \(r.stderrText)")
    }
}

@Test func collectionFolderAndUniqueNames() throws {
    var c = DateComponents()
    (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 5, 9, 7)
    let date = try #require(Calendar.current.date(from: c))
    #expect(Operations.collectionFolder(base: "/tmp/zebrane", date: date).path == "/tmp/zebrane/2026-10-05 09.07")
    #expect(Operations.collectionFolder(base: "/tmp/zebrane", date: date, timestamped: false).path == "/tmp/zebrane")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-unit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("praca.txt")
    #expect(Operations.uniqueURL(a) == a)
    try Data().write(to: a)
    #expect(Operations.uniqueURL(a).lastPathComponent == "praca (2).txt")
    try Data().write(to: dir.appendingPathComponent("praca (2).txt"))
    #expect(Operations.uniqueURL(a).lastPathComponent == "praca (3).txt")
    let folder = dir.appendingPathComponent("imac01")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(Operations.uniqueURL(folder).lastPathComponent == "imac01 (2)")
}

@Test func polishPlurals() {
    #expect(Operations.plural(1, "plik", "pliki", "plików") == "plik")
    #expect(Operations.plural(2, "plik", "pliki", "plików") == "pliki")
    #expect(Operations.plural(5, "plik", "pliki", "plików") == "plików")
    #expect(Operations.plural(12, "plik", "pliki", "plików") == "plików")
    #expect(Operations.plural(22, "plik", "pliki", "plików") == "pliki")
    #expect(Operations.plural(0, "plik", "pliki", "plików") == "plików")
}

@Test func filesPreferencesRecentsAndDefaults() throws {
    var p = FilesPreferences()
    for i in 0..<10 { p.remember("/tmp/\(i)") }
    p.remember("/tmp/5")
    #expect(p.recentRemoteFolders.count == 8)
    #expect(p.recentRemoteFolders.first == "/tmp/5")
    #expect(p.recentRemoteFolders.filter { $0 == "/tmp/5" }.count == 1)
    var s = AppSettings()
    s.localFolder = "~/Public/cmcr"
    #expect(p.collectBase(s) == "~/Public/cmcr/zebrane")
    let decoded = try JSONDecoder().decode(FilesPreferences.self, from: Data(#"{"downloadFolder":"/tmp"}"#.utf8))
    #expect(decoded.downloadFolder == "/tmp" && decoded.collectTimestamped)
}

@Test func collectedContentsListsFilesWithTimesAndFoldersDeepestFirst() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("cmcr-unit-\(UUID().uuidString)")
    try fm.createDirectory(at: dir.appendingPathComponent("projekt/src"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("projekt/src/main ą.txt")
    try Data("abc".utf8).write(to: file)
    let stamp = Date(timeIntervalSince1970: 1_759_650_000.75)
    try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
    try fm.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: "/etc")
    let (files, folders) = Operations.collectedContents(dir)
    #expect(folders == ["projekt/src", "projekt"])
    let main = try #require(files.first { $0.path == "projekt/src/main ą.txt" })
    #expect(main.size == 3 && main.modified == 1_759_650_000 && !main.isLink)
    let link = try #require(files.first { $0.path == "link" })
    #expect(link.isLink)
    #expect(files.count == 2, "the enumerator must not follow the link into /etc")
}
