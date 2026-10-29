import AppKit
import CMCRCore
import SwiftUI
import UniformTypeIdentifiers

extension RemoteEntry {
    /// The name as it can be shown safely in one line: control characters and the bidirectional overrides (which
    /// SwiftUI text applies, e.g. „praca\u{202E}fdp.command” shown as „pracadnammoc.pdf”) made visible (AUDIT DOD-13).
    var displayName: String { TerminalText.escape(name, keepBackslash: true) }

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
            .width(min: 140, ideal: 220)
            TableColumn("Data modyfikacji", value: \.modified) { e in
                Text(e.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(e.modified.formatted(date: .complete, time: .standard))
            }
            .width(min: 90, ideal: 125)
            TableColumn("Rozmiar", value: \.size) { e in
                Text(e.sizeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 50, ideal: 65)
            TableColumn("Rodzaj", value: \.kindDescription) { e in
                Text(e.kindDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Właściciel", value: \.owner) { e in
                Text(e.owner)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 50, ideal: 70)
        }
        .alternatingRowBackgrounds(browser.visibleEntries.isEmpty ? .disabled : .enabled)
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
                Text(st == .online || st == .unknown || st == .checking ? m.name : "\(m.name) (\(st.displayName.lowercased()))")
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
                                   description: Text("Dodaj komputery w Konfiguracji › Komputery."))
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
                        Button { browser.showHidden = true } label: {
                            Label("Pokaż ukryte pliki", systemImage: "eye.slash")
                        }
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
                    Button {
                        browser.asRoot = true
                        browser.reload()
                    } label: {
                        Label("Otwórz jako administrator", systemImage: "lock.shield")
                    }
                    .buttonStyle(.borderedProminent)
                case .notFound, .notDirectory:
                    if browser.canGoUp {
                        Button { browser.goUp() } label: {
                            Label("Folder nadrzędny", systemImage: "arrow.up")
                        }
                        .help("Przejdź do folderu nadrzędnego")
                    }
                case .noConsoleUser:
                    Button { browser.open(RemotePaths.student + "/Desktop") } label: {
                        Label("Pokaż Biurko ucznia", systemImage: "menubar.dock.rectangle")
                    }
                case .authentication:
                    Button { model.section = .setup } label: {
                        Label("Otwórz Konfigurację", systemImage: "gearshape")
                    }
                default:
                    EmptyView()
                }
                Button { browser.reload() } label: {
                    Label("Spróbuj ponownie", systemImage: "arrow.clockwise")
                }
            }
            .fixedSize()
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
        case .unreachable: return "moon.zzz.fill"
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
            return "Biurko, Dokumenty i Pobrane rzeczy są chronione przez macOS. Na tym komputerze włącz: Ustawienia systemowe › Ogólne › Udostępnianie › Zdalne logowanie (ⓘ) › „Daj użytkownikom zdalnym pełny dostęp do dysku”."
        case .noConsoleUser:
            return "Folder zalogowanego użytkownika jest dostępny tylko wtedy, gdy ktoś jest zalogowany na tym komputerze."
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

    var isNewFolder: Bool { if case .newFolder = kind { return true } else { return false } }

    /// Why `name` cannot be used for a file or folder on the iMac; nil when it can (`RemotePaths.isValidName`).
    static func problem(_ name: String) -> String? {
        guard !RemotePaths.isValidName(name) else { return nil }
        if name.isEmpty { return "Wpisz nazwę." }
        if name == "." || name == ".." { return "„.” i „..” nie mogą być nazwą." }
        if name.utf8.count > 255 { return "Nazwa jest za długa – najwyżej 255 bajtów (litery z ogonkami liczą się podwójnie)." }
        if name.contains("/") { return "Nazwa nie może zawierać „/”." }
        return "Nazwa nie może zawierać znaku NUL."
    }
}

extension View {
    /// Sheet with a text field used for "Nowy folder" and "Zmień nazwę" (the file browser and the folder picker). A
    /// name that cannot be used is explained in the sheet, which stays open with the typed name – an alert closes
    /// with any of its buttons, so the name was lost and nothing said why (AUDIT WSP-07, REV-28, REV-30).
    func namePrompt(_ prompt: Binding<NamePrompt?>, folder: String,
                    onCommit: @escaping (NamePrompt, String) -> Void) -> some View {
        sheet(item: prompt) { p in
            NamePromptSheet(prompt: p, folder: folder, onCommit: onCommit)
        }
    }
}

private struct NamePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: NamePrompt
    let folder: String
    let onCommit: (NamePrompt, String) -> Void
    @ViewState private var text: String

    init(prompt: NamePrompt, folder: String, onCommit: @escaping (NamePrompt, String) -> Void) {
        self.prompt = prompt
        self.folder = folder
        self.onCommit = onCommit
        _text = ViewState(initialValue: prompt.text)
    }

    var name: String { text.trimmingCharacters(in: .whitespaces) }
    var problem: String? { NamePrompt.problem(name) }

    var body: some View {
        Form {
            Section {
                // Return is the default button's (enabled only for a usable name): no second commit from onSubmit.
                TextField("Nazwa", text: $text)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(prompt.isNewFolder ? "Nowy folder" : "Zmień nazwę")
            } footer: {
                Text(place)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Anuluj") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(prompt.isNewFolder ? "Utwórz" : "Zmień nazwę", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
    }

    /// Where the change is made; the folder and the old name are read from the iMac (AUDIT DOD-13).
    var place: String {
        if case .rename(let e) = prompt.kind { return "Nowa nazwa dla „\(e.displayName)”." }
        return "Folder zostanie utworzony w: \(TerminalText.escape(folder, keepBackslash: true))"
    }

    func commit() {
        guard problem == nil else { return }
        onCommit(prompt, name)
        dismiss()
    }
}
