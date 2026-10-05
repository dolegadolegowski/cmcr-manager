import CMCRCore
import Foundation

// Command line counterpart of cmcr-helpers.sh, sharing configuration with the CMCR Manager app.

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IONBF, 0)

let argv = Array(CommandLine.arguments.dropFirst())

// Hidden test commands (Tests/e2e/suites/core-runtime.sh) parse their own options.
if let first = argv.first, first.hasPrefix("__") {
    let cli = CLI(args: Arguments([]))
    let rest = Array(argv.dropFirst()).filter { $0 != "--root" }
    exit(await HiddenCommands.run(first, rest, select: { cli.targets($0) }, root: argv.contains("--root"),
                                  settings: cli.sshSettings()))
}

if let code = await ExtraCommands.run(argv) { exit(code) }

let cli = CLI(args: Arguments(argv))
for issue in ConfigStore.loadIssues { FileHandle.standardError.write(Data("⚠ \(issue)\n".utf8)) }
exit(await cli.run())
