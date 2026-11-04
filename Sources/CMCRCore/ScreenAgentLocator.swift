import Foundation

/// Finds the copy of CMCR Screen Agent.app that ships with this app, to upload it to the iMacs.
public enum ScreenAgentLocator {
    /// The variable that points the app and cmcrctl at another agent bundle (the e2e harness's ad-hoc build).
    public static let environmentKey = "CMCR_SCREEN_AGENT_APP"
    static let applicationsApp = URL(fileURLWithPath: "/Applications/CMCR Manager.app")

    /// The bundled agent, or `nil` when this build has none (e.g. `swift run` without the bundle step).
    /// Lookup order: `CMCR_SCREEN_AGENT_APP` (test harness / DEBUG only), `Contents/Helpers` of the running app,
    /// `Contents/Helpers` of the app around `cmcrctl` (`Contents/Resources/bin`), next to the executable, and
    /// finally `/Applications/CMCR Manager.app`.
    public static func bundledAgent(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    mainBundle: Bundle = .main) -> URL? {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return bundledAgent(environment: environment, bundleURL: mainBundle.bundleURL,
                            executableURL: mainBundle.executableURL, applicationsApp: applicationsApp,
                            debugBuild: debugBuild)
    }

    /// `bundledAgent` with every input injectable (unit tests).
    static func bundledAgent(environment: [String: String], bundleURL: URL, executableURL: URL?, applicationsApp: URL,
                             debugBuild: Bool) -> URL? {
        // An explicit override is final: falling back to the installed app would quietly upload another agent than
        // the one the harness built.
        if debugBuild || inTestHarness(environment), let path = environment[environmentKey], !path.isEmpty {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return isAgentBundle(url) ? url : nil
        }
        var candidates: [URL] = []
        if bundleURL.pathExtension == "app" { candidates.append(helper(in: bundleURL)) }
        if let exe = executableURL {
            // cmcrctl inside the app: …/CMCR Manager.app/Contents/Resources/bin/cmcrctl (often reached via a symlink
            // such as /usr/local/bin/cmcrctl).
            var app = exe.resolvingSymlinksInPath()
            for _ in 0..<4 { app.deleteLastPathComponent() }
            if app.pathExtension == "app" { candidates.append(helper(in: app)) }
            // A build folder: build/cmcrctl next to build/CMCR Screen Agent.app.
            candidates.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent(ScreenAgentInfo.appName, isDirectory: true))
        }
        candidates.append(helper(in: applicationsApp))
        return candidates.first(where: isAgentBundle)
    }

    static func helper(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(ScreenAgentInfo.appName, isDirectory: true)
    }

    /// A folder holding `Contents/MacOS/cmcr-screen-agent`.
    static func isAgentBundle(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let exe = url.appendingPathComponent("Contents/MacOS/\(ScreenAgentInfo.executableName)")
        guard FileManager.default.fileExists(atPath: exe.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: exe.path)
    }

    /// The e2e harness (Tests/e2e/run.sh): an isolated configuration and its throw-away Keychain service, the same
    /// test as cmcrctl's `inTestHarness` (Sources/cmcrctl/Legacy.swift) – a teacher's own CMCR_CONFIG_DIR is not
    /// enough to swap the agent that gets installed on the iMacs.
    static func inTestHarness(_ env: [String: String]) -> Bool {
        !(env["CMCR_CONFIG_DIR"] ?? "").isEmpty && (env["CMCR_KEYCHAIN_SERVICE"] ?? "").hasPrefix("pl.cmcr.manager.e2e-")
    }
}
