import CMCRCore
import SwiftUI

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @State private var appName = ""
    @State private var appArguments = ""
    @State private var urlToOpen = ""
    @State private var showSystem = false
    @State private var confirm: ConfirmRequest?

    var body: some View {
        Page {
            TargetHeader(section: .apps,
                         subtitle: "Zdalne uruchamianie i zamykanie aplikacji w sesji użytkownika zalogowanego przy komputerze.")
            bulkBox
            runningBox
            installedBox
            LastBatchView(section: .apps)
        }
        .onAppear {
            if !model.selectedMachines.isEmpty { model.refreshRunningApps(model.selectedMachines) }
        }
        .confirmation($confirm)
    }

    // MARK: Bulk actions

    var bulkBox: some View {
        SectionBox(title: "Na wszystkich zaznaczonych", icon: "square.stack.3d.up") {
            HStack {
                TextField("Nazwa aplikacji, np. Safari lub Unity Hub", text: $appName)
                    .frame(minWidth: 260)
                Menu {
                    ForEach(knownAppNames, id: \.self) { name in
                        Button(name) { appName = name }
                    }
                    if knownAppNames.isEmpty {
                        Text("Użyj „Pobierz listę zainstalowanych”")
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Wybierz z aplikacji zainstalowanych na zaznaczonych komputerach")
                TextField("Argumenty (opcjonalnie)", text: $appArguments)
                    .frame(maxWidth: 200)
            }
            HStack {
                TargetButton(title: "Uruchom", icon: "play.fill") {
                    model.launchApp(appName, arguments: appArguments, on: model.selectedMachines)
                }
                .disabled(appName.isEmpty)
                TargetButton(title: "Zamknij", icon: "xmark.circle", prominent: false) {
                    model.quitApp(appName, force: false, on: model.selectedMachines)
                }
                .disabled(appName.isEmpty)
                TargetButton(title: "Wymuś zamknięcie", icon: "bolt.circle", role: .destructive, prominent: false) {
                    let name = appName
                    confirm = ConfirmRequest(
                        title: "Wymusić zamknięcie „\(name)”?",
                        message: "Aplikacja zostanie natychmiast zakończona (SIGKILL) na \(model.selection.count) komputerach. Niezapisane dane użytkownika przepadną.",
                        button: "Wymuś zamknięcie") {
                        model.quitApp(name, force: true, on: model.selectedMachines)
                    }
                }
                .disabled(appName.isEmpty)
            }
            HStack {
                TextField("Adres URL lub ścieżka pliku do otwarcia u użytkownika", text: $urlToOpen)
                TargetButton(title: "Otwórz", icon: "safari", prominent: false) {
                    model.openURL(urlToOpen, on: model.selectedMachines)
                }
                .disabled(urlToOpen.isEmpty)
            }
        }
    }

    var knownAppNames: [String] {
        let paths = model.selectedMachines.flatMap { model.installedApps[$0.id] ?? [] }
        let names = Set(paths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Running apps

    var runningBox: some View {
        SectionBox(title: "Uruchomione aplikacje", icon: "app.badge") {
            HStack {
                TargetButton(title: "Odśwież", icon: "arrow.clockwise", prominent: false) {
                    model.refreshRunningApps(model.selectedMachines)
                }
                Toggle("Pokaż procesy systemowe i agentów", isOn: $showSystem)
                Spacer()
            }
            if model.selectedMachines.isEmpty {
                Text("Zaznacz komputery, aby zobaczyć uruchomione aplikacje.").foregroundStyle(.secondary)
            }
            ForEach(model.selectedMachines) { m in
                RunningAppsList(machine: m, info: model.runningApps[m.id], showSystem: showSystem) { app, force in
                    if force {
                        confirm = ConfirmRequest(title: "Wymusić zamknięcie \(app.name)?",
                                                 message: "\(m.name): proces \(app.pid) zostanie zakończony natychmiast.",
                                                 button: "Wymuś zamknięcie") {
                            model.kill(app, on: m, force: true)
                        }
                    } else {
                        model.kill(app, on: m, force: false)
                    }
                }
            }
        }
    }

    // MARK: Installed apps

    var installedBox: some View {
        SectionBox(title: "Zainstalowane aplikacje", icon: "square.grid.3x3") {
            HStack {
                TargetButton(title: "Pobierz listę zainstalowanych", icon: "arrow.down.circle", prominent: false) {
                    model.refreshInstalledApps(model.selectedMachines)
                }
                Spacer()
            }
            let rows = installedRows
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.path) { row in
                        HStack {
                            Text(((row.path as NSString).lastPathComponent as NSString).deletingPathExtension)
                                .frame(width: 220, alignment: .leading)
                            Text(row.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("\(row.count)/\(model.selectedMachines.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(row.count == model.selectedMachines.count ? Color.secondary : Color.orange)
                                .help("Na ilu zaznaczonych komputerach jest zainstalowana")
                            Button("Uruchom") { model.launchApp(row.path, on: model.selectedMachines) }
                                .controlSize(.small)
                            if row.path.hasPrefix("/Applications/") {
                                Button("Odinstaluj") {
                                    confirm = ConfirmRequest(
                                        title: "Odinstalować \((row.path as NSString).lastPathComponent)?",
                                        message: "Pakiet aplikacji zostanie usunięty z \(model.selection.count) komputerów.",
                                        button: "Odinstaluj") {
                                        model.uninstall(row.path, on: model.selectedMachines)
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
        }
    }

    struct InstalledRow { let path: String; let count: Int }

    var installedRows: [InstalledRow] {
        var counts: [String: Int] = [:]
        for m in model.selectedMachines {
            for p in model.installedApps[m.id] ?? [] { counts[p, default: 0] += 1 }
        }
        return counts.map { InstalledRow(path: $0.key, count: $0.value) }
            .sorted { ($0.path as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }
    }
}

struct RunningAppsList: View {
    let machine: Machine
    let info: HostApps?
    let showSystem: Bool
    let onQuit: (RunningApp, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(machine.name).font(.headline)
                if let user = info?.user {
                    Label(user, systemImage: "person.fill").font(.caption).foregroundStyle(.secondary)
                }
                if let info { Text(info.updatedAt.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
            }
            if info == nil {
                Text("Ładowanie…").foregroundStyle(.secondary).font(.caption)
            } else if let error = info?.error {
                Text(error).foregroundStyle(.red).font(.caption)
            } else if info?.user == nil {
                Text("Nikt nie jest zalogowany.").foregroundStyle(.secondary).font(.caption)
            } else {
                let apps = (info?.apps ?? []).filter { showSystem || !$0.isSystem }
                if apps.isEmpty {
                    Text("Brak uruchomionych aplikacji.").foregroundStyle(.secondary).font(.caption)
                }
                ForEach(apps) { app in
                    HStack {
                        Image(systemName: app.isSystem ? "gearshape" : "app")
                            .foregroundStyle(.secondary)
                        Text(app.name).frame(width: 200, alignment: .leading)
                        Text("PID \(app.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(app.bundlePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Zamknij") { onQuit(app, false) }.controlSize(.small)
                        Button("Wymuś") { onQuit(app, true) }.controlSize(.small)
                    }
                }
            }
            Divider()
        }
    }
}
