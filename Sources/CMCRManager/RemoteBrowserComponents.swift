import AppKit
import CMCRCore
import SwiftUI
import UniformTypeIdentifiers

extension RemoteEntry {
    /// Name safe for a single line (newlines and tabs made visible).
    var displayName: String {
        name.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
    }

    var contentType: UTType {
        if isPackage { return fileExtension == "app" ? .applicationBundle : (UTType(filenameExtension: fileExtension) ?? .package) }
        if isFolder { return .folder }
        if kind == .other { return .item }
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    /// Finder-like "Rodzaj" column (in Polish regardless of the system's language).
    var kindDescription: String {
        if kind == .symlink { return pointsToDirectory && !isPackage ? "Dowiązanie do folderu" : "Dowiązanie" }
        if isFolder { return "Folder" }
        if kind == .other { return "Plik specjalny" }
        let t = contentType
        let ext = fileExtension.uppercased()
        let kinds: [(UTType, String)] = [
            (.applicationBundle, "Aplikacja"), (.image, "Obraz \(ext)"), (.movie, "Film"), (.audio, "Dźwięk"),
            (.pdf, "Dokument PDF"), (.spreadsheet, "Arkusz kalkulacyjny"), (.presentation, "Prezentacja"),
            (.shellScript, "Skrypt"), (.sourceCode, "Kod źródłowy"), (.html, "Strona internetowa"),
            (.plainText, "Dokument tekstowy"), (.rtf, "Dokument RTF"), (.json, "Dane JSON"),
            (.diskImage, "Obraz dysku"), (.archive, "Archiwum"), (.font, "Czcionka"),
            (.unixExecutable, "Program"), (.bundle, "Pakiet"),
        ]
        if let match = kinds.first(where: { t.conforms(to: $0.0) }) { return match.1 }
        if ["DOC", "DOCX", "PAGES", "ODT"].contains(ext) { return "Dokument tekstowy" }
        if ["PKG", "MPKG"].contains(ext) { return "Pakiet instalacyjny" }
        return ext.isEmpty ? "Dokument" : "Dokument \(ext)"
    }

    var sizeText: String {
        kind == .file ? size.formatted(.byteCount(style: .file)) : "—"
    }
}

/// Finder icons for remote entries (by content type, cached).
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: RemoteEntry) -> NSImage {
        let type = entry.contentType
        if let cached = cache[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = image
        return image
    }
}

extension RemotePaths {
    /// The placeholder path written for people: `/Users/{student}/Desktop` → `/Users/student/Desktop`,
    /// `{console}` → `‹zalogowany użytkownik›`, `~` → `‹katalog administratora›`.
    static func display(_ path: String, settings: AppSettings) -> String {
        var p = resolveLocal(path, studentUser: settings.studentUser)
            .replacingOccurrences(of: "{console}", with: "‹zalogowany użytkownik›")
        if p == "~" || p.hasPrefix("~/") { p = "‹katalog administratora›" + p.dropFirst() }
        return p
    }
}

/// Icon, friendly name and path of a remote folder (`Biurko ucznia › Projekty` + `/Users/student/Desktop/Projekty`).
struct RemoteFolderLabel: View {
    let path: String
    let settings: AppSettings
    var large = true

    var body: some View {
        let f = RemotePaths.friendlyName(path, settings: settings)
        HStack(spacing: 10) {
            Image(systemName: f.icon)
                .font(large ? .title2 : .body)
                .foregroundStyle(.tint)
                .frame(width: large ? 30 : 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title)
                    .font(large ? .headline : .body)
                    .lineLimit(2)
                Text(path.isEmpty ? "—" : RemotePaths.display(path, settings: settings))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .help(path)
    }
}

/// One cell of the name column: Finder icon, name, link badge; hidden items are dimmed like in Finder.
struct RemoteEntryLabel: View {
    let entry: RemoteEntry
    var dimmed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: entry))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            if let target = entry.linkTarget {
                Image(systemName: "arrow.turn.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Dowiązanie do: \(target)")
            }
        }
        .opacity(entry.isHidden || dimmed ? 0.5 : 1)
        .help(entry.name)
    }
}

/// Finder-like list of a remote folder.
struct RemoteFileTable<Menu: View>: View {
    @ObservedObject var browser: RemoteBrowserModel
    /// Folder picker: files are shown dimmed, only folders matter.
    var foldersOnly = false
    let onOpen: (RemoteEntry) -> Void
    @ViewBuilder let menu: (Set<RemoteEntry.ID>) -> Menu

