import Foundation

/// Screen Sharing (VNC) through an ssh tunnel. A `.local` name is not authenticated: any device on the network can
/// answer to it, and Screen Sharing would send the administrator's name and password to it. The tunnel goes
/// through ssh with the same strict host key check as every other connection (a Mac with an unknown or changed key
/// is refused before logging in), and Screen Sharing connects to its local end on 127.0.0.1.
public extension SSH {
    /// Remote port of Screen Sharing on the Mac.
    static let screenSharingPort = 5900

    /// Opens `ssh -L 127.0.0.1:<free port>:127.0.0.1:5900` and returns the local port once it accepts connections.
    /// The ssh process runs `sleep <linger>` on the Mac: it ends by itself after that time, as soon as Screen
    /// Sharing has closed its connections (ssh waits for forwarded connections), so nothing has to clean it up.
    static func screenSharingTunnel(to host: Machine, password: String?, settings: SSHSettings,
                                    linger: Int = 60) async -> Result<Int, CommandResult> {
        if let refused = refusal(for: host) { return .failure(refused) }
        guard let port = freeLocalPort() else { return .failure(.failure("Brak wolnego portu na tym Macu.")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = options(settings, password: password, mux: false)
            + ["-o", "ExitOnForwardFailure=yes", "-n",
               "-L", "127.0.0.1:\(port):127.0.0.1:\(screenSharingPort)",
               "-T", "-p", String(host.port), "--", host.destination, "sleep \(max(5, linger))"]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment(settings, password: password) { env[k] = v }
        process.environment = env
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        TunnelProcesses.shared.keep(process)
        do {
            try process.run()
        } catch {
            TunnelProcesses.shared.release(process)
            return .failure(.failure("Nie można uruchomić ssh: \(error.localizedDescription)"))
        }
        let deadline = Date().addingTimeInterval(TimeInterval(settings.connectTimeout + 15))
        while Date() < deadline {
            if !process.isRunning {
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                return .failure(CommandResult(exitCode: process.terminationStatus, stderr: SSHNoise.filter(stderr)))
            }
            if localPortAcceptsConnections(port) { return .success(port) }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        process.terminate()
        return .failure(CommandResult(exitCode: -1, stderr: Data("Przekroczono limit czasu.\n".utf8), timedOut: true))
    }

    /// `vnc://<account>@127.0.0.1:<port>`: the account is percent-encoded, so `#`, `/`, `?` or `@` in it can never
    /// point Screen Sharing at another host.
    static func screenSharingURL(user: String, localPort: Int) -> URL? {
        var c = URLComponents()
        c.scheme = "vnc"
        c.user = user
        c.host = "127.0.0.1"
        c.port = localPort
        return c.url
    }

    /// A port nobody listens on right now (the kernel's choice for port 0).
    internal static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return named == 0 ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    internal static func localPortAcceptsConnections(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = loopback(port: port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }
}

/// Tunnel processes stay referenced until they end (Process must not be released while it runs).
final class TunnelProcesses: @unchecked Sendable {
    static let shared = TunnelProcesses()
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    func keep(_ p: Process) {
        lock.lock()
        running[ObjectIdentifier(p)] = p
        lock.unlock()
        p.terminationHandler = { [weak self] ended in self?.release(ended) }
    }

    func release(_ p: Process) {
        lock.lock()
        running[ObjectIdentifier(p)] = nil
        lock.unlock()
    }
}

/// A failed command as the error of a `Result` (e.g. `SSH.screenSharingTunnel`).
extension CommandResult: Error {}
