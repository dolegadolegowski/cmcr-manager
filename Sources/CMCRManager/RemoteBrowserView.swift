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
            HStack(spacing: 10) {
                RemoteHostPicker(browser: browser)
                    .labelsHidden()
                Divider().frame(height: 18)
                RemotePathBar(browser: browser)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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
        .toolbar { toolbar }
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

    // MARK: Toolbar

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            RemoteNavigationButtons(browser: browser)
        }
        ToolbarItemGroup {
            Menu {
                ForEach(RemotePaths.favorites(model.settings)) { f in
                    Button { browser.open(f.path) } label: { Label(f.title, systemImage: f.icon) }
                }
                let recents = files.prefs.recentRemoteFolders
                if !recents.isEmpty {
                    Divider()
                    Section("Ostatnio używane") {
                        ForEach(recents, id: \.self) { path in
                            Button(RemotePaths.friendlyName(path, settings: model.settings).title) { browser.open(path) }
                        }
                    }
                }
            } label: {
                Label("Ulubione", systemImage: "star")
            }
            .help("Przejdź do często używanego folderu")
            Button {
                prompt = NamePrompt(kind: .newFolder, text: "Nowy folder")
            } label: {
                Label("Nowy folder", systemImage: "folder.badge.plus")
            }
            .disabled(browser.listing == nil)
            .help("Utwórz nowy folder w tym miejscu")
            Button {
                uploadWithPanel()
            } label: {
                Label("Wyślij tutaj…", systemImage: "arrow.up.doc")
            }
            .disabled(browser.listing == nil)
            .help("Wyślij pliki z tego Maca do bieżącego folderu (możesz też przeciągnąć je z Findera)")
            Button {
                download(browser.selectedEntries)
            } label: {
                Label("Pobierz", systemImage: "arrow.down.doc")
            }
            .disabled(browser.selection.isEmpty)
            .help("Pobierz zaznaczone elementy na ten Mac")
            Button(role: .destructive) {
                confirmDelete(browser.selectedEntries)
            } label: {
                Label("Usuń", systemImage: "trash")
            }
            .disabled(browser.selection.isEmpty)
            .help("Usuń zaznaczone elementy z iMaca (nie trafiają do Kosza)")
            Toggle(isOn: $browser.showHidden) {
                Label("Pokaż ukryte", systemImage: browser.showHidden ? "eye" : "eye.slash")
            }
            .help(browser.showHidden ? "Ukryj ukryte pliki i foldery" : "Pokaż ukryte pliki i foldery")
            Toggle(isOn: Binding(get: { browser.asRoot }, set: { browser.asRoot = $0; browser.reload() })) {
                Label("Jako administrator", systemImage: "lock.shield")
            }
            .help("Przeglądaj z uprawnieniami administratora (sudo) – także prywatne foldery użytkowników")
        }
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
                Text(notice.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Szczegóły") { model.section = .jobs }
                    .buttonStyle(.link)
                    .help("Pełny wynik w sekcji Zadania")
            } else {
                Text(summary)
            }
            Spacer(minLength: 8)
            if let l = browser.listing {
                if !l.writable && !browser.asRoot {
                    Label("Tylko do odczytu – zmiany przez sudo", systemImage: "lock")
                        .help("Konto administratora nie może tu zapisywać; nowe pliki i foldery zostaną utworzone przez sudo.")
                }
                Text("Właściciel: \(l.owner)")
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
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    var summary: String {
        guard let l = browser.listing else { return browser.isLoading ? "Wczytywanie…" : "" }
        let n = browser.visibleEntries.count
        var parts = ["\(n) \(Operations.plural(n, "element", "elementy", "elementów"))"]
        if browser.hiddenCount > 0 { parts.append("ukryte: \(browser.hiddenCount)") }
        if !browser.selection.isEmpty { parts.append("zaznaczono: \(browser.selection.count)") }
        if l.truncated { parts.append("pokazano \(l.entries.count) z \(l.total)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Menu & actions

    @ViewBuilder func contextMenu(_ ids: Set<RemoteEntry.ID>) -> some View {
        let entries = browser.listing?.entries.filter { ids.contains($0.id) } ?? []
        if entries.isEmpty {
            Button("Nowy folder…") { prompt = NamePrompt(kind: .newFolder, text: "Nowy folder") }
            Button("Wyślij tutaj pliki…") { uploadWithPanel() }
            Divider()
            Button("Odśwież") { browser.reload() }
        } else {
            if entries.count == 1, let e = entries.first, e.isFolder {
                Button("Otwórz") { browser.enter(e) }
                Button("Wyślij pliki do tego folderu…") { uploadWithPanel(into: e) }
                Button("Ustaw jako cel wysyłania (Pliki)") {
                    files.useDestination(browser.portablePathFor(e))
                    model.section = .files
                }
                Divider()
            }
            Button("Pobierz…") { download(entries) }
            if entries.count == 1, let e = entries.first {
                Button("Zmień nazwę…") { prompt = NamePrompt(kind: .rename(e), text: e.name) }
            }
            Button("Kopiuj ścieżkę") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entries.map { RemotePaths.join(browser.path, $0.name) }.joined(separator: "\n"),
                                               forType: .string)
            }
            Divider()
            Button("Usuń…", role: .destructive) { confirmDelete(entries) }
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Pobierz tutaj"
        panel.message = entries.count == 1
            ? "Gdzie zapisać „\(entries[0].displayName)” z \(browser.host?.name ?? "iMaca")?"
            : "Gdzie zapisać \(entries.count) elementów z \(browser.host?.name ?? "iMaca")?"
        panel.directoryURL = URL(fileURLWithPath: expandTilde(files.prefs.downloadFolder), isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        files.prefs.downloadFolder = (url.path as NSString).abbreviatingWithTildeInPath
        browser.download(entries, to: url)
    }

    func uploadWithPanel(into folder: RemoteEntry? = nil) {
        let target = folder.map { "„\($0.displayName)”" } ?? "bieżącego folderu"
        let urls = Pickers.files(message: "Wybierz pliki lub foldery do wysłania do \(target) na \(browser.host?.name ?? "iMacu").")
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
        confirm = ConfirmRequest(
            title: "Zastąpić istniejące elementy?",
            message: "W tym folderze na \(browser.host?.name ?? "iMacu") są już: \(names). Pliki o tych samych nazwach zostaną zastąpione, a do folderów zostanie dodana nowa zawartość.",
            button: "Zastąp") {
            browser.upload(urls)
        }
    }

    func confirmDelete(_ entries: [RemoteEntry]) {
        guard !entries.isEmpty else { return }
        let title = entries.count == 1
            ? "Usunąć „\(entries[0].displayName)”?"
            : "Usunąć \(entries.count) \(Operations.plural(entries.count, "element", "elementy", "elementów"))?"
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

extension RemoteBrowserModel {
    /// A subfolder of the current folder written with placeholders.
    func portablePathFor(_ entry: RemoteEntry) -> String {
        RemotePaths.tokenize(RemotePaths.join(path, entry.name), studentUser: app.settings.studentUser,
                             consoleUser: listing?.consoleUser, adminHome: listing?.adminHome)
    }
}
