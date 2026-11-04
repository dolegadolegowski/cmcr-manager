import Darwin
import Foundation

/// A failed socket or file operation, with a Polish description for `ERR … <opis>`.
public struct IOFailure: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: Equatable, Sendable { case timeout, closed, tooLong, system }
    public var kind: Kind
    public var message: String
    public var errno: Int32

    public init(_ kind: Kind, _ message: String, errno: Int32 = 0) {
        self.kind = kind
        self.message = message
        self.errno = errno
    }

    /// `what: <strerror>` for the current errno.
    public static func system(_ what: String, _ code: Int32 = Darwin.errno) -> IOFailure {
        IOFailure(.system, "\(what): \(String(cString: strerror(code)))", errno: code)
    }

    public var description: String { message }
}

public enum UnixSocket {
    /// Longest socket path `sockaddr_un` holds (with its terminating NUL).
    public static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// The address of `path`; fails when the path does not fit (bind/connect would silently cut it).
    public static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathLength else {
            throw IOFailure(.tooLong, "ścieżka gniazda jest za długa (\(bytes.count) bajtów, najwyżej \(maxPathLength)): \(path)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    /// A new stream socket that never raises SIGPIPE.
    public static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IOFailure.system("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    public static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    /// Connects to `path`, waiting at most `timeout` (a full listen queue makes connect wait).
    public static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = try address(path)
        let fd = try makeSocket()
        setNonBlocking(fd, true)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 {
            let code = errno
            guard code == EINPROGRESS || code == EAGAIN || code == EINTR else {
                close(fd)
                throw IOFailure.system("połączenie z \(path)", code)
            }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(max(1, timeout * 1000)))
            if n == 0 {
                close(fd)
                throw IOFailure(.timeout, "brak połączenia z \(path) w ciągu \(Int(timeout)) s")
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            if n < 0 || soError != 0 {
                close(fd)
                throw IOFailure.system("połączenie z \(path)", soError != 0 ? soError : errno)
            }
        }
        setNonBlocking(fd, false)
        return fd
    }
}

/// Reading and writing one socket with an inactivity timeout and an overall deadline, so a silent or trickling
/// peer cannot hold either side forever.
public final class SocketStream {
    public let fd: Int32
    public var inactivity: TimeInterval
    public var deadline: Date
    private var buffer = [UInt8]()
    private var start = 0

    public init(fd: Int32, inactivity: TimeInterval, total: TimeInterval) {
        self.fd = fd
        self.inactivity = inactivity
        self.deadline = Date().addingTimeInterval(total)
    }

    private func wait(for events: Int16) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw IOFailure(.timeout, "przekroczony limit czasu połączenia") }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&p, 1, Int32(max(1, min(inactivity, remaining) * 1000)))
            if n > 0 { return }
            if n == 0 {
                if remaining <= inactivity { throw IOFailure(.timeout, "przekroczony limit czasu połączenia") }
                throw IOFailure(.timeout, "brak odpowiedzi w ciągu \(Int(inactivity)) s")
            }
            if errno != EINTR { throw IOFailure.system("poll") }
        }
    }

    private func fill() throws {
        if start > 0 && start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        try wait(for: Int16(POLLIN))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            throw IOFailure.system("odczyt z gniazda")
        }
        if n == 0 { throw IOFailure(.closed, "połączenie zostało zamknięte") }
        buffer.append(contentsOf: chunk[0..<n])
    }

    /// One line without its line feed (a trailing CR is dropped too).
    public func readLine(maxLength: Int = 8192) throws -> String {
        while true {
            if let nl = buffer[start...].firstIndex(of: 0x0A) {
                var bytes = Array(buffer[start..<nl])
                start = nl + 1
                if bytes.last == 0x0D { bytes.removeLast() }
                guard let s = String(bytes: bytes, encoding: .utf8) else { throw IOFailure(.system, "wiersz nie jest w UTF-8") }
                return s
            }
            if buffer.count - start > maxLength { throw IOFailure(.tooLong, "za długi wiersz") }
            try fill()
        }
    }

    /// Exactly `count` bytes.
    public func readBytes(_ count: Int) throws -> Data {
        var out = Data(capacity: count)
        while out.count < count {
            if start == buffer.count { try fill(); continue }
            let take = min(count - out.count, buffer.count - start)
            out.append(contentsOf: buffer[start..<(start + take)])
            start += take
        }
        return out
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                try wait(for: Int16(POLLOUT))
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw IOFailure.system("zapis do gniazda")
                }
                offset += n
            }
        }
    }

    public func writeLine(_ line: String) throws {
        try write(Data((line + "\n").utf8))
    }
}

/// Who is on the other end of a connected unix socket.
public enum PeerIdentity {
    /// Effective uid of the peer (`LOCAL_PEERCRED`).
    public static func uid(of fd: Int32) -> uid_t? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) == 0, cred.cr_version == XUCRED_VERSION else {
            return nil
        }
        return cred.cr_uid
    }

    /// The process that created the peer's socket (`LOCAL_PEERPID`).
    public static func pid(of fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Path of the executable `pid` runs.
    public static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// The arguments `pid` was started with (argv, `kern.procargs2`); readable for root and for the same user.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // Layout: argc (int32), the exec path, NUL padding, then argc NUL-terminated arguments.
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        guard argc > 0, argc < 4096 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args.count == argc ? args : nil
    }

    /// Whether two paths name the same file: the same resolved path, or the same file system object (firmlinks such
    /// as /Library ↔ /System/Volumes/Data/Library resolve to different strings).
    public static func sameFile(_ a: String, _ b: String) -> Bool {
        if let ra = realPath(a), let rb = realPath(b), ra == rb { return true }
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    public static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
