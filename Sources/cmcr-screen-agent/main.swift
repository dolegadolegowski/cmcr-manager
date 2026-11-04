import Foundation
import ScreenAgentKit

// CMCR Screen Agent (docs/screen-agent.md).
//
//   cmcr-screen-agent serve          – the LaunchAgent in the logged-in user's session: takes a screenshot only when
//                                      asked over its unix socket
//   cmcr-screen-agent client <uid> … – run by the preview script (root) over SSH: asks the agent of user <uid>,
//                                      checks it is the installed agent and saves the screenshots
//   cmcr-screen-agent --version      – the agent's version (ScreenAgentInfo.version)
//
// DEBUG builds only (the e2e harness and ScreenAgentKitTests; none of this exists in `-c release`):
//   CMCR_SETUP_ROOT_PREFIX=<dir>       every system path (install dir, run, shots) lives under <dir>, in serve and
//                                      client mode
//   CMCR_SCREEN_AGENT_TEST_DIR=<dir>   serve runs headless with files in <dir> instead of AppKit, ScreenCaptureKit
//                                      and TCC (TestBackend.swift lists them); in client mode it accepts an agent
//                                      running as this user even for another <uid> (the harness has no root)
//   CMCR_SCREEN_AGENT_TEST_UID=<n>     serve binds <n>.sock instead of the socket of its own uid
//   --test-seams                       prints "debug" (a release build answers with a usage error)

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    FileHandle.standardError.write(Data("""
    Użycie:
      cmcr-screen-agent serve
      cmcr-screen-agent client <uid> ping
      cmcr-screen-agent client <uid> capture <maxpx> <jakość 10-100> <main|all|1-9>
      cmcr-screen-agent client <uid> notice <b64 tytuł> <b64 tekst>
      cmcr-screen-agent client <uid> front
      cmcr-screen-agent client <uid> request-permission
      cmcr-screen-agent --version

    """.utf8))
}

switch arguments.first {
case "--version":
    print(AgentInfo.version)
    exit(0)
case "serve":
    guard arguments.count == 1 else { printUsage(); exit(AgentInfo.ClientCode.usage) }
    Serve.run()
case "client":
    exit(Client.run(Array(arguments.dropFirst())))
#if DEBUG
case "--test-seams":
    print("debug")
    exit(0)
#endif
case "-h", "--help":
    printUsage()
    exit(0)
default:
    printUsage()
    exit(AgentInfo.ClientCode.usage)
}
