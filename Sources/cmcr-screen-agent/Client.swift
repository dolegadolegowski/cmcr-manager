import Darwin
import Foundation
import ScreenAgentKit

/// `cmcr-screen-agent client <uid> <command> …` (docs/screen-agent.md › Klient). Run by the preview script as root
/// (or by the logged-in user). Before anything is sent it makes sure the socket belongs to user <uid> and that the
/// process behind it is the installed agent: a student cannot put a program of their own there to show the teacher
/// a fake screen. Prints result lines on stdout; every failure is one `ERR <code> <text>` line and an exit code.
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

    static func run(_ args: [String]) -> Int32 {
        do {
            let (uid, request) = try parse(args)
            try execute(uid: uid, request: request)
            return Code.ok
        } catch let f as Failure {
            print(ClientOutput.error(f.code, f.message))
            return f.exitCode
        } catch {
            print(ClientOutput.error("error", "\(error)"))
            return Code.other
        }
    }

    static func parse(_ args: [String]) throws -> (uid_t, AgentRequest) {
        guard args.count >= 2, let n = strictInt(args[0]), n <= Int(Int32.max) else {
            throw Failure.usage("użycie: cmcr-screen-agent client <uid> ping|capture|notice|front|request-permission …")
        }
        let uid = uid_t(n)
        let rest = Array(args.dropFirst(2))
        func count(_ k: Int) throws {
            guard rest.count == k else { throw Failure.usage("nieprawidłowa liczba argumentów polecenia \(args[1])") }
        }
        switch args[1] {
        case "ping":
            try count(0)
            return (uid, .ping)
        case "front":
            try count(0)
            return (uid, .front)
        case "request-permission":
            try count(0)
            return (uid, .requestPermission)
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
            return (uid, .capture(maxSide: maxSide, quality: quality, display: display))
        case "notice":
            try count(2)
            guard let title = Base64Field.decode(rest[0]), let text = Base64Field.decode(rest[1]) else {
                throw Failure.usage("tytuł i tekst komunikatu muszą być w base64 (UTF-8)")
            }
            return (uid, .notice(title: title, text: text))
        default:
            throw Failure.usage("nieznane polecenie: \(args[1])")
        }
    }

    // MARK: - Exchange

    private static func execute(uid: uid_t, request: AgentRequest) throws {
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

        let fd = try connect(paths: paths, uid: uid, owners: owners, runDirOwners: [0, me])
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
            throw Failure.unreachable(e.kind == .closed ? "usługa zamknęła połączenie bez odpowiedzi" : "usługa nie odpowiada: \(e.message)")
        } catch let e as ProtocolError {
            throw Failure.protocolError(e.message)
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
            let lines = try receiveShots(count: count, stream: stream, store: try shotStore(paths: paths, uid: uid))
            print(ClientOutput.front(front))
            for line in lines { print(line) }
        default:
            throw Failure.protocolError("odpowiedź nie pasuje do polecenia: \(reply.line.prefix(60))")
        }
    }

    /// Checks the socket of user `uid`, connects and checks who answered.
    private static func connect(paths: AgentPaths, uid: uid_t, owners: Set<uid_t>, runDirOwners: Set<uid_t>) throws -> Int32 {
        var st = stat()
        // The run folder is root's (1733): a real folder, not a link to somewhere a student controls. (The client
        // itself may own it too: as root that is the same, and in the harness the developer created it.)
        guard lstat(paths.runDir, &st) == 0 else {
            throw Failure.unreachable("brak katalogu \(paths.runDir) – usługa nie jest zainstalowana")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, runDirOwners.contains(st.st_uid) else {
            throw Failure.untrusted("\(paths.runDir) nie jest katalogiem roota")
        }
        let socketPath = paths.socketPath(uid: uid)
        guard lstat(socketPath, &st) == 0 else {
            throw Failure.unreachable("brak gniazda usługi \(socketPath) – usługa nie działa w sesji użytkownika")
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw Failure.untrusted("\(socketPath) nie jest gniazdem")
        }
        guard owners.contains(st.st_uid) else {
            throw Failure.untrusted("gniazdo \(socketPath) należy do uid \(st.st_uid), a nie \(uid)")
        }
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath, timeout: AgentInfo.clientTimeout)
        } catch let e as IOFailure {
            throw Failure.unreachable("usługa nie odpowiada: \(e.message)")
        }
        guard let peerUID = PeerIdentity.uid(of: fd), owners.contains(peerUID) else {
            close(fd)
            throw Failure.untrusted("po drugiej stronie gniazda jest proces innego użytkownika")
        }
        let expected = paths.executablePath
        guard let pid = PeerIdentity.pid(of: fd), let exe = PeerIdentity.executablePath(of: pid) else {
            close(fd)
            throw Failure.untrusted("nie można ustalić procesu po drugiej stronie gniazda")
        }
        guard PeerIdentity.sameFile(exe, expected) else {
            close(fd)
            throw Failure.untrusted("gniazdo obsługuje \(exe) (PID \(pid)), a nie zainstalowana usługa \(expected)")
        }
        // LOCAL_PEERPID names the process that created the listening socket. Some other program could create it,
        // pass it to a child and then exec the installed agent in a short-lived mode (e.g. `client`) to borrow its
        // path; the agent in `serve` mode would have replaced that socket with its own.
        guard let args = PeerIdentity.arguments(of: pid), args.count == 2, args[1] == "serve" else {
            close(fd)
            throw Failure.untrusted("proces \(pid) po drugiej stronie gniazda nie jest usługą w trybie serve")
        }
        return fd
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

    /// Reads `count` images, saves each over the previous one and removes images of displays not in this capture.
    private static func receiveShots(count: Int, stream: SocketStream, store: ShotStore) throws -> [String] {
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
            try store.removeOthers(keeping: seen)
        } catch let e as IOFailure {
            throw Failure.write(e.message)
        }
        return lines
    }
}
