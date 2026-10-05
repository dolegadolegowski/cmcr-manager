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
                         subtitle: "Wysyłanie plików na komputery uczniów, zbieranie prac i porządki w folderach.")
                .alignedWithGroupedForm()
                .padding([.horizontal, .top], 20)
            Form {
                pushSection
                collectSection
                cleanSection
                conventionSection
                if let batch = model.lastBatch[.files] {
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
        .groupedFormPageBackground()
        .sheet(item: $picker) { request in
            RemoteFolderPicker(app: model, request: request)
                .environmentObject(model)
        }
        .confirmation($confirm)
    }

    /// Macs the actions run on (selected ones, without the unreachable ones when they are skipped) – the same
    /// count as in the header.
    var targets: [Machine] { model.selectedMachines }
    var reachable: [Machine] { model.actionTargets }

    /// Tooltip of an action button: on how many Macs it runs and which ones are left out.
    func targetHelp(_ action: String) -> String {
        let selected = targets.count, count = reachable.count
        if selected == 0 { return "Najpierw zaznacz komputery na liście." }
        if count == 0 { return "Wszystkie zaznaczone komputery są niedostępne. Odśwież ich stan albo wyłącz „Pomiń niedostępne”." }
        if count == selected { return "\(action) – \(Polish.onComputers(count))." }
        return "\(action) – \(Polish.onComputers(count)) z \(selected) zaznaczonych (niedostępne zostaną pominięte)."
    }

    // MARK: Push

    var pushSection: some View {
        Section {
            FileListEditor(items: $model.pushItems)
            folderRow("Dokąd wysłać", path: state.destination) {
                favoritesMenu { state.useDestination($0) }
                Button {
                    picker = RemoteFolderRequest(purpose: .pushDestination, initialPath: state.destination) {
                        state.useDestination($0)
                    }
                } label: {
                    Label("Wybierz folder…", systemImage: "folder.badge.gearshape")
                }
                .help("Przeglądaj foldery na komputerze ucznia i wskaż, dokąd mają trafić pliki")
            }
            if RemotePaths.usesConsoleUser(state.destination) {
                Label("Pliki trafią do osoby zalogowanej na danym komputerze; komputery, na których nikt nie jest zalogowany, zostaną pominięte.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // The options follow as ordinary form rows (inside the group they would be squeezed into one row).
            DisclosureGroup(isExpanded: $state.showAdvanced) {
                EmptyView()
            } label: {
                Label("Zaawansowane: ścieżka, właściciel i uprawnienia", systemImage: "slider.horizontal.3")
            }
            if state.showAdvanced {
                advancedPush
            }
            HStack(spacing: 12) {
                Text(pushHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button {
                    state.push(to: targets)
                } label: {
                    Label(reachable.isEmpty ? "Wyślij pliki" : "Wyślij na \(Polish.computers(reachable.count))",
                          systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(reachable.isEmpty || model.pushItems.isEmpty || state.destination.isEmpty)
                .help(targetHelp("Wyślij pliki do folderu „\(RemotePaths.friendlyName(state.destination, settings: model.settings).title)”"))
            }
        } header: {
            Label("Wyślij pliki", systemImage: "paperplane")
        }
    }

    @ViewBuilder var advancedPush: some View {
        LabeledContent {
            TextField("Ścieżka na komputerze",
                      text: Binding(get: { state.destination }, set: { state.editDestination($0) }),
                      prompt: Text("/Users/{student}/Desktop"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
                .onSubmit { state.rememberFolder(state.destination) }
        } label: {
            Text("Ścieżka na komputerze")
            Text("{student} – konto ucznia (\(model.settings.studentUser)), {console} – osoba zalogowana, ~ – katalog administratora.")
        }
        Picker("Właściciel plików", selection: Binding(get: { state.owner }, set: { state.setOwner($0) })) {
            ForEach(OwnerChoice.allCases) { Text($0.label).tag($0) }
        }
        if state.owner == .custom {
            TextField("Konto właściciela", text: $state.customOwner, prompt: Text("użytkownik[:grupa]"))
        }
        Picker("Uprawnienia", selection: Binding(get: { state.mode }, set: { state.setMode($0) })) {
            ForEach(PushMode.allCases) { Text($0.label).tag($0) }
        }
        Toggle(isOn: Binding(get: { state.pushAsRoot || state.owner != .keep }, set: { state.pushAsRoot = $0 })) {
            Text("Z uprawnieniami administratora")
            Text(state.owner != .keep
                 ? "Wymagane, bo zmieniany jest właściciel plików."
                 : "Potrzebne, gdy folder należy do innego konta (sudo).")
        }
        .disabled(state.owner != .keep)
    }

    /// A remote folder with what it is for ("Dokąd wysłać") and the buttons that change it.
    func folderRow<Buttons: View>(_ caption: String, path: String,
                                  @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RemoteFolderLabel(path: path, settings: model.settings)
            }
            Spacer(minLength: 12)
            buttons()
        }
        .padding(.vertical, 2)
    }

    var pushHint: String {
        if model.pushItems.isEmpty { return "Dodaj pliki lub foldery do wysłania." }
        if targets.isEmpty { return "Zaznacz komputery na liście." }
        if state.destination.isEmpty { return "Wybierz folder docelowy." }
        let n = model.pushItems.count
        return "\(Polish.count(n, "element", "elementy", "elementów")) → \(RemotePaths.friendlyName(state.destination, settings: model.settings).title)"
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
                        Button { action(path) } label: {
                            Label(RemotePaths.friendlyName(path, settings: model.settings).title, systemImage: "clock")
                        }
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
            folderRow("Skąd zebrać", path: state.collectSource) {
                Button {
                    picker = RemoteFolderRequest(purpose: .collectSource, initialPath: state.collectSource) {
                        state.useCollectSource($0)
                    }
                } label: {
                    Label("Zmień folder…", systemImage: "folder")
                }
                .help("Wskaż folder na komputerach uczniów, z którego mają zostać zebrane prace")
            }
            HStack(spacing: 10) {
                let local = expandTilde(state.collectBase)
                Image(nsImage: NSWorkspace.shared.icon(forFile: FileManager.default.fileExists(atPath: local)
                                                       ? local : NSHomeDirectory()))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
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
                Button {
                    if let url = Pickers.folder() { state.collectBase = (url.path as NSString).abbreviatingWithTildeInPath }
                } label: {
                    Label("Zmień…", systemImage: "folder")
                }
                .help("Wybierz folder na tym Macu, do którego trafią zebrane prace")
            }
            Toggle(isOn: $state.prefs.collectTimestamped) {
                Text("Osobny folder z datą i godziną dla każdego zbierania")
                Text("Prace trafią do: \(state.nextCollectionExample)")
            }
            Toggle(isOn: $state.collectAsRoot) {
                Text("Z uprawnieniami administratora")
                Text("Potrzebne do prywatnych folderów ucznia, np. Biurka lub Dokumentów.")
            }
            Toggle(isOn: $state.collectClean) {
                Text("Po zebraniu wyczyść folder ucznia")
                Text("Usuwa tylko zebrane pliki, których nikt potem nie zmienił.")
            }
            .help("Usuwane są tylko pliki skopiowane na ten Mac i niezmienione od tej chwili – praca zapisana w międzyczasie zostaje.")
            HStack(spacing: 12) {
                Button {
                    state.revealLastCollection()
                } label: {
                    Label("Pokaż zebrane prace", systemImage: "folder")
                }
                .help("Otwiera w Finderze folder z ostatnio zebranymi pracami")
                Spacer(minLength: 12)
                Button(role: state.collectClean ? .destructive : nil) {
                    collect()
                } label: {
                    // The ellipsis: with cleaning on, a confirmation comes first.
                    Label((reachable.isEmpty ? "Zbierz prace" : "Zbierz z \(Polish.ofComputers(reachable.count))")
                          + (state.collectClean ? "…" : ""),
                          systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(state.collectClean ? .red : nil)
                .disabled(reachable.isEmpty || state.collectSource.isEmpty)
                .help(targetHelp(state.collectClean ? "Zbierz prace i wyczyść folder (z potwierdzeniem)" : "Zbierz prace"))
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
        let affected = reachable
        confirm = ConfirmRequest(
            title: "Zebrać prace i wyczyścić folder?",
            message: "Po skopiowaniu na ten Mac zebrane pliki zostaną trwale usunięte z folderu „\(place)” \(Polish.onComputers(affected.count)): \(names(affected)).",
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
            folderRow("Folder na komputerach uczniów", path: state.cleanPath) {
                Button {
                    picker = RemoteFolderRequest(purpose: .cleanFolder, initialPath: state.cleanPath) { state.cleanPath = $0 }
                } label: {
                    Label("Zmień folder…", systemImage: "folder")
                }
                .help("Wskaż folder na komputerach uczniów")
            }
            HStack(spacing: 10) {
                Button {
                    state.browse(state.cleanPath)
                } label: {
                    Label("Otwórz w Przeglądarce plików", systemImage: AppSection.browser.icon)
                }
                .help("Pokazuje ten folder w dziale Przeglądarka plików (na pierwszym zaznaczonym komputerze)")
                TargetButton(title: "Pokaż listę plików", icon: "list.bullet", prominent: false) {
                    let path = model.settings.resolve(state.cleanPath)
                    model.runScript("Zawartość \(path)", on: targets, section: .files) { _ in
                        Scripts.listFolder(path, asRoot: true)
                    }
                }
                Spacer(minLength: 12)
                TargetButton(title: "Wyczyść folder…", icon: "trash", role: .destructive, prominent: false) {
                    confirmClean()
                }
                .disabled(state.cleanPath.isEmpty)
            }
        } header: {
            Label("Przeglądanie i porządki", systemImage: "folder.badge.minus")
        } footer: {
            FormSectionNote("„Pokaż listę plików” wypisze zawartość folderu z każdego komputera w wyniku poniżej. „Wyczyść folder” usuwa całą jego zawartość – z potwierdzeniem.")
        }
    }

    func confirmClean() {
        let list = targets
        let affected = reachable
        let path = model.settings.resolve(state.cleanPath)
        let title = RemotePaths.friendlyName(state.cleanPath, settings: model.settings).title
        confirm = ConfirmRequest(
            title: "Wyczyścić folder „\(title)”?",
            message: "Cała zawartość \(path) zostanie trwale usunięta \(Polish.onComputers(affected.count)): \(names(affected)). Tej operacji nie można cofnąć.",
            button: "Usuń zawartość") {
            model.runScript("Wyczyść \(path)", on: list, section: .files) { _ in Scripts.cleanFolder(path) }
        }
    }

    // MARK: cmcr-helpers convention

    var conventionSection: some View {
        let local = (expandTilde(model.settings.localFolder) as NSString).abbreviatingWithTildeInPath
        let shared = RemotePaths.friendlyName(model.settings.sharedFolder, settings: model.settings).title
        return Section {
            FormActionRow("Foldery na tym Macu",
                          caption: "\(local)/all – dla wszystkich komputerów, \(local)/<nazwa komputera> – tylko dla niego.") {
                Button {
                    model.prepareLocalFolders()
                } label: {
                    Label("Przygotuj foldery", systemImage: "folder.badge.plus")
                }
                .help("Utwórz \(local)/all oraz foldery wszystkich komputerów i pokaż je w Finderze")
                Button {
                    model.openLocalFolder(model.settings.localFolder)
                } label: {
                    Label("Pokaż w Finderze", systemImage: "folder")
                }
                .help("Otwórz \(local) w Finderze")
            }
            FormActionRow("Wyślij do: \(shared)",
                          caption: "Jak cmcr-push: właściciel \(model.settings.studentUser), wszyscy mogą zmieniać pliki.") {
                TargetButton(title: "Tylko foldery komputerów", icon: "arrow.up.circle", prominent: false) {
                    model.pushConvention(on: targets, includeAll: false)
                }
                TargetButton(title: "Wyślij wszystko", icon: "arrow.up.circle.fill", prominent: false) {
                    model.pushConvention(on: targets, includeAll: true)
                }
            }
            FormActionRow("Pobierz z: \(shared)",
                          caption: "Jak cmcr-pull: do \(local)/<nazwa komputera>; pliki o tych samych nazwach zostaną zastąpione.") {
                TargetButton(title: "Pobierz", icon: "arrow.down.circle", prominent: false) {
                    model.pullFiles(source: model.settings.sharedFolder, localBase: model.settings.localFolder,
                                    asRoot: false, on: targets)
                }
            }
        } header: {
            Label("Foldery „all” i komputerów (jak w cmcr-helpers)", systemImage: "folder.badge.gearshape")
        } footer: {
            FormSectionNote("Do zbierania prac lepiej użyć „Zbierz prace uczniów” – niczego nie nadpisuje.")
        }
    }
}
