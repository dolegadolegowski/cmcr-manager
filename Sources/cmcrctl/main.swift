import Foundation

// Command line counterpart of cmcr-helpers.sh, sharing configuration with the CMCR Manager app.

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IONBF, 0)

exit(await CLI(args: Arguments(Array(CommandLine.arguments.dropFirst()))).run())
