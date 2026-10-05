import CMCRCore
import Foundation

// Shared helpers of the module commands (install, browse, classroom, setup, screen-watch). They parse their own
// arguments with `ModuleArguments`, under the same rules as the core commands: unknown options and surplus
// arguments are usage errors, a missing host list selects every Mac only at a terminal, disruptive commands
// ask for confirmation (`--yes` without a terminal), and the exit code is 0, 1 or 2.

/// `--root`/`--force` of `_builder`, the e2e test hook, which reads them from the raw command line.
let rawArguments = Array(CommandLine.arguments.dropFirst())
var root: Bool { rawArguments.contains("--root") }
var force: Bool { rawArguments.contains("--force") }

let legacyCLI = CLI(args: Arguments([]))
var sshSettings: SSHSettings { legacyCLI.sshSettings() }
var settings: AppSettings { legacyCLI.settings }

/// Host selection of the module commands.
enum ModuleHosts {
    /// Commands that only read (filevault, app-version, schedule show, readiness): no list = every Mac, like status.
    static func readOnly(_ spec: String?) -> [Machine] { legacyCLI.targets(spec, defaultAll: true) }

    /// Commands that change something: no list = every Mac only at a terminal, announced there. In a script a
    /// dropped argument (an unquoted `#3` is a comment) must not widen the command to the whole lab.
    static func changing(_ spec: String?, _ command: String) -> [Machine] {
        legacyCLI.targetsOrAllAtTerminal(spec, command: command)
    }

    /// The list is required, also at a terminal.
    static func required(_ spec: String?, _ command: String, why: String = "") -> [Machine] {
        guard let spec else {
            moduleUsageError(command, "Podaj komputery dla polecenia \(command): all, numer (4), lista (1,3), zakres (1-5) "
                             + "lub pozycja (@2)\(why.isEmpty ? "." : " – \(why).")")
        }
        return legacyCLI.targets(spec)
    }

    /// Exactly one Mac.
    static func one(_ spec: String?, _ command: String, usage text: String) -> Machine {
        guard spec != nil else { moduleUsageError(command, text) }
        return legacyCLI.single(spec, usage: text)
    }

    static func names(_ list: [Machine]) -> String { legacyCLI.names(list) }
}

/// Prints why `r` failed. 0 or 1: the documented exit codes – raw remote or ssh codes (255, 65, a script's
/// `exit 2` that would look like a usage error) and local failures (-1, which `max` would swallow) are not
/// passed through.
func report(_ r: CommandResult) -> Int32 {
    if !r.succeeded { Console.err("✘ \(SSH.diagnose(r).1)") }
    return r.succeeded ? ExitCode.success : ExitCode.failure
}

/// Runs `body` for every host – at most `-j N` at a time, output in list order, `--prefix` honoured – under a
/// `name:` header. 0 when it succeeded everywhere, else 1.
func eachHost(_ list: [Machine], _ a: ModuleArguments, header: Bool = true,
              _ body: @escaping @Sendable (HostIO) async -> Int32) async -> Int32 {
    let codes = await runHosts(list, jobs: a.jobs ?? 1, prefixLines: a.prefix) { io in
        if header { io.out("\(io.host.name):") }
        return await body(io)
    }
    return codes.allSatisfy { $0 == ExitCode.success } ? ExitCode.success : ExitCode.failure
}

/// One remote script per host (see `eachHost`).
func runEach(_ list: [Machine], _ a: ModuleArguments, ssh: SSHSettings, timeout: TimeInterval? = nil,
             _ script: @escaping @Sendable (Machine) -> RemoteScript) async -> Int32 {
    await eachHost(list, a) { io in
        let r = await SSH.run(script(io.host), on: io.host, password: Keychain.password(for: io.host), settings: ssh,
                              timeout: timeout, onOutput: io.stream)
        return io.report(r)
    }
}

/// Commands contributed by feature modules, dispatched before the main argument parser.
enum ExtraCommands {
    static var usage: String {
        [ScriptCommands.usage, SetupCommands.usage, BrowseCLI.usage, ClassroomCLI.usage, screenWatchUsage, SelfUpdateCommand.usage].joined(separator: "\n")
    }

    /// Commands parsed with `ModuleArguments` (setup, setup-script and readiness have their own parser and help).
    static let moduleCommands: Set<String> = Set(ScriptCommands.specs.keys).union(BrowseCLI.specs.keys)
        .union(ClassroomCLI.specs.keys).union(["screen-watch", "rename"])

