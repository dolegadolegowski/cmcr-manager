import Foundation
import Testing
@testable import CMCRCore

// ScreenAgentLocator: where the app and cmcrctl find the CMCR Screen Agent.app they upload to the iMacs.

private struct LocatorFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmcr-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// A fake agent bundle at `path` (relative to root); `executable: false` leaves out the binary, `version: nil` the
    /// Info.plist.
    @discardableResult
    func agent(_ path: String, executable: Bool = true, version: String? = ScreenAgentInfo.version,
               id: String = ScreenAgentInfo.bundleID) throws -> URL {
        let app = root.appendingPathComponent(path, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        if let version {
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        if executable {
            let exe = macOS.appendingPathComponent(ScreenAgentInfo.executableName)
            try Data("#!/bin/sh\n".utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        }
        return app
    }

    @discardableResult
    func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func locate(env: [String: String] = [:], bundle: String, executable: String?, debug: Bool = false,
                applications: String = "Applications/CMCR Manager.app") -> URL? {
        ScreenAgentLocator.bundledAgent(environment: env, bundleURL: url(bundle), executableURL: executable.map(url),
                                        applicationsApp: url(applications), debugBuild: debug)
    }
}

private let helperPath = "Contents/Helpers/CMCR Screen Agent.app"

@Test func locatorFindsTheHelperOfTheRunningApp() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    let helper = try f.agent("Build/CMCR Manager.app/\(helperPath)")
    try f.agent("Applications/CMCR Manager.app/\(helperPath)")
    let found = f.locate(bundle: "Build/CMCR Manager.app", executable: "Build/CMCR Manager.app/Contents/MacOS/CMCRManager")
    #expect(found?.standardizedFileURL == helper.standardizedFileURL)
}

@Test func locatorFindsTheAppAroundCmcrctlThroughASymlink() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    let helper = try f.agent("Apps/CMCR Manager.app/\(helperPath)")
    let ctl = try f.file("Apps/CMCR Manager.app/Contents/Resources/bin/cmcrctl")
    try FileManager.default.createDirectory(at: f.url("bin"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: f.url("bin/cmcrctl"), withDestinationURL: ctl)
    let found = f.locate(bundle: "bin", executable: "bin/cmcrctl")
    #expect(found?.resolvingSymlinksInPath() == helper.resolvingSymlinksInPath())
}

@Test func locatorFindsTheAgentNextToTheExecutable() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    let next = try f.agent("build/CMCR Screen Agent.app")
    try f.file("build/cmcrctl")
    try f.agent("Applications/CMCR Manager.app/\(helperPath)")
    let found = f.locate(bundle: "build", executable: "build/cmcrctl")
    #expect(found?.resolvingSymlinksInPath() == next.resolvingSymlinksInPath())
}

@Test func locatorFallsBackToApplicationsAndOtherwiseNil() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    try f.file(".build/debug/CMCRManager")
    // A bare binary next to the executable is no bundle; the app without a helper does not count either.
    try f.file(".build/debug/cmcr-screen-agent")
    try FileManager.default.createDirectory(at: f.url("Applications/CMCR Manager.app/Contents"), withIntermediateDirectories: true)
    #expect(f.locate(bundle: ".build/debug", executable: ".build/debug/CMCRManager") == nil)
    let installed = try f.agent("Applications/CMCR Manager.app/\(helperPath)")
    #expect(f.locate(bundle: ".build/debug", executable: ".build/debug/CMCRManager")?.standardizedFileURL
        == installed.standardizedFileURL)
}

@Test func locatorRequiresTheExecutableInsideTheBundle() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    try f.agent("Build/CMCR Manager.app/\(helperPath)", executable: false)
    let installed = try f.agent("Applications/CMCR Manager.app/\(helperPath)")
    let found = f.locate(bundle: "Build/CMCR Manager.app", executable: "Build/CMCR Manager.app/Contents/MacOS/CMCRManager")
    #expect(found?.standardizedFileURL == installed.standardizedFileURL)
}

