import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Fixes from the sixth review round in the app (AUDIT UI-33).
@MainActor
@Suite struct RevR6appTests {
    /// The source of the app file `name` (Sources/CMCRManager or Sources/CMCRCore).
    static func source(_ name: String) throws -> String {
        let file = try #require(SymbolAvailabilityTests.appSources.first { $0.lastPathComponent == name }, "brak \(name)")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The symbols of the action `title` in `file`: a `Label`/`title:, icon:` pair (SymbolAvailabilityTests.labels),
    /// else the `FormRowIcon` of a row whose label is `Text("title")` (a toggle such as „Uprzedź zalogowanych
    /// uczniów”).
    static func symbols(of title: String, in file: String) throws -> Set<String> {
        let text = try source(file)
        let pairs = SymbolAvailabilityTests.labels(in: text, file: file).filter { $0.title == title }.map(\.symbol)
        if !pairs.isEmpty { return Set(pairs) }
        let lines = text.components(separatedBy: "\n")
        let icon = try NSRegularExpression(pattern: #"FormRowIcon\("([^"]+)"\)"#)
        var found = Set<String>()
        for (i, line) in lines.enumerated() where line.contains("Text(\"\(title)\")") {
            for next in lines[i..<min(lines.count, i + 6)] {
                let ns = next as NSString
                if let m = icon.firstMatch(in: next, range: NSRange(location: 0, length: ns.length)) {
                    found.insert(ns.substring(with: m.range(at: 1)))
                    break
                }
            }
        }
        return found
    }
}

extension RevR6appTests {
    /// The action of the app that each lesson step runs: the same script on the iMacs, or (Uprzedź uczniów) the same
    /// warning before a planned shutdown.
    static let sameActionAs: [LessonStepKind: (title: String, file: String)] = [
        .wake: ("Obudź", "PowerView.swift"),
        .materials: ("Wyślij pliki", "FilesView.swift"),
        .openApps: ("Uruchom", "AppsView.swift"),                 // Scripts.launchApp
        .greet: ("Wyślij wiadomość", "PowerView.swift"),          // Scripts.message
        .warn: ("Uprzedź zalogowanych uczniów", "PowerView.swift"),
        .collect: ("Zbierz prace uczniów", "FilesView.swift"),
        .quitApps: ("Zamknij", "AppsView.swift"),                 // Scripts.quitApp – an app on the iMacs
        .cleanShared: ("Wyczyść folder…", "FilesView.swift"),
        .cleanDownloads: ("Wyczyść folder…", "FilesView.swift"),  // Scripts.cleanFolder
        .logout: ("Wyloguj…", "PowerView.swift"),
        .sleep: ("Uśpij…", "PowerView.swift"),
        .shutdown: ("Wyłącz…", "PowerView.swift"),
    ]

    // UI-33: one action – one symbol also in Zajęcia. „Uruchom aplikacje” had macwindow.badge.plus (the symbol of
    // „Otwórz w nowym oknie”) while Aplikacje › „Uruchom” has play.fill, and „Zamknij aplikacje” had xmark.app
    // while Aplikacje › „Zamknij” has xmark.circle.
    @Test func everyLessonStepHasTheSymbolOfTheSameActionInTheApp() throws {
        #expect(Set(Self.sameActionAs.keys) == Set(LessonStepKind.allCases), "krok zajęć bez odpowiadającej mu akcji")
        func base(_ symbol: String) -> String { symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol }
        for step in LessonStepKind.allCases {
            let action = try #require(Self.sameActionAs[step])
            let symbols = try Self.symbols(of: action.title, in: action.file)
            #expect(symbols.count == 1, "„\(action.title)” (\(action.file)): \(symbols.sorted())")
            for symbol in symbols {
                #expect(base(step.icon) == base(symbol),
                        "krok „\(step.title)” ma symbol \(step.icon), a „\(action.title)” (\(action.file)) – \(symbol)")
            }
        }
    }
}
