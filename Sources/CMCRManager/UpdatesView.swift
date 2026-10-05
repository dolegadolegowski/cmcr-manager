import CMCRCore
import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var restart = false
    @ViewState private var recommendedOnly = false
    @ViewState private var allowMajor = false
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        Page {
            TargetHeader(section: .updates,
                         subtitle: "Zdalne aktualizacje systemu macOS (softwareupdate), pakietów Homebrew i aplikacji z App Store.")
            macOSBox
            otherBox
            LastBatchView(section: .updates)
        }
        .confirmation($confirm)
    }

    var macOSBox: some View {
        SectionBox(title: "macOS – Uaktualnienia oprogramowania", icon: "apple.logo") {
            HStack {
                TargetButton(title: "Sprawdź dostępne", icon: "magnifyingglass", prominent: false) {
                    model.checkUpdates(model.selectedMachines)
                }
                TargetButton(title: "Historia instalacji", icon: "clock.arrow.circlepath", prominent: false) {
                    model.runScript("Historia aktualizacji", on: model.selectedMachines) { _ in Scripts.updateHistory() }
                }
            }
            updatesTable
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Uruchom ponownie, jeśli wymagane (-R)", isOn: $restart)
                Toggle("Tylko zalecane (-r)", isOn: $recommendedOnly)
                Toggle("Pozwól na nową wersję macOS", isOn: $allowMajor)
                    .help("Bez tego zaznaczenia instalowane są tylko poprawki bieżącej wersji systemu – przejście np. z macOS 26 na 27 jest pomijane.")
            }
            HStack {
                TargetButton(title: "Pobierz (bez instalacji)", icon: "arrow.down.circle", prominent: false) {
                    model.runScript("softwareupdate --download", on: model.selectedMachines) { _ in
                        Scripts.installUpdates(restart: false, recommendedOnly: recommendedOnly, downloadOnly: true,
                                               allowMajorUpgrade: allowMajor)
                    }
                }
                TargetButton(title: "Zainstaluj aktualizacje", icon: "arrow.triangle.2.circlepath") {
                    let r = restart, rec = recommendedOnly, major = allowMajor
                    let majorNote = major ? " Uwaga: także przejście na nową wersję macOS (długa instalacja, restart)." : ""
                    confirm = ConfirmRequest(
                        title: major ? "Zainstalować aktualizacje i nową wersję macOS?" : "Zainstalować aktualizacje macOS?",
                        message: "\(Polish.onComputers(model.actionTargets.count).capitalizedFirst) zostanie uruchomione softwareupdate --install\(r ? " z automatycznym restartem – zalogowani użytkownicy stracą niezapisane dane" : "").\(majorNote)",
                        button: "Instaluj", destructive: r || major) {
                        model.runScript("softwareupdate --install\(r ? " --restart" : "")", on: model.selectedMachines) { _ in
                            Scripts.installUpdates(restart: r, recommendedOnly: rec, downloadOnly: false,
                                                   allowMajorUpgrade: major)
                        }
                    }
                }
            }
            Text("Na Macach z Apple Silicon aktualizacje systemu wymagają uwierzytelnienia właściciela woluminu – aplikacja przekazuje hasło administratora (--user/--stdinpass).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder var updatesTable: some View {
        let rows = model.selectedMachines.filter { model.updates[$0.id] != nil }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { m in
                    let info = model.updates[m.id]!
                    HStack(alignment: .top) {
                        Text(m.name).fontWeight(.medium).frame(width: 90, alignment: .leading)
                        if info.titles.isEmpty {
                            Label("Brak aktualizacji", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(info.titles, id: \.self) { Text("• \($0)") }
                            }
                        }
                        Spacer()
                        Text(info.checkedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }

    var otherBox: some View {
        SectionBox(title: "Aplikacje", icon: "app.badge.checkmark") {
            HStack {
                TargetButton(title: "Homebrew: update + upgrade", icon: "mug", prominent: false) {
                    model.runScript("brew update && brew upgrade", on: model.selectedMachines) { _ in
                        Scripts.brew("update && with_askpass brew upgrade")
                    }
                }
                TargetButton(title: "Homebrew: także aplikacje (--greedy)", icon: "mug.fill", prominent: false) {
                    model.runScript("brew upgrade --cask --greedy", on: model.selectedMachines) { _ in
                        Scripts.brew("upgrade --cask --greedy")
                    }
                }
                TargetButton(title: "App Store (mas upgrade)", icon: "bag", prominent: false) {
                    model.runScript("mas upgrade", on: model.selectedMachines) { _ in Scripts.masUpgrade() }
                }
            }
            Text("App Store (mas) aktualizuje aplikacje konta Apple ID zalogowanego w App Store na koncie administratora (raz, przy komputerze). Aktualizacje Unity i Android SDK: dział Instalacja › Unity Hub i Android SDK.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
