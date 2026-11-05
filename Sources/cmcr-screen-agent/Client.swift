import Darwin
import Foundation
import ScreenAgentKit

/// `cmcr-screen-agent client <uid> <command> …` (docs/screen-agent.md › Klient). Run by the preview script as root
/// (or by the logged-in user). Before anything is sent it makes sure the socket belongs to user <uid> and that the
/// process behind it is the installed agent: a student cannot put a program of their own there to show the teacher
/// a fake screen. Prints result lines on stdout; every failure is one `ERR <code> <text>` line and an exit code.
///
/// `--pid N` (right after `<uid>`, or as the last two arguments) names the pid launchd reports for the agent
/// (`launchctl print gui/<uid>/pl.cmcr.manager.screen-agent`); the scripts always pass it.
enum Client {
    private typealias Code = AgentInfo.ClientCode

    /// A failure to print as `ERR <code> <text>` and exit with `exitCode`.
    struct Failure: Error {
        var code: String
        var message: String
        var exitCode: Int32

        init(_ code: String, _ message: String, _ exitCode: Int32) {
            self.code = code
            self.message = message
            self.exitCode = exitCode
        }

        static func usage(_ m: String) -> Failure { Failure("usage", m, Code.usage) }
        static func unreachable(_ m: String) -> Failure { Failure("unreachable", m, Code.unreachable) }
        static func untrusted(_ m: String) -> Failure { Failure("untrusted", m, Code.untrusted) }
        static func protocolError(_ m: String) -> Failure { Failure("protocol", m, Code.protocolError) }
        static func write(_ m: String) -> Failure { Failure("write", m, Code.protocolError) }
    }

    /// A parsed command line.
    struct Invocation: Equatable {
        var uid: uid_t
        var request: AgentRequest
        /// The agent's pid as launchd reports it (`--pid`).
        var pid: pid_t?
    }

    static func run(_ args: [String]) -> Int32 {
        do {
            let invocation = try parse(args)
            try execute(invocation)
            return Code.ok
        } catch let f as Failure {
            print(ClientOutput.error(f.code, f.message))
            return f.exitCode
        } catch {
            print(ClientOutput.error("error", "\(error)"))
            return Code.other
        }
    }

    static func parse(_ arguments: [String]) throws -> Invocation {
        let usage = "użycie: cmcr-screen-agent client <uid> [--pid N] ping|capture|notice|front|request-permission …"
        guard let first = arguments.first, let uid = strictUID(first) else { throw Failure.usage(usage) }
        // --pid N: before the command or after its arguments (no argument of a command can be "--pid").
        var args = arguments
        var pid: pid_t?
        func takePid(at i: Int) throws {
            guard i + 1 < args.count, let n = strictInt(args[i + 1]), n > 0, n <= Int(Int32.max) else {
                throw Failure.usage("--pid wymaga numeru procesu")
            }
            pid = pid_t(n)
            args.removeSubrange(i...(i + 1))
        }
        if args.count > 1 && args[1] == "--pid" {
            try takePid(at: 1)
        } else if args.count > 2 && args[args.count - 2] == "--pid" {
            try takePid(at: args.count - 2)
        }
        guard args.count >= 2, !args.contains("--pid") else { throw Failure.usage(usage) }
        let rest = Array(args.dropFirst(2))
        func count(_ k: Int) throws {
            guard rest.count == k else { throw Failure.usage("nieprawidłowa liczba argumentów polecenia \(args[1])") }
        }
        switch args[1] {
        case "ping":
            try count(0)
            return Invocation(uid: uid, request: .ping, pid: pid)
        case "front":
            try count(0)
            return Invocation(uid: uid, request: .front, pid: pid)
        case "request-permission":
            try count(0)
            return Invocation(uid: uid, request: .requestPermission, pid: pid)
        case "capture":
            try count(3)
            guard let maxSide = strictInt(rest[0]), AgentInfo.maxSideRange.contains(maxSide) else {
                throw Failure.usage("nieprawidłowy rozmiar zrzutu: \(rest[0]) (\(AgentInfo.maxSideRange.lowerBound)–\(AgentInfo.maxSideRange.upperBound))")
            }
            guard let quality = strictInt(rest[1]), AgentInfo.qualityRange.contains(quality) else {
                throw Failure.usage("nieprawidłowa jakość JPEG: \(rest[1]) (10–100)")
            }
            guard let display = DisplaySelection(token: rest[2]) else {
                throw Failure.usage("nieprawidłowy ekran: \(rest[2]) (main, all albo 1–9)")
            }
            return Invocation(uid: uid, request: .capture(maxSide: maxSide, quality: quality, display: display), pid: pid)
        case "notice":
            try count(2)
            guard let title = Base64Field.decode(rest[0]), let text = Base64Field.decode(rest[1]) else {
                throw Failure.usage("tytuł i tekst komunikatu muszą być w base64 (UTF-8)")
            }
            return Invocation(uid: uid, request: .notice(title: title, text: text), pid: pid)
        default:
            throw Failure.usage("nieznane polecenie: \(args[1])")
        }
    }

