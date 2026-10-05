import AppKit
import CMCRCore
import SwiftUI

/// "Zajęcia": one-click lesson routines, attention mode and questions to students.
struct ClassroomView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .classroom,
                         subtitle: "Gotowe scenariusze na początek i koniec lekcji, tryb uwagi oraz szybkie pytania do uczniów.")
                .padding([.horizontal, .top], 20)
            ScrollViewReader { proxy in
                Form {
                    StartLessonSection(confirm: $confirm)
                    EndLessonSection(confirm: $confirm)
                    if let run = classroom.run {
                        LessonProgressSection(run: run)
                            .id("progress")
                    }
                    AttentionSection()
                    QuestionSection()
                    if model.lastBatch[.classroom] != nil {
                        Section {
                            LastBatchView(section: .classroom)
                        }
                    }
                }
                .formStyle(.grouped)
                .onChange(of: classroom.run?.id) { _, id in
                    guard id != nil else { return }
                    withAnimation { proxy.scrollTo("progress", anchor: .top) }
                }
            }
        }
        .confirmation($confirm)
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
                StepLabel(.wake, "Obudź komputery i poczekaj, aż będą gotowe")
            }
            if c.wrappedValue.wake {
                Stepper(value: c.wakeWaitMinutes, in: 1...10) {
                    Text("Czekaj najwyżej \(c.wrappedValue.wakeWaitMinutes) min")
                }
                .padding(.leading, 28)
                .help("Komputery, które w tym czasie nie odpowiedzą, zostaną pominięte w kolejnych krokach.")
            }

            Toggle(isOn: c.sendMaterials) {
                StepLabel(.materials, "Wyślij materiały z folderu na Macu nauczyciela")
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
                    }
                }
                .padding(.leading, 28)
                Picker("Dokąd", selection: c.destination) {
                    ForEach(LessonStartConfig.Destination.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .padding(.leading, 28)
            }

            Toggle(isOn: c.openApps) {
                StepLabel(.openApps, "Uruchom aplikacje")
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
                StepLabel(.greet, "Wyślij powitanie")
            }
            if c.wrappedValue.greet {
                TextField("Tytuł", text: c.greetingTitle)
                    .padding(.leading, 28)
                TextField("Treść", text: c.greetingText, prompt: Text("Treść powitania"), axis: .vertical)
                    .lineLimit(2...4)
                    .padding(.leading, 28)
                Picker("Forma", selection: c.greetingAsDialog) {
                    Text("Powiadomienie").tag(false)
                    Text("Okno z przyciskiem OK").tag(true)
                }
                .padding(.leading, 28)
            }

            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    classroom.startLesson(model, targets: model.selectedMachines)
                } label: {
                    Label("Rozpocznij zajęcia", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty || plan.steps.isEmpty || running)
                .help(model.selection.isEmpty ? "Zaznacz komputery na liście" : "Wykona zaznaczone kroki na \(model.selection.count) \(Plural.computersLocative(model.selection.count))")
            }
        } header: {
            Label("Rozpocznij zajęcia", systemImage: "play.circle")
        } footer: {
            Text("Kroki wykonują się po kolei na każdym komputerze; postęp zobaczysz poniżej i w sekcji Zadania.")
                .foregroundStyle(.secondary)
        }
    }

    var plan: LessonPlan { LessonPlan.start(c.wrappedValue, settings: model.settings) }

    var running: Bool { classroom.run.map { !$0.finished } ?? false }

    var materialsText: String {
        let folder = c.wrappedValue.materialsFolder
        if folder.isEmpty { return "Nie wybrano folderu" }
        let n = classroom.materialItems(folder).count
        return "\((folder as NSString).abbreviatingWithTildeInPath) – \(n) \(Plural.form(n, one: "element", few: "elementy", many: "elementów"))"
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
                StepLabel(.warn, "Uprzedź uczniów i odczekaj")
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

            Toggle(isOn: c.collect) {
                StepLabel(.collect, "Zbierz prace do nowego folderu")
            }
            if c.wrappedValue.collect {
                TextField("Klasa lub temat", text: c.collectLabel, prompt: Text("opcjonalnie, np. 3A Unity"))
                    .padding(.leading, 28)
                LabeledContent("Zapis do") {
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

            Toggle(isOn: c.quitApps) {
                StepLabel(.quitApps, "Zamknij aplikacje")
            }
            if c.wrappedValue.quitApps {
                Picker("Które", selection: c.quitAllApps) {
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

            Toggle(isOn: Binding(get: { c.wrappedValue.collect && c.wrappedValue.cleanShared },
                                 set: { c.wrappedValue.cleanShared = $0 })) {
                StepLabel(.cleanShared, "Wyczyść folder cmcr ucznia")
            }
            .disabled(!c.wrappedValue.collect)
            .help(c.wrappedValue.collect
                  ? "Po zebraniu prac usuwa zawartość folderu cmcr ucznia"
                  : "Włącz „Zbierz prace” – folder ucznia jest czyszczony dopiero po zebraniu z niego prac")
            Toggle(isOn: c.cleanDownloads) {
                StepLabel(.cleanDownloads, "Wyczyść folder Pobrane ucznia")
            }
            Toggle(isOn: c.logout) {
                StepLabel(.logout, "Wyloguj ucznia")
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

            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    askToEnd()
                } label: {
                    Label("Zakończ zajęcia", systemImage: "stop.fill")
                }
                .disabled(model.selection.isEmpty || plan.steps.isEmpty || running)
                .help(model.selection.isEmpty ? "Zaznacz komputery na liście" : "Wykona zaznaczone kroki na \(model.selection.count) \(Plural.computersLocative(model.selection.count))")
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
        let n = targets.count
        let users = targets.compactMap { model.status($0).consoleUser }.count
        var lines = plan.steps.map { "• \($0.title)" }
        if users > 0 { lines.append("\nZalogowani uczniowie: \(users). Niezapisane prace w otwartych aplikacjach przepadną.") }
        confirm = ConfirmRequest(
            title: "Zakończyć zajęcia na \(n) \(Plural.computersLocative(n))?",
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
                         : "Problemy na \(run.failedHosts) \(Plural.computersLocative(run.failedHosts)) – szczegóły w sekcji Zadania.")
                } else if let end = run.countdownEnd {
                    Image(systemName: "timer")
                    Text("Kolejne kroki za ") + Text(timerInterval: Date()...end, countsDown: true).monospacedDigit()
                    Button("Nie czekaj") { run.skipCountdown = true }
                        .controlSize(.small)
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
                }
                if !run.finished {
                    Button(role: .cancel) {
                        run.cancel()
                    } label: {
                        Label("Przerwij", systemImage: "xmark.circle")
                    }
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
            HStack {
                TextField("Komunikat na ekranie", text: $classroom.config.lockMessage)
                Menu {
                    ForEach(Self.templates, id: \.self) { t in Button(t) { classroom.config.lockMessage = t } }
                } label: {
                    Label("Szablony", systemImage: "text.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Wstaw gotowy komunikat")
            }
            Picker("Sposób blokady", selection: $classroom.config.lockMode) {
                ForEach(AttentionMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Odblokuj automatycznie", selection: $classroom.config.autoUnlockMinutes) {
                ForEach(Self.unlockChoices, id: \.self) { n in
                    Text(n == 0 ? "Nie (tylko ręcznie)" : "po \(n) min").tag(n)
                }
            }
            .help("Zabezpieczenie na wypadek utraty połączenia z komputerem – ekran odblokuje się sam.")
            if !lockedNames.isEmpty {
                LabeledContent("Zablokowane") {
                    Text(lockedNames).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack {
                Spacer()
                TargetButton(title: "Odblokuj", icon: "lock.open", prominent: false) {
                    classroom.unlock(model, model.selectedMachines)
                }
                .help("Zdejmij blokadę z zaznaczonych komputerów")
                TargetButton(title: "Zablokuj ekrany", icon: "lock.fill", prominent: false) {
                    classroom.lock(model, model.selectedMachines)
                }
                .help("Zakryj ekrany zaznaczonych komputerów komunikatem")
            }
        } header: {
            Label("Tryb uwagi", systemImage: "eye.slash")
        } footer: {
            Text("Blokada systemowa używa narzędzia LockScreen wbudowanego w macOS (z Apple Remote Desktop): zakrywa wszystkie ekrany i blokuje klawiaturę. Apple go nie dokumentuje, dlatego tryb automatyczny, gdy blokada się nie uruchomi, pokazuje komunikat na pełnym ekranie. Komunikat ukrywa Dock i pasek menu oraz wyłącza przełączanie aplikacji, ale nie jest zabezpieczeniem – nie powstrzyma np. wyłączenia komputera przyciskiem.")
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
            Picker("Czekaj na odpowiedź", selection: $classroom.config.questionTimeoutMinutes) {
                ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
            }
            HStack {
                Spacer()
                TargetButton(title: "Zadaj pytanie", icon: "questionmark.bubble", prominent: false) {
                    classroom.ask(model, model.selectedMachines, buttons: withButtons ? buttons : [])
                }
                .disabled(classroom.config.lastQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || buttonProblem != nil)
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
                    Text("czeka: \(round.pending)").foregroundStyle(.secondary).monospacedDigit()
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

struct StepLabel: View {
    let step: LessonStepKind
    let text: String

    init(_ step: LessonStepKind, _ text: String) {
        self.step = step
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: step.icon)
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
