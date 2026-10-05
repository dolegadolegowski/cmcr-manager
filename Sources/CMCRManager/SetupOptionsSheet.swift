import AppKit
import CMCRCore
import SwiftUI
import UniformTypeIdentifiers

/// What the options sheet does when confirmed.
enum SetupSheetMode: Identifiable {
    /// Run the setup script remotely as root on these Macs.
    case configure([Machine])
    /// Save a personalized copy to run at the computer with `sudo bash`.
    case save

    var id: String {
        switch self {
        case .configure(let targets): return "configure-" + targets.map(\.id.uuidString).joined()
        case .save: return "save"
        }
    }
}

/// Options of the one-time setup script, explained for a non-technical user.
struct SetupOptionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let mode: SetupSheetMode
    @ViewState private var o = SetupOptions.load()
    /// Set after saving: the sheet then shows how to run the file.
    @ViewState private var savedURL: URL?

    private var targets: [Machine] {
        if case .configure(let t) = mode { return t }
        return []
    }

    private var isSave: Bool {
        if case .save = mode { return true }
        return false
    }

    var body: some View {
        if let url = savedURL {
            SavedScriptSheet(url: url)
        } else {
            VStack(spacing: 0) {
                header
                Form {
                    warnings
                    accessSection
                    folderSection
                    powerSection
                    systemSection
                    advancedSection
                }
                .formStyle(.grouped)
                Divider()
                footer
            }
            .frame(width: 600, height: 700)
        }
    }

    // MARK: Header & footer

    var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSave ? "doc.badge.gearshape" : "wrench.and.screwdriver")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(isSave ? "Zapisz skrypt konfiguracyjny" : "Skonfiguruj iMaki")
                    .font(.title2.weight(.semibold))
                Text(isSave
                     ? "Plik do jednorazowego uruchomienia przy iMacu (sudo bash). Jeden plik pasuje do wszystkich iMaców – konto administratora i nazwa są wykrywane na miejscu."
                     : "Skrypt konfiguracyjny \(SetupScript.version) zostanie wysłany przez SSH i uruchomiony jako root na: \(targetNames). Można go bezpiecznie uruchamiać wielokrotnie – zmienia tylko to, co trzeba.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    var targetNames: String {
        let names = targets.prefix(8).map(\.name).joined(separator: ", ")
        return targets.count > 8 ? "\(names) i \(targets.count - 8) innych" : names
    }

    var footer: some View {
        HStack {
            if !isSave {
                Button {
                    run(.verify)
                } label: {
                    Label("Tylko sprawdź", systemImage: "checklist")
                }
                .help("Uruchamia skrypt w trybie sprawdzania: raport pokaże, co zostałoby zmienione, nic nie jest zmieniane.")
                .disabled(o.validationError() != nil)
            }
            Spacer()
            Button("Anuluj", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                if isSave { save() } else { run(.apply) }
            } label: {
                Label(isSave ? "Zapisz…" : "Skonfiguruj (\(targets.count))",
                      systemImage: isSave ? "square.and.arrow.down" : "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(o.validationError() != nil || (!isSave && targets.isEmpty))
        }
        .padding(16)
    }

    // MARK: Sections

    @ViewBuilder var warnings: some View {
        let problems = warningTexts
        if !problems.isEmpty {
            Section {
                ForEach(problems, id: \.self) { text in
                    Label {
                        Text(text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    var warningTexts: [String] {
        var out: [String] = []
        if let e = o.validationError() { out.append(e) }
        if let f = SetupScript.sharedFolderProblem(model.settings) { out.append(f + " Popraw go w zakładce Ustawienia.") }
        if o.installKey && model.managerPublicKey == nil {
            out.append("Na tym Macu nie ma jeszcze klucza SSH – wygeneruj go w zakładce Dostęp i hasła, inaczej skrypt go nie zainstaluje.")
        }
        if !isSave && !model.hasSharedPassword && targets.contains(where: { $0.usesSharedPassword }) {
            out.append("Nie zapisano hasła administratora – bez niego uruchomienie jako root się nie uda (chyba że iMac ma sudo bez hasła).")
        }
        return out
    }

    var accessSection: some View {
        Section("Dostęp zdalny") {
            OptionToggle(title: "Zainstaluj klucz SSH tej aplikacji", icon: "key.horizontal",
                         detail: keyDetail, isOn: $o.installKey)
                .disabled(model.managerPublicKey == nil)
            OptionToggle(title: "SSH tylko dla administratorów", icon: "lock.shield",
                         detail: "Logowanie zdalne dozwolone tylko dla grupy Administratorzy – uczniowie nie zalogują się przez SSH.",
                         isOn: $o.restrictSSH)
            OptionToggle(title: "Podtrzymuj połączenia SSH", icon: "antenna.radiowaves.left.and.right",
                         detail: "Zamyka zawieszone połączenia po około 3 minutach (np. gdy ten Mac uśnie w trakcie zadania).",
                         isOn: $o.sshKeepAlive)
            OptionToggle(title: "Udostępnianie ekranu (VNC) dla administratorów", icon: "rectangle.on.rectangle",
                         detail: "Pełne zdalne sterowanie w aplikacji „Udostępnianie ekranu”. Za pierwszym razem może być potrzebne przełączenie go w Ustawieniach przy komputerze.",
                         isOn: $o.enableVNC)
        }
    }

    var keyDetail: String {
        guard let key = model.managerPublicKey else { return "Brak klucza SSH na tym Macu (Dostęp i hasła › Wygeneruj nowy klucz)." }
        let comment = key.split(separator: " ").dropFirst(2).joined(separator: " ")
        return "Aplikacja będzie logować się bez hasła\(comment.isEmpty ? "" : " (klucz \(comment))")."
    }

    var folderSection: some View {
        Section("Folder ucznia") {
            LabeledContent {
                Text(model.settings.resolve(model.settings.sharedFolder))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } label: {
                FormLabel(title: "Folder współdzielony", icon: "folder")
            }
            OptionToggle(title: "Wspólne uprawnienia do plików (ACL)", icon: "person.2",
                         detail: "Pliki wysłane przez nauczyciela i zapisane przez ucznia mogą edytować obie strony.",
                         isOn: $o.sharedACL)
        }
    }

    var powerSection: some View {
        Section("Zasilanie") {
            OptionToggle(title: "Budzenie przez sieć (Wake-on-LAN)", icon: "dot.radiowaves.left.and.right",
                         detail: "Pozwala obudzić uśpionego iMaca z aplikacji (przez kabel Ethernet).",
                         isOn: $o.wakeOnLAN)
            OptionToggle(title: "Nie usypiaj komputera", icon: "moon.zzz",
                         detail: "iMac nie przechodzi w uśpienie, więc zawsze odpowiada; ekran nadal może się wyłączać.",
                         isOn: $o.noSleep)
            OptionToggle(title: "Włączaj po zaniku zasilania", icon: "bolt",
                         detail: "Po powrocie prądu iMac uruchomi się sam (jeśli model to obsługuje).",
                         isOn: $o.autoRestart)
            Picker(selection: $o.scheduleMode) {
                Text("Bez zmian").tag(SetupOptions.ScheduleMode.unchanged)
                Text("Ustaw harmonogram").tag(SetupOptions.ScheduleMode.set)
                Text("Usuń harmonogram").tag(SetupOptions.ScheduleMode.off)
            } label: {
                FormLabel(title: "Automatyczne włączanie i wyłączanie", icon: "calendar.badge.clock")
            }
            if o.scheduleMode == .set {
                ScheduleEditor(options: $o)
            }
        }
    }

    var systemSection: some View {
        Section("System") {
            OptionToggle(title: "Ustaw nazwę komputera", icon: "textformat",
                         detail: isSave ? "Nazwa jak konto administratora, np. imac07 (adres imac07.local)."
                                        : "Nazwa według adresu z listy komputerów, np. imac07.local → imac07, więc adres się nie zmienia.",
                         isOn: $o.setHostname)
            if o.setHostname, !isSave, let note = hostnameNote {
                Label {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }
            }
            Picker(selection: $o.updates) {
                Text("Bez zmian").tag(SetupOptions.UpdatePolicy.unchanged)
                Text("Tylko sprawdzaj").tag(SetupOptions.UpdatePolicy.check)
                Text("Pobieraj, instaluj poprawki bezpieczeństwa").tag(SetupOptions.UpdatePolicy.download)
                Text("Instaluj wszystko automatycznie").tag(SetupOptions.UpdatePolicy.auto)
            } label: {
                FormLabel(title: "Aktualizacje macOS", icon: "arrow.triangle.2.circlepath")
            }
            OptionToggle(title: "Zainstaluj Rosetta 2", icon: "cpu",
                         detail: "Potrzebna programom dla procesorów Intel na iMacach z Apple Silicon.",
                         isOn: $o.rosetta)
            OptionToggle(title: "Odblokuj SSH w zaporze", icon: "shield.lefthalf.filled",
                         detail: "Wyłącza „Blokuj wszystkie połączenia przychodzące”, które uniemożliwia połączenie z aplikacji.",
                         isOn: $o.fixFirewall)
        }
    }

    /// Targets whose address is not `name.local` keep their computer name (see `SetupScript.hostname(for:)`).
    var hostnameNote: String? {
        let kept = targets.filter { SetupScript.hostname(for: $0) == nil }
        guard !kept.isEmpty else { return nil }
        let list = kept.prefix(6).map { "\($0.name) (\($0.address))" }.joined(separator: ", ")
        let more = kept.count > 6 ? " i \(kept.count - 6) innych" : ""
        return "Nazwa zostanie bez zmian na: \(list)\(more) – adres nie ma postaci nazwa.local (np. imac07.local)."
    }

    var advancedSection: some View {
        Section {
            Picker(selection: $o.sudo) {
                Text("Bez zmian").tag(SetupOptions.SudoPolicy.unchanged)
                Text("Włącz (niezalecane)").tag(SetupOptions.SudoPolicy.passwordless)
                Text("Wyłącz").tag(SetupOptions.SudoPolicy.requirePassword)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sudo bez hasła")
                        Text("Każdy, kto ma klucz SSH tej aplikacji, miałby pełne uprawnienia roota bez hasła.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock.open").frame(width: 22)
                }
            }
            OptionToggle(title: "Logowanie SSH wyłącznie kluczem", icon: "lock",
                         detail: "Wyłącza logowanie hasłem przez SSH. Wymaga instalacji klucza tej aplikacji.",
                         isOn: $o.sshKeyOnly)
                .disabled(!o.installKey)
            TextField(text: $o.keyFrom, prompt: Text("np. 192.168.1.0/24")) {
                FormLabel(title: "Klucz tylko z adresów", icon: "network")
            }
            .help("Opcjonalnie: klucz aplikacji zadziała tylko z tych adresów lub sieci (oddzielone przecinkami).")
        } header: {
            Text("Zaawansowane")
        } footer: {
            Text("Domyślne ustawienia wystarczają w większości pracowni.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    func run(_ mode: SetupScript.Mode) {
        o.save()
        model.runSetupScript(o, mode: mode, on: targets)
        dismiss()
    }

    func save() {
        o.save()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SetupScript.fileName
        panel.allowedContentTypes = [UTType.shellScript]
        panel.message = "Zapisz skrypt, np. na pendrive, aby uruchomić go przy każdym iMacu."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = SetupScript.standalone(o, settings: model.settings, publicKey: model.managerPublicKey)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
            ConfigStore.log("Zapisano skrypt konfiguracyjny \(SetupScript.version) → \(url.path)")
            savedURL = url
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Switch with an SF Symbol and a one-line explanation under the title.
struct OptionToggle: View {
    let title: String
    let icon: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: icon)
                    .frame(width: 22)
            }
        }
        .toggleStyle(.switch)
    }
}

/// Form row label with a fixed-width icon, so titles line up with those of `OptionToggle`.
struct FormLabel: View {
    let title: String
    let icon: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .frame(width: 22)
        }
    }
}

/// Days and times of the power schedule (pmset repeat).
struct ScheduleEditor: View {
    @Binding var options: SetupOptions

    private static let days: [(letter: Character, label: String, name: String)] = [
        ("M", "Pn", "poniedziałek"), ("T", "Wt", "wtorek"), ("W", "Śr", "środa"), ("R", "Cz", "czwartek"),
        ("F", "Pt", "piątek"), ("S", "So", "sobota"), ("U", "Nd", "niedziela"),
    ]

    var body: some View {
        LabeledContent("Dni") {
            HStack(spacing: 4) {
                ForEach(Self.days, id: \.letter) { day in
                    Toggle(day.label, isOn: dayBinding(day.letter))
                        .toggleStyle(.button)
                        .help(day.name)
                }
            }
        }
        DatePicker("Włączenie o", selection: timeBinding(\.scheduleOn), displayedComponents: .hourAndMinute)
        Toggle("Wyłączanie", isOn: Binding(
            get: { !options.scheduleOff.isEmpty },
            set: { options.scheduleOff = $0 ? "17:00" : "" }))
        if !options.scheduleOff.isEmpty {
            DatePicker("Wyłączenie o", selection: timeBinding(\.scheduleOff), displayedComponents: .hourAndMinute)
            Picker("O tej godzinie", selection: $options.scheduleAction) {
                Text("Wyłącz komputer").tag(SetupOptions.ScheduleAction.shutdown)
                Text("Uśpij komputer").tag(SetupOptions.ScheduleAction.sleep)
            }
            if options.scheduleAction == .shutdown {
                Text("Wyłączonego komputera nie obudzi Wake-on-LAN – włączy go dopiero harmonogram lub przycisk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func dayBinding(_ letter: Character) -> Binding<Bool> {
        Binding(
            get: { options.scheduleDays.contains(letter) },
            set: { on in
                var set = Set(options.scheduleDays)
                if on { set.insert(letter) } else { set.remove(letter) }
                options.scheduleDays = String(Self.days.map(\.letter).filter { set.contains($0) })
            })
    }

    func timeBinding(_ key: WritableKeyPath<SetupOptions, String>) -> Binding<Date> {
        Binding(
            get: {
                let p = options[keyPath: key].split(separator: ":").compactMap { Int($0) }
                var c = DateComponents()
                c.hour = p.first ?? 7
                c.minute = p.count > 1 ? p[1] : 0
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                options[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }
}

/// Shown after saving the script: how to run it at each iMac.
struct SavedScriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    private var command: String {
        let name = url.lastPathComponent
        let safe = name.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        return "sudo bash ~/Downloads/\(safe ? name : shQuote(name)) --guided"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Skrypt zapisany", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            HStack {
                Text(url.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Pokaż w Finderze", systemImage: "folder")
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    NumberedStep(n: 1, text: "Skopiuj plik na iMaca (pendrive lub AirDrop) do folderu Pobrane rzeczy konta administratora (imacNN).")
                    NumberedStep(n: 2, text: "Zaloguj się na iMacu na konto administratora i otwórz Terminal (Programy › Narzędzia).")
                    NumberedStep(n: 3, text: "Wpisz poniższe polecenie, naciśnij Return i podaj hasło administratora:")
                    HStack {
                        Text(command)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        } label: {
                            Label("Kopiuj", systemImage: "doc.on.doc")
                        }
                        .help("Kopiuje polecenie do schowka")
                    }
                    NumberedStep(n: 4, text: "Skrypt wypisze raport po polsku. Przy krokach, których nie da się wykonać automatycznie, otworzy właściwy panel Ustawień i poczeka, aż skończysz.")
                }
                .padding(6)
            } label: {
                Label("Jak uruchomić na każdym iMacu", systemImage: "list.number")
            }
            Text("Plik zawiera tylko klucz publiczny tej aplikacji (nie jest tajny) – żadnych haseł. Uruchomienie przez „bash” działa także dla plików z AirDrop lub internetu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Gotowe") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

struct NumberedStep: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.callout.weight(.bold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
