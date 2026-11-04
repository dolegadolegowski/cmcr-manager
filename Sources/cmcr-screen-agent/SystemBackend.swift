import AppKit
import CoreGraphics
import Foundation
import ScreenAgentKit
import ScreenCaptureKit

/// Lock and fast-user-switching state of this login session (`CGSessionCopyCurrentDictionary`).
struct SessionState {
    var onConsole: Bool
    var locked: Bool

    static func current() -> SessionState {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No window server session at all: nothing of it is on the screen.
            return SessionState(onConsole: false, locked: false)
        }
        // kCGSessionOnConsoleKey is a CFSTR macro Swift does not import; its value is this string.
        let onConsole = (dict["kCGSSessionOnConsoleKey"] as? Bool) ?? true
        let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return SessionState(onConsole: onConsole, locked: locked)
    }

    static var mainDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}

/// The real agent: ScreenCaptureKit for screenshots, AppKit for the notice and the frontmost app.
final class SystemBackend: AgentBackend {
    private let notices = NoticePresenter()

    /// The main thread runs AppKit for the whole life of the agent: an accessory app (no Dock icon, no menu bar;
    /// the bundle's LSUIElement says the same) whose only windows are the notice panels.
    static func prepareApplication() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        _ = CGMainDisplayID()
    }

    static func runApplication() -> Never {
        NSApplication.shared.run()
        exit(0)
    }

    func status() -> AgentStatus {
        let session = SessionState.current()
        // Preflight only: it never shows the permission dialog (a student could not approve it anyway).
        return AgentStatus(permissionGranted: CGPreflightScreenCaptureAccess(), locked: session.locked,
                           onConsole: session.onConsole, asleep: SessionState.mainDisplayAsleep, user: NSUserName())
    }

    func capture(maxSide: Int, quality: Int, display: DisplaySelection) -> Result<CaptureOutput, AgentFailure> {
        // Without the permission ScreenCaptureKit itself would bring up the dialog: never get that far.
        guard CGPreflightScreenCaptureAccess() else { return .failure(.noPermission) }
        let session = SessionState.current()
        guard session.onConsole else { return .failure(.notConsole) }
        guard !session.locked else { return .failure(.locked) }
        guard !SessionState.mainDisplayAsleep else { return .failure(.asleep) }
        let front = frontApp()
        let box = Box<Result<[CapturedImage], AgentFailure>>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.value = await Self.captureImages(maxSide: maxSide, quality: quality, display: display)
            done.signal()
        }
        guard done.wait(timeout: .now() + AgentInfo.captureTimeout) == .success, let result = box.value else {
            return .failure(AgentFailure(.failed, "zrzut ekranu nie zakończył się w ciągu \(Int(AgentInfo.captureTimeout)) s"))
        }
        return result.map { CaptureOutput(frontApp: front, images: $0) }
    }

    func notice(title: String, text: String) -> NoticeResult {
        onMain(timeout: 5) { [notices] in notices.show(title: title, text: text, seconds: AgentInfo.noticeSeconds) } ?? .hidden
    }

    func frontApp() -> String {
        onMain(timeout: 3) { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" } ?? ""
    }

    func requestPermission() -> Bool {
        // Shows macOS's own dialog at the iMac ("Otwórz Ustawienia systemowe") and adds the agent to the Screen
        // Recording list; the answer is the state right now (the admin decides later).
        withTimeout(5) { CGRequestScreenCaptureAccess() } ?? false
    }

    // MARK: - ScreenCaptureKit

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The display's size in pixels (SCDisplay reports points; Retina displays have 2 pixels per point).
    private static func pixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0, mode.pixelWidth > 0 else {
            return (display.width, display.height)
        }
        let scale = Double(mode.pixelWidth) / Double(mode.width)
        return (Int((Double(display.width) * scale).rounded()), Int((Double(display.height) * scale).rounded()))
    }

    private static func captureImages(maxSide: Int, quality: Int,
                                      display selection: DisplaySelection) async -> Result<[CapturedImage], AgentFailure> {
        do {
            let content = try await SCShareableContent.current
            var byID: [CGDirectDisplayID: SCDisplay] = [:]
            for d in content.displays { byID[d.displayID] = d }
            // Numbered like `screencapture -D`: 1 = main display, then CGGetActiveDisplayList order.
            var order = ImageMath.orderedDisplays(main: CGMainDisplayID(), active: activeDisplays()).filter { byID[$0] != nil }
            for d in content.displays where !order.contains(d.displayID) { order.append(d.displayID) }
            guard let numbers = selection.numbers(displayCount: order.count) else {
                return .failure(.noDisplay(selection, count: order.count))
            }
            var images: [CapturedImage] = []
            for n in numbers {
                guard let display = byID[order[n - 1]] else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let pixels = pixelSize(of: display)
                let size = ImageMath.fit(width: pixels.width, height: pixels.height, maxSide: maxSide)
                config.width = size.width
                config.height = size.height
                config.showsCursor = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Safety net: should ScreenCaptureKit hand back more pixels than asked for, scale them down here.
                guard let fitted = JPEGCodec.downscaled(image, maxSide: maxSide),
                      let jpeg = JPEGCodec.encode(fitted, quality: quality) else {
                    return .failure(AgentFailure(.failed, "nie można zakodować zrzutu ekranu \(n) do JPEG"))
                }
                images.append(CapturedImage(display: n, width: fitted.width, height: fitted.height, jpeg: jpeg))
            }
            guard !images.isEmpty else { return .failure(.noDisplay(selection, count: order.count)) }
            return .success(images)
        } catch let error as SCStreamError where error.code == .userDeclined {
            return .failure(.noPermission)
        } catch {
            let ns = error as NSError
            return .failure(AgentFailure(.failed, "zrzut ekranu nie powiódł się: \(ns.localizedDescription) (\(ns.domain) \(ns.code))"))
        }
    }
}

