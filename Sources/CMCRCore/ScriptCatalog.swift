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
