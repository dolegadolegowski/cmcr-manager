import CMCRCore
import Foundation

// CMCR Screen Agent on the iMacs, from the app: install or update, ask for the Screen Recording permission,
// remove (Konfiguracja › Przygotowanie iMaców, the screen tiles, „Skonfiguruj zaznaczone”). The remote work is
// done by `Operations` (docs/screen-agent.md); this file turns it into jobs and plain words.

extension AppModel {
    /// The app's own copy of CMCR Screen Agent.app, which is uploaded to the iMacs; nil in a build without it
    /// (`swift run`). A variable so the model tests do not depend on what is installed on the developer's Mac.
    static var bundledScreenAgent: () -> URL? = { ScreenAgentLocator.bundledAgent() }

    static let screenAgentMissingText = "Ta kopia CMCR Manager nie zawiera usługi podglądu ekranu (\(ScreenAgentInfo.displayName)) "
        + "– na przykład uruchomiona przez swift run. Zbuduj aplikację skryptem scripts/build-app.sh albo zainstaluj wydanie z GitHuba."

    static let screenAgentInstallTitle = "Usługa podglądu ekranu – instalacja lub aktualizacja (\(ScreenAgentInfo.version))"
    static let screenAgentPermissionTitle = "Usługa podglądu ekranu – prośba o uprawnienie nagrywania ekranu"
    static let screenAgentRemoveTitle = "Usługa podglądu ekranu – usuwanie"

    /// Installs or updates the agent on the targets (the same version is left as it is, with its permission).
    @discardableResult
    func installScreenAgent(on targets: [Machine], section: AppSection = .setup,
                            onResult: (@MainActor (Machine, CommandResult) -> Void)? = nil) -> Batch? {
        guard let agent = Self.bundledScreenAgent() else {
            reportFailure("Brak usługi podglądu w tej kopii aplikacji", hint: Self.screenAgentMissingText)
            return nil
        }
        return runBatch(Self.screenAgentInstallTitle, on: targets, section: section) { m, job in
            let r = await self.installScreenAgent(agent, on: m, job: job)
            onResult?(m, r)
            return r
        }
    }

    /// One Mac, inside a job – also the first step of „Skonfiguruj zaznaczone”. The machine-readable `CMCR:AGENT`
    /// lines are left out of the log and written out in words after the operation.
    func installScreenAgent(_ agent: URL, on m: Machine, job: Job) async -> CommandResult {
        let filter = AgentLineFilter(OutputSink(job).callback)
        let r = await Operations.installScreenAgent(on: m, agentApp: agent, password: password(for: m),
                                                    settings: sshSettings, handle: job.handle, onOutput: filter.callback)
        job.flushIncoming()
        if r.succeeded { ScreenAgentInstallReport.parse(r.stdoutText).lines.forEach(job.note) }
        return r
    }

    /// Asks the agent in the logged-in user's session to request the permission: macOS shows its dialog at the iMac
    /// and lists the agent under Screen & System Audio Recording, where someone at the computer switches it on.
    @discardableResult
    func requestScreenAgentPermission(on targets: [Machine], section: AppSection = .setup,
                                      onResult: (@MainActor (Machine, CommandResult) -> Void)? = nil) -> Batch? {
        runBatch(Self.screenAgentPermissionTitle, on: targets, section: section) { m, job in
            let r = await Operations.requestScreenAgentPermission(on: m, password: self.password(for: m),
                                                                  settings: self.sshSettings, handle: job.handle,
                                                                  onOutput: AgentLineFilter(OutputSink(job).callback).callback)
            job.flushIncoming()
            if r.succeeded { job.note(Self.permissionNote(r.stdoutText)) }
            onResult?(m, r)
            return r
        }
    }

    /// What to do after the request, from the agent's answer (`PERMISSION granted|denied`, docs/screen-agent.md).
    static func permissionNote(_ output: String) -> String {
        let place = "Ustawienia systemowe › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego › włącz "
            + "„\(ScreenAgentInfo.displayName)” (hasło administratora), potem w aplikacji „Sprawdź ponownie”."
        if output.contains("PERMISSION granted") { return "Usługa podglądu ma już uprawnienie nagrywania ekranu – podgląd może działać." }
        if output.contains("PERMISSION denied") { return "Na iMacu pojawiło się okno macOS. Przy komputerze: " + place }
        return "Prośba wysłana. Przy komputerze: " + place
    }

    /// Removes the agent, its LaunchAgent, screenshots and permission (asked for first in the view).
    @discardableResult
    func removeScreenAgent(on targets: [Machine], section: AppSection = .setup,
                           onResult: (@MainActor (Machine, CommandResult) -> Void)? = nil) -> Batch? {
        runBatch(Self.screenAgentRemoveTitle, on: targets, section: section) { m, job in
            let r = await Operations.removeScreenAgent(on: m, password: self.password(for: m), settings: self.sshSettings,
                                                       handle: job.handle,
                                                       onOutput: AgentLineFilter(OutputSink(job).callback).callback)
            job.flushIncoming()
            if r.succeeded {
                job.note("Usługa podglądu usunięta – podgląd ekranu tego iMaca nie działa, dopóki nie zainstalujesz jej ponownie.")
            }
            onResult?(m, r)
            return r
        }
    }
}

