// Ed25519 signing of update manifests for CMCR Manager (maintainer tool, run with `swift scripts/update-signing.swift`).
//
//   keygen [--file PATH] [--force]       new key → login Keychain (or a 0600 file); prints the PUBLIC key
//   public-key                           public key of the configured private key
//   manifest --app A.app --zip Z.zip --tag vX.Y.Z [--notes-file F] --out cmcr-update.json
//   sign FILE                            base64 signature of FILE's exact bytes → stdout
//   verify FILE SIG [--keys-from Sources/CMCRCore/UpdateKeys.swift | --public-key B64]
//   is-newer A B                         exit 0 when version A > version B (SemVer)
//   leak-check < files                   fails when one of the NUL-separated files (git ls-files -z) contains the key
//
// Private key lookup (first match): $CMCR_UPDATE_SIGNING_KEY (base64) → Keychain item
// service "pl.cmcr.manager.update-signing", account "ed25519" → file $CMCR_UPDATE_SIGNING_KEY_FILE
// (default ~/.config/cmcr-manager/update-signing.key). The key is never printed, never written into the repo.

import CryptoKit
import Foundation
import Security

let keychainService = "pl.cmcr.manager.update-signing"
let keychainAccount = "ed25519"
let defaultKeyFile = NSString(string: "~/.config/cmcr-manager/update-signing.key").expandingTildeInPath

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-signing: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: Key storage

func keychainRead() -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: keychainAccount, kSecReturnData as String: true]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(decoding: data, as: UTF8.self)
}

func keychainWrite(_ value: String) -> Bool {
    let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                              kSecAttrAccount as String: keychainAccount, kSecValueData as String: Data(value.utf8),
                              kSecAttrLabel as String: "CMCR Manager – klucz podpisu aktualizacji (Ed25519)"]
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
}

func insideGitWorkTree(_ path: String) -> Bool {
    var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
        dir.deleteLastPathComponent()
    }
    return false
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    let env = ProcessInfo.processInfo.environment
    var encoded = env["CMCR_UPDATE_SIGNING_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    if encoded == nil, env["CMCR_UPDATE_SIGNING_KEY_FILE"] == nil { encoded = keychainRead() }
    if encoded == nil {
        let file = env["CMCR_UPDATE_SIGNING_KEY_FILE"] ?? defaultKeyFile
        if insideGitWorkTree(file) { fail("plik klucza \(file) leży w repozytorium git – przenieś go poza repozytorium") }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file),
           let perms = attrs[.posixPermissions] as? NSNumber, perms.intValue & 0o077 != 0 {
            fail("plik klucza \(file) jest dostępny dla innych (chmod 600)")
        }
        encoded = try? String(contentsOfFile: file, encoding: .utf8)
    }
    guard let encoded, let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("brak klucza prywatnego (uruchom: swift scripts/update-signing.swift keygen)")
    }
    return key
}

// MARK: Commands

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("podaj polecenie: keygen | public-key | manifest | sign | verify | is-newer | leak-check") }

