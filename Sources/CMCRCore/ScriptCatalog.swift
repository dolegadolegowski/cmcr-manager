import Foundation

/// Every remote script builder rendered with representative (and deliberately awkward) arguments.
/// Used by `cmcrctl selftest` and the unit tests to syntax-check all generated bash.
/// New builders should get an entry here.
public enum ScriptCatalog {
    public struct Sample: Sendable {
        public let name: String
        public let script: RemoteScript
    }

    public struct Problem: Sendable, CustomStringConvertible {
        public let name: String
        public let mode: String
        public let message: String
        public var description: String { "\(name) [\(mode)]: \(message)" }
    }

    /// Quotes, `$`, backticks, globs, braces, tabs, newlines and non-ASCII in one value.
    public static let awkward = "it's \"q\" $HOME `id` $(id) \\ ; | & * ? [x] {console} ~/x zażółć 🍎\ttab\nnowa linia !"

    public static var samples: [Sample] {
        let a = awkward
        var s: [Sample] = [
            Sample(name: "status", script: Scripts.status()),
            Sample(name: "sudoTest", script: Scripts.sudoTest()),
            Sample(name: "distributeKey", script: Scripts.distributeKey("ssh-ed25519 AAAAC3Nz \(a)")),
            Sample(name: "screenshot", script: Scripts.screenshot(maxSize: 1280, quality: 60, notify: true,
                                                                  onlyStandard: true, allowedUsers: ["student", a])),
            Sample(name: "screenshot(min)", script: Scripts.screenshot(maxSize: 0, quality: 0, notify: false,
                                                                       onlyStandard: false, allowedUsers: [])),
            Sample(name: "runningApps", script: Scripts.runningApps()),
            Sample(name: "installedApps", script: Scripts.installedApps()),
            Sample(name: "launchApp", script: Scripts.launchApp(a)),
            Sample(name: "launchApp(args)", script: Scripts.launchApp("/Applications/Safari.app",
                                                                      arguments: "--incognito \"https://example.com/?a=1&b=2\"")),
            Sample(name: "openURL", script: Scripts.openURL("https://example.com/?q=\(a)&x=1")),
            Sample(name: "quitApp(name)", script: Scripts.quitApp(a, force: false)),
            Sample(name: "quitApp(path)", script: Scripts.quitApp("/Applications/\(a).app", force: true)),
            Sample(name: "killProcess", script: Scripts.killProcess(12345, force: false)),
            Sample(name: "killProcess(force)", script: Scripts.killProcess(1, force: true)),
            Sample(name: "uninstallApp", script: Scripts.uninstallApp("/Applications/\(a).app")),
            Sample(name: "installPayload", script: Scripts.installPayload(remoteTar: "/tmp/\(a).tar")),
            Sample(name: "installFromURL", script: Scripts.installFromURL("https://example.com/\(a).dmg?x=1&y=2")),
            Sample(name: "installPayload(allowUnsigned)", script: Scripts.installPayload(remoteTar: "/tmp/\(a).tar", allowUnsigned: true)),
            Sample(name: "installFromURL(sha256)", script: Scripts.installFromURL("https://example.com/\(a).pkg", sha256: a,
                                                                                  allowUnsigned: true)),
            Sample(name: "brew", script: Scripts.brew("install --cask \"visual studio code\"")),
            Sample(name: "brew(chain)", script: Scripts.brew("update && with_askpass brew upgrade")),
            Sample(name: "installHomebrew", script: Scripts.installHomebrew()),
            Sample(name: "unityHub", script: Scripts.unityHub(["editors", "--all", a])),
            Sample(name: "unityInstallModules", script: Scripts.unityInstallModules(version: "6000.3.7f1", modules: ["android", a])),
            Sample(name: "androidSDK", script: Scripts.androidSDK(unityVersion: a, apiLevels: ["32", "34"])),
            Sample(name: "listUpdates", script: Scripts.listUpdates()),
            Sample(name: "updateHistory", script: Scripts.updateHistory()),
            Sample(name: "masUpgrade", script: Scripts.masUpgrade()),
            Sample(name: "pushFinalize", script: Scripts.pushFinalize(remoteTar: "/tmp/\(a).tar", destination: "/Users/{console}/\(a)",
                                                                      owner: a, mode: "777", asRoot: true)),
            Sample(name: "pushFinalize(empty)", script: Scripts.pushFinalize(remoteTar: "/tmp/x.tar", destination: "~/Public",
                                                                             owner: "", mode: "", asRoot: false)),
            Sample(name: "pullArchive", script: Scripts.pullArchive(source: "/Users/{console}/\(a)", asRoot: false)),
            Sample(name: "cleanFolder", script: Scripts.cleanFolder("/Users/student/\(a)/")),
            Sample(name: "listFolder", script: Scripts.listFolder("/Users/{console}/\(a)", asRoot: false)),
            Sample(name: "prepareSharedFolder", script: Scripts.prepareSharedFolder("/Users/student/\(a)", owner: a)),
            Sample(name: "message(dialog)", script: Scripts.message(title: a, text: a, asDialog: true)),
            Sample(name: "message(notification)", script: Scripts.message(title: "", text: a, asDialog: false)),
            Sample(name: "logoutUser", script: Scripts.logoutUser()),
            Sample(name: "enableScreenSharing", script: Scripts.enableScreenSharing()),
            Sample(name: "enableWakeOnLAN", script: Scripts.enableWakeOnLAN()),
            Sample(name: "exec", script: RemoteScript("echo \(shQuote(a)); for i in 1 2; do echo $i; done")),
            // U1 core-runtime (SSHRuntime.swift)
            Sample(name: "cancelScript", script: RemoteJobs.cancelScript(jobID: UUID().uuidString)),
            // U2 scripts
            Sample(name: "unityInstallEditor", script: Scripts.unityInstallEditor(version: "6000.3.7f1", modules: ["android", a],
                                                                                  changeset: "abc123")),
            Sample(name: "unityInstallEditor(min)", script: Scripts.unityInstallEditor(version: a, modules: [])),
            // U3 setup
            Sample(name: "readiness", script: Scripts.readiness(student: a, sharedFolder: "/Users/student/\(a)",
                                                                publicKey: "ssh-ed25519 AAAAC3Nz \(a)")),
            Sample(name: "readiness(noKey)", script: Scripts.readiness(student: "student", sharedFolder: "/Users/student/Public/cmcr",
                                                                       publicKey: nil)),
            Sample(name: "remote(apply)", script: SetupScript.remote(SetupOptions(), host: Machine(name: "imac04", address: "imac04.local", user: "imac04"),
                                                                     settings: AppSettings(), publicKey: "ssh-ed25519 AAAAC3Nz \(a)", mode: .apply)),
            Sample(name: "remote(verify)", script: SetupScript.remote(SetupOptions(), host: Machine(name: a, address: a, user: a),
                                                                      settings: AppSettings(), publicKey: nil, mode: .verify)),
            Sample(name: "createStudentFolder", script: Scripts.createStudentFolder("/Users/student/\(a)", owner: a)),
            // U5 screens (ScreenCapture.swift; Scripts.screenshot moved there – keep the existing two samples)
            Sample(name: "screenCapture", script: Scripts.screenCapture(ScreenCaptureOptions(maxSize: 1280, notify: true,
                                                                                             alreadyNotifiedUser: a,
                                                                                             allowedUsers: ["student", a],
                                                                                             display: .all, frames: 0))),
            Sample(name: "screenCapture(display)", script: Scripts.screenCapture(ScreenCaptureOptions(maxSize: 0, quality: 0, interval: 1,
                                                                                                      notify: false, onlyStandardAccounts: false,
                                                                                                      display: .number(2)))),
            // U6 files (Scripts+Browse.swift)
            Sample(name: "listDirectory", script: Scripts.listDirectory("/Users/{console}/\(a)", asRoot: false)),
            Sample(name: "listDirectory(root)", script: Scripts.listDirectory("/", asRoot: true, limit: 10)),
            Sample(name: "makeDirectory", script: Scripts.makeDirectory("/Users/student/\(a)", asRoot: false, intermediate: true)),
            Sample(name: "renameItem", script: Scripts.renameItem("/Users/student/\(a)", to: a, asRoot: true)),
            Sample(name: "deleteItems", script: Scripts.deleteItems(["/Users/student/\(a)", "/tmp/x y"], asRoot: false)),
            Sample(name: "deleteItems(dryRun)", script: Scripts.deleteItems([a], asRoot: true, dryRun: true)),
            Sample(name: "archiveItems", script: Scripts.archiveItems(in: "/Users/student/\(a)", names: [a, "b c"], asRoot: false)),
            Sample(name: "folderPresence", script: Scripts.folderPresence("/Users/{console}/\(a)", asRoot: false)),
            Sample(name: "removeCollected", script: Scripts.removeCollected(in: "/Users/student/\(a)",
                                                                            files: [CollectedFile(path: a, modified: 1_700_000_000, size: 12),
                                                                                    CollectedFile(path: "b c/d", modified: 1, size: 0, isLink: true)],
                                                                            folders: [a, "b c"], asRoot: true)),
            Sample(name: "removeCollected(empty)", script: Scripts.removeCollected(in: "~/Public", files: [], folders: [], asRoot: false)),
            // U8 classroom & power (Scripts+Classroom.swift)
            Sample(name: "lockScreen", script: Scripts.lockScreen(message: a, mode: .automatic, autoUnlockMinutes: 5)),
            Sample(name: "lockScreen(overlay)", script: Scripts.lockScreen(message: a, mode: .overlay, autoUnlockMinutes: 0)),
            Sample(name: "lockScreen(system)", script: Scripts.lockScreen(message: "", mode: .lockScreen, autoUnlockMinutes: 0)),
            Sample(name: "unlockScreen", script: Scripts.unlockScreen()),
            Sample(name: "ask", script: Scripts.ask(title: a, prompt: a, buttons: ["Tak", a], timeoutSeconds: 60)),
            Sample(name: "delayedPower", script: Scripts.delayedPower(.shutdown, minutes: 5, warning: a)),
            Sample(name: "delayedPower(restart)", script: Scripts.delayedPower(.restart, minutes: 0, warning: nil)),
            Sample(name: "cancelDelayedPower", script: Scripts.cancelDelayedPower()),
            Sample(name: "fileVaultStatus", script: Scripts.fileVaultStatus()),
            Sample(name: "applyEnergySchedule", script: Scripts.applyEnergySchedule(EnergySchedule(), autoRestart: true, wakeOnLAN: true)),
            Sample(name: "cancelEnergySchedule", script: Scripts.cancelEnergySchedule()),
            Sample(name: "energyScheduleStatus", script: Scripts.energyScheduleStatus()),
            Sample(name: "computerNames", script: Scripts.computerNames()),
            Sample(name: "renameComputer", script: Scripts.renameComputer(computerName: a, localHostName: "imac04")),
            Sample(name: "appVersion", script: Scripts.appVersion(a)),
            Sample(name: "quitAllApps", script: Scripts.quitAllApps()),
            Sample(name: "ping", script: Scripts.ping()),

        ]
        for restart in [false, true] {
            for recommended in [false, true] {
                for download in [false, true] {
                    s.append(Sample(name: "installUpdates(restart:\(restart),recommended:\(recommended),download:\(download))",
                                    script: Scripts.installUpdates(restart: restart, recommendedOnly: recommended,
                                                                   downloadOnly: download)))
                }
            }
        }
        for action in PowerAction.allCases {
            s.append(Sample(name: "power(\(action.rawValue))", script: Scripts.power(action)))
        }
        return s
    }

    /// Runs `bash -n` on the body (after the helper library) and on the full wrapper in user and root mode.
    public static func syntaxCheck(_ samples: [Sample] = samples, bash: String = "/bin/bash") async -> [Problem] {
        var problems: [Problem] = []
        if let p = await check(RemoteScript.library, bash: bash) {
            problems.append(Problem(name: "RemoteScript.library", mode: "biblioteka", message: p))
        }
        for sample in samples {
            if let p = await check(RemoteScript.library + "\n" + sample.script.body, bash: bash) {
                problems.append(Problem(name: sample.name, mode: "treść", message: p))
            }
            for asRoot in [false, true] {
                var script = sample.script
                script.asRoot = asRoot
                if let p = await check(script.render(), bash: bash) {
                    problems.append(Problem(name: sample.name, mode: asRoot ? "root" : "użytkownik", message: p))
                }
            }
        }
        return problems
    }

    static func check(_ text: String, bash: String) async -> String? {
        let r = await ProcessRunner.run(bash, ["--noprofile", "--norc", "-n"], stdin: Data(text.utf8))
        if r.succeeded { return nil }
        let err = r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? "bash -n zakończone kodem \(r.exitCode)" : err
    }
}
