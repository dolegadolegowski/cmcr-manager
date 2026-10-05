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
        case .cleanFolder: return "Wybierz folder na iMacach"
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
                    .frame(width: 230)
                Divider()
                content
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 560, idealHeight: 660)
        .onAppear {
            let start = request.initialPath.isEmpty ? RemotePaths.favorites(model.settings)[0].path : request.initialPath
            preferConsole = RemotePaths.usesConsoleUser(start)
            browser.open(start, on: browser.preferredHostID())
        }
        .onDisappear { browser.cancel() }
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
        let count = model.selectedMachines.count
        let targets = count > 1 ? "na wszystkich zaznaczonych komputerach (\(count))" : "na zaznaczonych komputerach"
        return "Wybrany folder zostanie użyty \(targets). Lista pokazuje zawartość jednego z nich – możesz go zmienić obok."
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
                RemotePathBar(browser: browser)
                Spacer(minLength: 8)
                Toggle(isOn: $browser.showHidden) {
                    Label("Pokaż ukryte", systemImage: browser.showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(browser.showHidden ? "Ukryj ukryte pliki i foldery" : "Pokaż ukryte pliki i foldery")
                Button {
                    prompt = NamePrompt(kind: .newFolder, text: "Nowy folder")
                } label: {
                    Label("Nowy folder", systemImage: "folder.badge.plus")
                }
                .disabled(browser.listing == nil)
                .help("Utwórz nowy folder w tym miejscu (na komputerze \(browser.host?.name ?? "—"))")
                SearchField(text: $browser.search, prompt: "Szukaj")
                    .frame(width: 150)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            RemoteFileTable(browser: browser, foldersOnly: true, onOpen: { browser.enter($0) }) { ids in
                let entries = browser.listing?.entries.filter { ids.contains($0.id) } ?? []
                if entries.count == 1, let e = entries.first, e.isFolder {
                    Button("Otwórz") { browser.enter(e) }
                    Button("Wybierz „\(e.displayName)”") { choose(e) }
                } else if ids.isEmpty {
                    Button("Nowy folder…") { prompt = NamePrompt(kind: .newFolder, text: "Nowy folder") }
                        .disabled(browser.listing == nil)
                    Button("Odśwież") { browser.reload() }
                }
            }
            .overlay { RemoteBrowserStatus(browser: browser, emptyHint: "Możesz wybrać ten folder albo utworzyć w nim nowy.") }
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            RemoteFolderLabel(path: chosenPath, settings: model.settings)
            Spacer(minLength: 12)
            if consoleApplies {
                Toggle("Zawsze folder zalogowanego użytkownika", isOn: $preferConsole)
                    .help("Na każdym iMacu zostanie użyty folder osoby, która jest akurat zalogowana ({console}).")
            }
            Button("Anuluj", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(chooseTitle) { choose(selectedFolder) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(browser.path.isEmpty || browser.isLoading)
        }
        .padding(16)
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
