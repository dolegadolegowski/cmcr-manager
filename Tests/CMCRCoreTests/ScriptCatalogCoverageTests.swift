import Foundation
import Testing
@testable import CMCRCore

/// `cmcrctl selftest` only checks what `ScriptCatalog.samples` renders, so every builder returning a
/// `RemoteScript` in the core sources needs a sample there (named `builder` or `builder(variant)`).
@Suite struct ScriptCatalogCoverageTests {
    static var coreSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/CMCRCore").standardizedFileURL
    }

    /// Names of non-private `static func`s whose declaration (up to the body) returns `RemoteScript`.
    static func builders(in source: String) -> [String] {
        let pattern = #"(?m)^[ \t]*(?:@\w+[ \t]+)*(?:(?:public|internal|package)[ \t]+)?static[ \t]+func[ \t]+(\w+)[ \t]*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let rest = text.substring(from: match.range.location)
            guard let open = rest.firstIndex(of: "{") else { return nil }
            let signature = rest[..<open].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return signature.contains("-> RemoteScript") ? text.substring(with: match.range(at: 1)) : nil
        }
    }

    @Test func parserFindsMultiLineSignaturesOnly() {
        let source = """
        public enum Scripts {
            public static func one() -> RemoteScript { RemoteScript("") }
            public static func two(a: Int,
                                   b: Int) -> RemoteScript {
                RemoteScript("")
            }
            static func three(_ x: String) -> String { x }
            private static func helper() -> RemoteScript { RemoteScript("") }
        }
        """
        #expect(Self.builders(in: source) == ["one", "two"])
    }

    @Test func everyBuilderHasASample() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.coreSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ScriptCatalog.swift" }
        try #require(files.contains { $0.lastPathComponent == "Scripts.swift" }, "nie znaleziono źródeł w \(Self.coreSources.path)")
        var builders: [String: String] = [:]
        for file in files {
            for name in Self.builders(in: try String(contentsOf: file, encoding: .utf8)) {
                builders[name] = file.lastPathComponent
            }
        }
        #expect(builders.count >= 30, "parser nie znalazł generatorów skryptów: \(builders.keys.sorted())")
        let sampled = Set(ScriptCatalog.samples.map { $0.name.split(separator: "(", maxSplits: 1)[0] }.map(String.init))
        let missing = builders.keys.filter { !sampled.contains($0) }.sorted()
        #expect(missing.isEmpty, """
            Brak próbek w ScriptCatalog.samples (cmcrctl selftest ich nie sprawdza): \
            \(missing.map { "\($0) (\(builders[$0]!))" }.joined(separator: ", "))
            """)
    }
}
