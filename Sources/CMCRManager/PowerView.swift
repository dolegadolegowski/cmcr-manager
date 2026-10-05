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
                TargetButton(title: "Wyloguj", icon: "rectangle.portrait.and.arrow.right", prominent: false) {
                    model.runScript("Wylogowanie (z pytaniem o zapis)", on: model.selectedMachines, section: .power) { _ in
                        Scripts.logoutUser(force: false)
                    }
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
                Text("Kiedy uśpić, uruchomić ponownie lub wyłączyć")
                Text(delay == 0 ? "Od razu po potwierdzeniu." : "Do tego czasu możesz to odwołać na dole tej sekcji.")
            }
            if delay > 0 {
                Toggle(isOn: $warnUsers) {
                    Text("Uprzedź zalogowanych uczniów")
                    Text("Na ekranie pojawi się komunikat z prośbą o zapisanie pracy.")
                }
            }
            PowerActionRow(title: "Uśpienie", icon: "moon.zzz",
                           caption: "Komputery zasną – obudzisz je przyciskiem „Obudź”.") {
                TargetButton(title: "Uśpij…", icon: "moon.zzz", prominent: false) {
                    request = PowerRequest(kind: .sleep, machines: model.selectedMachines, delay: delay, warn: warnUsers)
                }
            }
            PowerActionRow(title: "Ponowne uruchomienie", icon: "arrow.clockwise.circle",
                           caption: "Zalogowani uczniowie stracą niezapisane prace.") {
                CriticalTargetButton(title: "Uruchom ponownie…", icon: "arrow.clockwise.circle") {
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
                Image(systemName: icon)
            }
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
        case .logout: return "Wylogować uczniów \(Polish.onComputers(n))?"
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
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(request.kind == .sleep ? Color.accentColor : .red)
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
                Label("FileVault jest włączony \(Polish.onComputers(fileVaultCount)). Po ponownym uruchomieniu pojawi się ekran odblokowania dysku – dopóki ktoś nie wpisze hasła przy komputerze, nie połączysz się z nim (ani podglądem, ani budzeniem przez sieć).",
                      systemImage: "lock.shield")
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
                Button(role: request.kind == .sleep ? nil : .destructive) {
                    perform()
                    dismiss()
                } label: {
                    Text("\(request.verb) (\(effective.count))")
                }
                .tint(request.kind == .sleep ? nil : .red)
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
        let user = model.status(m).consoleUser
        let unreachable = model.willSkip(m)
        let skipped = unreachable || (skipLoggedIn && user != nil)
        return HStack(spacing: 8) {
            StatusDot(reachability: reachability)
            Text(m.name)
                .fontWeight(.medium)
                .strikethrough(skipped)
            Spacer()
            if unreachable {
                Text("pominięty – \(model.knownReachability(m).label)")
                    .foregroundStyle(.secondary)
            } else {
                if request.kind == .restart, classroom.fileVault[m.id] == true {
                    Label("FileVault", systemImage: "lock.shield")
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
        case .logout: return "rectangle.portrait.and.arrow.right"
        case .sleep: return "moon.zzz.fill"
        case .restart: return "arrow.clockwise.circle.fill"
        case .shutdown: return "power.circle.fill"
        }
    }

    var subtitle: String {
        if request.kind == .logout { return "Sesje zostaną zakończone natychmiast – aplikacje nie zapytają o zapisanie zmian." }
        if request.delay > 0 {
            return "Za \(request.delay) min\(request.warn ? ", po wcześniejszym komunikacie na ekranie" : ""). Do tego czasu możesz to odwołać przyciskiem „Odwołaj” (Zaplanowane na później)."
        }
        return request.kind == .sleep ? "Komputery zasną od razu; obudzisz je przyciskiem „Obudź”."
            : "Zalogowani uczniowie stracą niezapisane prace."
    }

    /// Macs the action really reaches: unreachable ones are skipped as in the header ("Pomiń niedostępne").
    var reached: [Machine] { request.machines.filter { !model.willSkip($0) } }

    var loggedIn: Int { reached.filter { model.status($0).consoleUser != nil }.count }

    var fileVaultCount: Int { reached.filter { classroom.fileVault[$0.id] == true }.count }

    var needsAcknowledgement: Bool {
        request.kind != .sleep && request.delay == 0 && effective.filter { model.status($0).consoleUser != nil }.count >= 5
    }

    var effective: [Machine] {
        skipLoggedIn ? reached.filter { model.status($0).consoleUser == nil } : reached
    }

    /// What is handed to the batch: unreachable Macs stay in it (as skipped jobs, so they can be retried).
    var targets: [Machine] {
        skipLoggedIn ? request.machines.filter { model.status($0).consoleUser == nil } : request.machines
    }

    func perform() {
        let list = targets
        guard !effective.isEmpty else { return }
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