switch command {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    let secret = key.rawRepresentation.base64EncodedString()
    if let file = option("--file", in: args) {
        if insideGitWorkTree(file) { fail("nie zapisuję klucza w repozytorium git: \(file)") }
        if FileManager.default.fileExists(atPath: file), !args.contains("--force") { fail("\(file) już istnieje (--force nadpisuje)") }
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600]) else {
            fail("nie można zapisać \(file)")
        }
        FileHandle.standardError.write(Data("Zapisano klucz prywatny w \(file) (0600). Zrób kopię zapasową w menedżerze haseł.\n".utf8))
    } else {
        if keychainRead() != nil { fail("klucz już jest w Pęku kluczy (\(keychainService)); usuń go ręcznie, aby wygenerować nowy") }
        guard keychainWrite(secret) else { fail("nie można zapisać klucza w Pęku kluczy") }
        FileHandle.standardError.write(Data("""
        Zapisano klucz prywatny w Pęku kluczy (usługa \(keychainService)).
        KOPIA ZAPASOWA (zrób ją teraz, bez klucza nie wydasz aktualizacji dla zainstalowanych kopii):
          security find-generic-password -s \(keychainService) -a \(keychainAccount) -w | pbcopy   → menedżer haseł
        Klucz publiczny (wpisz do Sources/CMCRCore/UpdateKeys.swift):

        """.utf8))
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public-key":
    print(loadPrivateKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("sign PLIK") }
    let key = loadPrivateKey()
    guard let sig = try? key.signature(for: data), key.publicKey.isValidSignature(sig, for: data) else { fail("podpisywanie nie powiodło się") }
    print(sig.base64EncodedString())

case "verify":
    guard args.count >= 3, let data = FileManager.default.contents(atPath: args[1]),
          let sigText = try? String(contentsOfFile: args[2], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("verify PLIK PODPIS") }
    var keys: [String] = []
    if let k = option("--public-key", in: args) { keys = [k] }
    if let src = option("--keys-from", in: args) {
        guard let text = try? String(contentsOfFile: src, encoding: .utf8) else { fail("brak \(src)") }
        // Every quoted 44-character base64 string in UpdateKeys.swift.
        let regex = try! NSRegularExpression(pattern: "\"([A-Za-z0-9+/]{43}=)\"")
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        guard !found.isEmpty else { fail("\(src) nie zawiera żadnego klucza publicznego (tylko PLACEHOLDER?)") }
        keys += found
    }
    if keys.isEmpty { keys = [loadPrivateKey().publicKey.rawRepresentation.base64EncodedString()] }
    let ok = keys.contains { k in
        guard let raw = Data(base64Encoded: k), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return pub.isValidSignature(sig, for: data)
    }
    guard ok else { fail("PODPIS NIEPRAWIDŁOWY dla kluczy: \(keys.joined(separator: ", "))") }
    print("Podpis prawidłowy.")

case "manifest":
    guard let app = option("--app", in: args), let zip = option("--zip", in: args),
          let tag = option("--tag", in: args), let out = option("--out", in: args) else {
        fail("manifest --app A.app --zip Z.zip --tag vX.Y.Z [--notes-file F] --out PLIK")
    }
    guard let plist = NSDictionary(contentsOfFile: "\(app)/Contents/Info.plist") as? [String: Any],
          let id = plist["CFBundleIdentifier"] as? String, let version = plist["CFBundleShortVersionString"] as? String,
          let exe = plist["CFBundleExecutable"] as? String else { fail("nie można odczytać \(app)/Contents/Info.plist") }
    let tagVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    guard tagVersion == version else { fail("tag \(tag) ≠ wersja pakietu \(version)") }
    guard let zipData = FileManager.default.contents(atPath: zip) else { fail("brak \(zip)") }
    let lipo = Process()
    let pipe = Pipe()
    lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
    lipo.arguments = ["-archs", "\(app)/Contents/MacOS/\(exe)"]
    lipo.standardOutput = pipe
    try? lipo.run()
    lipo.waitUntilExit()
    let archs = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 == "arm64" || $0 == "x86_64" }
    guard !archs.isEmpty else { fail("nie można ustalić architektur pliku wykonywalnego") }
    var manifest: [String: Any] = [
        "schema": 1,
        "bundleIdentifier": id,
        "version": version,
        "tag": tag,
        "file": (zip as NSString).lastPathComponent,
        "size": zipData.count,
        "sha256": SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined(),
        "minimumSystemVersion": plist["LSMinimumSystemVersion"] as? String ?? "13.0",
        "architectures": archs,
        "publishedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    if let build = plist["CFBundleVersion"] as? String { manifest["build"] = build }
    if let notesFile = option("--notes-file", in: args) {
        guard let notes = try? String(contentsOfFile: notesFile, encoding: .utf8) else { fail("brak \(notesFile)") }
        manifest["notes"] = notes
    }
    let data = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    guard FileManager.default.createFile(atPath: out, contents: data + Data("\n".utf8)) else { fail("nie można zapisać \(out)") }
    FileHandle.standardError.write(Data("Manifest \(out): \(version), \(archs.joined(separator: "+")), \(zipData.count) B\n".utf8))

case "leak-check":
    let key = loadPrivateKey().rawRepresentation
    let encoded = Data(key.base64EncodedString().utf8)
    let paths = FileHandle.standardInput.readDataToEndOfFile().split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    let leaks = paths.filter { path in
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return data.range(of: encoded) != nil || data.range(of: key) != nil
    }
    guard leaks.isEmpty else { fail("KLUCZ PRYWATNY znaleziono w: \(leaks.joined(separator: ", ")) – usuń go z historii i wygeneruj nowy") }
    print("Klucz prywatny nie występuje w \(paths.count) śledzonych plikach.")

case "is-newer":
    // Minimal SemVer comparison for release.sh (same rules as SemanticVersion in the app).
    func parse(_ s: String) -> ([Int], [String])? {
        var t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        if let p = t.firstIndex(of: "+") { t = String(t[..<p]) }
        let parts = t.split(separator: "-", maxSplits: 1)
        let nums = parts[0].split(separator: ".").compactMap { Int($0) }
        guard (1...3).contains(nums.count) else { return nil }
        return (nums + Array(repeating: 0, count: 3 - nums.count), parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : [])
    }
    guard args.count == 3, let a = parse(args[1]), let b = parse(args[2]) else { fail("is-newer A B") }
    if a.0 != b.0 { exit(a.0.lexicographicallyPrecedes(b.0) ? 1 : 0) }
    if a.1.isEmpty != b.1.isEmpty { exit(a.1.isEmpty ? 0 : 1) }
    for (x, y) in zip(a.1, b.1) where x != y {
        switch (Int(x), Int(y)) {
        case let (i?, j?): exit(i > j ? 0 : 1)
        case (.some, .none): exit(1)
        case (.none, .some): exit(0)
        default: exit(x > y ? 0 : 1)
        }
    }
    exit(a.1.count > b.1.count ? 0 : 1)

default:
    fail("nieznane polecenie \(command)")
}
