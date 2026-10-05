import AppKit
import CMCRCore
import SwiftUI

/// "Przeglądarka plików": Finder-like browsing of one iMac – download, upload by drag & drop, new folder,
/// rename and delete.
struct RemoteBrowserView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        RemoteBrowserPage(browser: model.files.browser, files: model.files)
    }
}

private struct RemoteBrowserPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var browser: RemoteBrowserModel
    @ObservedObject var files: FilesState
    @ViewState private var confirm: ConfirmRequest?
    @ViewState private var prompt: NamePrompt?
    @ViewState private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            locationBar
            Divider()
            RemoteFileTable(browser: browser, onOpen: open) { ids in contextMenu(ids) }
                .overlay { RemoteBrowserStatus(browser: browser) }
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(3)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let local = urls.filter(\.isFileURL)
                    guard browser.listing != nil, !local.isEmpty else { return false }
                    startUpload(local)
                    return true
                } isTargeted: { dropTargeted = $0 && browser.listing != nil }
                .onDeleteCommand { confirmDelete(browser.selectedEntries) }
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                RemoteNavigationButtons(browser: browser)
            }
        }
        .searchable(text: $browser.search, placement: .toolbar, prompt: "Szukaj w tym folderze")
        .navigationSubtitle(browser.host.map { "\($0.name) — \(browser.path)" } ?? "")
        .confirmation($confirm)
        .namePrompt($prompt, folder: browser.path) { p, name in
            switch p.kind {
            case .newFolder: browser.makeFolder(named: name)
            case .rename(let e): browser.rename(e, to: name)
            }
        }
        .onAppear {
            if browser.path.isEmpty {
                browser.open(RemotePaths.favorites(model.settings)[0].path, on: browser.preferredHostID())
            }
        }
        .onChange(of: model.selection) { _, _ in
            // Clicking a single Mac in the list shows the same folder on that Mac.
            let selected = model.selectedMachines
            if selected.count == 1, selected[0].id != browser.hostID { browser.setHost(selected[0].id) }
        }
    }

    // MARK: Location and actions

    /// Which Mac and folder are shown, and what can be done here. In a narrow window the view toggles show
    /// only their icons.
    var locationBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RemoteHostPicker(browser: browser)
                    .labelsHidden()
                favoritesMenu
                Divider().frame(height: 18)
                RemotePathBar(browser: browser)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    prompt = NamePrompt(kind: .newFolder, text: "Nowy folder")
                } label: {
                    Label("Nowy folder", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser.listing == nil)
                .help("Utwórz nowy folder w tym miejscu (⇧⌘N)")
                .fixedSize()
                Button {
                    download(browser.selectedEntries)
                } label: {
                    Label("Pobierz…", systemImage: "arrow.down.doc")
                }
                .disabled(browser.selection.isEmpty)
                .help("Pobierz zaznaczone elementy na ten Mac")
                .fixedSize()
                Button(role: .destructive) {
                    confirmDelete(browser.selectedEntries)
                } label: {
                    Label("Usuń…", systemImage: "trash")
                }
                .disabled(browser.selection.isEmpty)
                .help("Usuń zaznaczone elementy z komputera – nie trafią do Kosza (z potwierdzeniem; także klawisz Delete)")
                .fixedSize()
                Button {
                    uploadWithPanel()
                } label: {
                    Label("Wyślij tutaj…", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(browser.listing == nil)
                .help("Wyślij pliki z tego Maca do bieżącego folderu (możesz też przeciągnąć je z Findera)")
                .fixedSize()
                Spacer(minLength: 12)
                ViewThatFits(in: .horizontal) {
                    viewToggles(iconOnly: false)
                    viewToggles(iconOnly: true)
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    func viewToggles(iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: $browser.showHidden) {
                Label("Ukryte pliki", systemImage: browser.showHidden ? "eye" : "eye.slash")
                    .labelStyle(TitleOrIconLabelStyle(iconOnly: iconOnly))
            }
            .toggleStyle(.button)
            .help(browser.showHidden ? "Ukryj ukryte pliki i foldery" : "Pokaż ukryte pliki i foldery")
            Toggle(isOn: Binding(get: { browser.asRoot }, set: { browser.asRoot = $0; browser.reload() })) {
                Label("Jako administrator", systemImage: "lock.shield")
                    .labelStyle(TitleOrIconLabelStyle(iconOnly: iconOnly))
            }
            .toggleStyle(.button)
            .help("Przeglądaj z uprawnieniami administratora (sudo) – także prywatne foldery użytkowników")
        }
        .fixedSize()
    }

    var favoritesMenu: some View {
        Menu {
            ForEach(RemotePaths.favorites(model.settings)) { f in
                Button { browser.open(f.path) } label: { Label(f.title, systemImage: f.icon) }
            }
            let recents = files.prefs.recentRemoteFolders
            if !recents.isEmpty {
                Divider()
                Section("Ostatnio używane") {
                    ForEach(recents, id: \.self) { path in
                        Button { browser.open(path) } label: {
                            Label(RemotePaths.friendlyName(path, settings: model.settings).title, systemImage: "clock")
                        }
                    }
                }
            }
        } label: {
            Label("Ulubione", systemImage: "star")
        }
        .fixedSize()
        .help("Przejdź do często używanego folderu")
    }

    // MARK: Status bar

    var statusBar: some View {
        HStack(spacing: 8) {
            if let activity = browser.activity {
                ProgressView().controlSize(.small)
                Text(activity)
            } else if let notice = browser.notice {
                Image(systemName: notice.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isError ? .red : .green)
                    .accessibilityHidden(true)
                Text(notice.text)
                    .truncationMode(.middle)
                Button("Szczegóły") { model.section = .jobs }
                    .buttonStyle(.link)
                    .help("Pełny wynik w dziale Zadania")
            } else {
                Text(summary)
            }
            Spacer(minLength: 8)
            if let l = browser.listing {
                if !l.writable && !browser.asRoot {
                    Label("Tylko do odczytu", systemImage: "lock")
                        .help("Konto administratora nie może tu zapisywać; nowe pliki i foldery zostaną utworzone z uprawnieniami administratora (sudo).")
                }
                Text("Właściciel: \(l.owner)")
                    .help("Właściciel tego folderu na komputerze")
            }
            if browser.isLoading && browser.listing != nil {
                ProgressView().controlSize(.small)
            }
            Button {
                browser.reload()
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(browser.path.isEmpty)
            .help("Wczytaj folder ponownie")
        }
        .lineLimit(1)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    var summary: String {
        guard let l = browser.listing else { return browser.isLoading ? "Wczytywanie…" : "" }
        let n = browser.visibleEntries.count
        var parts = [Polish.count(n, "element", "elementy", "elementów")]
        if browser.hiddenCount > 0 { parts.append("ukryte: \(browser.hiddenCount)") }
        if !browser.selection.isEmpty { parts.append("zaznaczono: \(browser.selection.count)") }
        if l.truncated { parts.append("pokazano \(l.entries.count) z \(l.total)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Menu & actions

    @ViewBuilder func contextMenu(_ ids: Set<RemoteEntry.ID>) -> some View {
        let entries = browser.listing?.entries.filter { ids.contains($0.id) } ?? []
        if entries.isEmpty {
            Button { prompt = NamePrompt(kind: .newFolder, text: "Nowy folder") } label: {
                Label("Nowy folder…", systemImage: "folder.badge.plus")
            }
            Button { uploadWithPanel() } label: { Label("Wyślij tutaj pliki…", systemImage: "arrow.up.doc") }
            Divider()
            Button { browser.reload() } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
        } else {
            if entries.count == 1, let e = entries.first, e.isFolder {
                Button { browser.enter(e) } label: { Label("Otwórz", systemImage: "folder") }
                Button { uploadWithPanel(into: e) } label: {
                    Label("Wyślij pliki do tego folderu…", systemImage: "arrow.up.doc")
                }
                Button {
                    files.useDestination(browser.portablePathFor(e))
                    model.section = .files
                } label: {
                    Label("Ustaw jako cel wysyłania (Pliki)", systemImage: "paperplane")
                }
                Divider()
            }
            Button { download(entries) } label: { Label("Pobierz…", systemImage: "arrow.down.doc") }
            if entries.count == 1, let e = entries.first {
                Button { prompt = NamePrompt(kind: .rename(e), text: e.name) } label: {
                    Label("Zmień nazwę…", systemImage: "pencil")
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entries.map { RemotePaths.join(browser.path, $0.name) }.joined(separator: "\n"),
                                               forType: .string)
            } label: {
                Label("Kopiuj ścieżkę", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) { confirmDelete(entries) } label: { Label("Usuń…", systemImage: "trash") }
        }
    }

    func open(_ entry: RemoteEntry) {
        if entry.isFolder {
            browser.enter(entry)
        } else {
            download([entry])
        }
    }

    func download(_ entries: [RemoteEntry]) {
        guard !entries.isEmpty else { return }
        let source = browser.host.map { "z komputera \($0.name)" } ?? "z komputera"
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Pobierz tutaj"
        panel.message = entries.count == 1
            ? "Gdzie zapisać „\(entries[0].displayName)” \(source)?"
            : "Gdzie zapisać \(Polish.count(entries.count, "element", "elementy", "elementów")) \(source)?"
        panel.directoryURL = URL(fileURLWithPath: expandTilde(files.prefs.downloadFolder), isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        files.prefs.downloadFolder = (url.path as NSString).abbreviatingWithTildeInPath
        browser.download(entries, to: url)
    }

    func uploadWithPanel(into folder: RemoteEntry? = nil) {
        let target = folder.map { "„\($0.displayName)”" } ?? "bieżącego folderu"
        let host = browser.host.map { " na komputerze \($0.name)" } ?? ""
        let urls = Pickers.files(message: "Wybierz pliki lub foldery do wysłania do \(target)\(host).")
        guard !urls.isEmpty else { return }
        if let folder { browser.upload(urls, into: folder) } else { startUpload(urls) }
    }

    func startUpload(_ urls: [URL]) {
        let conflicts = browser.conflicts(for: urls)
        guard !conflicts.isEmpty else {
            browser.upload(urls)
            return
        }
        let names = conflicts.prefix(5).map { "„\($0)”" }.joined(separator: ", ") + (conflicts.count > 5 ? "…" : "")
        let host = browser.host.map { " na komputerze \($0.name)" } ?? ""
        confirm = ConfirmRequest(
            title: "Zastąpić istniejące elementy?",
            message: "W tym folderze\(host) są już: \(names). Pliki o tych samych nazwach zostaną zastąpione, a do folderów zostanie dodana nowa zawartość.",
            button: "Zastąp") {
            browser.upload(urls)
        }
    }

    func confirmDelete(_ entries: [RemoteEntry]) {
        guard !entries.isEmpty else { return }
        let title = entries.count == 1
            ? "Usunąć „\(entries[0].displayName)”?"
            : "Usunąć \(Polish.count(entries.count, "element", "elementy", "elementów"))?"
        let place = "z komputera \(browser.host?.name ?? "") (\(browser.path))"
        let message: String
        if entries.count == 1 {
            message = "Element zostanie trwale usunięty \(place). Nie trafi do Kosza – tej operacji nie można cofnąć."
        } else {
            let names = entries.prefix(5).map { "„\($0.displayName)”" }.joined(separator: ", ")
                + (entries.count > 5 ? " i \(entries.count - 5) innych" : "")
            message = "Zostaną trwale usunięte \(place): \(names). Nie trafią do Kosza – tej operacji nie można cofnąć."
        }
        confirm = ConfirmRequest(title: title, message: message, button: "Usuń") {
            browser.delete(entries)
        }
    }
}

/// Title and icon, or only the icon when space is short (the title stays as the accessibility label).
struct TitleOrIconLabelStyle: LabelStyle {
    var iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

extension RemoteBrowserModel {
    /// A subfolder of the current folder written with placeholders.
    func portablePathFor(_ entry: RemoteEntry) -> String {
        RemotePaths.tokenize(RemotePaths.join(path, entry.name), studentUser: app.settings.studentUser,
                             consoleUser: listing?.consoleUser, adminHome: listing?.adminHome)
    }
}
