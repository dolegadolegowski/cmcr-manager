import CMCRCore
import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var restart = false
    @ViewState private var recommendedOnly = false
    @ViewState private var allowMajor = false
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .updates,
                         subtitle: "Aktualizacje systemu macOS oraz programów z Homebrew i App Store na zaznaczonych komputerach.")
                .alignedWithGroupedForm()
                .padding([.horizontal, .top], 20)
            Form {
                checkSection
                installSection
                appsSection
                if let batch = model.lastBatch[.updates] {
                    Section {
                        BatchResultsView(batch: batch)
                    } header: {
                        Label("Wynik ostatniego działania", systemImage: "list.bullet.rectangle")
                    }
                    .id(batch.id)
                }
            }
            .formStyle(.grouped)
        }
        .groupedFormPageBackground()
        .confirmation($confirm)
    }

    // MARK: Check

    var checkSection: some View {
        let rows = model.selectedMachines.filter { model.updates[$0.id] != nil }
        return Section {
            FormActionRow("Dostępne aktualizacje", caption: "Sprawdzenie niczego nie instaluje i nie przeszkadza uczniom.") {
                TargetButton(title: "Historia instalacji", icon: "clock.arrow.circlepath", prominent: false) {
                    model.runScript("Historia aktualizacji", on: model.selectedMachines) { _ in Scripts.updateHistory() }
                }
                TargetButton(title: "Sprawdź aktualizacje", icon: "magnifyingglass") {
                    model.checkUpdates(model.selectedMachines)
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
            ForEach(rows) { m in
                if let info = model.updates[m.id] { updateRow(m, info) }
            }
        } header: {
            Label("Aktualizacje macOS", systemImage: "gear.badge")
        }
    }

    func updateRow(_ m: Machine, _ info: UpdateInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch info.check {
                case .upToDate:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                case .available:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            Text(m.name)
                .fontWeight(.medium)
                .frame(minWidth: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                switch info.check {
                case .upToDate:
                    Text("System jest aktualny")
                        .foregroundStyle(.secondary)
                case .available(let titles):
                    ForEach(titles, id: \.self) { Text($0) }
                case .failed(let reason):
                    Text("Nie udało się sprawdzić aktualizacji")
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Text(info.checkedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Sprawdzono o \(info.checkedAt.formatted(date: .abbreviated, time: .standard))")
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Install

    var installSection: some View {
        Section {
            Toggle(isOn: $restart) {
                Text("Uruchom ponownie, jeśli to potrzebne")
                Text("Aktualizację macOS instaluje dopiero restart, który wykonuje softwareupdate – bez tego zostanie tylko pobrana. Zalogowani uczniowie zostaną wylogowani i stracą niezapisaną pracę.")
            }
            .help("softwareupdate -R")
            Toggle(isOn: $recommendedOnly) {
                Text("Tylko zalecane aktualizacje")
                Text("Pomija aktualizacje, które Apple oznacza jako dodatkowe.")
            }
            .help("softwareupdate -r")
            Toggle(isOn: $allowMajor) {
                Text("Pozwól na nową wersję macOS")
                Text("Bez tego instalowane są tylko poprawki obecnej wersji – przejście np. z macOS 26 na 27 jest pomijane.")
            }
            HStack(spacing: 10) {
                TargetButton(title: "Stan instalacji", icon: "list.bullet.clipboard", prominent: false) {
                    let targets = model.selectedMachines
                    // Only watching: every Mac at once.
                    model.runBatch("Stan instalacji aktualizacji", on: targets, maxParallel: max(1, targets.count)) { m, job in
                        await Operations.followUpdate(on: m, password: model.password(for: m), settings: model.sshSettings,
                                                      handle: job.handle, maxCapture: AppModel.jobCapture,
                                                      onOutput: OutputSink(job).callback)
                    }
                }
                .help("Postęp lub wynik ostatniej instalacji uruchomionej z tej aplikacji – także po zerwanym połączeniu i po restarcie komputera. „Przerwij” kończy tylko śledzenie.")
                Spacer()
                TargetButton(title: "Tylko pobierz", icon: "arrow.down.circle", prominent: false) {
                    runInstall("softwareupdate --download", restart: false, recommendedOnly: recommendedOnly,
                               downloadOnly: true, allowMajor: allowMajor)
                }
                TargetButton(title: "Zainstaluj aktualizacje", icon: "arrow.triangle.2.circlepath") {
                    confirmInstall()
                }
            }
        } header: {
            Label("Instalacja aktualizacji macOS", systemImage: "arrow.down.app")
        } footer: {
            FormSectionNote("Na komputerach z procesorem Apple instalację macOS zatwierdza konto administratora z Secure Token (właściciel woluminu) – aplikacja poda jego hasło sama. Instalacja trwa na iMacu niezależnie od połączenia: po jego zerwaniu aplikacja łączy się ponownie, a po restarcie sprawdza wersję systemu.")
                .help("softwareupdate --user/--stdinpass")
        }
    }

    /// Updates run detached on the iMacs and are followed again after a lost connection (`Operations.installUpdates`).
    /// „Równoległe operacje” limits only how many start at a time: a Mac's slot is free again as soon as its install is
    /// going, not when it has finished – with the restart that can take an hour, and the last Macs would start that late
    /// (or never, if the app is quit).
    func runInstall(_ title: String, restart: Bool, recommendedOnly: Bool, downloadOnly: Bool, allowMajor: Bool,
                    onResult: (@MainActor (Machine, CommandResult) -> Void)? = nil) {
        let targets = model.selectedMachines
        let launches = HostGate(limit: max(1, model.settings.maxParallel))
        model.runBatch(title, on: targets, maxParallel: max(1, targets.count)) { m, job in
            guard await launches.acquire("launch", handle: job.handle) else { return .cancelledResult }
            let r = await Operations.installUpdates(restart: restart, recommendedOnly: recommendedOnly,
                                                    downloadOnly: downloadOnly, allowMajorUpgrade: allowMajor, on: m,
                                                    password: model.password(for: m), settings: model.sshSettings,
                                                    handle: job.handle, maxCapture: AppModel.jobCapture,
                                                    launched: { launches.release("launch") },
                                                    onOutput: OutputSink(job).callback)
            onResult?(m, r)
            return r
        }
    }

    func confirmInstall() {
        let r = restart, rec = recommendedOnly, major = allowMajor
        var message = "Aktualizacje macOS zostaną zainstalowane \(Polish.onComputers(model.actionTargets.count))."
        if r {
            message += " Komputery uruchomią się ponownie, jeśli aktualizacja tego wymaga – macOS najpierw wyloguje zalogowanych "
                + "uczniów (stracą niezapisaną pracę); aplikacja, której nie da się zamknąć, wstrzyma restart."
        }
        if major { message += " Uwaga: także przejście na nową wersję macOS (długa instalacja i restart)." }
        confirm = ConfirmRequest(
            title: major ? "Zainstalować aktualizacje i nową wersję macOS?" : "Zainstalować aktualizacje macOS?",
            message: message,
            button: "Zainstaluj", destructive: r || major) {
            runInstall("softwareupdate --install\(r ? " --restart" : "")", restart: r, recommendedOnly: rec,
                       downloadOnly: false, allowMajor: major) { m, result in
                // Installed: the list and the sidebar badge must not keep offering them (AUDIT APL-15) – but what the
                // script skipped is still pending (AUDIT REV-27).
                if result.succeeded {
                    model.updates[m.id] = model.updates[m.id]?.remaining(afterInstall: result.stdoutText, recommendedOnly: rec)
                }
            }
        }
    }

    // MARK: Apps

    var appsSection: some View {
        Section {
            FormActionRow("Programy z Homebrew",
                          caption: "Aktualizuje programy zainstalowane przez Homebrew (brew update i brew upgrade).") {
                TargetButton(title: "Aktualizuj programy", icon: "mug", prominent: false) {
                    model.runScript("brew update && brew upgrade", on: model.selectedMachines) { _ in
                        Scripts.brew("update && with_askpass brew upgrade")
                    }
                }
            }
            FormActionRow("Także aplikacje z własnym aktualizatorem",
                          caption: "Np. przeglądarki zainstalowane z Homebrew, które zwykle aktualizują się same (--greedy).") {
                TargetButton(title: "Aktualizuj wszystkie", icon: "mug.fill", prominent: false) {
                    model.runScript("brew upgrade --cask --greedy", on: model.selectedMachines) { _ in
                        Scripts.brew("upgrade --cask --greedy")
                    }
                }
            }
            FormActionRow("Aplikacje z App Store",
                          caption: "Wymaga zalogowania do App Store na koncie administratora (raz, przy komputerze).") {
                TargetButton(title: "Aktualizuj z App Store", icon: "bag", prominent: false) {
                    model.runScript("mas upgrade", on: model.selectedMachines) { _ in Scripts.masUpgrade() }
                }
            }
        } header: {
            Label("Aktualizacje aplikacji", systemImage: "app.badge.checkmark")
        } footer: {
            FormSectionNote("Unity i Android SDK aktualizuje się w dziale Instalacja.")
        }
    }
}

extension UpdateInfo {
    /// How `Scripts.installUpdates` reports an intermediate macOS version it left out (followed by the label and „ – ”).
    static let supersededPrefix = "↷ Pominięto wersję pośrednią: "

    /// What is still offered after a successful run of `Scripts.installUpdates`. The script installs only the labels
    /// it prints as „→ label”: without „Pozwól na nową wersję macOS” it skips a new major macOS („↷ Pominięto…”),
    /// with „Tylko zalecane” the optional updates, and it also succeeds when nothing was left to install. So only the
    /// installed labels leave the list (AUDIT APL-15, REV-27), and so do intermediate macOS versions the script left
    /// out because it installed a newer one; nil when nothing is pending any more.
    func remaining(afterInstall output: String, recommendedOnly: Bool) -> UpdateInfo? {
        switch check {
        case .upToDate: return self
        case .failed: return nil
        case .available(let titles):
            let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            // Nothing could have been skipped, so an empty list at install time means they were installed meanwhile.
            if !recommendedOnly, lines.contains("✔ Brak aktualizacji do zainstalowania."),
               !lines.contains(where: { $0.hasPrefix("↷ ") }) {
                return nil
            }
            // An intermediate macOS version left out for the newest one is not pending any more either.
            let superseded = lines.compactMap { line -> String? in
                guard line.hasPrefix(Self.supersededPrefix), let end = line.range(of: " – ") else { return nil }
                return String(line[line.index(line.startIndex, offsetBy: Self.supersededPrefix.count)..<end.lowerBound])
            }
            let installed = Set(lines.filter { $0.hasPrefix("→ ") }.map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) })
                .union(superseded)
            // The check's labels in the order of its titles: Parsers.softwareUpdates gives one title per label.
            let labels = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("* Label:") }
                .map { $0.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces) }
            let all = Parsers.softwareUpdates(raw)
            guard labels.count == all.count else { return self }      // cannot tell: keep offering them
            let done = Set(zip(labels, all).filter { installed.contains($0.0) }.map(\.1))
            let left = titles.filter { !done.contains($0) }
            guard !left.isEmpty else { return nil }
            var info = self
            info.check = .available(left)
            return info
        }
    }
}
