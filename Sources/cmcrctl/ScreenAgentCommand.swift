import CMCRCore
import Foundation

/// `cmcrctl screen-agent install|status|permission|remove KOMP`: CMCR Screen Agent, the service on the iMacs that
/// takes a screenshot only when the screen preview asks for it (docs/screen-agent.md). The same operations as
/// Konfiguracja › Przygotowanie iMaców › Szybkie naprawy in the app.
@MainActor
enum ScreenAgentCLI {
    nonisolated static let usage = """
      cmcrctl screen-agent install|status|permission|remove KOMP
                                                usługa podglądu ekranu (CMCR Screen Agent) na iMacach:
                                                install – zainstaluj lub zaktualizuj (ta sama albo nowsza wersja
                                                zostaje bez zmian razem z uprawnieniem), status – wersja, czy działa,
                                                uprawnienie (kod 1, gdy podgląd nie jest gotowy), permission –
                                                okno macOS z prośbą o uprawnienie nagrywania ekranu (włącza je
                                                ktoś przy komputerze), remove – usuń (po potwierdzeniu)
    """

    nonisolated static let spec = ModuleSpec(maxPositional: 2, parallel: true)

    static let syntax = "Użycie: cmcrctl screen-agent install|status|permission|remove KOMP [-j N]"

    nonisolated static let missingAgentText = "Ta kopia cmcrctl nie ma przy sobie usługi podglądu ekranu "
        + "(\(ScreenAgentInfo.appName)) – usługa jest częścią aplikacji CMCR Manager (Contents/Helpers). Użyj cmcrctl "
        + "z pakietu aplikacji (CMCR Manager.app/Contents/Resources/bin/cmcrctl) albo zbuduj ją: scripts/build-app.sh."

    static func run(_ a: ModuleArguments) async -> Int32 {
        switch a[0] {
        case "install": return await install(a)
        case "status": return await status(a)
        case "permission": return await permission(a)
        case "remove": return await remove(a)
        case nil: moduleUsageError(a.command, syntax)
        case let other?: moduleUsageError(a.command, "Nieznane polecenie screen-agent \(other).\n" + syntax)
        }
    }

    static func install(_ a: ModuleArguments) async -> Int32 {
        // Before the hosts: without the agent nothing could be installed, so nobody is asked about the whole lab.
        guard let agent = ScreenAgentLocator.bundledAgent() else {
            Console.err("✘ " + missingAgentText)
            return ExitCode.failure
        }
        let targets = ModuleHosts.changing(a[1], a.command)
        logAction(targets)
        let ssh = sshSettings
        return await eachHost(targets, a) { io in
            // A registered job: Ctrl-C stops the upload or the installation on the iMac too (Interruption).
            let r = await Interruption.shared.job(on: io.host) { handle in
                await Operations.installScreenAgent(on: io.host, agentApp: agent, password: Keychain.password(for: io.host),
                                                    settings: ssh, handle: handle, onOutput: io.stream)
            }
            if r.succeeded { io.out("→ \(io.host.name): \(installSummary(r.stdoutText, host: io.host))") }
            return io.report(r)
        }
    }

