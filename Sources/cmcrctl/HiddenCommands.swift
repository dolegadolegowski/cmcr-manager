import CMCRCore
import Foundation

/// Commands for the end-to-end tests (Tests/e2e/suites/core-runtime.sh); not listed in the help text.
///
///   cmcrctl __run-job "polecenie" nr [--root] [--cancel-after S] [--timeout S]
///       runs the command as a cancellable remote job, like the app does; prints `CMCR:JOB:<id>` first
///       and `CMCR:RESULT …` last
///   cmcrctl __forget-host-key nr
enum HiddenCommands {
    static func run(_ command: String, _ args: [String], select: (String?) -> [Machine], root: Bool,
                    settings: SSHSettings) async -> Int32 {
        switch command {
        case "__run-job":
            guard args.count >= 2, let host = select(args[1]).first else {
                FileHandle.standardError.write(Data("Użycie: cmcrctl __run-job \"polecenie\" nr [--cancel-after S] [--timeout S]\n".utf8))
                return 2
            }
            let id = RemoteJobs.newID()
            print("CMCR:JOB:\(id)")
            let handle = ProcessHandle()
            if let delay = value(after: "--cancel-after", in: args) {
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    handle.cancel()
                }
            }
            let r = await SSH.run(RemoteScript(args[0], asRoot: root, jobID: id), on: host,
                                  password: Keychain.password(for: host), settings: settings,
                                  timeout: value(after: "--timeout", in: args), handle: handle,
                                  onOutput: { channel, data in
                                      (channel == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(data)
                                  })
            await handle.cancellationFinished()
            print("CMCR:RESULT exit=\(r.exitCode) cancelled=\(r.cancelled) timedOut=\(r.timedOut)")
            return r.succeeded ? 0 : (r.exitCode == 0 ? 1 : r.exitCode)

        case "__forget-host-key":
            guard let spec = args.first, let host = select(spec).first else { return 2 }
            let r = await SSHKeys.forgetHostKey(host, settings: settings)
            FileHandle.standardOutput.write(r.stdout)
            FileHandle.standardError.write(r.stderr)
            return r.exitCode

        default:
            return 2
        }
    }

    private static func value(after flag: String, in args: [String]) -> TimeInterval? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return TimeInterval(args[i + 1])
    }
}
