import CMCRCore
import Foundation

// Helpers for command modules written against the original single-file cmcrctl (install, setup, browse, …).
// They parse their own arguments; `--root` and `--force` are read from the raw command line.

let rawArguments = Array(CommandLine.arguments.dropFirst())
var root: Bool { rawArguments.contains("--root") }
var force: Bool { rawArguments.contains("--force") }

let legacyCLI = CLI(args: Arguments([]))
var sshSettings: SSHSettings { legacyCLI.sshSettings() }
var settings: AppSettings { legacyCLI.settings }
var hosts: [Machine] { legacyCLI.hosts }

/// No spec means every Mac, as in cmcr-exec.
func selectHosts(_ spec: String?) -> [Machine] { legacyCLI.targets(spec, defaultAll: true) }

func report(_ r: CommandResult) -> Int32 {
    if !r.succeeded { Console.err("✘ \(SSH.diagnose(r).1)") }
    return r.succeeded ? 0 : (r.exitCode == 0 ? 1 : r.exitCode)
}

extension Console {
    static let printer: Operations.Output = { channel, data in Console.write(channel, data) }
}

/// Commands contributed by feature modules, dispatched before the main argument parser.
enum ExtraCommands {
    static var usage: String {
        [ScriptCommands.usage, SetupCommands.usage, screenWatchUsage, SelfUpdateCommand.usage].joined(separator: "\n")
    }

    /// Exit status, or nil when the command is not handled here. `argv` starts with the command word.
    @MainActor
    static func run(_ argv: [String]) async -> Int32? {
        guard let command = argv.first else { return nil }
        let args = argv.filter { $0 != "--root" && $0 != "--force" }
        if let code = await ScriptCommands.run(command, args) { return code }
        if command == "screen-watch" { return await screenWatchCommand(Array(args.dropFirst())) }
        if SetupCommands.names.contains(command) {
            return await SetupCommands.run(command, Array(args.dropFirst()), select: selectHosts,
                                           settings: settings, ssh: sshSettings)
        }
        return nil
    }
}

var fullUsage: String { usage + "\nInstalacja i inne\n" + ExtraCommands.usage }

let screenWatchUsage = """
  cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--display main|all|N]
                                            podgląd ekranu na żywo: kolejne klatki JPEG w katalogu
"""