    /// Exit status, or nil when the command is not handled here. `argv` starts with the command word.
    @MainActor
    static func run(_ argv: [String]) async -> Int32? {
        guard let command = argv.first else { return nil }
        let args = Array(argv.dropFirst())
        if command == "_builder" {
            return await ScriptCommands.builder(args.filter { $0 != "--root" && $0 != "--force" })
        }
        if SetupCommands.names.contains(command) {
            // Always root; `--root`/`--force` were accepted (and ignored) before the setup options existed.
            return await SetupCommands.run(command, args.filter { $0 != "--root" && $0 != "--force" },
                                           settings: settings, ssh: sshSettings)
        }
        guard moduleCommands.contains(command) else { return nil }
        // `ls` exists twice: `ls ŚCIEŻKA KOMP` (ls -la on several Macs) and `ls nr ścieżka` (structured
        // listing of one Mac). A path-looking first argument selects the former, handled by the main parser.
        if command == "ls", let first = args.first(where: { !$0.hasPrefix("-") }), looksLikeRemotePath(first) {
            return nil
        }
        // Answered before anything else: without a host list most of these commands would otherwise run on
        // every Mac (`lock --help` used to lock the whole lab).
        if ModuleArguments.wantsHelp(args) {
            Console.out(commandHelp(command, spec: ScriptCommands.specs[command] ?? BrowseCLI.specs[command]
                                    ?? ClassroomCLI.specs[command] ?? (command == "screen-watch" ? screenWatchSpec : nil)))
            return ExitCode.success
        }
        let ssh = sshSettings
        switch command {
        case "install", "install-url": return await ScriptCommands.run(command, args)
        case "screen-watch": return await screenWatchCommand(args)
        case "rename": return await rename(args, ssh: ssh)
        default:
            if BrowseCLI.specs[command] != nil {
                return await BrowseCLI.run(command, args, BrowseCLI.Context(settings: settings, ssh: ssh))
            }
            return await ClassroomCLI.run(command, args, settings: settings, ssh: ssh)
        }
    }

    static let renameUsage = """
    Użycie:
      cmcrctl rename nr ścieżka nowa-nazwa [--root]              zmiana nazwy pliku lub folderu
      cmcrctl rename KOMP [--name "Nazwa"] [--dry-run] [--update-list]
                                                                zmiana nazwy komputerów (także: rename-computer)
    """

    /// `rename nr ścieżka nowa-nazwa` renames a file, `rename KOMP [--name …]` computers. The form is chosen by
    /// the number of arguments, never guessed from their content: anything else is a usage error, so a file
    /// rename with a forgotten or relative argument can never turn into a root rename of the computers.
    static func rename(_ args: [String], ssh: SSHSettings) async -> Int32 {
        let any = ModuleArguments.parse("rename", args, ModuleSpec(flags: ["--dry-run", "--update-list", "--root"],
                                                                   values: ["--name"]))
        switch any.positional.count {
        case 3:
            let path = any.positional[1]
            guard looksLikeRemotePath(path) else {
                moduleUsageError("rename", "Ścieżka musi zaczynać się od /, ~ lub {student} (podano: \(path)).\n" + renameUsage)
            }
            if let option = ["--name", "--dry-run", "--update-list"].first(where: { any.values[$0] != nil || any.has($0) }) {
                moduleUsageError("rename", "Opcja \(option) dotyczy zmiany nazwy komputera, nie pliku.\n" + renameUsage)
            }
            return await BrowseCLI.run("rename", args, BrowseCLI.Context(settings: settings, ssh: ssh))
        case 0, 1:
            if let only = any.positional.first, looksLikeRemotePath(only) {
                moduleUsageError("rename", "Podaj komputer, ścieżkę i nową nazwę pliku.\n" + renameUsage)
            }
            if any.root { moduleUsageError("rename", "Opcja --root dotyczy zmiany nazwy pliku.\n" + renameUsage) }
            return await ClassroomCLI.run("rename", args, settings: settings, ssh: ssh)
        default:
            moduleUsageError("rename", "Polecenie rename przyjmuje 3 argumenty (plik) albo 1 (komputery), "
                             + "podano \(any.positional.count).\n" + renameUsage)
        }
    }
}

var fullUsage: String { usage + "\nInstalacja i inne\n" + ExtraCommands.usage }

let screenWatchUsage = """
  cmcrctl screen-watch nr katalog [--frames N] [--interval S] [--size PX] [--display main|all|N]
                                            podgląd ekranu na żywo: kolejne klatki JPEG w katalogu
                                            (kody wyjścia: 3 – nikt nie jest zalogowany, 4 – podgląd
                                            niedozwolony, 5 – brak uprawnienia nagrywania ekranu, 6 – sudo)
"""

func looksLikeRemotePath(_ s: String) -> Bool {
    s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("{")
}