/// What `Operations.installScreenAgent` reported in its machine-readable lines (docs/screen-agent.md › Instalacja):
/// `CMCR:AGENT <installed|updated|unchanged> <wersja>` and, per graphical session,
/// `CMCR:AGENT-SESSION <konto> <uid> <wiersz ping albo ERR …>`. Lines it does not know are ignored, missing ones leave
/// the fields empty, so the summary says only what is known.
struct ScreenAgentInstallReport: Equatable {
    enum Change: String { case installed, updated, unchanged }

    struct Session: Equatable {
        enum State: Equatable {
            case ready
            case noPermission
            /// Answered, without saying whether it has the permission.
            case answered
            case notAnswering(String)
        }

        var user: String
        var uid: String
        /// The client's `ping` line (`AGENT 1.0.0 perm=granted locked=0 …`) or `ERR <kod> <opis>`.
        var answer: String

        var state: State {
            if answer.hasPrefix("AGENT ") {
                let words = answer.split(separator: " ")
                switch words.first(where: { $0.hasPrefix("perm=") }).map({ $0.dropFirst("perm=".count) }) {
                case "granted"?: return .ready
                case "denied"?: return .noPermission
                default: return .answered
                }
            }
            // `ERR <kod> <opis>`: the description says it in words; the bare code only when there is none.
            let words = answer.split(separator: " ", maxSplits: 2).map(String.init)
            guard words.first == "ERR" else { return .notAnswering(answer) }
            if words.count > 1, words[1] == "noperm" { return .noPermission }
            return .notAnswering(words.count > 2 ? words[2] : words.count > 1 ? words[1] : "")
        }

        var text: String {
            switch state {
            case .ready: return "\(user): usługa działa i ma uprawnienie nagrywania ekranu."
            case .noPermission: return "\(user): usługa działa, ale nie ma jeszcze uprawnienia nagrywania ekranu."
            case .answered: return "\(user): usługa działa."
            case .notAnswering(let detail):
                return "\(user): usługa nie odpowiada\(detail.isEmpty ? "" : " (\(detail))")."
            }
        }
    }

    var change: Change?
    var version: String?
    var sessions: [Session] = []

    static func parse(_ text: String) -> ScreenAgentInstallReport {
        var report = ScreenAgentInstallReport()
        for raw in text.split(whereSeparator: \.isNewline) {
            let words = raw.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            switch words.first {
            case "CMCR:AGENT"? where words.count >= 2:
                report.change = Change(rawValue: words[1]) ?? report.change
                if words.count >= 3 { report.version = words[2] }
            case "CMCR:AGENT-SESSION"? where words.count >= 3:
                report.sessions.append(Session(user: words[1], uid: words[2], answer: words.count > 3 ? words[3] : ""))
            default:
                continue
            }
        }
        return report
    }

    var needsPermission: Bool { sessions.contains { $0.state == .noPermission } }

    /// For the end of the setup summary: „Usługa podglądu: zainstalowana (1.0.0).”
    var short: String {
        let v = version ?? ScreenAgentInfo.version
        let what: String
        switch change {
        case .installed?: what = "zainstalowana (\(v))"
        case .updated?: what = "zaktualizowana do \(v)"
        case .unchanged?: what = "bez zmian (\(v))"
        case nil: what = "zainstalowana"
        }
        return "Usługa podglądu: \(what)\(needsPermission ? " – bez uprawnienia nagrywania ekranu" : "")."
    }

    /// Log lines: one per session, then the outcome (the job's summary is its last line).
    var lines: [String] {
        let v = version ?? ScreenAgentInfo.version
        var out = sessions.map(\.text)
        var last: String
        switch change {
        case .installed?: last = "Usługa podglądu zainstalowana (wersja \(v))."
        case .updated?: last = "Usługa podglądu zaktualizowana do wersji \(v)."
        case .unchanged?: last = "Usługa podglądu bez zmian – wersja \(v) była już zainstalowana."
        case nil: last = "Usługa podglądu zainstalowana."
        }
        if sessions.isEmpty {
            last += " Nikt nie jest zalogowany – usługa uruchomi się przy najbliższym logowaniu."
        } else if needsPermission {
            last += change == .updated
                ? " Nowa wersja potrzebuje ponownie uprawnienia nagrywania ekranu (podpis ad-hoc) – Szybkie naprawy › Poproś o uprawnienie nagrywania ekranu."
                : " Nadaj jej uprawnienie nagrywania ekranu: Szybkie naprawy › Poproś o uprawnienie nagrywania ekranu."
        }
        out.append(last)
        return out
    }
}

/// Hides the machine-readable `CMCR:AGENT…` lines of the agent operations from the job log; the app reads them
/// from the result's stdout and writes them out in words (ScreenAgentInstallReport).
final class AgentLineFilter: @unchecked Sendable {
    private let forward: Operations.Output
    private let decoder = UTF8StreamDecoder()
    private let lock = NSLock()
    private var pending = ""

    init(_ forward: @escaping Operations.Output) { self.forward = forward }

    var callback: Operations.Output {
        { [self] channel, data in
            guard channel == .stdout else { forward(channel, data); return }
            lock.lock()
            pending += decoder.decode(data)
            var out = ""
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending.removeSubrange(...nl)
                if !line.hasPrefix("CMCR:AGENT") { out += line + "\n" }
            }
            lock.unlock()
            if !out.isEmpty { forward(.stdout, Data(out.utf8)) }
        }
    }
}
