import CMCRCore
import SwiftUI

/// A request to pick a folder on the iMacs (the destination of a push, the source of "Zbierz prace"…).
struct RemoteFolderRequest: Identifiable {
    enum Purpose { case pushDestination, collectSource, cleanFolder }

    let id = UUID()
    let purpose: Purpose
    let initialPath: String
    let onChoose: (String) -> Void

    var title: String {
        switch purpose {
        case .pushDestination: return "Do którego folderu wysłać pliki?"
        case .collectSource: return "Z którego folderu zebrać prace?"
        case .cleanFolder: return "Który folder uporządkować?"
        }
    }
}

/// Finder-like sheet for choosing a folder on the iMacs instead of typing its path.
struct RemoteFolderPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: RemoteFolderRequest
    @StateObject private var browser: RemoteBrowserModel
    @ViewState private var preferConsole = false
    @ViewState private var prompt: NamePrompt?
    /// Whether the chosen folder exists on each selected Mac.
    @ViewState private var presence: [UUID: FolderPresence] = [:]
    @ViewState private var presenceChecking = false

    init(app: AppModel, request: RemoteFolderRequest) {
        self.request = request
        _browser = StateObject(wrappedValue: RemoteBrowserModel(app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 265)
                Divider()
                content
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, idealWidth: 1020, minHeight: 580, idealHeight: 680)
        .onAppear {
            let start = request.initialPath.isEmpty ? RemotePaths.favorites(model.settings)[0].path : request.initialPath
            preferConsole = RemotePaths.usesConsoleUser(start)
            browser.open(start, on: browser.preferredHostID())
        }
        .onDisappear { browser.cancel() }
        .task(id: browser.isLoading ? "" : "\(chosenPath)|\(browser.asRoot)") { await checkPresence() }
        .namePrompt($prompt, folder: browser.path) { _, name in browser.makeFolder(named: name) }
    }

    // MARK: Parts

    var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            RemoteHostPicker(browser: browser, title: "Pokaż pliki z")
        }
        .padding(16)
    }

    var subtitle: String {
        guard model.selectedMachines.count > 1 else {
            return "Lista pokazuje foldery zaznaczonego komputera – inny komputer możesz wybrać obok."
        }
        return "Wybrany folder zostanie użyty na każdym zaznaczonym komputerze. Lista pokazuje zawartość jednego z nich – komputer możesz zmienić obok."
    }

    var sidebar: some View {
        let favorites = RemotePaths.favorites(model.settings)
        let favoritePaths = Set(favorites.map(\.path))
        let recents = model.files.prefs.recentRemoteFolders.filter { !favoritePaths.contains($0) }
        return List(selection: Binding<String?>(
            get: { browser.listing == nil ? nil : browser.portablePath(preferConsole: preferConsole) },
            set: { path in
                guard let path else { return }
                preferConsole = RemotePaths.usesConsoleUser(path)
                browser.open(path)
            })) {
            Section("Ulubione") {
                ForEach(favorites) { f in
                    Label(f.title, systemImage: f.icon)
                        .help(RemotePaths.display(f.path, settings: model.settings))
                        .tag(Optional(f.path))
                }
            }
            if !recents.isEmpty {
                Section("Ostatnio używane") {
                    ForEach(recents, id: \.self) { path in
                        Label(RemotePaths.friendlyName(path, settings: model.settings).title, systemImage: "clock")
                            .help(RemotePaths.display(path, settings: model.settings))
                            .tag(Optional(path))
                    }
                }
            }
            Section("Ten komputer") {
                Label("Dysk systemowy", systemImage: "internaldrive").tag(Optional("/"))
                Label("Wszyscy użytkownicy", systemImage: "person.2.crop.square.stack").tag(Optional("/Users"))
            }
        }
        .listStyle(.sidebar)
    }

    var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RemoteNavigationButtons(browser: browser)
                    .labelStyle(.iconOnly)
                Spacer(minLength: 8)
                Toggle(isOn: $browser.showHidden) {
                    Label("Ukryte pliki", systemImage: browser.showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                .help(browser.showHidden ? "Ukryj ukryte pliki i foldery" : "Pokaż ukryte pliki i foldery")
                Button {
                    prompt = NamePrompt(kind: .newFolder, text: "Nowy folder")
                } label: {
                    Label("Nowy folder", systemImage: "folder.badge.plus")
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser.listing == nil)
                .help("Utwórz nowy folder w tym miejscu na komputerze \(browser.host?.name ?? "—") (⇧⌘N)")
                SearchField(text: $browser.search, prompt: "Szukaj w tym folderze")
                    .frame(width: 210)
                    .accessibilityLabel("Szukaj w tym folderze")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            RemoteFileTable(browser: browser, foldersOnly: true, onOpen: { browser.enter($0) }) { ids in
                let entries = browser.listing?.entries.filter { ids.contains($0.id) } ?? []
                if entries.count == 1, let e = entries.first, e.isFolder {
                    Button { browser.enter(e) } label: { Label("Otwórz", systemImage: "folder") }
                    Button { choose(e) } label: { Label("Wybierz „\(e.displayName)”", systemImage: "checkmark.circle") }
                } else if ids.isEmpty {
                    Button { prompt = NamePrompt(kind: .newFolder, text: "Nowy folder") } label: {
                        Label("Nowy folder…", systemImage: "folder.badge.plus")
                    }
                    .disabled(browser.listing == nil)
                    Button { browser.reload() } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
                }
            }
            .overlay { RemoteBrowserStatus(browser: browser, emptyHint: "Możesz wybrać ten folder albo utworzyć w nim nowy.") }
            Divider()
            RemotePathBar(browser: browser)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wybrany folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RemoteFolderLabel(path: chosenPath, settings: model.settings)
                presenceLine
                    .font(.callout)
                    .padding(.top, 2)
            }
            Spacer(minLength: 12)
            if consoleApplies {
                Toggle("Zawsze folder zalogowanego użytkownika", isOn: $preferConsole)
                    .help("Na każdym komputerze zostanie użyty folder osoby, która jest akurat zalogowana ({console}).")
            }
            Button("Anuluj", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(chooseTitle) { choose(selectedFolder) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(browser.path.isEmpty || browser.isLoading)
                .help("Użyj tego folderu na wszystkich zaznaczonych komputerach")
        }
        .padding(16)
    }

    // MARK: Presence on the selected Macs

    @ViewBuilder var presenceLine: some View {
        let targets = model.selectedMachines
        if presenceChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sprawdzanie, czy ten folder jest na zaznaczonych komputerach (\(targets.count))…")
                    .foregroundStyle(.secondary)
            }
        } else if let summary = Self.presenceSummary(presence, targets: targets, purpose: request.purpose) {
            Label {
                Text(summary.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: summary.warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(summary.warning ? .orange : .green)
            }
            .help(summary.details)
        }
    }

    /// Checks the chosen folder on every selected Mac (only when more than one is selected).
    func checkPresence() async {
        presence = [:]
        let targets = model.selectedMachines
        let path = chosenPath
        guard targets.count > 1, !path.isEmpty, !browser.isLoading else {
            presenceChecking = false
            return
        }
        presenceChecking = true
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let resolved = model.settings.resolve(path)
        let root = browser.asRoot
        let settings = model.sshSettings
        let checks = targets.map { m in
            (machine: m, password: model.password(for: m), offline: model.status(m).reachability == .offline,
             handle: ProcessHandle())
        }
        let handles = checks.map(\.handle)
        let results = await withTaskCancellationHandler {
            await withTaskGroup(of: (UUID, FolderPresence).self, returning: [UUID: FolderPresence].self) { group in
                for c in checks {
                    group.addTask {
                        if c.offline { return (c.machine.id, .unreachable) }
                        let p = await Operations.folderPresence(resolved, on: c.machine,
                                                                asRoot: root && !(c.password ?? "").isEmpty,
                                                                password: c.password, settings: settings,
                                                                handle: c.handle)
                        return (c.machine.id, p)
                    }
                }
                var out: [UUID: FolderPresence] = [:]
                for await (id, p) in group { out[id] = p }
                return out
            }
        } onCancel: {
            handles.forEach { $0.cancel() }
        }
        guard !Task.isCancelled else { return }
        presence = results
        presenceChecking = false
    }

    struct PresenceSummary: Equatable {
        let text: String
        let details: String
        let warning: Bool
    }

    static func presenceSummary(_ results: [UUID: FolderPresence], targets: [Machine],
                                purpose: RemoteFolderRequest.Purpose) -> PresenceSummary? {
        guard !results.isEmpty else { return nil }
        func list(_ names: [String]) -> String {
            names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " i \(names.count - 5) innych" : "")
        }
        let checked = targets.filter { results[$0.id] != nil }
        let missing = checked.filter { results[$0.id] == .missing || results[$0.id] == .notFolder }.map(\.name)
        let unchecked = checked.filter {
            guard let p = results[$0.id] else { return false }
            return p != .exists && p != .missing && p != .notFolder
        }
        let details = checked.map { "\($0.name): \(results[$0.id]?.label ?? "")" }.joined(separator: "\n")
        if missing.isEmpty && unchecked.isEmpty {
            return PresenceSummary(text: "Ten folder jest na wszystkich zaznaczonych komputerach (\(checked.count)).",
                                   details: details, warning: false)
        }
        var parts: [String] = []
        if !missing.isEmpty {
            let consequence: String
            switch purpose {
            case .pushDestination: consequence = "zostanie utworzony podczas wysyłania"
            case .collectSource: consequence = "z tych komputerów nic nie zostanie zebrane"
            case .cleanFolder: consequence = "tam nie ma czego czyścić"
            }
            parts.append("Brak folderu na \(missing.count) z \(checked.count): \(list(missing)) – \(consequence).")
        }
        if !unchecked.isEmpty {
            let names = unchecked.map { m -> String in
                guard let p = results[m.id] else { return m.name }
                if case .failed = p { return "\(m.name) (błąd)" }
                return "\(m.name) (\(p.label))"
            }
            parts.append("Nie sprawdzono: \(list(names)).")
        }
        return PresenceSummary(text: parts.joined(separator: " "), details: details, warning: true)
    }

    // MARK: Choice

    var selectedFolder: RemoteEntry? {
        let s = browser.selectedEntries
        return s.count == 1 && s[0].isFolder ? s[0] : nil
    }

    var chooseTitle: String {
        if let f = selectedFolder { return "Wybierz „\(f.displayName)”" }
        return "Wybierz ten folder"
    }

    var consoleApplies: Bool {
        guard let c = browser.listing?.consoleUser else { return false }
        let home = "/Users/" + c
        return browser.path == home || browser.path.hasPrefix(home + "/")
    }

    var chosenPath: String {
        portable(selectedFolder.map { RemotePaths.join(browser.path, $0.name) } ?? browser.path)
    }

    func portable(_ path: String) -> String {
        RemotePaths.tokenize(path, studentUser: model.settings.studentUser, consoleUser: browser.listing?.consoleUser,
                             preferConsole: preferConsole && consoleApplies, adminHome: browser.listing?.adminHome)
    }

    func choose(_ entry: RemoteEntry?) {
        let path = portable(entry.map { RemotePaths.join(browser.path, $0.name) } ?? browser.path)
        guard !path.isEmpty else { return }
        model.files.rememberFolder(path)
        request.onChoose(path)
        dismiss()
    }
}
