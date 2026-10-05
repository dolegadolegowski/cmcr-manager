import AppKit
import CMCRCore
import SwiftUI

/// Parts of the "Zajęcia" section, switched with a segmented control (each fits on one screen).
enum ClassroomTab: String, CaseIterable, Identifiable {
    case start, end, attention, questions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return "Początek lekcji"
        case .end: return "Koniec lekcji"
        case .attention: return "Tryb uwagi"
        case .questions: return "Pytania"
        }
    }

    var icon: String {
        switch self {
        case .start: return "play.circle"
        case .end: return "stop.circle"
        case .attention: return "eye.slash"
        case .questions: return "questionmark.bubble"
        }
    }

    var help: String {
        switch self {
        case .start: return "Scenariusz na początek lekcji: budzenie, materiały, aplikacje, powitanie"
        case .end: return "Scenariusz na koniec lekcji: zbieranie prac, porządki, wylogowanie, uśpienie"
        case .attention: return "Zablokuj ekrany uczniów komunikatem, np. „Proszę patrzeć na tablicę”"
        case .questions: return "Zadaj uczniom pytanie i zbierz odpowiedzi"
        }
    }
}

/// "Zajęcia": one-click lesson routines, attention mode and questions to students.
struct ClassroomView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @AppStorage("classroom.tab") private var tab: ClassroomTab = .start
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .classroom,
                         subtitle: "Początek i koniec lekcji jednym przyciskiem, tryb uwagi (zablokowane ekrany) i szybkie pytania do uczniów.")
                .padding([.horizontal, .top], 20)
            Picker("Część", selection: $tab) {
                ForEach(ClassroomTab.allCases) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                        .help(t.help)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            ScrollViewReader { proxy in
                Form {
                    switch tab {
                    case .start:
                        StartLessonSection(confirm: $confirm)
                        progress(.start)
                    case .end:
                        EndLessonSection(confirm: $confirm)
                        progress(.end)
                    case .attention:
                        AttentionSection()
                    case .questions:
                        QuestionSection()
                    }
                    if model.lastBatch[.classroom] != nil {
                        Section {
                            LastBatchView(section: .classroom)
                        }
                    }
                }
                .formStyle(.grouped)
                .onChange(of: classroom.run?.id) { _, id in
                    guard id != nil, let kind = classroom.run?.plan.kind else { return }
                    tab = kind == .start ? .start : .end
                    withAnimation { proxy.scrollTo("progress", anchor: .top) }
                }
            }
        }
        .confirmation($confirm)
    }

    @ViewBuilder private func progress(_ kind: LessonPlan.Kind) -> some View {
        if let run = classroom.run, run.plan.kind == kind {
            LessonProgressSection(run: run)
                .id("progress")
        }
    }
}

// MARK: - Start of lesson

