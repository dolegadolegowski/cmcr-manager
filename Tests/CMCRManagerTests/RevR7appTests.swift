import AppKit
import Foundation
import Testing
@testable import CMCRCore
@testable import CMCRManager

/// Fixes from the seventh review round in the app (AUDIT REV-67, REV-68, UI-34).
@MainActor
@Suite struct RevR7appTests {
    /// A window that can show a notice, on screen but out of sight (borderless, far from every display).
    static func window() -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 120, height: 80), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        return w
    }
}

extension RevR7appTests {
    // REV-67: AppKit does not update the text of an open alert. A configuration problem found while the alert with
    // the earlier ones was open (a second broken hand edit of hosts.json, saved before OK) was not shown, and „OK”
    // or „Pokaż pliki w Finderze” removed it together with the others – unseen. The alert shows the problems found
    // when it opened and removes only them; the new one is shown by the next alert.
    @Test func aProblemFoundWhileTheAlertIsOpenIsShownByTheNextOne() throws {
        let windows = NoticeWindows()
        var issues = ["ISSUE-A"]
        let first = try #require(windows.configIssues(for: issues))
        #expect(first.issues == ["ISSUE-A"])
        issues.append("ISSUE-B")
        #expect(windows.configIssues(for: issues) == first, "otwarty komunikat zmienił treść")
        issues = try #require(windows.dismiss(first, from: issues))
        #expect(issues == ["ISSUE-B"], "OK usunęło problem, którego nie pokazano")
        let next = try #require(windows.configIssues(for: issues))
        #expect(next.issues == ["ISSUE-B"])
        #expect(next.id != first.id)
        // The alert that closes after its button („OK”) dismisses nothing more.
        #expect(windows.dismiss(first, from: issues) == nil)
        #expect(windows.presenter(for: first) == nil)
        issues = try #require(windows.dismiss(next, from: issues))
        #expect(issues.isEmpty)
        #expect(windows.configIssues(for: issues) == nil)
    }

    // …and in the windows: the open alert keeps its problems and window, the next one comes after OK.
    @Test func theNextAlertComesAfterTheOpenOne() throws {
        let windows = NoticeWindows()
        let main = Self.window(), wall = Self.window()
        defer { main.close(); wall.close() }
        windows.register(main)
        windows.register(wall)
        wall.orderFront(nil)
        var issues = ["ISSUE-A"]
        let first = try #require(windows.configIssues(for: issues))
        #expect(windows.presenter(for: first) === wall)
        issues.append("ISSUE-B")
        main.orderFront(nil)
        #expect(windows.configIssues(for: issues) == first)
        #expect(windows.presenter(for: first) === wall, "otwarty komunikat przeszedł do innego okna")
        issues = try #require(windows.dismiss(first, from: issues))
        let next = try #require(windows.configIssues(for: issues))
        #expect(next.issues == ["ISSUE-B"])
        #expect(windows.presenter(for: next) === main)
    }

    // REV-68: the window chosen for the configuration problems was remembered by their text and never forgotten.
    // The same problem again (the same damaged bytes keep the same .bak name, so the same text) was shown by the
    // window that showed it last time – e.g. the Screen Wall on a projector – not by the one the user works in now.
    // Every alert is placed anew.
    @Test func theSameProblemAgainIsShownByTheWindowInUseNow() throws {
        let windows = NoticeWindows()
        let main = Self.window(), wall = Self.window()
        defer { main.close(); wall.close() }
        windows.register(main)
        windows.register(wall)
        wall.orderFront(nil)
        var issues = ["ISSUE-A"]
        let first = try #require(windows.configIssues(for: issues))
        #expect(windows.presenter(for: first) === wall)
        issues = try #require(windows.dismiss(first, from: issues))
        #expect(issues.isEmpty)
        main.orderFront(nil)
        issues.append("ISSUE-A")
        let again = try #require(windows.configIssues(for: issues))
        #expect(again.issues == first.issues)
        #expect(windows.presenter(for: again) === main, "ten sam problem pokazało okno wybrane poprzednio")
    }
}

extension RevR7appTests {
    /// The steps of both routines with everything switched on.
    static var allSteps: [[LessonStepKind]] {
        var start = LessonStartConfig()
        start.wake = true
        start.sendMaterials = true
        start.openApps = true
        start.apps = "Safari"
        start.greet = true
        var end = LessonEndConfig()
        end.warn = true
        end.quitApps = true
        end.collect = true
        end.cleanShared = true
        end.cleanDownloads = true
        end.logout = true
        end.power = .shutdown
        return [LessonPlan.start(start, settings: AppSettings()).steps, LessonPlan.end(end, settings: AppSettings()).steps]
    }

    // UI-34: both cleanup steps have `trash`, the symbol of Pliki › „Wyczyść folder…” (UI-33), and the header of the
    // lesson run grid showed only the symbols – two identical columns side by side: a red ✕ under one of them did
    // not say which folder was not cleaned. A step whose symbol another step of the plan has too gets a short caption.
    @Test func everyColumnOfTheRunGridHasAHeaderOfItsOwn() throws {
        for steps in Self.allSteps {
            let headers = steps.map { "\($0.icon) \($0.gridCaption(in: steps) ?? "")" }
            #expect(Set(headers).count == steps.count, "\(headers)")
        }
        let end = Self.allSteps[1]
        #expect(end.contains(.cleanShared) && end.contains(.cleanDownloads))
        #expect(LessonStepKind.cleanShared.gridCaption(in: end) == "folder ucznia")
        #expect(LessonStepKind.cleanDownloads.gridCaption(in: end) == "Pobrane")
        // A symbol of its own says enough: no caption, the grid stays compact.
        #expect(LessonStepKind.collect.gridCaption(in: end) == nil)
        #expect(LessonStepKind.cleanDownloads.gridCaption(in: [.quitApps, .cleanDownloads]) == nil)
        // Any two steps with one symbol (also ones added later) get short captions of their own.
        for a in LessonStepKind.allCases {
            for b in LessonStepKind.allCases where a != b && a.icon == b.icon {
                let captionA = a.gridCaption(in: [a, b]), captionB = b.gridCaption(in: [a, b])
                #expect(captionA != nil && captionA != captionB, "\(a) i \(b): \(captionA ?? "-") / \(captionB ?? "-")")
                #expect((captionA ?? "").count <= 14, "za długi podpis kolumny: \(captionA ?? "")")
            }
        }
        // The header of the grid in Zajęcia shows them.
        #expect(try RevR6appTests.source("ClassroomView.swift").contains("gridCaption(in: run.plan.steps)"))
    }
}
