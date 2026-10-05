import CMCRCore
import SwiftUI

struct DestinationPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
    let owner: OwnerChoice
    let mode: String

    static func all(_ s: AppSettings) -> [DestinationPreset] {
        [
            DestinationPreset(id: "shared", title: "Folder cmcr ucznia (cmcr-push)", path: s.sharedFolder, owner: .student, mode: "777"),
            DestinationPreset(id: "desktop", title: "Biurko ucznia", path: "/Users/{student}/Desktop", owner: .student, mode: ""),
            DestinationPreset(id: "documents", title: "Dokumenty ucznia", path: "/Users/{student}/Documents", owner: .student, mode: ""),
            DestinationPreset(id: "consoleDesktop", title: "Biurko zalogowanego użytkownika", path: "/Users/{console}/Desktop", owner: .console, mode: ""),
            DestinationPreset(id: "usersShared", title: "Wspólny folder /Users/Shared", path: "/Users/Shared", owner: .keep, mode: "777"),
            DestinationPreset(id: "applications", title: "Programy (/Applications)", path: "/Applications", owner: .admin, mode: ""),
            DestinationPreset(id: "custom", title: "Inna ścieżka…", path: "", owner: .keep, mode: ""),
        ]
    }
}

struct FilesView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var presetID = "shared"
    @ViewState private var destination = ""
    @ViewState private var owner: OwnerChoice = .student
    @ViewState private var customOwner = ""
    @ViewState private var mode = "777"
    @ViewState private var pushAsRoot = true

    @ViewState private var pullSource = ""
    @ViewState private var pullAsRoot = false
    @ViewState private var cleanPath = ""
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        Page {
            TargetHeader(section: .files,
                         subtitle: "Wgrywanie plików do wskazanych folderów (cmcr-push), zbieranie prac z komputerów (cmcr-pull) i porządki.")
            pushBox
            pullBox
            conventionBox
            cleanBox
            LastBatchView(section: .files)
        }
        .onAppear {
            if destination.isEmpty { applyPreset("shared") }
            if pullSource.isEmpty { pullSource = model.settings.sharedFolder }
            if cleanPath.isEmpty { cleanPath = model.settings.sharedFolder }
        }
        .confirmation($confirm)
    }

    // MARK: Push

    var pushBox: some View {
        SectionBox(title: "Wyślij pliki do folderu", icon: "arrow.up.doc") {
            FileListEditor(items: $model.pushItems)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Miejsce docelowe")
                    Picker("", selection: $presetID) {
                        ForEach(DestinationPreset.all(model.settings)) { p in Text(p.title).tag(p.id) }
                    }
                    .labelsHidden()
                    .onChange(of: presetID) { _, id in applyPreset(id) }
                }
                GridRow {
                    Text("Ścieżka na iMacu")
                    TextField("/Users/student/Public/cmcr", text: $destination)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Właściciel")
                    HStack {
                        Picker("", selection: $owner) {
                            ForEach(OwnerChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        if owner == .custom {
                            TextField("użytkownik[:grupa]", text: $customOwner).frame(maxWidth: 200)
                        }
                    }
                }
                GridRow {
                    Text("Uprawnienia")
                    HStack {
                        Picker("", selection: $mode) {
                            Text("Bez zmian").tag("")
                            Text("777 – wszyscy mogą zmieniać (jak cmcr-push)").tag("777")
                            Text("755 – odczyt dla wszystkich").tag("755")
                            Text("644 – pliki tylko do odczytu").tag("644")
                            Text("700 – tylko właściciel").tag("700")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        Toggle("Z uprawnieniami administratora (sudo)", isOn: $pushAsRoot)
                    }
                }
            }
            Text("W ścieżkach można użyć {student} (konto ucznia z Konfiguracji) oraz {console} (aktualnie zalogowany użytkownik).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TargetButton(title: "Wyślij na zaznaczone", icon: "paperplane.fill") {
                    model.pushFiles(model.pushItems, destination: destination,
                                    owner: model.ownerString(owner, custom: customOwner),
                                    mode: mode, asRoot: pushAsRoot || owner != .keep, on: model.selectedMachines)
                }
                .disabled(model.pushItems.isEmpty || destination.isEmpty)
                if !pushAsRoot && owner != .keep {
                    Text("Zmiana właściciela wymaga sudo – zostanie użyte.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func applyPreset(_ id: String) {
        guard let p = DestinationPreset.all(model.settings).first(where: { $0.id == id }) else { return }
        if id != "custom" { destination = p.path }
        owner = p.owner
        mode = p.mode
    }

    // MARK: Pull

    var pullBox: some View {
        SectionBox(title: "Pobierz pliki z komputerów (zbieranie prac)", icon: "arrow.down.doc") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Folder na iMacu")
                    TextField("/Users/student/Public/cmcr", text: $pullSource).font(.body.monospaced())
                }
                GridRow {
                    Text("Zapisz lokalnie w")
                    HStack {
                        TextField("~/Public/cmcr", text: $model.settings.localFolder).font(.body.monospaced())
                        Button("Wybierz…") {
                            if let url = Pickers.folder() { model.settings.localFolder = url.path }
                        }
                    }
                }
            }
            Text("Każdy komputer trafia do własnego podfolderu (np. \(model.settings.localFolder)/imac04.local) – jak w cmcr-pull.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TargetButton(title: "Pobierz z zaznaczonych", icon: "tray.and.arrow.down.fill") {
                    model.pullFiles(source: pullSource, localBase: model.settings.localFolder, asRoot: pullAsRoot,
                                    on: model.selectedMachines)
                }
                .disabled(pullSource.isEmpty)
                Toggle("Jako root (np. foldery prywatne ucznia)", isOn: $pullAsRoot)
                Spacer()
                Button("Otwórz folder lokalny") { model.openLocalFolder(model.settings.localFolder) }
            }
        }
    }

    // MARK: Convention

    var conventionBox: some View {
        SectionBox(title: "Konwencja cmcr-helpers", icon: "folder.badge.gearshape") {
            Text("Lokalnie: \(model.settings.localFolder)/all → na wszystkie komputery, \(model.settings.localFolder)/<host> → tylko na dany komputer. Cel: \(model.settings.sharedFolder) (właściciel \(model.settings.studentUser), chmod 777).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Przygotuj foldery lokalne") { model.prepareLocalFolders() }
                TargetButton(title: "cmcr-push (all + host)", icon: "arrow.up.circle", prominent: false) {
                    model.pushConvention(on: model.selectedMachines, includeAll: true)
                }
                TargetButton(title: "Tylko foldery hostów", icon: "arrow.up.circle", prominent: false) {
                    model.pushConvention(on: model.selectedMachines, includeAll: false)
                }
                TargetButton(title: "cmcr-pull", icon: "arrow.down.circle", prominent: false) {
                    model.pullFiles(source: model.settings.sharedFolder, localBase: model.settings.localFolder,
                                    asRoot: false, on: model.selectedMachines)
                }
            }
        }
    }

    // MARK: Clean / list

    var cleanBox: some View {
        SectionBox(title: "Przeglądanie i porządki", icon: "trash") {
            HStack {
                TextField("Folder", text: $cleanPath).font(.body.monospaced())
                TargetButton(title: "Pokaż zawartość", icon: "list.bullet", prominent: false) {
                    let path = model.settings.resolve(cleanPath)
                    model.runScript("ls -la \(path)", on: model.selectedMachines) { _ in
                        Scripts.listFolder(path, asRoot: true)
                    }
                }
                TargetButton(title: "Wyczyść folder", icon: "trash", role: .destructive, prominent: false) {
                    let path = model.settings.resolve(cleanPath)
                    confirm = ConfirmRequest(
                        title: "Wyczyścić folder?",
                        message: "Cała zawartość \(path) zostanie trwale usunięta \(Polish.onComputers(model.actionTargets.count)).",
                        button: "Usuń zawartość") {
                        model.runScript("Wyczyść \(path)", on: model.selectedMachines) { _ in Scripts.cleanFolder(path) }
                    }
                }
            }
        }
    }
}
