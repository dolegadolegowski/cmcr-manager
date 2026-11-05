import Darwin
import Foundation

/// The folder the client saves screenshots in: `shots/<uid>/screen-<n>.jpg` (docs/screen-agent.md › Ścieżki).
/// Each file is written to a temporary file in the same folder and renamed over the previous one, so a reader
/// (the preview script's `md5`/`cat`) always sees a whole image; images of displays that were not part of the last
/// capture of all displays are removed.
public struct ShotStore: Sendable {
    /// `shots` (created 0700 when missing).
    public let root: String
    /// `shots/<uid>`.
    public let directory: String

    public init(root: String, uid: uid_t) {
        self.root = root
        self.directory = "\(root)/\(uid)"
    }

    public static func fileName(display: Int) -> String { "screen-\(display).jpg" }

    public func path(display: Int) -> String { "\(directory)/\(Self.fileName(display: display))" }

    /// Creates `root` and `directory` as 0700. An existing one must be a real directory (not a symlink) owned by
    /// this process's effective user; a wider mode is narrowed.
    public func prepare() throws {
        try Self.ensurePrivateDirectory(root)
        try Self.ensurePrivateDirectory(directory)
    }

    static func ensurePrivateDirectory(_ path: String) throws {
        var st = stat()
        if lstat(path, &st) != 0 {
            guard errno == ENOENT else { throw IOFailure.system("katalog \(path)") }
            if mkdir(path, 0o700) != 0 && errno != EEXIST { throw IOFailure.system("tworzenie katalogu \(path)") }
            guard lstat(path, &st) == 0 else { throw IOFailure.system("katalog \(path)") }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw IOFailure(.system, "\(path) nie jest katalogiem (np. dowiązanie symboliczne) – zrzut nie został zapisany")
        }
        guard st.st_uid == geteuid() else {
            throw IOFailure(.system, "katalog \(path) należy do innego użytkownika (uid \(st.st_uid))")
        }
        if st.st_mode & 0o077 != 0 && chmod(path, 0o700) != 0 { throw IOFailure.system("chmod \(path)") }
    }

    /// Writes one display's image atomically (mode 0600) and returns its path.
    @discardableResult
    public func write(display: Int, data: Data) throws -> String {
        let final = path(display: display)
        var template = Array("\(directory)/.screen-\(display).XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw IOFailure.system("plik tymczasowy w \(directory)") }
        let temp = String(cString: template)
        var ok = false
        defer {
            if !ok { unlink(temp) }
        }
        do {
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0 else { throw IOFailure.system("chmod \(temp)") }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw IOFailure.system("zapis \(temp)")
                    }
                    offset += n
                }
            }
        }
        guard rename(temp, final) == 0 else { throw IOFailure.system("zapis \(final)") }
        ok = true
        return final
    }

    /// Removes `screen-<n>.jpg` of every display not in `keep` (nothing of the kind when `keep` is nil: only a
    /// capture of all displays knows which are gone), and temporary files a killed client left behind (only old ones:
    /// a second client may be writing its own right now).
    public func removeOthers(keeping keep: Set<Int>?) throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            throw IOFailure.system("odczyt katalogu \(directory)")
        }
        let now = time(nil)
        for name in names {
            if name.hasPrefix(".screen-") {
                var st = stat()
                if lstat("\(directory)/\(name)", &st) == 0 && now - st.st_mtimespec.tv_sec > 60 {
                    unlink("\(directory)/\(name)")
                }
                continue
            }
            guard let keep, name.hasPrefix("screen-"), name.hasSuffix(".jpg") else { continue }
            let middle = name.dropFirst("screen-".count).dropLast(".jpg".count)
            guard let n = strictInt(String(middle)), !keep.contains(n) else { continue }
            if unlink("\(directory)/\(name)") != 0 && errno != ENOENT {
                throw IOFailure.system("usuwanie \(directory)/\(name)")
            }
        }
    }
}