    /// One line in words from the operation's `CMCR:AGENT` lines (docs/screen-agent.md › Instalacja).
    nonisolated static func installSummary(_ output: String, host: Machine) -> String {
        var change = "", version = ScreenAgentInfo.version
        var sessions = 0, withoutPermission: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let words = raw.split(separator: " ").map(String.init)
            if words.first == "CMCR:AGENT", words.count >= 2 {
                change = words[1]
                if words.count >= 3 { version = words[2] }
            } else if words.first == "CMCR:AGENT-SESSION", words.count >= 3 {
                sessions += 1
                if words.contains("perm=denied") || (words.count > 4 && words[3] == "ERR" && words[4] == "noperm") {
                    withoutPermission.append(words[1])
                }
            }
        }
        var text: String
        switch change {
        case "newer":
            // Nothing was touched (no sessions are reported): an older copy never replaces a newer one.
            return "na iMacu jest nowsza usługa podglądu (\(version)) – zostaje bez zmian; zaktualizuj CMCR Manager"
        case "updated": text = "usługa podglądu zaktualizowana do wersji \(version)"
        case "unchanged": text = "usługa podglądu bez zmian (wersja \(version) była już zainstalowana)"
        default: text = "usługa podglądu zainstalowana (wersja \(version))"
        }
        if sessions == 0 {
            text += "; nikt nie jest zalogowany – uruchomi się przy najbliższym logowaniu"
        } else if !withoutPermission.isEmpty {
            text += "; bez uprawnienia nagrywania ekranu (\(withoutPermission.joined(separator: ", "))): "
                + "cmcrctl screen-agent permission \(host.name)"
        }
        return text
    }

    /// One line per Mac; 0 only when the preview can work everywhere (the agent current, running for the logged-in
    /// user and allowed to record the screen – or nobody logged in yet).
    static func status(_ a: ModuleArguments) async -> Int32 {
        let targets = ModuleHosts.readOnly(a[1])
        let ssh = sshSettings
        let codes = await runHosts(targets, jobs: a.jobs ?? 1, prefixLines: a.prefix) { io in
            let (found, r) = await Operations.screenAgentStatus(on: io.host, password: Keychain.password(for: io.host),
                                                                settings: ssh)
            guard let found else {
                io.out("\(io.host.name): błąd: \(r.succeeded ? "nieczytelna odpowiedź iMaca." : SSH.diagnose(r).1)")
                if !r.started, HostTrust.refusal(r) != nil {
                    io.err("  W terminalu: cmcrctl trust \(io.host.name) – pokaże odcisk klucza i zapyta o zaufanie.")
                }
                return ExitCode.failure
            }
            io.out("\(io.host.name): \(statusLine(found, sessionError: sessionError(found, r)))")
            return isReady(found) ? ExitCode.success : ExitCode.failure
        }
        return codes.allSatisfy { $0 == ExitCode.success } ? ExitCode.success : ExitCode.failure
    }

    /// Why the session at the screen could not be asked: the agent of another account answers only root, so a sudo
    /// that failed (no saved password, a wrong one) leaves the agent's state unknown – said in words, not hidden.
    nonisolated static func sessionError(_ s: ScreenAgentStatus, _ r: CommandResult) -> String? {
        guard s.isInstalled, s.consoleUser != nil, !s.sessionChecked else { return nil }
        let why = r.succeeded ? "" : SSH.diagnose(r).1.trimmingCharacters(in: .whitespacesAndNewlines)
        return "nie udało się zapytać usługi w sesji zalogowanego użytkownika (potrzebne działające sudo)"
            + (why.isEmpty ? "" : ": " + why)
    }

    nonisolated static func statusLine(_ s: ScreenAgentStatus, sessionError: String? = nil) -> String {
        guard let installed = s.installedVersion else { return "wersja: brak usługi, załadowana: nie, uprawnienie: –" }
        var version = installed
        switch SetupScript.compareVersions(installed, ScreenAgentInfo.version) {
        case .orderedAscending: version += " (starsza niż \(ScreenAgentInfo.version) – cmcrctl screen-agent install)"
        case .orderedDescending: version += " (nowsza niż \(ScreenAgentInfo.version) tej kopii cmcrctl)"
        case .orderedSame: break
        }
        let user = s.consoleUser
        let loaded = user == nil ? "–" : s.loaded.map { $0 ? "tak" : "nie" } ?? "?"
        var parts = ["wersja: \(version)", "załadowana: \(loaded)"]
        switch s.permission {
        case .granted: parts.append("uprawnienie: nadane")
        case .denied: parts.append("uprawnienie: brak")
        case .unknown: parts.append("uprawnienie: nieznane")
        }
        parts.append("zalogowany: \(user ?? "nikt")")
        if s.locked { parts.append("ekran zablokowany") }
        if let error = s.error, !error.isEmpty { parts.append("błąd: \(error)") }
        else if let sessionError { parts.append("błąd: \(sessionError)") }
        return parts.joined(separator: ", ")
    }

    /// The preview can work: a version at least as new as this one's, and – with someone logged in – running there,
    /// answering and allowed to record the screen. Nobody logged in: nothing more can be checked yet.
    nonisolated static func isReady(_ s: ScreenAgentStatus) -> Bool {
        guard let installed = s.installedVersion,
              SetupScript.compareVersions(installed, ScreenAgentInfo.version) != .orderedAscending else { return false }
        guard s.consoleUser != nil else { return true }
        return s.loaded == true && s.permission == .granted && (s.error ?? "").isEmpty
    }

    static func permission(_ a: ModuleArguments) async -> Int32 {
        let targets = ModuleHosts.changing(a[1], a.command)
        logAction(targets)
        let ssh = sshSettings
        return await eachHost(targets, a) { io in
            let r = await Interruption.shared.job(on: io.host) { handle in
                await Operations.requestScreenAgentPermission(on: io.host, password: Keychain.password(for: io.host),
                                                              settings: ssh, handle: handle, onOutput: io.stream)
            }
            if r.succeeded { io.out("→ \(io.host.name): \(permissionHint(r.stdoutText, host: io.host))") }
            return io.report(r)
        }
    }

    nonisolated static func permissionHint(_ output: String, host: Machine) -> String {
        if output.contains("PERMISSION granted") { return "usługa podglądu ma już uprawnienie nagrywania ekranu." }
        let place = "przy komputerze: Ustawienia systemowe › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego "
            + "› włącz „\(ScreenAgentInfo.displayName)” (hasło administratora); potem: cmcrctl screen-agent status \(host.name)"
        return output.contains("PERMISSION denied") ? "na iMacu pojawiło się okno macOS – " + place : "prośba wysłana – " + place
    }

    static func remove(_ a: ModuleArguments) async -> Int32 {
        let targets = ModuleHosts.changing(a[1], a.command)
        CLI.confirm("Usunięcie usługi podglądu ekranu z: \(ModuleHosts.names(targets)). Podgląd ekranów przestanie na nich "
                    + "działać, a po ponownej instalacji uprawnienie nagrywania ekranu trzeba nadać od nowa przy każdym iMacu.",
                    yes: a.yes)
        logAction(targets)
        let ssh = sshSettings
        return await eachHost(targets, a) { io in
            let r = await Interruption.shared.job(on: io.host) { handle in
                await Operations.removeScreenAgent(on: io.host, password: Keychain.password(for: io.host), settings: ssh,
                                                   handle: handle, onOutput: io.stream)
            }
            if r.succeeded { io.out("→ \(io.host.name): usługa podglądu usunięta.") }
            return io.report(r)
        }
    }
}