    // MARK: - Exchange

    private static func execute(_ invocation: Invocation) throws {
        let uid = invocation.uid, request = invocation.request
        let env = ProcessInfo.processInfo.environment
        let paths = AgentPaths.current(environment: env)
        var testMode = false
        #if DEBUG
        // The e2e harness has no root and no second account: everything runs as the developer.
        testMode = !(env["CMCR_SCREEN_AGENT_TEST_DIR"] ?? "").isEmpty
        #endif
        let me = geteuid()
        if !testMode && me != 0 && me != uid {
            throw Failure.usage("uruchom jako root albo jako użytkownik o uid \(uid)")
        }
        // Who may own the socket and be the agent: user <uid> (in the harness also the developer).
        var owners: Set<uid_t> = [uid]
        if testMode { owners.insert(getuid()) }

        let (fd, peer) = try connect(paths: paths, uid: uid, owners: owners, runDirOwners: [0, me],
                                     expectedPID: invocation.pid)
        defer { close(fd) }
        let stream = SocketStream(fd: fd, inactivity: AgentInfo.clientTimeout, total: AgentInfo.clientTotalTimeout)
        do {
            try stream.writeLine(request.line)
        } catch let e as IOFailure {
            throw Failure.unreachable("usługa nie przyjęła polecenia: \(e.message)")
        }
        let reply: AgentReply
        do {
            reply = try AgentReply.parse(stream.readLine())
        } catch let e as IOFailure {
            switch e.kind {
            case .closed: throw Failure.unreachable("usługa zamknęła połączenie bez odpowiedzi")
            // Something answered, but not with a valid line: not a dead agent (no restart for it).
            case .tooLong, .invalid: throw Failure.protocolError("nieprawidłowa odpowiedź usługi: \(e.message)")
            case .timeout, .system: throw Failure.unreachable("usługa nie odpowiada: \(e.message)")
            }
        } catch let e as ProtocolError {
            throw Failure.protocolError(e.message)
        }
        // The process must still be running normally now that it has answered (not stopped meanwhile).
        if let why = PeerIdentity.suspendedState(of: peer) {
            throw Failure.untrusted("usługa po drugiej stronie gniazda nie działa: \(why)")
        }
        if case let .error(code, message) = reply {
            throw Failure(code, message.isEmpty ? code : message, AgentErrorCode.clientExitCode(for: code))
        }
        switch (request, reply) {
        case (.ping, .ping(let status)):
            print(ClientOutput.agent(status))
        case (.front, .front(let name)):
            print(ClientOutput.front(name))
        case (.notice, .notice(let result)):
            print(ClientOutput.notice(result))
        case (.requestPermission, .permission(let granted)):
            print(ClientOutput.permission(granted: granted))
        case (.capture, .capture(let count, let front)):
            guard case let .capture(_, _, display) = request else { fatalError("unreachable") }
            let lines = try receiveShots(count: count, stream: stream, store: try shotStore(paths: paths, uid: uid),
                                         removeOthers: display == .all)
            print(ClientOutput.front(front))
            for line in lines { print(line) }
        default:
            throw Failure.protocolError("odpowiedź nie pasuje do polecenia: \(reply.line.prefix(60))")
        }
    }

