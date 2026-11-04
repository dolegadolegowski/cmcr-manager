import Foundation
import ScreenAgentKit

/// One captured display, ready to send.
struct CapturedImage {
    var display: Int
    var width: Int
    var height: Int
    var jpeg: Data
}

struct CaptureOutput {
    var frontApp: String
    var images: [CapturedImage]
}

/// A request the agent could not fulfil: `ERR <code> <message>`.
struct AgentFailure: Error {
    var code: AgentErrorCode
    var message: String

    init(_ code: AgentErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    static let noPermission = AgentFailure(.noperm, "CMCR Screen Agent nie ma uprawnienia „Nagrywanie ekranu i dźwięku systemowego”")
    static let locked = AgentFailure(.locked, "ekran jest zablokowany")
    static let notConsole = AgentFailure(.notconsole, "sesja użytkownika nie jest teraz na ekranie (szybkie przełączanie użytkowników)")
    static let asleep = AgentFailure(.asleep, "ekran jest uśpiony")

    static func noDisplay(_ selection: DisplaySelection, count: Int) -> AgentFailure {
        if count == 0 { return AgentFailure(.nodisplay, "brak podłączonego ekranu") }
        return AgentFailure(.nodisplay, "brak ekranu \(selection.token) (podłączonych ekranów: \(count))")
    }
}

/// What actually answers the requests: the real screen (`SystemBackend`) or, in DEBUG builds, files in a test
/// folder (`TestBackend`). Every method is called on a connection queue, never on the main thread.
protocol AgentBackend: AnyObject {
    func status() -> AgentStatus
    func capture(maxSide: Int, quality: Int, display: DisplaySelection) -> Result<CaptureOutput, AgentFailure>
    func notice(title: String, text: String) -> NoticeResult
    func frontApp() -> String
    func requestPermission() -> Bool
    /// Called with every valid request line (the test backend records them).
    func received(_ request: AgentRequest, line: String)
    /// The test backend can pretend the process is old (`RestartPolicy`).
    var pretendsOldProcess: Bool { get }
}

extension AgentBackend {
    func received(_ request: AgentRequest, line: String) {}
    var pretendsOldProcess: Bool { false }
}

/// A value handed from one thread to another (a semaphore orders the accesses; the lock keeps it safe anyway).
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Runs `body` on the main thread (AppKit) and waits for it at most `timeout`; `nil` when it did not finish.
func onMain<T>(timeout: TimeInterval, _ body: @escaping () -> T) -> T? {
    if Thread.isMainThread { return body() }
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        box.value = body()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.value
}

/// Runs `body` on another thread and waits for it at most `timeout`.
func withTimeout<T>(_ timeout: TimeInterval, _ body: @escaping () -> T) -> T? {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.value = body()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.value
}