@Test func locatorSkipsAgentsOfAnotherVersion() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    // A standalone cmcrctl or `swift run` next to an installed CMCR Manager of another release: its agent is not this
    // build's and would be uploaded under this build's version.
    try f.file(".build/debug/cmcrctl")
    try f.agent("Applications/CMCR Manager.app/\(helperPath)", version: "0.0.1")
    #expect(f.locate(bundle: ".build/debug", executable: ".build/debug/cmcrctl") == nil)
    // Earlier places are skipped the same way; the first one of this version wins.
    try f.agent(".build/debug/CMCR Screen Agent.app", version: "99.0.0")
    try f.agent("Applications/CMCR Manager.app/\(helperPath)")
    #expect(f.locate(bundle: ".build/debug", executable: ".build/debug/cmcrctl")?.standardizedFileURL
        == f.url("Applications/CMCR Manager.app/\(helperPath)").standardizedFileURL)
    // Another bundle identifier, or no Info.plist at all, is no agent of this build either.
    try f.agent("Other/CMCR Manager.app/\(helperPath)", id: "com.example.agent")
    try f.agent("Bare/CMCR Manager.app/\(helperPath)", version: nil)
    #expect(f.locate(bundle: "Other/CMCR Manager.app", executable: nil, applications: "none.app") == nil)
    #expect(f.locate(bundle: "Bare/CMCR Manager.app", executable: nil, applications: "none.app") == nil)
    // The explicit override is taken whatever its version (the e2e tests install older and newer copies).
    let old = try f.agent("e2e/CMCR Screen Agent.app", version: "0.9.0")
    #expect(f.locate(env: ["CMCR_SCREEN_AGENT_APP": old.path], bundle: "x", executable: nil, debug: true)?
        .standardizedFileURL == old.standardizedFileURL)
}

@Test func locatorOverrideOnlyInDebugBuildsOrTheHarness() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    let override = try f.agent("e2e/agent-bundle/CMCR Screen Agent.app")
    let installed = try f.agent("Applications/CMCR Manager.app/\(helperPath)")
    let env = ["CMCR_SCREEN_AGENT_APP": override.path]
    let harness = env.merging(["CMCR_CONFIG_DIR": f.url("config").path,
                               "CMCR_KEYCHAIN_SERVICE": "pl.cmcr.manager.e2e-123"]) { a, _ in a }
    let teacher = env.merging(["CMCR_CONFIG_DIR": f.url("config").path,
                               "CMCR_KEYCHAIN_SERVICE": "pl.cmcr.manager"]) { a, _ in a }

    #expect(f.locate(env: env, bundle: "x", executable: nil, debug: true)?.standardizedFileURL == override.standardizedFileURL)
    #expect(f.locate(env: harness, bundle: "x", executable: nil)?.standardizedFileURL == override.standardizedFileURL)
    // A release build outside the harness ignores the variable.
    #expect(f.locate(env: env, bundle: "x", executable: nil)?.standardizedFileURL == installed.standardizedFileURL)
    #expect(f.locate(env: teacher, bundle: "x", executable: nil)?.standardizedFileURL == installed.standardizedFileURL)
    // An override that points nowhere is not silently replaced by the installed agent.
    #expect(f.locate(env: ["CMCR_SCREEN_AGENT_APP": f.url("missing.app").path], bundle: "x", executable: nil,
                     debug: true) == nil)
    // An empty one is no override.
    #expect(f.locate(env: ["CMCR_SCREEN_AGENT_APP": ""], bundle: "x", executable: nil, debug: true)?.standardizedFileURL
        == installed.standardizedFileURL)
}

@Test func locatorPublicEntryPointHonoursTheOverride() throws {
    let f = try LocatorFixture()
    defer { f.cleanUp() }
    let override = try f.agent("agent/CMCR Screen Agent.app")
    // Unit tests are DEBUG builds (and the harness variables make it count in a release build too).
    let env = ["CMCR_SCREEN_AGENT_APP": override.path, "CMCR_CONFIG_DIR": f.url("config").path,
               "CMCR_KEYCHAIN_SERVICE": "pl.cmcr.manager.e2e-unit"]
    #expect(ScreenAgentLocator.bundledAgent(environment: env)?.standardizedFileURL == override.standardizedFileURL)
}
