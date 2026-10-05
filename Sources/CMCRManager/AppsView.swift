import AppKit
import CMCRCore
import SwiftUI

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var appName = ""
    @ViewState private var appArguments = ""
    @ViewState private var urlToOpen = ""
    @ViewState private var showSystem = false
    @ViewState private var installedFilter = ""
    @ViewState private var collapsed: Set<UUID> = []
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .apps,
                         subtitle: "Uruchamianie i zamykanie aplikacji u osoby zalogowanej przy komputerze, otwieranie stron i plików, lista zainstalowanych aplikacji.")
                .padding([.horizontal, .top], 20)
            Form {
                bulkSection
                openSection
                runningSection
                installedSection
                if let batch = model.lastBatch[.apps] {
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
        .onAppear {
            if !model.selectedMachines.isEmpty { model.refreshRunningApps(model.selectedMachines) }
        }
        .confirmation($confirm)
    }

    // MARK: Launch / quit on every selected Mac

    var bulkSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("Nazwa aplikacji", text: $appName, prompt: Text("np. Safari lub Unity Hub"))
                        .labelsHidden()
                    knownAppsMenu
                }
            } label: {
                Text("Aplikacja")
            }
            TextField(text: $appArguments, prompt: Text("opcjonalnie")) {
                Text("Argumenty")
                Text("Dodatkowe opcje uruchomienia, np. adres strony. Z argumentami otwiera się nowe okno aplikacji.")
            }
            .help("Argumenty jak w Terminalu – cudzysłowy grupują słowa. Z argumentami uruchamiana jest nowa instancja aplikacji.")
            HStack(spacing: 10) {
                TargetButton(title: "Wymuś zamknięcie", icon: "bolt.circle", role: .destructive, prominent: false) {
                    let name = appName
                    confirm = ConfirmRequest(
                        title: "Wymusić zamknięcie „\(name)”?",
                        message: "Aplikacja zostanie natychmiast zakończona \(Polish.onComputers(model.actionTargets.count)). Niezapisana praca uczniów przepadnie.",
                        button: "Wymuś zamknięcie") {
                        model.quitApp(name, force: true, on: model.selectedMachines)
                    }
                }
                .tint(.red)
                .disabled(appName.isEmpty)
                Spacer(minLength: 12)
                TargetButton(title: "Zamknij", icon: "xmark.circle", prominent: false) {
                    model.quitApp(appName, force: false, on: model.selectedMachines)
                }
                .disabled(appName.isEmpty)
                TargetButton(title: "Uruchom", icon: "play.fill") {
                    model.launchApp(appName, arguments: appArguments, on: model.selectedMachines)
                }
                .disabled(appName.isEmpty)
            }
        } header: {
            Label("Aplikacja na zaznaczonych komputerach", systemImage: "macwindow.on.rectangle")
        } footer: {
            Text("„Zamknij” działa jak polecenie Zakończ – aplikacja może zapytać o zapisanie zmian. „Wymuś zamknięcie” kończy ją od razu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var knownAppsMenu: some View {
        Menu {
            if knownAppNames.isEmpty {
                Text("Najpierw pobierz listę zainstalowanych aplikacji (niżej).")
            }
            ForEach(knownAppNames, id: \.self) { name in
                Button(name) { appName = name }
            }
        } label: {
            Label("Wybierz z listy", systemImage: "list.bullet")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Wybierz z aplikacji zainstalowanych na zaznaczonych komputerach")
    }

    var knownAppNames: [String] {
        let paths = model.selectedMachines.flatMap { model.installedApps[$0.id] ?? [] }
        let names = Set(paths.map(Self.appName))
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func appName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: Open a web page or a file

    var openSection: some View {
        Section {
            TextField("Adres lub plik", text: $urlToOpen, prompt: Text("https://… lub /Users/Shared/plik.pdf"))
            HStack {
                Text("Otworzy się u osoby zalogowanej, w aplikacji domyślnej dla tego adresu lub pliku.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                TargetButton(title: "Otwórz", icon: "arrow.up.forward.app") {
                    model.openURL(urlToOpen, on: model.selectedMachines)
                }
                .disabled(urlToOpen.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Label("Otwórz stronę internetową lub plik", systemImage: "safari")
        }
    }

    // MARK: Running apps

    var runningSection: some View {
        let groups = runningGroups
        return Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aplikacje otwarte przez zalogowanych użytkowników")
                    Text("Lista odświeża się sama po uruchomieniu lub zamknięciu aplikacji.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                TargetButton(title: "Odśwież listę", icon: "arrow.clockwise", prominent: false) {
                    model.refreshRunningApps(model.selectedMachines)
                }
            }
            Toggle(isOn: $showSystem) {
                Text("Pokaż także programy działające w tle")
                Text("Np. ikony na pasku menu i usługi systemowe.")
            }
            if model.selectedMachines.isEmpty {
                Label("Zaznacz komputery na liście, aby zobaczyć uruchomione aplikacje.", systemImage: "hand.point.left")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups.machines) { m in
                machineApps(m, info: model.runningApps[m.id])
            }
            ForEach(groups.notes, id: \.text) { note in
                noteRow(note)
            }
        } header: {
            Label("Uruchomione aplikacje", systemImage: "app.badge")
        }
    }

    struct MachineNote {
        let text: String
        let icon: String
        let color: Color
        let names: [String]
    }

    /// Macs with a list of apps get their own expandable row; the rest (loading, nobody logged in, errors) are
    /// summed up in one row per message, so fifteen identical "unreachable" lines do not drown the list.
    var runningGroups: (machines: [Machine], notes: [MachineNote]) {
        var machines: [Machine] = []
        var notes: [String: MachineNote] = [:]
        var order: [String] = []
        func add(_ text: String, _ icon: String, _ color: Color, _ m: Machine) {
            if let n = notes[text] {
                notes[text] = MachineNote(text: text, icon: icon, color: color, names: n.names + [m.name])
            } else {
                notes[text] = MachineNote(text: text, icon: icon, color: color, names: [m.name])
                order.append(text)
            }
        }
        for m in model.selectedMachines {
            guard let info = model.runningApps[m.id] else {
                add("Wczytywanie listy…", "hourglass", .secondary, m)
                continue
            }
            if let error = info.error {
                add(error, "exclamationmark.triangle.fill", .orange, m)
            } else if info.user == nil {
                add("Nikt nie jest zalogowany.", "person.crop.circle.badge.questionmark", .secondary, m)
            } else {
                machines.append(m)
            }
        }
        return (machines, order.compactMap { notes[$0] })
    }

    func noteRow(_ note: MachineNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: note.icon)
                .foregroundStyle(note.color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.names.joined(separator: ", "))
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text(note.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    func machineApps(_ m: Machine, info: HostApps?) -> some View {
        let apps = (info?.apps ?? []).filter { showSystem || !$0.isSystem }
        let expanded = Binding(get: { !collapsed.contains(m.id) },
                               set: { if $0 { collapsed.remove(m.id) } else { collapsed.insert(m.id) } })
        return DisclosureGroup(isExpanded: expanded) {
            if apps.isEmpty {
                Text("Brak otwartych aplikacji.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                RunningAppRow(app: app) { force in quit(app, on: m, force: force) }
                    .padding(.vertical, 2)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(m.name).fontWeight(.semibold)
                if let user = info?.user {
                    Label(user, systemImage: "person.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Zalogowany użytkownik: \(user)")
                }
                Spacer(minLength: 8)
                Text("\(Polish.count(apps.count, "aplikacja", "aplikacje", "aplikacji"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let info {
                    Text(info.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Stan z godziny \(info.updatedAt.formatted(date: .omitted, time: .standard))")
                }
            }
        }
    }

    func quit(_ app: RunningApp, on m: Machine, force: Bool) {
        guard force else {
            model.kill(app, on: m, force: false)
            return
        }
        confirm = ConfirmRequest(title: "Wymusić zamknięcie „\(app.name)”?",
                                 message: "Na komputerze \(m.name) aplikacja zostanie zakończona natychmiast – niezapisana praca przepadnie.",
                                 button: "Wymuś zamknięcie", targets: [m]) {
            model.kill(app, on: m, force: true)
        }
    }

    // MARK: Installed apps

    var installedSection: some View {
        let checked = model.selectedMachines.filter { model.installedApps[$0.id] != nil }.count
        let rows = installedRows
        let filter = installedFilter.trimmingCharacters(in: .whitespaces)
        let shown = filter.isEmpty ? rows : rows.filter { Self.appName($0.path).localizedStandardContains(filter) }
        return Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aplikacje w folderach Programy")
                    Text(checked == 0
                         ? "Pobierz listę, aby zobaczyć, na ilu komputerach jest każda aplikacja."
                         : "Sprawdzono \(Polish.computers(checked)). Pomarańczowa liczba – aplikacji brakuje na części z nich.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                TargetButton(title: checked == 0 ? "Pobierz listę" : "Odśwież listę",
                             icon: "arrow.down.circle", prominent: false) {
                    model.refreshInstalledApps(model.selectedMachines)
                }
            }
            if !rows.isEmpty {
                SearchField(text: $installedFilter, prompt: "Szukaj aplikacji")
                    .accessibilityLabel("Szukaj aplikacji")
                if shown.isEmpty {
                    Text("Żadna aplikacja nie pasuje do „\(filter)”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.path) { row in
                    installedRow(row, checked: checked)
                }
            }
        } header: {
            Label("Zainstalowane aplikacje", systemImage: "square.grid.3x3")
        }
    }

    func installedRow(_ row: InstalledRow, checked: Int) -> some View {
        let name = Self.appName(row.path)
        return HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(forBundlePath: row.path))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(row.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("na \(row.count) z \(checked)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.count == checked ? Color.secondary : Color.orange)
                .fixedSize()
                .help("Zainstalowana \(Polish.onComputers(row.count)) z \(checked) sprawdzonych")
            Button {
                model.launchApp(row.path, on: model.selectedMachines)
            } label: {
                Label("Uruchom", systemImage: "play.fill")
            }
            .controlSize(.small)
            .help("Uruchom \(name) na zaznaczonych komputerach")
            if row.path.hasPrefix("/Applications/") {
                Button(role: .destructive) {
                    confirm = ConfirmRequest(
                        title: "Odinstalować \(name)?",
                        message: "Aplikacja \((row.path as NSString).lastPathComponent) zostanie usunięta z \(Polish.ofComputers(model.actionTargets.count)).",
                        button: "Odinstaluj") {
                        model.uninstall(row.path, on: model.selectedMachines)
                    }
                } label: {
                    Label("Odinstaluj…", systemImage: "trash")
                }
                .controlSize(.small)
                .help("Usuń \(name) z folderu Programy na zaznaczonych komputerach (z potwierdzeniem)")
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

/// One app open on a Mac: icon, name, process number and the quit buttons.
struct RunningAppRow: View {
    let app: RunningApp
    let onQuit: (_ force: Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(forBundlePath: app.bundlePath))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.bundlePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Proces nr \(app.pid): \(app.bundlePath)")
            }
            Spacer(minLength: 8)
            Button {
                onQuit(false)
            } label: {
                Label("Zamknij", systemImage: "xmark.circle")
            }
            .controlSize(.small)
            .help("Zamknij \(app.name) – aplikacja może zapytać o zapisanie zmian")
            Button(role: .destructive) {
                onQuit(true)
            } label: {
                Label("Wymuś", systemImage: "bolt.circle")
            }
            .controlSize(.small)
            .help("Wymuś zamknięcie \(app.name) od razu (z potwierdzeniem) – niezapisane zmiany przepadną")
        }
        .accessibilityElement(children: .contain)
    }
}

/// Icons of apps on the iMacs, taken from the same app on this Mac when it has one (cached).
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundlePath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .applicationBundle)
        cache[path] = image
        return image
    }
}
