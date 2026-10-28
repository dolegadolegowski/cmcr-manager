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
                         subtitle: "Wiadomości dla uczniów, wylogowanie, usypianie, ponowne uruchamianie i wyłączanie komputerów oraz harmonogram zasilania.")
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
            Picker("Jak pokazać", selection: $asDialog) {
                Text("Okno z przyciskiem OK").tag(true)
                Text("Powiadomienie").tag(false)
            }
            HStack {
                if model.selection.isEmpty {
                    SelectFirstHint()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TargetButton(title: "Wyślij wiadomość", icon: "paperplane.fill") {
                    let t = title, m = text, d = asDialog
                    model.runScript("Wiadomość: \(m.prefix(40))", on: model.selectedMachines, section: .power) { _ in
                        Scripts.message(title: t, text: m, asDialog: d)
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        } header: {
            Label("Wiadomość dla uczniów", systemImage: "text.bubble")
        } footer: {
            Text("Wiadomość zobaczą uczniowie zalogowani na zaznaczonych komputerach. ⌘↩ wysyła.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Session

    var sessionSection: some View {
        Section {
            PowerActionRow(title: "Wygaszenie ekranów", icon: "moon",
                           caption: "Monitory zgasną – uczeń obudzi je myszą lub klawiaturą.") {
                TargetButton(title: "Uśpij ekrany", icon: "moon", prominent: false) {
                    model.power(.displaySleep, on: model.selectedMachines)
                }
            }
            PowerActionRow(title: "Wylogowanie", icon: "rectangle.portrait.and.arrow.right",
                           caption: "Jak „Wyloguj” w menu Apple – aplikacje zapytają ucznia o zapisanie zmian.") {
                TargetButton(title: "Wyloguj…", icon: "rectangle.portrait.and.arrow.right", prominent: false) {
                    request = PowerRequest(kind: .gentleLogout, machines: model.selectedMachines)
                }
            }
            PowerActionRow(title: "Natychmiastowe wylogowanie", icon: "rectangle.portrait.and.arrow.right.fill",
                           caption: "Sesja kończy się od razu – niezapisane prace przepadną.") {
                CriticalTargetButton(title: "Wyloguj natychmiast…", icon: "rectangle.portrait.and.arrow.right.fill") {
                    request = PowerRequest(kind: .logout, machines: model.selectedMachines)
                }
            }
        } header: {
            Label("Sesja ucznia", systemImage: "person.crop.circle")
        }
    }

    // MARK: Power

    var powerSection: some View {
        Section {
            PowerActionRow(title: "Budzenie przez sieć", icon: "sunrise",
                           caption: "Budzi uśpione komputery (Wake-on-LAN) i czeka, aż odpowiedzą. Wyłączonych nie włączy.") {
                TargetButton(title: "Obudź", icon: "sunrise", prominent: false, includeUnreachable: true) {
                    model.wake(model.selectedMachines)
                }
            }
            Picker(selection: $delay) {
                Text("Teraz").tag(0)
                ForEach([1, 5, 10, 15], id: \.self) { Text("Za \($0) min").tag($0) }
            } label: {
                Label {
                    Text("Kiedy uśpić, uruchomić ponownie lub wyłączyć")
                    Text(delay == 0 ? "Od razu po potwierdzeniu." : "Do tego czasu możesz to odwołać na dole tego działu.")
                } icon: {
                    FormRowIcon("clock")
                }
            }
            if delay > 0 {
                Toggle(isOn: $warnUsers) {
                    Label {
                        Text("Uprzedź zalogowanych uczniów")
                        Text("Na ekranie pojawi się komunikat z prośbą o zapisanie pracy.")
                    } icon: {
                        FormRowIcon("exclamationmark.bubble")
                    }
                }
            }
            PowerActionRow(title: "Uśpienie", icon: "powersleep",
                           caption: "Komputery zasną – obudzisz je przyciskiem „Obudź”.") {
                TargetButton(title: "Uśpij…", icon: "powersleep", prominent: false) {
                    request = PowerRequest(kind: .sleep, machines: model.selectedMachines, delay: delay, warn: warnUsers)
                }
            }
            PowerActionRow(title: "Ponowne uruchomienie", icon: "restart",
                           caption: "Zalogowani uczniowie stracą niezapisane prace.") {
                CriticalTargetButton(title: "Uruchom ponownie…", icon: "restart") {
                    request = PowerRequest(kind: .restart, machines: model.selectedMachines, delay: delay, warn: warnUsers)
                }
            }
            PowerActionRow(title: "Wyłączenie", icon: "power",
                           caption: "Wyłączonych komputerów nie obudzisz przez sieć – włączy je harmonogram albo przycisk.") {
                CriticalTargetButton(title: "Wyłącz…", icon: "power") {
                    request = PowerRequest(kind: .shutdown, machines: model.selectedMachines, delay: delay, warn: warnUsers)
                }
            }
            PowerActionRow(title: "Zaplanowane na później", icon: "clock.badge.xmark",
                           caption: "Odwołuje uśpienie, ponowne uruchomienie lub wyłączenie ustawione z opóźnieniem.") {
                TargetButton(title: "Odwołaj", icon: "clock.badge.xmark", prominent: false) {
                    classroom.cancelDelayedPower(model, model.selectedMachines)
                }
            }
        } header: {
            Label("Zasilanie", systemImage: "power")
        } footer: {
            Text("Budzenie przez sieć wymaga adresu MAC (aplikacja zapamiętuje go przy odświeżaniu stanu), połączenia kablem Ethernet i włączonej opcji „Budź przy dostępie do sieci” (harmonogram poniżej).")
                .foregroundStyle(.secondary)
        }
    }
}

/// `TargetButton` for actions that end sessions, delete or switch Macs off: red title and icon, same targets.
struct CriticalTargetButton: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        let selected = model.selectedMachines.count
        let count = model.actionTargets.count
        Button(role: .destructive, action: action) {
            CriticalLabel(title: title, icon: icon)
        }
        .buttonStyle(.bordered)
        .disabled(count == 0)
        .help(TargetButton(title: title.replacingOccurrences(of: "…", with: ""), action: {}).help(selected: selected, count: count))
    }
}

private struct CriticalLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .foregroundStyle(isEnabled ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
    }
}

/// Row in the style of System Settings: what an action does on the left, its button on the right.
struct PowerActionRow<Action: View>: View {
    let title: String
    let icon: String
    let caption: String
    @ViewBuilder var action: Action

    var body: some View {
        LabeledContent {
            action
                .fixedSize()
        } label: {
            Label {
                Text(title)
                Text(caption)
            } icon: {
                FormRowIcon(icon)
            }
        }
    }
}

// MARK: - Confirmation sheet

struct PowerRequest: Identifiable {
    /// `gentleLogout` is „Wyloguj” from the Apple menu (the apps ask to save); `logout` ends the sessions at once.
    enum Kind { case gentleLogout, logout, sleep, restart, shutdown }

    let id = UUID()
    let kind: Kind
    let machines: [Machine]
    var delay = 0
    var warn = true

    var action: PowerAction? {
        switch kind {
        case .gentleLogout, .logout: return nil
        case .sleep: return .sleep
        case .restart: return .restart
        case .shutdown: return .shutdown
        }
    }

    var verb: String {
        switch kind {
        case .gentleLogout: return "Wyloguj"
        case .logout: return "Wyloguj natychmiast"
        case .sleep: return "Uśpij"
        case .restart: return "Uruchom ponownie"
        case .shutdown: return "Wyłącz"
        }
    }

    /// The question for the `n` Macs the action will really reach.
    func question(_ n: Int) -> String {
        let what = Polish.computers(n)
        switch kind {
        case .gentleLogout, .logout: return "Wylogować uczniów \(Polish.onComputers(n))?"
        case .sleep: return "Uśpić \(what)?"
        case .restart: return "Uruchomić ponownie \(what)?"
        case .shutdown: return "Wyłączyć \(what)?"
        }
    }

    /// Can make students lose unsaved work (the confirmation button is red, a repeat is confirmed as destructive).
    var isDestructive: Bool { kind != .sleep && kind != .gentleLogout }

    /// Starts the confirmed action. Every target is handed to the batch: Macs left out because a student is logged in
    /// become skipped jobs, and the batch remembers the confirmation, so „Powtórz na nieudanych” asks again.
    @MainActor
    func start(model: AppModel, classroom: ClassroomModel, skipLoggedIn: Bool) {
        let skip = skipLoggedIn ? Set(machines.filter { !model.status($0).loggedInUsers.isEmpty }.map(\.id)) : []
        let confirmation = BatchConfirmation(button: verb, destructive: isDestructive)
        model.perform(skipping: skip, reason: .loggedInUser, confirmation: confirmation) {
            switch kind {
            case .gentleLogout:
                model.runScript("Wylogowanie (z pytaniem o zapis)", on: machines, section: .power) { _ in
                    Scripts.logoutUser(force: false)
                }
            case .logout:
                model.runScript("Wylogowanie użytkownika", on: machines, section: .power) { _ in Scripts.logoutUser() }
            case .sleep, .restart, .shutdown:
                guard let action else { return }
                classroom.delayedPower(model, action, minutes: delay, warning: warning(for: action), machines)
            }
        }
    }

    /// The message shown on the students' screens before a delayed action (nil: none).
    func warning(for action: PowerAction) -> String? {
        guard delay > 0 && warn else { return nil }
        switch action {
        case .restart: return "Komputer zostanie uruchomiony ponownie za \(delay) min. Zapisz swoją pracę."
        case .shutdown: return "Komputer zostanie wyłączony za \(delay) min. Zapisz swoją pracę."
        default: return "Komputer zostanie uśpiony za \(delay) min. Zapisz swoją pracę."
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
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(request.isDestructive ? Color.red : .accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.question(effective.count)).font(.headline)
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Dotyczy: \(Polish.computers(effective.count))")
                    .font(.subheadline.weight(.semibold))
                List(request.machines) { m in row(m) }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: min(220, CGFloat(request.machines.count) * 26 + 10))
            }
            if request.kind == .restart && fileVaultCount > 0 {
                Label(fileVaultWarning, systemImage: "lock.doc")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.kind == .shutdown {
                Label("Wyłączonych komputerów nie obudzisz przez sieć. Jeśli mają się same włączyć rano, użyj harmonogramu zasilania albo wybierz „Uśpij”.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loggedIn > 0 {
                Toggle("Pomiń komputery z zalogowanym uczniem (\(loggedIn))", isOn: $skipLoggedIn)
            }
            if needsAcknowledgement {
                Toggle("Rozumiem, że niezapisane prace uczniów przepadną", isOn: $understood)
            }
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Never the default action: Return must not restart a classroom.
                Button(role: request.isDestructive ? .destructive : nil) {
                    perform()
                    dismiss()
                } label: {
                    Text("\(request.verb) (\(effective.count))")
                }
                .tint(request.isDestructive ? .red : nil)
                .buttonStyle(.borderedProminent)
                .disabled(effective.isEmpty || (needsAcknowledgement && !understood))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if request.kind == .restart { classroom.checkFileVault(model, request.machines) }
        }
    }

    private func row(_ m: Machine) -> some View {
        let reachability = model.status(m).reachability
        let user = model.status(m).loggedInText
        let unreachable = model.willSkip(m)
        let skipped = unreachable || (skipLoggedIn && user != nil)
        return HStack(spacing: 8) {
            StatusDot(reachability: reachability)
            Text(m.name)
                .fontWeight(.medium)
                .strikethrough(skipped)
            Spacer()
            if unreachable {
                Text("pominięty – \(model.knownReachability(m).displayName.lowercased())")
                    .foregroundStyle(.secondary)
            } else {
                if request.kind == .restart, classroom.fileVault[m.id] == true {
                    Label("FileVault", systemImage: "lock.doc")
                        .foregroundStyle(.orange)
                        .help("Po ponownym uruchomieniu komputer zatrzyma się na ekranie odblokowania dysku.")
                }
                if let user {
                    Label(skipped ? "\(user) – pominięty" : "zalogowany: \(user)", systemImage: "person.fill")
                        .foregroundStyle(skipped ? Color.secondary : Color.orange)
                } else {
                    Text("nikt nie jest zalogowany").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .opacity(skipped ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    var icon: String {
        switch request.kind {
        case .gentleLogout, .logout: return "rectangle.portrait.and.arrow.right"
        case .sleep: return "powersleep"
        case .restart: return "restart.circle.fill"
        case .shutdown: return "power.circle.fill"
        }
    }

    var subtitle: String {
        if request.kind == .logout { return "Sesje zostaną zakończone natychmiast – aplikacje nie zapytają o zapisanie zmian." }
        if request.kind == .gentleLogout {
            return "Jak „Wyloguj” w menu Apple – aplikacje zapytają uczniów o zapisanie zmian, więc wylogowanie może chwilę potrwać."
        }
        if request.delay > 0 {
            return "Za \(request.delay) min\(request.warn ? ", po wcześniejszym komunikacie na ekranie" : ""). Do tego czasu możesz to odwołać przyciskiem „Odwołaj” (Zaplanowane na później)."
        }
        return request.kind == .sleep ? "Komputery zasną od razu; obudzisz je przyciskiem „Obudź”."
            : "Zalogowani uczniowie stracą niezapisane prace."
    }

    /// Macs the action really reaches: unreachable ones are skipped as in the header ("Pomiń niedostępne").
    var reached: [Machine] { request.machines.filter { !model.willSkip($0) } }

    var loggedIn: Int { reached.filter { !model.status($0).loggedInUsers.isEmpty }.count }

    var fileVaultCount: Int { reached.filter { classroom.fileVault[$0.id] == true }.count }

    /// The restart arms the one-time FileVault unlock where macOS supports it (`cmcr_arm_authrestart`), so the
    /// unlock screen is only the fallback there (AUDIT KOM-12).
    var fileVaultWarning: String {
        let fv = reached.filter { classroom.fileVault[$0.id] == true }
        let lead = "FileVault jest włączony \(Polish.onComputers(fv.count))."
        if fv.allSatisfy({ classroom.fileVaultAutoUnlock[$0.id] == true }) {
            return lead + " Aplikacja uzbroi jednorazowe odblokowanie dysku (fdesetup authrestart), więc komputery powinny "
                + "uruchomić się bez hasła FileVault. Jeśli konto administratora nie może odblokować dysku, zatrzymają się "
                + "na ekranie odblokowania – wtedy nie połączysz się z nimi, dopóki ktoś nie wpisze hasła przy komputerze."
        }
        return lead + " Po ponownym uruchomieniu pojawi się ekran odblokowania dysku – dopóki ktoś nie wpisze hasła przy "
            + "komputerze, nie połączysz się z nim (ani podglądem, ani budzeniem przez sieć)."
    }

    var needsAcknowledgement: Bool {
        request.isDestructive && request.delay == 0 && effective.filter { !model.status($0).loggedInUsers.isEmpty }.count >= 5
    }

    var effective: [Machine] {
        skipLoggedIn ? reached.filter { model.status($0).loggedInUsers.isEmpty } : reached
    }

    func perform() {
        guard !effective.isEmpty else { return }
        request.start(model: model, classroom: classroom, skipLoggedIn: skipLoggedIn)
    }
}
