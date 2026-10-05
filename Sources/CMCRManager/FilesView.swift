import AppKit
import CMCRCore
import SwiftUI

struct FilesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        FilesPage(state: model.files)
    }
}

private struct FilesPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: FilesState
    @ViewState private var picker: RemoteFolderRequest?
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .files,
                         subtitle: "Wysyłanie plików na iMaki, zbieranie prac uczniów i porządki w folderach.")
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                pushSection
                collectSection
                cleanSection
                conventionSection
                if let batch = model.lastBatch[.files] {
                    Section("Wynik ostatniej operacji") {
                        BatchResultsView(batch: batch)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(item: $picker) { request in
            RemoteFolderPicker(app: model, request: request)
                .environmentObject(model)
        }
        .confirmation($confirm)
    }

    var targets: [Machine] { model.selectedMachines }

    func targetCount(_ n: Int) -> String {
        "\(n) \(Operations.plural(n, "komputer", "komputery", "komputerów"))"
    }

    // MARK: Push

    var pushSection: some View {
        Section {
            FileListEditor(items: $model.pushItems)
            HStack(spacing: 12) {
                RemoteFolderLabel(path: state.destination, settings: model.settings)
                Spacer(minLength: 12)
                favoritesMenu { state.useDestination($0) }
                Button {
                    picker = RemoteFolderRequest(purpose: .pushDestination, initialPath: state.destination) {
                        state.useDestination($0)
                    }
                } label: {
                    Label("Wybierz folder na iMacu…", systemImage: "folder.badge.gearshape")
                }
                .controlSize(.large)
                .help("Przeglądaj foldery na iMacu i wskaż, gdzie mają trafić pliki")
            }
            .padding(.vertical, 4)
            if RemotePaths.usesConsoleUser(state.destination) {
                Label("Pliki trafią do osoby zalogowanej na danym iMacu; komputery bez zalogowanego użytkownika zostaną pominięte.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Zaawansowane", isExpanded: $state.showAdvanced) {
                TextField("Ścieżka na iMacu",
                          text: Binding(get: { state.destination }, set: { state.editDestination($0) }),
                          prompt: Text("/Users/{student}/Desktop"))
                    .font(.body.monospaced())
                    .onSubmit { state.rememberFolder(state.destination) }
                Picker("Właściciel plików", selection: Binding(get: { state.owner }, set: { state.setOwner($0) })) {
                    ForEach(OwnerChoice.allCases) { Text($0.label).tag($0) }
                }
                if state.owner == .custom {
                    TextField("Konto", text: $state.customOwner, prompt: Text("użytkownik[:grupa]"))
                }
                Picker("Uprawnienia", selection: Binding(get: { state.mode }, set: { state.setMode($0) })) {
                    ForEach(PushMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Z uprawnieniami administratora (sudo)",
                       isOn: Binding(get: { state.pushAsRoot || state.owner != .keep }, set: { state.pushAsRoot = $0 }))
                    .disabled(state.owner != .keep)
                    .help(state.owner != .keep ? "Zmiana właściciela zawsze wymaga sudo." : "Potrzebne, gdy folder należy do innego konta.")
                Text("W ścieżce można użyć {student} (konto ucznia: \(model.settings.studentUser)), {console} (osoba zalogowana na iMacu) i ~ (katalog administratora).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(pushHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button {
                    state.push(to: targets)
                } label: {
                    Label(targets.isEmpty ? "Wyślij pliki" : "Wyślij na \(targetCount(targets.count))",
                          systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(targets.isEmpty || model.pushItems.isEmpty || state.destination.isEmpty)
            }
        } header: {
            Label("Wyślij pliki na iMaki", systemImage: "paperplane")
        }
    }

    var pushHint: String {
        if model.pushItems.isEmpty { return "Dodaj pliki lub foldery do wysłania." }
        if targets.isEmpty { return "Zaznacz komputery na liście." }
        if state.destination.isEmpty { return "Wybierz folder na iMacu." }
        let n = model.pushItems.count
        return "\(n) \(Operations.plural(n, "element", "elementy", "elementów")) → \(RemotePaths.friendlyName(state.destination, settings: model.settings).title)"
    }

    func favoritesMenu(_ action: @escaping (String) -> Void) -> some View {
        Menu {
            Section("Ulubione") {
                ForEach(RemotePaths.favorites(model.settings)) { f in
                    Button { action(f.path) } label: { Label(f.title, systemImage: f.icon) }
                }
            }
            let favorites = Set(RemotePaths.favorites(model.settings).map(\.path))
            let recents = state.prefs.recentRemoteFolders.filter { !favorites.contains($0) }
            if !recents.isEmpty {
                Section("Ostatnio używane") {
                    ForEach(recents, id: \.self) { path in
                        Button(RemotePaths.friendlyName(path, settings: model.settings).title) { action(path) }
                    }
                }
            }
        } label: {
            Label("Ulubione", systemImage: "star")
        }
        .fixedSize()
        .help("Szybki wybór często używanego folderu")
    }

    // MARK: Collect

    var collectSection: some View {
        Section {
            HStack(spacing: 12) {
                RemoteFolderLabel(path: state.collectSource, settings: model.settings)
                Spacer(minLength: 12)
                Button {
                    picker = RemoteFolderRequest(purpose: .collectSource, initialPath: state.collectSource) {
                        state.collectSource = $0
                    }
                } label: {
                    Label("Zmień folder…", systemImage: "folder")
                }
                .help("Wskaż folder na iMacach, z którego mają zostać zebrane prace")
            }
            .padding(.vertical, 4)
            HStack(spacing: 10) {
                let local = expandTilde(state.collectBase)
                Image(nsImage: NSWorkspace.shared.icon(forFile: FileManager.default.fileExists(atPath: local)
                                                       ? local : NSHomeDirectory()))
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zapisz na tym Macu w")
                    Text((local as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button("Zmień…") {
                    if let url = Pickers.folder() { state.collectBase = (url.path as NSString).abbreviatingWithTildeInPath }
                }
                .help("Wybierz folder na tym Macu, do którego trafią zebrane prace")
            }
            Toggle(isOn: $state.prefs.collectTimestamped) {
                Text("Osobny folder z datą i godziną dla każdego zbierania")
                Text("Prace trafią do: \(state.nextCollectionExample)")
            }
            Toggle("Z uprawnieniami administratora (prywatne foldery ucznia)", isOn: $state.collectAsRoot)
            Toggle(isOn: $state.collectClean) {
                Text("Po zebraniu wyczyść folder ucznia")
                Text("Usuwane są tylko pliki, które dotarły na ten Mac – praca zapisana w międzyczasie zostaje.")
            }
            HStack(spacing: 12) {
                Spacer()
                Button {
                    state.revealLastCollection()
                } label: {
                    Label("Pokaż w Finderze", systemImage: "folder")
                }
                Button(role: state.collectClean ? .destructive : nil) {
                    collect()
                } label: {
                    Label(targets.isEmpty ? "Zbierz prace" : "Zbierz z \(targets.count) \(Operations.plural(targets.count, "komputera", "komputerów", "komputerów"))",
                          systemImage: "tray.and.arrow.down.fill")
                }
                .controlSize(.large)
                .disabled(targets.isEmpty || state.collectSource.isEmpty)
            }
        } header: {
            Label("Zbierz prace uczniów", systemImage: "tray.and.arrow.down")
        }
    }

    func collect() {
        let list = targets
        guard state.collectClean else {
            state.collect(from: list)
            return
        }
        let place = RemotePaths.friendlyName(state.collectSource, settings: model.settings).title
        confirm = ConfirmRequest(
            title: "Zebrać prace i wyczyścić folder?",
            message: "Po skopiowaniu na ten Mac zebrane pliki zostaną trwale usunięte z folderu „\(place)” na \(targetCount(list.count)): \(names(list)).",
            button: "Zbierz i wyczyść") {
            state.collect(from: list)
        }
    }

    func names(_ list: [Machine]) -> String {
        list.prefix(6).map(\.name).joined(separator: ", ") + (list.count > 6 ? "…" : "")
    }

    // MARK: Clean / browse

    var cleanSection: some View {
        Section {
            HStack(spacing: 12) {
                RemoteFolderLabel(path: state.cleanPath, settings: model.settings)
                Spacer(minLength: 12)
                Button {
                    picker = RemoteFolderRequest(purpose: .cleanFolder, initialPath: state.cleanPath) { state.cleanPath = $0 }
                } label: {
                    Label("Zmień folder…", systemImage: "folder")
                }
            }
            .padding(.vertical, 4)
            HStack(spacing: 8) {
                Button {
                    state.browse(state.cleanPath)
                } label: {
                    Label("Przeglądaj na iMacu", systemImage: "externaldrive.connected.to.line.below")
                }
                .help("Otwórz ten folder w Przeglądarce plików (pierwszy zaznaczony komputer)")
                Button {
                    let path = model.settings.resolve(state.cleanPath)
                    model.runScript("Zawartość \(path)", on: targets, section: .files) { _ in
                        Scripts.listFolder(path, asRoot: true)
                    }
                } label: {
                    Label("Pokaż zawartość na zaznaczonych", systemImage: "list.bullet")
                }
                .disabled(targets.isEmpty)
                .help("Lista plików z każdego zaznaczonego komputera (wynik poniżej)")
                Spacer(minLength: 12)
                Button(role: .destructive) {
                    confirmClean()
                } label: {
                    Label("Wyczyść folder…", systemImage: "trash")
                }
                .disabled(targets.isEmpty || state.cleanPath.isEmpty)
                .help("Usuń całą zawartość folderu na zaznaczonych komputerach")
            }
        } header: {
            Label("Przeglądanie i porządki", systemImage: "folder.badge.minus")
        }
    }

    func confirmClean() {
        let list = targets
        let path = model.settings.resolve(state.cleanPath)
        let title = RemotePaths.friendlyName(state.cleanPath, settings: model.settings).title
        confirm = ConfirmRequest(
            title: "Wyczyścić folder „\(title)”?",
            message: "Cała zawartość \(path) zostanie trwale usunięta na \(targetCount(list.count)): \(names(list)). Tej operacji nie można cofnąć.",
            button: "Usuń zawartość") {
            model.runScript("Wyczyść \(path)", on: list, section: .files) { _ in Scripts.cleanFolder(path) }
        }
    }

    // MARK: cmcr-helpers convention

    var conventionSection: some View {
        let local = (expandTilde(model.settings.localFolder) as NSString).abbreviatingWithTildeInPath
        let shared = RemotePaths.friendlyName(model.settings.sharedFolder, settings: model.settings).title
        return Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Foldery na tym Macu")
                    Text("\(local)/all → na wszystkie komputery, \(local)/<host> → tylko na dany komputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Przygotuj foldery") { model.prepareLocalFolders() }
                    .help("Utwórz \(local)/all oraz foldery wszystkich komputerów i pokaż je w Finderze")
                Button("Otwórz w Finderze") { model.openLocalFolder(model.settings.localFolder) }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wyślij do: \(shared)")
                    Text("cmcr-push – właściciel \(model.settings.studentUser), wszyscy mogą zmieniać")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button {
                    model.pushConvention(on: targets, includeAll: true)
                } label: {
                    Label("Wszystko", systemImage: "arrow.up.circle")
                }
                .disabled(targets.isEmpty)
                .help("Wyślij pliki z folderu all oraz z folderu danego komputera")
                Button {
                    model.pushConvention(on: targets, includeAll: false)
                } label: {
                    Label("Tylko foldery komputerów", systemImage: "arrow.up.circle")
                }
                .disabled(targets.isEmpty)
                .help("Wyślij tylko pliki z folderów <host> (bez folderu all)")
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pobierz z: \(shared)")
                    Text("cmcr-pull – do \(local)/<host>; pliki o tych samych nazwach są nadpisywane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button {
                    model.pullFiles(source: model.settings.sharedFolder, localBase: model.settings.localFolder,
                                    asRoot: false, on: targets)
                } label: {
                    Label("Pobierz", systemImage: "arrow.down.circle")
                }
                .disabled(targets.isEmpty)
                .help("Do zbierania prac lepiej użyć „Zbierz prace uczniów” – niczego nie nadpisuje")
            }
        } header: {
            Label("Konwencja cmcr-helpers", systemImage: "folder.badge.gearshape")
        }
    }
}