/// The observation notice: a small panel in the top right corner of every display, the same as the earlier
/// osascript one (Scripts.observeNoticeJXA). A non-activating panel of an accessory app never takes the keyboard,
/// ignores the mouse, shows over full-screen apps and needs no Notification Center permission. Main thread only.
final class NoticePresenter {
    private var panels: [NSPanel] = []
    private var timer: Timer?

    func show(title: String, text: String, seconds: TimeInterval) -> NoticeResult {
        // A locked screen (screen saver with password, lock screen) or a sleeping display: the panel would be drawn
        // where nobody sees it, so it does not count as shown (AUDIT ZAJ-05). A session in the background (fast user
        // switching) is not on the screen either.
        let session = SessionState.current()
        if session.locked || SessionState.mainDisplayAsleep { return .locked }
        guard session.onConsole else { return .hidden }
        closeAll()
        let w: CGFloat = 420, h: CGFloat = 96, pad: CGFloat = 16
        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            let rect = NSRect(x: vf.maxX - w - pad, y: vf.maxY - h - pad, width: w, height: h)
            let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: 1001)
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.backgroundColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 0.96)
            let titleField = NSTextField(labelWithString: title)
            titleField.font = .boldSystemFont(ofSize: 16)
            titleField.textColor = .white
            titleField.frame = NSRect(x: 18, y: h - 38, width: w - 36, height: 22)
            let textField = NSTextField(wrappingLabelWithString: text)
            textField.font = .systemFont(ofSize: 14)
            textField.textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88)
            textField.frame = NSRect(x: 18, y: 12, width: w - 36, height: h - 54)
            panel.contentView?.addSubview(titleField)
            panel.contentView?.addSubview(textField)
            panels.append(panel)
        }
        // The timer that removes the panels is set up before anything is reported.
        let t = Timer(timeInterval: max(2, seconds), repeats: false) { [weak self] _ in self?.closeAll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        var shown = false
        for panel in panels {
            panel.orderFrontRegardless()
            if panel.isVisible { shown = true }
        }
        if !shown { closeAll() }
        return shown ? .shown : .hidden
    }

    private func closeAll() {
        timer?.invalidate()
        timer = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }
}