private struct StartLessonSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @Binding var confirm: ConfirmRequest?

    private var c: Binding<LessonStartConfig> { $classroom.config.start }

    var body: some View {
        Section {
            Toggle(isOn: c.wake) {
                StepLabel(.wake, "Obudź komputery i poczekaj, aż będą gotowe",
                          caption: "Uśpione komputery dostaną sygnał budzenia przez sieć (Wake-on-LAN).")
            }
            if c.wrappedValue.wake {
                Stepper(value: c.wakeWaitMinutes, in: 1...10) {
                    Text("Czekaj najwyżej \(c.wrappedValue.wakeWaitMinutes) min")
                }
                .padding(.leading, 28)
                .help("Komputery, które w tym czasie nie odpowiedzą, zostaną pominięte w kolejnych krokach.")
            }

            Toggle(isOn: c.sendMaterials) {
                StepLabel(.materials, "Wyślij materiały z folderu na Macu nauczyciela",
                          caption: "Zawartość wybranego folderu trafi do każdego ucznia.")
            }
            if c.wrappedValue.sendMaterials {
                LabeledContent("Folder z materiałami") {
                    HStack {
                        Text(materialsText)
                            .foregroundStyle(c.wrappedValue.materialsFolder.isEmpty ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Wybierz…") {
                            if let url = Pickers.folder() { c.wrappedValue.materialsFolder = url.path }
                        }
                        .help("Wybierz folder z materiałami na tym Macu")
                    }
                }
                .padding(.leading, 28)
                Picker("Dokąd wysłać", selection: c.destination) {
                    ForEach(LessonStartConfig.Destination.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .padding(.leading, 28)
            }

            Toggle(isOn: c.openApps) {
                StepLabel(.openApps, "Uruchom aplikacje",
                          caption: "Otworzą się u zalogowanego ucznia.")
            }
            if c.wrappedValue.openApps {
                HStack {
                    TextField("Aplikacje", text: c.apps, prompt: Text("np. Unity Hub, Safari"))
                    AppNameMenu { name in
                        let list = c.wrappedValue.appList
                        if !list.contains(name) { c.wrappedValue.apps = (list + [name]).joined(separator: ", ") }
                    }
                }
                .padding(.leading, 28)
            }

            Toggle(isOn: c.greet) {
                StepLabel(.greet, "Wyślij powitanie",
                          caption: "Wiadomość pojawi się na ekranie ucznia.")
            }
            if c.wrappedValue.greet {
                TextField("Tytuł", text: c.greetingTitle)
                    .padding(.leading, 28)
                TextField("Treść", text: c.greetingText, prompt: Text("Treść powitania"), axis: .vertical)
                    .lineLimit(2...4)
                    .padding(.leading, 28)
                Picker("Jak pokazać", selection: c.greetingAsDialog) {
                    Text("Powiadomienie").tag(false)
                    Text("Okno z przyciskiem OK").tag(true)
                }
                .padding(.leading, 28)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                    if let note = wakeNote {
                        Text(note)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    classroom.startLesson(model, targets: model.selectedMachines)
                } label: {
                    Label("Rozpocznij zajęcia", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(targetCount == 0 || plan.steps.isEmpty || running)
                .help(buttonHelp)
            }
        } header: {
            Label("Rozpocznij zajęcia", systemImage: "play.circle")
        } footer: {
            Text("Kroki wykonują się po kolei na każdym komputerze; postęp zobaczysz poniżej i w dziale Zadania.")
                .foregroundStyle(.secondary)
        }
    }

    var plan: LessonPlan { LessonPlan.start(c.wrappedValue, settings: model.settings) }

    var running: Bool { classroom.run.map { !$0.finished } ?? false }

    /// A lesson that starts by waking the Macs runs on the unreachable ones too (they are woken first).
    var targetCount: Int {
        plan.steps.contains(.wake) ? model.selectedMachines.count : model.actionTargets.count
    }

    var wakeNote: String? {
        guard plan.steps.contains(.wake) else { return nil }
        let asleep = model.selectedMachines.filter { model.knownReachability($0).isUnreachable }.count
        return asleep == 0 ? nil : "Niedostępne komputery (\(asleep)) zostaną najpierw obudzone."
    }

    var buttonHelp: String {
        if model.selection.isEmpty { return "Najpierw zaznacz komputery na liście." }
        if plan.steps.isEmpty { return "Włącz przynajmniej jeden krok." }
        if targetCount == 0 {
            return "Wszystkie zaznaczone komputery są niedostępne – włącz budzenie albo odśwież stan komputerów."
        }
        return "Wykona zaznaczone kroki \(Polish.onComputers(targetCount))."
    }

    var materialsText: String {
        let folder = c.wrappedValue.materialsFolder
        if folder.isEmpty { return "Nie wybrano folderu" }
        let n = classroom.materialItems(folder).count
        return "\((folder as NSString).abbreviatingWithTildeInPath) – \(Polish.count(n, "element", "elementy", "elementów"))"
    }

    var summary: String {
        let steps = plan.steps
        if steps.isEmpty { return "Włącz przynajmniej jeden krok." }
        return steps.map(\.title).joined(separator: " → ")
    }
}

// MARK: - End of lesson

private struct EndLessonSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @Binding var confirm: ConfirmRequest?

    private var c: Binding<LessonEndConfig> { $classroom.config.end }

    var body: some View {
        Section {
            Toggle(isOn: c.warn) {
                StepLabel(.warn, "Uprzedź uczniów i odczekaj",
                          caption: "Uczniowie zobaczą komunikat; kolejne kroki ruszą po odliczeniu czasu.")
            }
            if c.wrappedValue.warn {
                TextField("Komunikat", text: c.warnText, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(.leading, 28)
                Stepper(value: c.warnMinutes, in: 1...15) {
                    Text("Odczekaj \(c.wrappedValue.warnMinutes) min przed kolejnymi krokami")
                }
                .padding(.leading, 28)
            }

            Toggle(isOn: c.quitApps) {
                StepLabel(.quitApps, "Zamknij aplikacje",
                          caption: "Przed zebraniem prac, aby w kopii znalazły się zapisane pliki.")
            }
            if c.wrappedValue.quitApps {
                Picker("Które aplikacje", selection: c.quitAllApps) {
                    Text("Wszystkie aplikacje ucznia").tag(true)
                    Text("Tylko wybrane").tag(false)
                }
                .padding(.leading, 28)
                if !c.wrappedValue.quitAllApps {
                    HStack {
                        TextField("Aplikacje", text: c.apps, prompt: Text("np. Unity, Safari"))
                        AppNameMenu { name in
                            let list = c.wrappedValue.appList
                            if !list.contains(name) { c.wrappedValue.apps = (list + [name]).joined(separator: ", ") }
                        }
                    }
                    .padding(.leading, 28)
                }
            }

            Toggle(isOn: c.collect) {
                StepLabel(.collect, "Zbierz prace do nowego folderu",
                          caption: "Kopia folderu cmcr każdego ucznia trafi na ten Mac.")
            }
            if c.wrappedValue.collect {
                TextField("Klasa lub temat", text: c.collectLabel, prompt: Text("opcjonalnie, np. 3A Unity"))
                    .padding(.leading, 28)
                LabeledContent("Zapisz w") {
                    HStack {
                        Text(collectPreview)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            model.openLocalFolder((model.settings.localFolder as NSString).appendingPathComponent("zebrane"))
                        } label: {
                            Label("Pokaż w Finderze", systemImage: "folder")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Otwórz folder z zebranymi pracami")
                    }
                }
                .padding(.leading, 28)
            }

            Toggle(isOn: Binding(get: { c.wrappedValue.collect && c.wrappedValue.cleanShared },
                                 set: { c.wrappedValue.cleanShared = $0 })) {
                StepLabel(.cleanShared, "Wyczyść folder cmcr ucznia",
                          caption: "Tylko po udanym zebraniu prac z tego komputera.")
            }
            .disabled(!c.wrappedValue.collect)
            .help(c.wrappedValue.collect
                  ? "Po zebraniu prac usuwa zawartość folderu cmcr ucznia"
                  : "Włącz „Zbierz prace” – folder ucznia jest czyszczony dopiero po zebraniu z niego prac")
            Toggle(isOn: c.cleanDownloads) {
                StepLabel(.cleanDownloads, "Wyczyść folder Pobrane ucznia",
                          caption: "Usuwa pliki pobrane z internetu.")
            }
            Toggle(isOn: c.logout) {
                StepLabel(.logout, "Wyloguj ucznia",
                          caption: "Niezapisane prace w otwartych aplikacjach przepadną.")
            }
            Picker(selection: c.power) {
                ForEach(LessonEndConfig.PowerChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                StepLabel(c.wrappedValue.power == .shutdown ? .shutdown : .sleep, "Na koniec")
            }
            if c.wrappedValue.power == .shutdown {
                Label("Wyłączonych komputerów nie obudzisz przez sieć (Wake-on-LAN działa tylko z uśpienia). Rano włączy je tylko harmonogram zasilania albo przycisk.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                let disruptive = c.wrappedValue.isDisruptive
                Button(role: disruptive ? .destructive : nil) {
                    askToEnd()
                } label: {
                    Label(disruptive ? "Zakończ zajęcia…" : "Zakończ zajęcia", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(disruptive ? .red : nil)
                .fixedSize()
                .disabled(model.actionTargets.isEmpty || plan.steps.isEmpty || running)
                .help(buttonHelp)
            }
        } header: {
            Label("Zakończ zajęcia", systemImage: "stop.circle")
        } footer: {
            Text("Folder cmcr ucznia jest czyszczony tylko razem ze zbieraniem prac i tylko na komputerach, z których udało się je zebrać. Gdy zbieranie się nie uda, folder Pobrane też zostaje nietknięty. Aplikacje są zamykane przed zbieraniem prac.")
                .foregroundStyle(.secondary)
        }
    }

    var plan: LessonPlan { LessonPlan.end(c.wrappedValue, settings: model.settings) }

    var running: Bool { classroom.run.map { !$0.finished } ?? false }

    var buttonHelp: String {
        let n = model.actionTargets.count
        if model.selection.isEmpty { return "Najpierw zaznacz komputery na liście." }
        if plan.steps.isEmpty { return "Włącz przynajmniej jeden krok." }
        if n == 0 { return "Wszystkie zaznaczone komputery są niedostępne – odśwież stan komputerów." }
        return "Wykona zaznaczone kroki \(Polish.onComputers(n))"
            + (c.wrappedValue.isDisruptive ? " – najpierw poprosi o potwierdzenie." : ".")
    }

    var collectPreview: String {
        let url = LessonPlan.collectFolder(base: model.settings.localFolder, label: c.wrappedValue.collectLabel, date: Date())
        return (url.appendingPathComponent("<komputer>").path as NSString).abbreviatingWithTildeInPath
    }

    var summary: String {
        let steps = plan.steps
        if steps.isEmpty { return "Włącz przynajmniej jeden krok." }
        return steps.map(\.title).joined(separator: " → ")
    }

    func askToEnd() {
        let targets = model.selectedMachines
        guard c.wrappedValue.isDisruptive else {
            classroom.endLesson(model, targets: targets)
            return
        }
        let reached = model.actionTargets
        let n = reached.count
        let users = reached.compactMap { model.status($0).consoleUser }.count
        var lines = plan.steps.map { "• \($0.title)" }
        if users > 0 { lines.append("\nZalogowani uczniowie: \(users). Niezapisane prace w otwartych aplikacjach przepadną.") }
        confirm = ConfirmRequest(
            title: "Zakończyć zajęcia \(Polish.onComputers(n))?",
            message: lines.joined(separator: "\n"),
            button: "Zakończ zajęcia") {
            classroom.endLesson(model, targets: targets)
        }
    }
}

// MARK: - Progress

private struct LessonProgressSection: View {
    @ObservedObject var run: LessonRun
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            HStack(spacing: 12) {
                if run.finished {
                    Image(systemName: run.failedHosts == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(run.failedHosts == 0 ? .green : .orange)
                    Text(run.failedHosts == 0 ? "Gotowe na wszystkich komputerach."
                         : "Problemy \(Polish.onComputers(run.failedHosts)) – szczegóły w dziale Zadania.")
                } else if let end = run.countdownEnd {
                    Image(systemName: "timer")
                    Text("Kolejne kroki za ") + Text(timerInterval: Date()...end, countsDown: true).monospacedDigit()
                    Button {
                        run.skipCountdown = true
                    } label: {
                        Label("Pomiń odliczanie", systemImage: "forward.fill")
                    }
                    .controlSize(.small)
                    .help("Wykonaj kolejne kroki od razu, bez czekania do końca odliczania")
                } else {
                    ProgressView(value: run.progress)
                        .frame(maxWidth: 220)
                    Text("\(Int(run.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if let folder = run.plan.collectFolder {
                    Button {
                        NSWorkspace.shared.open(folder)
                    } label: {
                        Label("Otwórz zebrane prace", systemImage: "folder")
                    }
                    .help("Pokaż folder z zebranymi pracami w Finderze")
                }
                if !run.finished {
                    Button(role: .cancel) {
                        run.cancel()
                    } label: {
                        Label("Przerwij", systemImage: "xmark.circle")
                    }
                    .help("Zatrzymaj scenariusz – kroki, które już się wykonały, nie zostaną cofnięte")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Komputer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(run.plan.steps.enumerated()), id: \.offset) { _, step in
                        Image(systemName: step.icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .help(step.title)
                            .accessibilityLabel(step.title)
                    }
                }
                ForEach(run.machines) { m in
                    GridRow {
                        Text(m.name).fontWeight(.medium)
                        ForEach(Array(run.plan.steps.enumerated()), id: \.offset) { i, step in
                            StepStateIcon(state: run.state(m.id, i))
                                .frame(width: 22)
                                .help("\(step.title): \(run.state(m.id, i).detail)")
                        }
                    }
                }
            }
        } header: {
            Label("\(run.plan.kind.title) – \(run.startedAt.formatted(date: .omitted, time: .shortened))",
                  systemImage: "list.bullet.clipboard")
        }
    }
}

struct StepStateIcon: View {
    let state: StepState

    var body: some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityLabel("oczekuje")
        case .running:
            ProgressView().controlSize(.small).accessibilityLabel("w toku")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("wykonano")
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).accessibilityLabel("pominięto")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("błąd")
        }
    }
}

// MARK: - Attention mode

private struct AttentionSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared

    static let templates = ["Proszę patrzeć na tablicę", "Przerwa – wracamy za 5 minut", "Słuchamy instrukcji nauczyciela",
                            "Odłóż mysz i klawiaturę"]
    static let unlockChoices = [0, 5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                TextField("Komunikat na ekranie", text: $classroom.config.lockMessage,
                          prompt: Text("np. Proszę patrzeć na tablicę"))
                Menu {
                    ForEach(Self.templates, id: \.self) { t in Button(t) { classroom.config.lockMessage = t } }
                } label: {
                    Label("Szablony", systemImage: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Wstaw gotowy komunikat")
            }
            Picker(selection: $classroom.config.lockMode) {
                ForEach(AttentionMode.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            } label: {
                Text("Sposób blokady")
                Text(classroom.config.lockMode.caption)
            }
            Picker(selection: $classroom.config.autoUnlockMinutes) {
                ForEach(Self.unlockChoices, id: \.self) { n in
                    Text(n == 0 ? "Nie – tylko ręcznie" : "Po \(n) min").tag(n)
                }
            } label: {
                Text("Odblokuj automatycznie")
                Text("Zabezpieczenie na wypadek utraty połączenia – ekran odblokuje się sam.")
            }
            if !lockedNames.isEmpty {
                LabeledContent {
                    Text(lockedNames).foregroundStyle(.secondary).lineLimit(2)
                } label: {
                    Label("Zablokowane teraz", systemImage: "lock.fill")
                }
            }
            HStack(spacing: 12) {
                Spacer()
                TargetButton(title: "Odblokuj ekrany", icon: "lock.open", prominent: false) {
                    classroom.unlock(model, model.selectedMachines)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .help("Zdejmij blokadę z zaznaczonych komputerów (⇧⌘U)")
                TargetButton(title: "Zablokuj ekrany", icon: "lock.fill") {
                    classroom.lock(model, model.selectedMachines)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Zakryj ekrany zaznaczonych komputerów komunikatem (⇧⌘L)")
            }
        } header: {
            Label("Tryb uwagi", systemImage: "eye.slash")
        } footer: {
            Text("Blokada systemowa korzysta z narzędzia wbudowanego w macOS (LockScreen z Apple Remote Desktop): zakrywa wszystkie ekrany i blokuje klawiaturę. Apple go nie dokumentuje, więc gdy się nie uruchomi, tryb automatyczny pokaże komunikat na pełnym ekranie. Komunikat ukrywa Dock i pasek menu, ale nie jest zabezpieczeniem – nie powstrzyma np. wyłączenia komputera przyciskiem.")
                .foregroundStyle(.secondary)
        }
    }

    var lockedNames: String {
        model.machines.filter { classroom.isLocked($0.id) }.map(\.name).joined(separator: ", ")
    }
}

// MARK: - Questions

private struct QuestionSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared

    private var withButtons: Bool { classroom.config.questionWithButtons }
    private var buttons: [String] { classroom.config.questionButtonList }

    /// Why the question cannot be sent yet (shown under the button list), or nil.
    private var buttonProblem: String? {
        guard withButtons else { return nil }
        if buttons.isEmpty { return "Wpisz nazwy przycisków, rozdzielone przecinkami." }
        let limit = ClassroomConfig.maxQuestionButtons
        if buttons.count > limit {
            return "Okno pytania mieści najwyżej \(limit) przyciski – usuń \(buttons.count - limit)."
        }
        return nil
    }

    var body: some View {
        Section {
            TextField("Pytanie", text: $classroom.config.lastQuestion, prompt: Text("np. Czy skończyłeś zadanie 3?"),
                      axis: .vertical)
                .lineLimit(1...4)
            Picker("Odpowiedź", selection: $classroom.config.questionWithButtons) {
                Text("Uczeń wpisuje tekst").tag(false)
                Text("Uczeń wybiera przycisk").tag(true)
            }
            .pickerStyle(.segmented)
            if withButtons {
                TextField("Przyciski", text: $classroom.config.questionButtons, prompt: Text("np. Tak, Nie, Potrzebuję pomocy"))
                    .help("Najwyżej \(ClassroomConfig.maxQuestionButtons) przyciski, rozdzielone przecinkami.")
                if let buttonProblem {
                    Label(buttonProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Picker(selection: $classroom.config.questionTimeoutMinutes) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
            } label: {
                Text("Czekaj na odpowiedź")
                Text("Potem okno pytania zniknie z ekranu ucznia.")
            }
            HStack {
                Spacer()
                TargetButton(title: "Zadaj pytanie", icon: "questionmark.bubble") {
                    classroom.ask(model, model.selectedMachines, buttons: withButtons ? buttons : [])
                }
                .disabled(classroom.config.lastQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || buttonProblem != nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
            if let round = classroom.question {
                AnswersView(round: round)
            }
        } header: {
            Label("Zapytaj uczniów", systemImage: "questionmark.bubble")
        } footer: {
            Text("Pytanie pojawia się w oknie na ekranie ucznia; odpowiedzi zbierają się tutaj.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AnswersView: View {
    @ObservedObject var round: QuestionRound
    @ObservedObject private var classroom = ClassroomModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("„\(round.question)” – \(round.askedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                if round.pending > 0 {
                    ProgressView().controlSize(.small)
                    Text("czeka na odpowiedź: \(round.pending)").foregroundStyle(.secondary).monospacedDigit()
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rows.dropFirst().map { $0.joined(separator: "\t") }.joined(separator: "\n"),
                                                   forType: .string)
                } label: {
                    Label("Kopiuj", systemImage: "doc.on.doc")
                }
                .help("Kopiuj odpowiedzi do schowka")
                Button {
                    classroom.exportCSV(rows, suggestedName: "odpowiedzi.csv")
                } label: {
                    Label("Eksportuj CSV…", systemImage: "square.and.arrow.up")
                }
                .help("Zapisz odpowiedzi w pliku CSV (otworzysz go w Excelu lub Numbers)")
            }
            .controlSize(.small)
            ForEach(round.machines) { m in
                LabeledContent {
                    answerText(m)
                } label: {
                    Text(label(m))
                }
            }
        }
    }

    func label(_ m: Machine) -> String {
        if let user = round.answers[m.id]?.user, !user.isEmpty { return "\(m.name) · \(user)" }
        return m.name
    }

    @ViewBuilder func answerText(_ m: Machine) -> some View {
        if let a = round.answers[m.id] {
            Text(a.displayText)
                .foregroundStyle(a.kind == .answered ? .primary : .secondary)
                .textSelection(.enabled)
        } else if let e = round.errors[m.id] {
            Text(e).foregroundStyle(.red).lineLimit(2)
        } else {
            Text("czeka na odpowiedź…").foregroundStyle(.tertiary)
        }
    }

    var rows: [[String]] {
        [["Komputer", "Uczeń", "Odpowiedź", "Godzina"]] + round.machines.map { m in
            let a = round.answers[m.id]
            return [m.name, a?.user ?? "", a?.displayText ?? round.errors[m.id] ?? "",
                    round.answeredAt[m.id]?.formatted(date: .omitted, time: .standard) ?? ""]
        }
    }
}

// MARK: - Shared bits

/// Step of a lesson routine: its icon, a title and an optional one-line explanation under it.
struct StepLabel: View {
    let step: LessonStepKind
    let text: String
    var caption: String?

    init(_ step: LessonStepKind, _ text: String, caption: String? = nil) {
        self.step = step
        self.text = text
        self.caption = caption
    }

    var body: some View {
        Label {
            Text(text)
            if let caption {
                Text(caption)
            }
        } icon: {
            Image(systemName: step.icon)
        }
    }
}

extension AttentionMode {
    /// Wording for the picker (the core label names the undocumented tool).
    var displayLabel: String {
        switch self {
        case .automatic: return "Automatycznie (zalecane)"
        case .lockScreen: return "Blokada systemowa"
        case .overlay: return "Komunikat na pełnym ekranie"
        }
    }

    var caption: String {
        switch self {
        case .automatic: return "Najpierw blokada systemowa, a gdy się nie uruchomi – komunikat na pełnym ekranie."
        case .lockScreen: return "Zakrywa ekrany i blokuje klawiaturę narzędziem wbudowanym w macOS."
        case .overlay: return "Okno z komunikatem zasłania ekran ucznia."
        }
    }
}

/// Menu with application names known from the Apps section (installed apps of any Mac).
struct AppNameMenu: View {
    @EnvironmentObject var model: AppModel
    let pick: (String) -> Void

    var body: some View {
        Menu {
            let names = knownNames
            if names.isEmpty {
                Text("Lista pojawi się po pobraniu zainstalowanych aplikacji (sekcja Aplikacje).")
            }
            ForEach(names, id: \.self) { name in Button(name) { pick(name) } }
        } label: {
            Label("Wybierz aplikację", systemImage: "square.grid.2x2")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Wybierz z listy zainstalowanych aplikacji")
    }

    var knownNames: [String] {
        let all = model.installedApps.values.flatMap { $0 }
            .filter { $0.hasPrefix("/Applications/") }
            .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        return Array(Set(all)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
