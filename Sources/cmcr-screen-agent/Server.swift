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
            guard let n = strictUID(s) else { fatal("nieprawidłowe CMCR_SCREEN_AGENT_TEST_UID: \(s)") }
            uid = n
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
            server = try AgentServer(socketPath: paths.socketPath(uid: uid), directory: paths.socketDir(uid: uid),
                                     backend: backend ?? SystemBackend())
        } catch let problem as SocketLocation.Problem {
            switch problem {
            case .missing(let m), .untrusted(let m): fatal(m)
            }
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
    /// Until when (uptime) the notice panel this agent showed last stays on screen.
    private var noticeVisibleUntil: TimeInterval = 0
    /// An exit after a denied capture waits for the notice panel to go.
    private var exitPending = false
    private var active = 0
    private var stopping = false
    private let connections = DispatchQueue(label: "\(AgentInfo.label).connection", attributes: .concurrent)
    /// At most this many requests at once; further connections wait in the listen queue (`listenBacklog`).
    private let slots = DispatchSemaphore(value: 8)
    private var sources: [DispatchSourceProtocol] = []

    init(socketPath: String, directory: String, backend: AgentBackend) throws {
        path = socketPath
        self.backend = backend
        // run/<uid> (owner: this user, 0700) is created by root before it starts the agent: without it (or with
        // anything else there) the agent stops and launchd tries again later. Nobody else can create anything in it.
        try SocketLocation.checkForAgent(directory: directory, owner: getuid())
        var addr = try UnixSocket.address(socketPath)
        // A leftover in its own folder (a socket of an earlier run, or anything this user put there) is removed;
        // unlink never follows a link and cannot remove a folder.
        var st = stat()
        if lstat(socketPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) != S_IFDIR else {
                throw ServeError("\(socketPath) jest katalogiem – nie zostanie usunięty")
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
        guard listen(fd, AgentInfo.listenBacklog) == 0, lstat(socketPath, &st) == 0 else {
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
            var status = backend.status()
            status.user = limitedName(status.user)
            try? stream.writeLine(AgentReply.ping(status).line)
        case let .capture(maxSide, quality, display):
            switch backend.capture(maxSide: maxSide, quality: quality, display: display) {
            case .success(let out):
                var data = Data((AgentReply.capture(count: out.images.count, frontApp: limitedName(out.frontApp)).line + "\n").utf8)
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
            let result = backend.notice(title: title, text: text)
            if result == .shown {
                // The panel closes itself after noticeSeconds (at least 2 s); a little more for drawing.
                let until = ProcessInfo.processInfo.systemUptime + max(2, backend.noticeSeconds) + 0.5
                lock.lock(); noticeVisibleUntil = max(noticeVisibleUntil, until); lock.unlock()
            }
            try? stream.writeLine(AgentReply.notice(result).line)
        case .front:
            try? stream.writeLine(AgentReply.front(limitedName(backend.frontApp())).line)
        case .requestPermission:
            lock.lock(); lastPermissionRequest = ProcessInfo.processInfo.systemUptime; lock.unlock()
            try? stream.writeLine(AgentReply.permission(granted: backend.requestPermission()).line)
        }
        if denied { restartIfStale() }
    }

    /// A capture found no Screen Recording permission in a process that has been running for a while: macOS may
    /// have cached a decision that has changed since (an admin granted it at the iMac), so this agent ends after
    /// answering and launchd starts a fresh one (docs/screen-agent.md › Zasady usługi). Never after a PING, not
    /// while the permission dialog it showed may still be up, and not while its notice panel is on screen (the
    /// student must be able to read it): the exit then waits until the panel has gone.
    private func restartIfStale() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let since = lastPermissionRequest.map { now - $0 }
        let noticeRemaining = noticeVisibleUntil - now
        let alreadyPending = exitPending
        lock.unlock()
        let age = backend.pretendsOldProcess ? .infinity : now - started
        switch RestartPolicy.afterDeniedCapture(processAge: age, sincePermissionRequest: since,
                                                noticeRemaining: noticeRemaining) {
        case .stay:
            return
        case .later(let delay):
            guard !alreadyPending else { return }
            lock.lock(); exitPending = true; lock.unlock()
            agentLog.info("brak uprawnienia do nagrywania ekranu – ponowne uruchomienie po zniknięciu komunikatu")
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                lock.lock(); exitPending = false; lock.unlock()
                restartIfStale()
            }
        case .exit:
            exitNow()
        }
    }

    private func exitNow() {
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
