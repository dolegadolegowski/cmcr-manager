import Darwin
import Foundation
import os
import ScreenAgentKit

let agentLog = Logger(subsystem: AgentInfo.label, category: "agent")

/// Prints a fatal start-up problem (launchd keeps no stdout: os_log has it too) and exits.
func fatal(_ message: String) -> Never {
    agentLog.error("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("cmcr-screen-agent: \(message)\n".utf8))
    exit(1)
}

/// `cmcr-screen-agent serve`.
enum Serve {
    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        let paths = AgentPaths.current(environment: env)
        var uid = getuid()
        var backend: AgentBackend?
        #if DEBUG
        if let s = env["CMCR_SCREEN_AGENT_TEST_UID"], !s.isEmpty {
            guard let n = strictInt(s) else { fatal("nieprawidłowe CMCR_SCREEN_AGENT_TEST_UID: \(s)") }
            uid = uid_t(n)
        }
        if let dir = env["CMCR_SCREEN_AGENT_TEST_DIR"], !dir.isEmpty {
            backend = TestBackend(directory: dir)
        }
        #endif
        let headless = backend != nil
        // AppKit (and with it the window server connection) is set up on the main thread before any request can
        // reach CoreGraphics from a connection thread.
        if !headless { SystemBackend.prepareApplication() }
        let server: AgentServer
        do {
            server = try AgentServer(socketPath: paths.socketPath(uid: uid), runDir: paths.runDir,
                                     backend: backend ?? SystemBackend())
        } catch {
            fatal("\(error)")
        }
        server.start()
        agentLog.info("CMCR Screen Agent \(AgentInfo.version, privacy: .public) gotowy (\(server.path, privacy: .public))")
        if headless { dispatchMain() }
        SystemBackend.runApplication()
    }
}

struct ServeError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// The socket server: one request per connection, only from root or the agent's own user.
final class AgentServer {
    let path: String
    let backend: AgentBackend
    private let listenFD: Int32
    private let identity: (dev: dev_t, ino: ino_t)
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var lastPermissionRequest: TimeInterval?
    private var active = 0
    private var stopping = false
    private let connections = DispatchQueue(label: "\(AgentInfo.label).connection", attributes: .concurrent)
    /// At most this many requests at once; further connections wait in the listen queue.
    private let slots = DispatchSemaphore(value: 8)
    private var sources: [DispatchSourceProtocol] = []

    init(socketPath: String, runDir: String, backend: AgentBackend) throws {
        path = socketPath
        self.backend = backend
        // The run folder (root:wheel 1733) is created by the installer; without it the agent is not installed
        // properly and must not create anything itself.
        var st = stat()
        guard lstat(runDir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw ServeError("brak katalogu \(runDir) – zainstaluj usługę ponownie (Konfiguracja › Przygotowanie iMaców)")
        }
        var addr = try UnixSocket.address(socketPath)
        // A leftover of an earlier run is removed only when it is this user's own socket: anything else (a file, a
        // link, someone else's socket) is left alone and the agent stops.
        if lstat(socketPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
                throw ServeError("\(socketPath) istnieje i nie jest gniazdem tego użytkownika – nie zostanie usunięte")
            }
            guard unlink(socketPath) == 0 else { throw ServeError("nie można usunąć starego gniazda \(socketPath): \(String(cString: strerror(errno)))") }
        } else if errno != ENOENT {
            throw ServeError("\(socketPath): \(String(cString: strerror(errno)))")
        }
        let fd = try UnixSocket.makeSocket()
        // Created 0600 from the start (no window between bind and chmod).
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let bindError = errno
        umask(oldMask)
        guard bound == 0 else {
            close(fd)
            throw ServeError("nie można utworzyć gniazda \(socketPath): \(String(cString: strerror(bindError)))")
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0, lstat(socketPath, &st) == 0 else {
            let e = errno
            close(fd)
            unlink(socketPath)
            throw ServeError("nie można nasłuchiwać na \(socketPath): \(String(cString: strerror(e)))")
        }
        listenFD = fd
        identity = (st.st_dev, st.st_ino)
    }

