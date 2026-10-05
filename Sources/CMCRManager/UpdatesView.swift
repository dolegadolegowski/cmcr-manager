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
                .padding([.horizontal, .top], 20)
            Form {
                checkSection
                installSection
                appsSection
                if let batch = model.lastBatch[.updates] {
                    Section {
                        BatchResultsView(batch: batch)
                    } header: {
                        Label("Wynik ostatniej operacji", systemImage: "list.bullet.rectangle")
                    }
                    .id(batch.id)
                }
            }
            .formStyle(.grouped)
        }
        .confirmation($confirm)
    }

    // MARK: Check

    var checkSection: some View {
        let rows = model.selectedMachines.filter { model.updates[$0.id] != nil }
        return Section {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dostępne aktualizacje")
                    Text("Sprawdzenie niczego nie instaluje i nie przeszkadza uczniom.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                TargetButton(title: "Historia instalacji", icon: "clock.arrow.circlepath", prominent: false) {
                    model.runScript("Historia aktualizacji", on: model.selectedMachines) { _ in Scripts.updateHistory() }
                }
                TargetButton(title: "Sprawdź aktualizacje", icon: "magnifyingglass") {
                    model.checkUpdates(model.selectedMachines)
                }
            }
            ForEach(rows) { m in
                if let info = model.updates[m.id] { updateRow(m, info) }
            }
        } header: {
            Label("Aktualizacje macOS", systemImage: "apple.logo")
        }
    }

    func updateRow(_ m: Machine, _ info: UpdateInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: info.titles.isEmpty ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                .foregroundStyle(info.titles.isEmpty ? Color.green : Color.orange)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(m.name)
                .fontWeight(.medium)
                .frame(minWidth: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if info.titles.isEmpty {
                    Text("System jest aktualny")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(info.titles, id: \.self) { Text($0) }
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
            Text("Komputery z procesorem Apple wymagają do instalacji hasła administratora – aplikacja poda je sama.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            model.runScript("softwareupdate --install\(r ? " --restart" : "")", on: model.selectedMachines) { _ in
                Scripts.installUpdates(restart: r, recommendedOnly: rec, downloadOnly: false, allowMajorUpgrade: major)
            }
        }
    }

    // MARK: Apps

    var appsSection: some View {
        Section {
            actionRow("Programy z Homebrew",
                      "Aktualizuje programy zainstalowane przez Homebrew (brew update i brew upgrade).") {
                TargetButton(title: "Aktualizuj programy", icon: "mug", prominent: false) {
                    model.runScript("brew update && brew upgrade", on: model.selectedMachines) { _ in
                        Scripts.brew("update && with_askpass brew upgrade")
                    }
                }
            }
            actionRow("Także aplikacje z własnym aktualizatorem",
                      "Np. przeglądarki zainstalowane z Homebrew, które zwykle aktualizują się same (--greedy).") {
                TargetButton(title: "Aktualizuj wszystkie", icon: "mug.fill", prominent: false) {
                    model.runScript("brew upgrade --cask --greedy", on: model.selectedMachines) { _ in
                        Scripts.brew("upgrade --cask --greedy")
                    }
                }
            }
            actionRow("Aplikacje z App Store",
                      "Wymaga zalogowania do App Store na koncie administratora (raz, przy komputerze).") {
                TargetButton(title: "Aktualizuj z App Store", icon: "bag", prominent: false) {
                    model.runScript("mas upgrade", on: model.selectedMachines) { _ in Scripts.masUpgrade() }
                }
            }
        } header: {
            Label("Aktualizacje aplikacji", systemImage: "app.badge.checkmark")
        } footer: {
            Text("Unity i Android SDK aktualizuje się w dziale Instalacja.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func actionRow<Button: View>(_ title: String, _ caption: String,
                                 @ViewBuilder button: () -> Button) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            button()
        }
    }
}
