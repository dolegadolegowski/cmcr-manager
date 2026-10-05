import CMCRCore
import SwiftUI

struct PowerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @ViewState private var title = "Wiadomość od nauczyciela"
    @ViewState private var text = ""
    @ViewState private var asDialog = true
    @ViewState private var delay = 0
    @ViewState private var warnUsers = true
    @ViewState private var request: PowerRequest?

    static let templates = [
        "Zapisz swoją pracę.",
        "Koniec zajęć za 5 minut – zapisz pracę w folderze cmcr.",
        "Proszę spojrzeć na tablicę.",
        "Za chwilę wyłączę komputery – zapisz pracę.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .power,
                         subtitle: "Komunikaty dla uczniów, wylogowanie, usypianie, restart, wyłączanie i harmonogram zasilania.")
                .padding([.horizontal, .top], 20)
            Form {
                messageSection
                sessionSection
                powerSection
                EnergyScheduleSection()
                if model.lastBatch[.power] != nil {
                    Section { LastBatchView(section: .power) }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(item: $request) { r in
            PowerConfirmSheet(request: r)
        }
    }

    // MARK: Message

    var messageSection: some View {
        Section {
            TextField("Tytuł", text: $title)
            HStack(alignment: .firstTextBaseline) {
                TextField("Treść", text: $text, prompt: Text("Treść wiadomości dla zalogowanych uczniów"), axis: .vertical)
                    .lineLimit(2...6)
                Menu {
                    ForEach(Self.templates, id: \.self) { t in Button(t) { text = t } }
                } label: {
                    Label("Szablony", systemImage: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Wstaw gotową wiadomość")
            }
            Picker("Forma", selection: $asDialog) {
                Text("Okno z przyciskiem OK").tag(true)
                Text("Powiadomienie").tag(false)
            }
            HStack {
                Spacer()
                TargetButton(title: "Wyślij wiadomość", icon: "paperplane.fill") {
                    let t = title, m = text, d = asDialog
                    model.runScript("Wiadomość: \(m.prefix(40))", on: model.selectedMachines, section: .power) { _ in
                        Scripts.message(title: t, text: m, asDialog: d)
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Label("Wiadomość dla uczniów", systemImage: "text.bubble")
        }
    }

    // MARK: Session

    var sessionSection: some View {
        Section {
            HStack {
                TargetButton(title: "Uśpij ekran", icon: "moon", prominent: false) {
                    model.power(.displaySleep, on: model.selectedMachines)
                }
                .help("Wyłącza tylko monitor – uczeń obudzi go myszą lub klawiaturą.")
                Spacer()
                TargetButton(title: "Wyloguj", icon: "rectangle.portrait.and.arrow.right", prominent: false) {
                    model.runScript("Wylogowanie (z pytaniem o zapis)", on: model.selectedMachines, section: .power) { _ in
                        Scripts.logoutUser(force: false)
                    }
                }
                .help("Jak „Wyloguj” w menu Apple: aplikacje mogą zapytać ucznia o zapisanie zmian i wstrzymać wylogowanie.")
                TargetButton(title: "Wyloguj natychmiast", icon: "rectangle.portrait.and.arrow.right.fill", role: .destructive,
                             prominent: false) {
                    request = PowerRequest(kind: .logout, machines: model.selectedMachines)
                }
                .tint(.red)
                .help("Kończy sesję ucznia od razu – aplikacje nie zapytają o zapisanie zmian.")
            }
        } header: {
            Label("Sesja użytkownika", systemImage: "person.crop.circle")
        }
    }

    // MARK: Power

    var powerSection: some View {
        Section {
            Picker("Kiedy", selection: $delay) {
                Text("Teraz").tag(0)
                ForEach([1, 5, 10, 15], id: \.self) { Text("Za \($0) min").tag($0) }
            }
            if delay > 0 {
                Toggle("Uprzedź zalogowanych uczniów komunikatem", isOn: $warnUsers)
            }
            HStack {
                TargetButton(title: "Obudź", icon: "sunrise", prominent: false, includeUnreachable: true) {
                    model.wake(model.selectedMachines)
                }
                .help("Wyślij pakiet Wake-on-LAN i poczekaj, aż komputery odpowiedzą (działa tylko z uśpienia).")
                TargetButton(title: "Uśpij", icon: "moon.zzz", prominent: false) {
                    request = PowerRequest(kind: .sleep, machines: model.selectedMachines, delay: delay, warn: warnUsers)
                }
                Spacer()
                TargetButton(title: "Uruchom ponownie", icon: "arrow.clockwise.circle", role: .destructive, prominent: false) {
                    request = PowerRequest(kind: .restart, machines: model.selectedMachines, delay: delay, warn: warnUsers)
                }
                .tint(.red)
                TargetButton(title: "Wyłącz", icon: "power", role: .destructive, prominent: false) {
                    request = PowerRequest(kind: .shutdown, machines: model.selectedMachines, delay: delay, warn: warnUsers)
                }
                .tint(.red)
            }
            HStack {
                Spacer()
                TargetButton(title: "Anuluj zaplanowane", icon: "clock.badge.xmark", prominent: false) {
                    classroom.cancelDelayedPower(model, model.selectedMachines)
                }
                .help("Odwołaj restart, wyłączenie lub uśpienie zaplanowane z opóźnieniem.")
            }
        } header: {
            Label("Zasilanie", systemImage: "power")
        } footer: {
            Text("Wake-on-LAN budzi komputery tylko z uśpienia – wyłączonego komputera nie włączy. Wymaga adresu MAC (zbierany przy odświeżaniu stanu), połączenia Ethernet i opcji „Budź przy dostępie do sieci”.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Confirmation sheet

struct PowerRequest: Identifiable {
    enum Kind { case logout, sleep, restart, shutdown }

    let id = UUID()
    let kind: Kind
    let machines: [Machine]
    var delay = 0
    var warn = true

    var action: PowerAction? {
        switch kind {
        case .logout: return nil
        case .sleep: return .sleep
        case .restart: return .restart
        case .shutdown: return .shutdown
        }
    }

    var verb: String {
        switch kind {
        case .logout: return "Wyloguj"
        case .sleep: return "Uśpij"
        case .restart: return "Uruchom ponownie"
        case .shutdown: return "Wyłącz"
        }
    }

    var question: String {
        let n = machines.count
        let what = "\(n) \(Plural.computers(n))"
        switch kind {
        case .logout: return "Wylogować użytkowników na \(n) \(Plural.computersLocative(n))?"
        case .sleep: return "Uśpić \(what)?"
        case .restart: return "Uruchomić ponownie \(what)?"
        case .shutdown: return "Wyłączyć \(what)?"
        }
    }
}

/// Lists the target Macs with their logged-in users (and FileVault for restarts) before a disruptive action.
struct PowerConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @Environment(\.dismiss) private var dismiss
    let request: PowerRequest
    @ViewState private var skipLoggedIn = false
    @ViewState private var understood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(request.kind == .sleep ? Color.accentColor : .red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.question).font(.headline)
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            List(request.machines) { m in
                HStack {
                    StatusDot(reachability: model.status(m).reachability)
                    Text(m.name).fontWeight(.medium)
                    Spacer()
                    if request.kind == .restart, classroom.fileVault[m.id] == true {
                        Label("FileVault", systemImage: "lock.shield")
                            .foregroundStyle(.orange)
                            .help("Po restarcie komputer zatrzyma się na ekranie odblokowania dysku.")
                    }
                    if let user = model.status(m).consoleUser {
                        Label(user, systemImage: "person.fill").foregroundStyle(.orange)
                            .help("Zalogowany użytkownik")
                    } else {
                        Text("nikt nie jest zalogowany").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 120, idealHeight: 220)
            if request.kind == .restart && fileVaultCount > 0 {
                Label("FileVault jest włączony na \(fileVaultCount) \(Plural.computersLocative(fileVaultCount)). Po restarcie pojawi się ekran odblokowania dysku – dopóki ktoś nie wpisze hasła przy komputerze, nie połączysz się z nim (SSH, podgląd, Wake-on-LAN).",
                      systemImage: "lock.shield")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.kind == .shutdown {
                Label("Wyłączonych komputerów nie obudzisz przez sieć. Jeśli mają się same włączyć rano, użyj harmonogramu zasilania albo wybierz Uśpij.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loggedIn > 0 {
                Toggle("Pomiń komputery z zalogowanym użytkownikiem (\(loggedIn))", isOn: $skipLoggedIn)
            }
            if needsAcknowledgement {
                Toggle("Rozumiem, że niezapisane prace uczniów przepadną", isOn: $understood)
            }
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    perform()
                    dismiss()
                } label: {
                    Text(buttonTitle)
                }
                .tint(request.kind == .sleep ? nil : .red)
                .buttonStyle(.borderedProminent)
                .disabled(targets.isEmpty || (needsAcknowledgement && !understood))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if request.kind == .restart { classroom.checkFileVault(model, request.machines) }
        }
    }

    var icon: String {
        switch request.kind {
        case .logout: return "rectangle.portrait.and.arrow.right"
        case .sleep: return "moon.zzz.fill"
        case .restart: return "arrow.clockwise.circle.fill"
        case .shutdown: return "power.circle.fill"
        }
    }

    var subtitle: String {
        if request.kind == .logout { return "Sesje zostaną zakończone natychmiast – aplikacje nie zapytają o zapisanie zmian." }
        if request.delay > 0 {
            return "Za \(request.delay) min\(request.warn ? ", po wcześniejszym komunikacie na ekranie" : ""). Do tego czasu możesz to odwołać przyciskiem „Anuluj zaplanowane”."
        }
        return request.kind == .sleep ? "Komputery zasną od razu; obudzisz je przez Wake-on-LAN."
            : "Zalogowani użytkownicy stracą niezapisane prace."
    }

    var loggedIn: Int { request.machines.filter { model.status($0).consoleUser != nil }.count }

    var fileVaultCount: Int { request.machines.filter { classroom.fileVault[$0.id] == true }.count }

    var needsAcknowledgement: Bool {
        request.kind != .sleep && request.delay == 0 && targets.filter { model.status($0).consoleUser != nil }.count >= 5
    }

    var targets: [Machine] {
        skipLoggedIn ? request.machines.filter { model.status($0).consoleUser == nil } : request.machines
    }

    var buttonTitle: String {
        let n = targets.count
        return "\(request.verb) (\(n))"
    }

    func perform() {
        let list = targets
        guard !list.isEmpty else { return }
        switch request.kind {
        case .logout:
            model.runScript("Wylogowanie użytkownika", on: list, section: .power) { _ in Scripts.logoutUser() }
        case .sleep, .restart, .shutdown:
            guard let action = request.action else { return }
            let warning: String?
            if request.delay > 0 && request.warn {
                switch action {
                case .restart: warning = "Komputer zostanie uruchomiony ponownie za \(request.delay) min. Zapisz swoją pracę."
                case .shutdown: warning = "Komputer zostanie wyłączony za \(request.delay) min. Zapisz swoją pracę."
                default: warning = "Komputer zostanie uśpiony za \(request.delay) min. Zapisz swoją pracę."
                }
            } else {
                warning = nil
            }
            classroom.delayedPower(model, action, minutes: request.delay, warning: warning, list)
        }
    }
}
