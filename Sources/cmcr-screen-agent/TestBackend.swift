#if DEBUG
import Foundation
import ScreenAgentKit

/// DEBUG-only stand-in for the screen (`CMCR_SCREEN_AGENT_TEST_DIR=<dir>`): no AppKit, no ScreenCaptureKit, no TCC
/// call, so the e2e harness and ScreenAgentKitTests can run the real agent on a developer's Mac. Every request
/// reads the files in <dir> again, so a test can change the state between requests:
///
///   perm               "denied" → no Screen Recording permission (anything else, or no file: granted)
///   locked             exists → the screen is locked (CAPTURE: ERR locked, NOTICE: locked)
///   notconsole         exists → the session is not at the screen (ERR notconsole)
///   asleep             exists → the display sleeps (ERR asleep)
///   notice             shown | hidden | locked (default shown)
///   front              the frontmost app (default "Finder")
///   user               the account name PING reports (default: this user)
///   displays           number of displays (default 1)
///   size               WxH of every display in pixels (default 1440x900)
///   variant            exists → the generated picture has other colours (a "changed screen")
///   capture-fail       exists → ERR failed with the file's text
///   capture-delay      seconds to wait before answering a capture
///   old                exists → the process counts as older than 30 s (it exits after ERR noperm / perm=denied)
///
/// It writes: requests.log (every request line; NOTICE also decoded as `NOTICE-TEXT <title> | <text>`) and
/// permission-requested (touched by REQUEST-PERMISSION).
final class TestBackend: AgentBackend {
    let directory: String
    private let logLock = NSLock()

    init(directory: String) {
        self.directory = directory
    }

    private func file(_ name: String) -> String { "\(directory)/\(name)" }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name)) }
    private func text(_ name: String) -> String? {
        (try? String(contentsOfFile: file(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var permissionGranted: Bool { text("perm") != "denied" }

    var pretendsOldProcess: Bool { exists("old") }

    func received(_ request: AgentRequest, line: String) {
        var entry = line + "\n"
        if case let .notice(title, text) = request { entry += "NOTICE-TEXT \(title) | \(text)\n" }
        logLock.lock()
        defer { logLock.unlock() }
        let path = file("requests.log")
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(entry.utf8))
        }
    }

    func status() -> AgentStatus {
        AgentStatus(permissionGranted: permissionGranted, locked: exists("locked"), onConsole: !exists("notconsole"),
                    asleep: exists("asleep"), user: text("user") ?? NSUserName())
    }

    func capture(maxSide: Int, quality: Int, display: DisplaySelection) -> Result<CaptureOutput, AgentFailure> {
        if let delay = text("capture-delay").flatMap(Double.init), delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard permissionGranted else { return .failure(.noPermission) }
        let s = status()
        guard s.onConsole else { return .failure(.notConsole) }
        guard !s.locked else { return .failure(.locked) }
        guard !s.asleep else { return .failure(.asleep) }
        if exists("capture-fail") {
            let why = text("capture-fail") ?? ""
            return .failure(AgentFailure(.failed, why.isEmpty ? "testowy błąd zrzutu" : why))
        }
        let count = text("displays").flatMap { Int($0) } ?? 1
        guard let numbers = display.numbers(displayCount: count) else { return .failure(.noDisplay(display, count: count)) }
        var width = 1440, height = 900
        if let size = text("size")?.split(separator: "x"), size.count == 2, let w = Int(size[0]), let h = Int(size[1]),
           w > 0, h > 0 {
            width = w
            height = h
        }
        let fitted = ImageMath.fit(width: width, height: height, maxSide: maxSide)
        var images: [CapturedImage] = []
        for n in numbers {
            guard let image = TestPattern.make(width: fitted.width, height: fitted.height, display: n, variant: exists("variant")),
                  let jpeg = JPEGCodec.encode(image, quality: quality) else {
                return .failure(AgentFailure(.failed, "nie można utworzyć obrazu testowego"))
            }
            images.append(CapturedImage(display: n, width: image.width, height: image.height, jpeg: jpeg))
        }
        return .success(CaptureOutput(frontApp: frontApp(), images: images))
    }

    func notice(title: String, text: String) -> NoticeResult {
        if exists("locked") { return .locked }
        return NoticeResult(rawValue: self.text("notice") ?? "") ?? .shown
    }

    func frontApp() -> String { text("front") ?? "Finder" }

    func requestPermission() -> Bool {
        FileManager.default.createFile(atPath: file("permission-requested"), contents: Data())
        return permissionGranted
    }
}
#endif
