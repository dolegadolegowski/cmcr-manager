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
                Text("Część aktualizacji wymaga restartu – zalogowani uczniowie stracą niezapisaną pracę.")
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
                Spacer()
                TargetButton(title: "Tylko pobierz", icon: "arrow.down.circle", prominent: false) {
                    model.runScript("softwareupdate --download", on: model.selectedMachines) { _ in
                        Scripts.installUpdates(restart: false, recommendedOnly: recommendedOnly, downloadOnly: true,
                                               allowMajorUpgrade: allowMajor)
                    }
                }
                TargetButton(title: "Zainstaluj aktualizacje", icon: "arrow.triangle.2.circlepath") {
                    confirmInstall()
                }
            }
        } header: {
            Label("Instalacja aktualizacji macOS", systemImage: "arrow.down.app")
        } footer: {
            FormSectionNote("Komputery z procesorem Apple wymagają do instalacji hasła administratora – aplikacja poda je sama.")
                .help("softwareupdate --user/--stdinpass")
        }
    }

    func confirmInstall() {
        let r = restart, rec = recommendedOnly, major = allowMajor
        var message = "Aktualizacje macOS zostaną zainstalowane \(Polish.onComputers(model.actionTargets.count))."
        if r { message += " Komputery uruchomią się ponownie, jeśli aktualizacja tego wymaga – zalogowani uczniowie stracą niezapisaną pracę." }
        if major { message += " Uwaga: także przejście na nową wersję macOS (długa instalacja i restart)." }
        confirm = ConfirmRequest(
            title: major ? "Zainstalować aktualizacje i nową wersję macOS?" : "Zainstalować aktualizacje macOS?",
            message: message,
            button: "Zainstaluj", destructive: r || major) {
            model.runScript("softwareupdate --install\(r ? " --restart" : "")", on: model.selectedMachines,
                            script: { _ in
                                Scripts.installUpdates(restart: r, recommendedOnly: rec, downloadOnly: false, allowMajorUpgrade: major)
                            }) { m, result in
                // Installed: the list and the sidebar badge must not keep offering them (AUDIT APL-15).
                if result.succeeded { model.updates[m.id] = nil }
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