    var body: some View {
        Table(browser.visibleEntries, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Nazwa", value: \.name, comparator: .localizedStandard) { e in
                RemoteEntryLabel(entry: e, dimmed: foldersOnly && !e.isFolder)
            }
            .width(min: 150, ideal: 230)
            TableColumn("Data modyfikacji", value: \.modified) { e in
                Text(e.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Rozmiar", value: \.size) { e in
                Text(e.sizeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 55, ideal: 70)
            TableColumn("Rodzaj", value: \.kindDescription) { e in
                Text(e.kindDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Właściciel", value: \.owner) { e in
                Text(e.owner)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
            menu(ids)
        } primaryAction: { ids in
            guard ids.count == 1, let e = browser.listing?.entries.first(where: { ids.contains($0.id) }) else { return }
            onOpen(e)
        }
    }
}

/// Breadcrumbs of the current folder (`imac04 › Users › student › Desktop`), each one clickable. Deep paths
/// keep the Mac, the last three folders and an "…" menu with the ones in between.
struct RemotePathBar: View {
    @ObservedObject var browser: RemoteBrowserModel

    var body: some View {
        let crumbs = RemotePaths.breadcrumbs(browser.path)
        let collapsed = crumbs.count > 5 ? Array(crumbs[1..<(crumbs.count - 3)]) : []
        let shown = collapsed.isEmpty ? crumbs : [crumbs[0]] + crumbs.suffix(3)
        HStack(spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    separator
                }
                if index == 1 && !collapsed.isEmpty {
                    Menu {
                        ForEach(collapsed.reversed(), id: \.path) { c in
                            Button { browser.open(c.path) } label: { Label(c.name, systemImage: "folder") }
                        }
                    } label: {
                        Text("…")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(collapsed.map(\.name).joined(separator: " › "))
                    separator
                }
                crumbButton(crumb, isRoot: crumb.path == "/", isLast: index == shown.count - 1)
            }
        }
        .lineLimit(1)
    }

    var separator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    func crumbButton(_ crumb: (name: String, path: String), isRoot: Bool, isLast: Bool) -> some View {
        let label = Label(isRoot ? (browser.host?.name ?? "Dysk") : crumb.name,
                          systemImage: isRoot ? "desktopcomputer" : "folder")
            .labelStyle(.titleAndIcon)
            .truncationMode(.middle)
        let help = isRoot ? "Dysk systemowy komputera \(browser.host?.name ?? "")" : crumb.path
        if isLast {
            label
                .fontWeight(.semibold)
                .layoutPriority(1)
                .help(help)
        } else {
            Button { browser.open(crumb.path) } label: { label }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help(help)
        }
    }
}

/// Back / forward / up buttons.
struct RemoteNavigationButtons: View {
    @ObservedObject var browser: RemoteBrowserModel

    var body: some View {
        ControlGroup {
            Button { browser.goBack() } label: { Label("Wstecz", systemImage: "chevron.left") }
                .disabled(!browser.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Poprzedni folder (⌘[)")
            Button { browser.goForward() } label: { Label("Dalej", systemImage: "chevron.right") }
                .disabled(!browser.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Następny folder (⌘])")
        }
        .controlGroupStyle(.navigation)
        .fixedSize()
        Button { browser.goUp() } label: { Label("Folder nadrzędny", systemImage: "arrow.up") }
            .disabled(!browser.canGoUp)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Przejdź do folderu nadrzędnego (⌘↑)")
    }
}

/// Picker of the Mac to browse (status shown next to the name).
struct RemoteHostPicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var browser: RemoteBrowserModel
    var title = "Komputer"

    var body: some View {
        Picker(title, selection: Binding(get: { browser.hostID }, set: { browser.setHost($0) })) {
            ForEach(model.machines) { m in
                let st = model.status(m).reachability
                Text(st == .online || st == .unknown || st == .checking ? m.name : "\(m.name) (\(st.label))")
                    .tag(Optional(m.id))
            }
        }
        .fixedSize()
        .help("Komputer, którego pliki są pokazywane")
    }
}

/// Loading, error and empty states shown over the file list.
struct RemoteBrowserStatus: View {
    @ObservedObject var browser: RemoteBrowserModel
    var emptyHint = "Przeciągnij tutaj pliki z Findera, aby je wysłać."

    var body: some View {
        switch browser.phase {
        case .idle where browser.host == nil:
            ContentUnavailableView("Brak komputerów", systemImage: "desktopcomputer",
                                   description: Text("Dodaj komputery w Konfiguracji."))
        case .loading where browser.listing == nil:
            ProgressView("Wczytywanie zawartości folderu…")
        case .failed(let error):
            RemoteBrowseErrorView(error: error, browser: browser)
        case .loaded where browser.visibleEntries.isEmpty:
            if !browser.search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: browser.search)
            } else {
                ContentUnavailableView {
                    Label("Folder jest pusty", systemImage: "folder")
                } description: {
                    Text(browser.hiddenCount > 0
                         ? "Ukryte elementy: \(browser.hiddenCount). \(emptyHint)"
                         : emptyHint)
                } actions: {
                    if browser.hiddenCount > 0 {
                        Button("Pokaż ukryte") { browser.showHidden = true }
                    }
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Explains why a folder could not be shown and offers the fix.
struct RemoteBrowseErrorView: View {
    @EnvironmentObject var model: AppModel
    let error: RemoteBrowseError
    @ObservedObject var browser: RemoteBrowserModel

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(description)
        } actions: {
            HStack {
                switch error {
                case .accessDenied where !browser.asRoot:
                    Button("Otwórz jako administrator") {
                        browser.asRoot = true
                        browser.reload()
                    }
                    .buttonStyle(.borderedProminent)
                case .notFound, .notDirectory:
                    if browser.canGoUp {
                        Button("Przejdź do folderu nadrzędnego") { browser.goUp() }
                    }
                case .noConsoleUser:
                    Button("Pokaż Biurko ucznia") { browser.open(RemotePaths.student + "/Desktop") }
                case .authentication:
                    Button("Otwórz Konfigurację") { model.section = .setup }
                default:
                    EmptyView()
                }
                Button("Spróbuj ponownie") { browser.reload() }
            }
        }
    }

    var title: String {
        switch error {
        case .notFound: return "Folder nie istnieje"
        case .notDirectory: return "To nie jest folder"
        case .accessDenied: return "Brak dostępu do folderu"
        case .privacyDenied: return "macOS blokuje dostęp do tego folderu"
        case .noConsoleUser: return "Nikt nie jest zalogowany"
        case .unreachable: return "Komputer jest niedostępny"
        case .authentication: return "Nie można się zalogować"
        default: return "Nie udało się wczytać folderu"
        }
    }

    var icon: String {
        switch error {
        case .notFound: return "questionmark.folder"
        case .notDirectory: return "doc"
        case .accessDenied: return "lock"
        case .privacyDenied: return "hand.raised"
        case .noConsoleUser: return "person.crop.circle.badge.questionmark"
        case .unreachable: return "wifi.slash"
        case .authentication: return "key"
        default: return "exclamationmark.triangle"
        }
    }

    var description: String {
        let message = error.localizedDescription
        switch error {
        case .accessDenied:
            return browser.asRoot
                ? message
                : "Konto administratora nie ma uprawnień do tego folderu. Można go otworzyć z uprawnieniami administratora (sudo)."
        case .privacyDenied:
            return "Biurko, Dokumenty i Pobrane są chronione przez macOS. Na tym iMacu włącz: Ustawienia systemowe › Ogólne › Udostępnianie › Zdalne logowanie (ⓘ) › „Zezwalaj zdalnym użytkownikom na pełny dostęp do dysku”."
        case .noConsoleUser:
            return "Folder zalogowanego użytkownika jest dostępny tylko wtedy, gdy ktoś jest zalogowany na tym Macu."
        default:
            return message
        }
    }
}

/// Native search field (for sheets, where `.searchable` has no toolbar to live in).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
    }
}

/// Text prompt for a new folder or a new name.
struct NamePrompt: Identifiable {
    enum Kind { case newFolder, rename(RemoteEntry) }
    let id = UUID()
    let kind: Kind
    var text: String
}

extension View {
    /// Alert with a text field used for "Nowy folder" and "Zmień nazwę".
    func namePrompt(_ prompt: Binding<NamePrompt?>, folder: String,
                    onCommit: @escaping (NamePrompt, String) -> Void) -> some View {
        let isNew: Bool = { if case .newFolder = prompt.wrappedValue?.kind { return true } else { return false } }()
        return alert(isNew ? "Nowy folder" : "Zmień nazwę",
                     isPresented: Binding(get: { prompt.wrappedValue != nil },
                                          set: { if !$0 { prompt.wrappedValue = nil } }),
                     presenting: prompt.wrappedValue) { p in
            TextField("Nazwa", text: Binding(get: { prompt.wrappedValue?.text ?? p.text },
                                             set: { prompt.wrappedValue?.text = $0 }))
            Button(isNew ? "Utwórz" : "Zmień nazwę") {
                let name = (prompt.wrappedValue?.text ?? p.text).trimmingCharacters(in: .whitespaces)
                if RemotePaths.isValidName(name) { onCommit(p, name) } else { NSSound.beep() }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { p in
            if case .rename(let e) = p.kind {
                Text("Nowa nazwa dla „\(e.displayName)”.")
            } else {
                Text("Folder zostanie utworzony w: \(folder)")
            }
        }
    }
}