    func start() {
        let accepter = Thread { [self] in acceptLoop() }
        accepter.name = "accept"
        accepter.start()

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [self] in
                agentLog.info("koniec pracy (sygnał \(sig))")
                removeSocket()
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
        // Another copy may have taken the path over (e.g. "Zakończ i otwórz ponownie" in System Settings starts one
        // outside launchd), or the uninstaller removed it: an agent nobody can reach any more just ends (launchd's
        // KeepAlive brings back a single one).
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        watchdog.setEventHandler { [self] in
            if !socketIsOurs() {
                agentLog.info("gniazdo \(self.path, privacy: .public) zostało usunięte lub zastąpione – koniec pracy")
                exit(0)
            }
        }
        watchdog.resume()
        sources.append(watchdog)
    }

    private func socketIsOurs() -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_dev == identity.dev && st.st_ino == identity.ino
    }

    private func removeSocket() {
        if socketIsOurs() { unlink(path) }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                lock.lock(); let ending = stopping; lock.unlock()
                if ending { return }
                agentLog.error("accept: \(String(cString: strerror(errno)), privacy: .public)")
                usleep(200_000)
                continue
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            slots.wait()
            connections.async { [self] in
                lock.lock(); active += 1; lock.unlock()
                handle(fd)
                close(fd)
                lock.lock(); active -= 1; lock.unlock()
                slots.signal()
            }
        }
    }

    private func handle(_ fd: Int32) {
        var peerUID = uid_t(), peerGID = gid_t()
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == 0 || peerUID == getuid() else {
            agentLog.error("odrzucono połączenie od uid \(peerUID)")
            return
        }
        let stream = SocketStream(fd: fd, inactivity: AgentInfo.clientTimeout, total: AgentInfo.clientTotalTimeout)
        guard let line = try? stream.readLine(maxLength: 4096) else { return }
        let request: AgentRequest
        do {
            request = try AgentRequest.parse(line)
        } catch {
            try? stream.writeLine(AgentReply.error(.protocol, "\(error)").line)
            return
        }
        backend.received(request, line: line)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "CMCR Screen Agent")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var denied = false
        switch request {
        case .ping:
            let status = backend.status()
            denied = !status.permissionGranted
            try? stream.writeLine(AgentReply.ping(status).line)
        case let .capture(maxSide, quality, display):
            switch backend.capture(maxSide: maxSide, quality: quality, display: display) {
            case .success(let out):
                var data = Data((AgentReply.capture(count: out.images.count, frontApp: out.frontApp).line + "\n").utf8)
                for image in out.images {
                    let header = ImageHeader(display: image.display, width: image.width, height: image.height,
                                             byteCount: image.jpeg.count)
                    data.append(Data((header.line + "\n").utf8))
                    data.append(image.jpeg)
                }
                do { try stream.write(data) } catch { agentLog.error("wysyłanie zrzutu: \(error.localizedDescription, privacy: .public)") }
            case .failure(let failure):
                denied = failure.code == .noperm
                try? stream.writeLine(AgentReply.error(failure.code, failure.message).line)
            }
        case let .notice(title, text):
            try? stream.writeLine(AgentReply.notice(backend.notice(title: title, text: text)).line)
        case .front:
            try? stream.writeLine(AgentReply.front(backend.frontApp()).line)
        case .requestPermission:
            lock.lock(); lastPermissionRequest = ProcessInfo.processInfo.systemUptime; lock.unlock()
            try? stream.writeLine(AgentReply.permission(granted: backend.requestPermission()).line)
        }
        if denied { restartIfStale() }
    }

    /// No Screen Recording permission in a process that has been running for a while: macOS may have cached a
    /// decision that has changed since (an admin granted it at the iMac), so this agent ends after answering and
    /// launchd starts a fresh one (docs/screen-agent.md › Zasady usługi).
    private func restartIfStale() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let since = lastPermissionRequest.map { now - $0 }
        lock.unlock()
        let age = backend.pretendsOldProcess ? .infinity : now - started
        guard RestartPolicy.shouldExitAfterDenied(processAge: age, sincePermissionRequest: since) else { return }
        lock.lock()
        let first = !stopping
        stopping = true
        lock.unlock()
        guard first else { return }
        agentLog.info("brak uprawnienia do nagrywania ekranu – ponowne uruchomienie, by odczytać aktualny stan")
        // Nothing new reaches this process; requests already being answered get up to 2 s.
        removeSocket()
        close(listenFD)
        for _ in 0..<20 {
            lock.lock(); let busy = active; lock.unlock()
            if busy <= 1 { break }
            usleep(100_000)
        }
        exit(0)
    }
}