    /// Checks the socket of user `uid`, connects and checks who answered; returns the socket and the agent's pid.
    private static func connect(paths: AgentPaths, uid: uid_t, owners: Set<uid_t>, runDirOwners: Set<uid_t>,
                                expectedPID: pid_t?) throws -> (Int32, pid_t) {
        // run: root's, nobody else may write to it; run/<uid>: user <uid>'s own 0700 folder (root creates it), not a
        // link; the socket in it: a socket of user <uid>. (The client itself may own run too: as root that is the
        // same, and in the harness the developer created it.)
        do {
            try SocketLocation.checkForClient(paths: paths, uid: uid, owners: owners, runDirOwners: runDirOwners)
        } catch {
            switch error {
            case .missing(let m): throw Failure.unreachable(m)
            case .untrusted(let m): throw Failure.untrusted(m)
            }
        }
        let socketPath = paths.socketPath(uid: uid)
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath, timeout: AgentInfo.clientTimeout,
                                        attempts: AgentInfo.connectAttempts, retryDelay: AgentInfo.connectRetryDelay)
        } catch let e as IOFailure {
            throw Failure.unreachable("usługa nie odpowiada: \(e.message)")
        }
        do {
            return (fd, try checkPeer(fd, owners: owners, expected: paths.executablePath, expectedPID: expectedPID))
        } catch {
            close(fd)
            throw error
        }
    }

    /// Who answered: a process of user <uid>, the pid launchd reports for the agent (`--pid`), running normally
    /// (not stopped or traced), the installed executable, in serve mode.
    private static func checkPeer(_ fd: Int32, owners: Set<uid_t>, expected: String, expectedPID: pid_t?) throws -> pid_t {
        guard let peerUID = PeerIdentity.uid(of: fd), owners.contains(peerUID) else {
            throw Failure.untrusted("po drugiej stronie gniazda jest proces innego użytkownika")
        }
        // LOCAL_PEERPID names the process that created the listening socket – not necessarily the one answering:
        // that process could have handed the socket to another one and then become (exec) the installed agent, or
        // have ended so that the agent started later got its pid. launchd's pid of the agent rules out the first,
        // and a stopped or traced process is never the one answering (it is how the second would be kept quiet).
        guard let pid = PeerIdentity.pid(of: fd) else {
            throw Failure.untrusted("nie można ustalić procesu po drugiej stronie gniazda")
        }
        if let expectedPID, pid != expectedPID {
            throw Failure.untrusted("gniazdo utworzył proces \(pid), a launchd uruchomił usługę jako proces \(expectedPID)")
        }
        if let why = PeerIdentity.suspendedState(of: pid) {
            throw Failure.untrusted("usługa po drugiej stronie gniazda nie działa: \(why)")
        }
        guard let exe = PeerIdentity.executablePath(of: pid) else {
            throw Failure.untrusted("nie można ustalić procesu po drugiej stronie gniazda")
        }
        guard PeerIdentity.sameFile(exe, expected) else {
            throw Failure.untrusted("gniazdo obsługuje \(exe) (PID \(pid)), a nie zainstalowana usługa \(expected)")
        }
        // The installed agent started in a short-lived mode (e.g. `client`) would not keep the socket either.
        guard let args = PeerIdentity.arguments(of: pid), args.count == 2, args[1] == "serve" else {
            throw Failure.untrusted("proces \(pid) po drugiej stronie gniazda nie jest usługą w trybie serve")
        }
        return pid
    }

    /// Where the screenshots go: `shots/<uid>` (root:wheel 700). The logged-in user running the client for their
    /// own session cannot write there and uses a folder in their own temporary directory instead; the `SHOT` lines
    /// name the files either way.
    private static func shotStore(paths: AgentPaths, uid: uid_t) throws -> ShotStore {
        let primary = ShotStore(root: paths.shotsDir, uid: uid)
        do {
            try primary.prepare()
            return primary
        } catch let e as IOFailure {
            guard geteuid() != 0 else { throw Failure.write(e.message) }
            var tmp = NSTemporaryDirectory()
            while tmp.hasSuffix("/") { tmp.removeLast() }
            let own = ShotStore(root: "\(tmp)/cmcr-screen-agent", uid: uid)
            do {
                try own.prepare()
            } catch let e2 as IOFailure {
                throw Failure.write("\(e.message); \(e2.message)")
            }
            return own
        }
    }

    /// Reads `count` images and saves each over the previous one. After a capture of all displays the images of
    /// displays that are gone are removed; a capture of one display leaves the others alone (another preview of the
    /// same account may be showing them right now).
    private static func receiveShots(count: Int, stream: SocketStream, store: ShotStore,
                                     removeOthers: Bool) throws -> [String] {
        var lines: [String] = []
        var seen = Set<Int>()
        for _ in 0..<count {
            let header: ImageHeader
            let data: Data
            do {
                header = try ImageHeader.parse(stream.readLine())
                guard seen.insert(header.display).inserted else {
                    throw ProtocolError("ekran \(header.display) przesłany dwa razy")
                }
                data = try stream.readBytes(header.byteCount)
            } catch let e as ProtocolError {
                throw Failure.protocolError(e.message)
            } catch let e as IOFailure {
                if e.kind == .timeout { throw Failure.unreachable("usługa nie odpowiada: \(e.message)") }
                throw Failure.protocolError("niepełny zrzut ekranu: \(e.message)")
            }
            guard JPEGCodec.looksLikeJPEG(data) else {
                throw Failure.protocolError("dane ekranu \(header.display) nie są obrazem JPEG")
            }
            do {
                let path = try store.write(display: header.display, data: data)
                lines.append(ClientOutput.shot(header, path: path))
            } catch let e as IOFailure {
                throw Failure.write(e.message)
            }
        }
        do {
            try store.removeOthers(keeping: removeOthers ? seen : nil)
        } catch let e as IOFailure {
            throw Failure.write(e.message)
        }
        return lines
    }
}
