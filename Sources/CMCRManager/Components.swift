import AppKit
import CMCRCore
import SwiftUI
import UniformTypeIdentifiers

extension Reachability {
    var color: Color {
        switch self {
        case .online: return .green
        case .offline: return .gray
        case .authFailed: return .orange
        case .error: return .red
        case .checking: return .blue
        case .unknown: return Color.secondary.opacity(0.6)
        }
    }

    /// Distinct shape per state, so the status does not depend on colour alone.
    var symbol: String {
        switch self {
        case .online: return "checkmark.circle.fill"
        case .offline: return "moon.zzz.fill"
        case .authFailed: return "key.slash"
        case .error: return "exclamationmark.triangle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "circle.dashed"
        }
    }
}

/// Status of a Mac: a coloured SF Symbol (or a spinner while checking) with an accessibility label.
struct StatusDot: View {
    let reachability: Reachability

    var body: some View {
        Group {
            if reachability == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: reachability.symbol)
                    .foregroundStyle(reachability.color)
                    .imageScale(.medium)
            }
        }
        .frame(width: 16, height: 16)
        .help(reachability.label.capitalizedFirst)
        .accessibilityElement()
        .accessibilityLabel("Stan: \(reachability.label)")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Header shown on every action page: which Macs the action will target.
struct TargetHeader: View {
    @EnvironmentObject var model: AppModel
    let section: AppSection
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 16)
                    TargetSummary()
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    TargetSummary()
                }
            }
            if let subtitle {
                // No fixedSize here: these headers also sit outside scroll views, where a vertically fixed
                // text would inflate the window's minimum height.
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.bottom, 4)
    }

    var title: some View {
        Label(section.title, systemImage: section.icon)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
    }
}

/// "Cel: 6 komputerów" – counts only the Macs an action will really reach, names in the tooltip.
struct TargetSummary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let selected = model.selectedMachines
        let unreachable = selected.filter { model.status($0).reachability.isUnreachable }
        if selected.isEmpty {
            Label("Zaznacz komputery na liście", systemImage: "hand.point.left")
                .foregroundStyle(.secondary)
                .font(.callout)
                .symbolRenderingMode(.multicolor)
        } else {
            HStack(spacing: 10) {
                Label {
                    Text(summary(selected: selected.count, unreachable: unreachable.count))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "scope")
                }
                .font(.callout)
                .help(names(selected))
                if !unreachable.isEmpty {
                    Toggle("Pomiń niedostępne", isOn: $model.skipUnreachable)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Niedostępne teraz: \(unreachable.map(\.name).joined(separator: ", ")). "
                              + "Pominięte komputery pojawią się w wynikach – można później powtórzyć na nich operację.")
                }
            }
            .fixedSize()
        }
    }

    func summary(selected: Int, unreachable: Int) -> String {
        guard unreachable > 0 else { return "Cel: \(Polish.computers(selected))" }
        if model.skipUnreachable {
            return "Cel: \(Polish.computers(selected - unreachable)) (pominięte niedostępne: \(unreachable))"
        }
        return "Cel: \(Polish.computers(selected)), w tym niedostępne: \(unreachable)"
    }

    func names(_ machines: [Machine]) -> String {
        let list = machines.map { m in
            model.willSkip(m) ? "\(m.name) (pominięty – \(model.status(m).reachability.label))" : m.name
        }
        return list.joined(separator: ", ")
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
    }
}

/// Action button for the selected Macs. Disabled when nothing reachable is selected; the tooltip says on how
/// many Macs it will run (unreachable ones are skipped unless `includeUnreachable`, e.g. Wake-on-LAN).
struct TargetButton: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var icon: String = "play.fill"
    var role: ButtonRole?
    var prominent = true
    var includeUnreachable = false
    let action: () -> Void

    var body: some View {
        let selected = model.selectedMachines.count
        let count = includeUnreachable ? selected : model.actionTargets.count
        let button = Button(role: role, action: action) {
            Label(title, systemImage: icon)
        }
        .disabled(count == 0)
        .help(help(selected: selected, count: count))
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    func help(selected: Int, count: Int) -> String {
        if selected == 0 { return "Najpierw zaznacz komputery na liście." }
        if count == 0 {
            return "Wszystkie zaznaczone komputery były niedostępne przy ostatnim sprawdzeniu. "
                + "Odśwież stan komputerów albo wyłącz „Pomiń niedostępne”."
        }
        if count == selected { return "\(title) – \(Polish.onComputers(count))." }
        return "\(title) – \(Polish.onComputers(count)) z \(selected) zaznaczonych (niedostępne zostaną pominięte)."
    }
}

// MARK: - Confirmation

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    var destructive = true
    /// Macs the action affects, listed in the confirmation sheet. nil = the current action targets; an empty
    /// list means the question is not about Macs (a plain alert is shown).
    var targets: [Machine]?
    let action: () -> Void
}

extension View {
    /// Asks before running `request.action`: a sheet listing the affected Macs and their logged-in users, or a
    /// plain alert for questions that do not concern Macs.
    func confirmation(_ request: Binding<ConfirmRequest?>) -> some View {
        modifier(ConfirmationModifier(request: request))
    }
}

private struct ConfirmationModifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var request: ConfirmRequest?

    func targets(_ r: ConfirmRequest) -> [Machine] { r.targets ?? model.actionTargets }

    func body(content: Content) -> some View {
        let sheet = Binding<ConfirmRequest?>(
            get: { request.flatMap { targets($0).isEmpty ? nil : $0 } },
            set: { if $0 == nil { request = nil } })
        let alert = Binding<Bool>(
            get: { request.map { targets($0).isEmpty } ?? false },
            set: { if !$0 { request = nil } })
        content
            .sheet(item: sheet) { r in
                ConfirmSheet(request: r, targets: targets(r)) { request = nil }
                    .environmentObject(model)
            }
            .alert(request?.title ?? "", isPresented: alert, presenting: request) { r in
                Button(r.button, role: r.destructive ? .destructive : nil) { r.action() }
                Button("Anuluj", role: .cancel) {}
            } message: { r in
                Text(r.message)
            }
            .dialogSeverity(request?.destructive == true ? .critical : .automatic)
    }
}

/// Lists the Macs a dangerous action will hit, highlights logged-in users and can leave those Macs out.
struct ConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    let request: ConfirmRequest
    let targets: [Machine]
    let close: () -> Void
    @ViewState private var skipLoggedIn = false
    @ViewState private var acknowledged = false

    /// From this many Macs on, a destructive action needs an explicit "Rozumiem".
    static let acknowledgeFrom = 5

    var withUser: [Machine] { targets.filter { model.status($0).consoleUser != nil } }
    var effective: [Machine] {
        skipLoggedIn ? targets.filter { model.status($0).consoleUser == nil } : targets
    }
    var needsAcknowledgement: Bool { request.destructive && effective.count >= Self.acknowledgeFrom }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: request.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(request.destructive ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.title).font(.headline)
                    Text(request.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Dotyczy: \(Polish.computers(effective.count))")
                    .font(.subheadline.weight(.semibold))
                List(targets) { m in row(m) }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: min(220, CGFloat(targets.count) * 26 + 10))
            }
            if !withUser.isEmpty {
                Toggle("Pomiń komputery z zalogowanym użytkownikiem (\(withUser.count))", isOn: $skipLoggedIn)
                    .help(withUser.map(\.name).joined(separator: ", "))
            }
            if needsAcknowledgement {
                Toggle("Rozumiem – operacja obejmie \(Polish.computers(effective.count)) i nie da się jej cofnąć",
                       isOn: $acknowledged)
            }
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                confirmButton
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder var confirmButton: some View {
        let disabled = effective.isEmpty || (needsAcknowledgement && !acknowledged)
        if request.destructive {
            // Never the default action: Return must not restart a classroom.
            Button(role: .destructive, action: confirm) { Text(request.button) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(disabled)
        } else {
            Button(request.button, action: confirm)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        }
    }

    func row(_ m: Machine) -> some View {
        let user = model.status(m).consoleUser
        let skipped = skipLoggedIn && user != nil
        return HStack(spacing: 8) {
            StatusDot(reachability: model.status(m).reachability)
            Text(m.name)
                .fontWeight(.medium)
                .strikethrough(skipped)
            Spacer()
            if let user {
                Label(skipped ? "\(user) – pominięty" : "zalogowany: \(user)", systemImage: "person.fill")
                    .foregroundStyle(skipped ? Color.secondary : Color.orange)
                    .font(.callout)
            } else {
                Text("nikt nie jest zalogowany")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .opacity(skipped ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    func confirm() {
        let skip = skipLoggedIn ? Set(withUser.map(\.id)) : []
        let action = request.action
        close()
        model.perform(skipping: skip, reason: .loggedInUser, action)
    }
}

// MARK: - Results

extension Job.State {
    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        case .skipped: return "forward.end.circle"
        }
    }

    var color: Color {
        switch self {
        case .queued, .running: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .skipped: return .gray
        }
    }
}

struct JobStateIcon: View {
    let state: Job.State

    var body: some View {
        Group {
            if state == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: state.symbol).foregroundStyle(state.color)
            }
        }
        .frame(width: 16, height: 16)
        .help(state.label)
        .accessibilityElement()
        .accessibilityLabel(state.label)
    }
}

enum JobDurationText {
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600) h \((s % 3600) / 60) min" }
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }
}

/// Counts of a batch: ✓ 12  ✗ 2  ⏭ 1.
struct BatchCounts: View {
    @ObservedObject var batch: Batch

    var body: some View {
        HStack(spacing: 8) {
            if !batch.finished {
                Text("\(batch.completed)/\(batch.jobs.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            count(batch.succeeded, .succeeded, "Gotowe")
            count(batch.failed, .failed, "Błędy")
            count(batch.cancelled, .cancelled, "Przerwane")
            count(batch.skipped, .skipped, "Pominięte")
        }
        .font(.callout)
        .fixedSize()
    }

    @ViewBuilder func count(_ n: Int, _ state: Job.State, _ label: String) -> some View {
        if n > 0 {
            Label("\(n)", systemImage: state.symbol)
                .foregroundStyle(state.color)
                .monospacedDigit()
                .help("\(label): \(n)")
                .accessibilityLabel("\(label): \(n)")
        }
    }
}

/// Retry / select-failed actions shared by the results box and the Jobs view.
struct BatchActions: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var batch: Batch

    var body: some View {
        if !batch.finished {
            Button(role: .destructive) { batch.cancel() } label: {
                Label("Anuluj", systemImage: "stop.circle")
            }
            .help("Przerywa operację na wszystkich komputerach tej partii")
        } else {
            let retry = batch.retryableMachines
            if !retry.isEmpty, let rerun = batch.rerun {
                Button { rerun(retry) } label: {
                    Label("Powtórz na nieudanych (\(retry.count))", systemImage: "arrow.counterclockwise")
                }
                .help("Uruchamia to samo ponownie \(Polish.onComputers(retry.count)): "
                      + retry.map(\.name).joined(separator: ", "))
            }
            if !batch.problemMachines.isEmpty {
                Button { model.selectProblems(of: batch) } label: {
                    Label("Zaznacz nieudane", systemImage: "checklist")
                }
                .help("Zaznacza na liście komputery, na których operacja się nie udała lub została pominięta")
            }
        }
    }
}

struct BatchResultsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var batch: Batch
    @ViewState private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 6) {
                    heading
                    HStack(spacing: 10) { controls }
                }
            }
            if !batch.finished {
                ProgressView(value: Double(batch.completed), total: Double(max(1, batch.jobs.count)))
                    .accessibilityLabel("Postęp: \(batch.completed) z \(batch.jobs.count)")
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(batch.jobs) { job in
                    JobRow(job: job, expanded: Binding(
                        get: { expanded.contains(job.id) },
                        set: { if $0 { expanded.insert(job.id) } else { expanded.remove(job.id) } }))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(batch.title).font(.headline).lineLimit(2)
            Text(batch.createdAt.formatted(date: .omitted, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var controls: some View {
        BatchCounts(batch: batch)
        BatchActions(batch: batch)
            .controlSize(.small)
        Button {
            model.showJobs(batch.id)
        } label: {
            Label("Pokaż w Zadaniach", systemImage: "list.bullet.rectangle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Otwiera tę operację w sekcji Zadania (pełne wyniki, eksport, grupowanie)")
        Button {
            if expanded.count == batch.jobs.count { expanded = [] } else { expanded = Set(batch.jobs.map(\.id)) }
        } label: {
            Label(expanded.count == batch.jobs.count ? "Zwiń wszystkie" : "Rozwiń wszystkie",
                  systemImage: expanded.count == batch.jobs.count ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(expanded.count == batch.jobs.count ? "Zwiń wyniki wszystkich komputerów" : "Rozwiń wyniki wszystkich komputerów")
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 10)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    JobStateIcon(state: job.state)
                    Text(job.machine.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 70, alignment: .leading)
                    Text(job.state == .running ? job.lastLine : job.summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                        .help(job.state == .running ? job.lastLine : job.summary)
                    Spacer()
                    if let duration = job.duration {
                        Text(JobDurationText.format(duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(job.machine.name), \(job.state.label), \(job.summary)")
            .accessibilityHint(expanded ? "Zwija wynik" : "Rozwija wynik")
            if expanded {
                JobLogView(job: job)
                    .frame(minHeight: 80, idealHeight: 200, maxHeight: 280)
                JobLogButtons(job: job)
                    .controlSize(.small)
            }
        }
    }
}

/// Copy / open full log / stop for one job.
struct JobLogButtons: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack {
            Spacer()
            if let url = job.logURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Otwórz pełny dziennik", systemImage: "doc.text.magnifyingglass")
                }
                .help(url.path)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.output, forType: .string)
            } label: {
                Label("Kopiuj wynik", systemImage: "doc.on.doc")
            }
            .disabled(job.output.isEmpty)
            if !job.isFinished {
                Button(role: .destructive) { job.handle.cancel() } label: {
                    Label("Przerwij", systemImage: "stop.circle")
                }
            }
        }
    }
}

/// Live log of one job (appends incrementally, so long outputs stay fast).
struct JobLogView: View {
    @ObservedObject var job: Job

    var body: some View {
        LogTextView(text: job.output.isEmpty ? "(brak wyjścia)" : job.output,
                generation: job.output.isEmpty ? -1 : job.outputGeneration)
    }
}

/// Read-only monospaced text view with Find (⌘F) that appends new text instead of re-laying out everything.
struct LogTextView: NSViewRepresentable {
    let text: String
    /// Change it whenever `text` is not just `previous text + more` (a different log, or a trimmed beginning).
    var generation = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.setAccessibilityLabel("Wynik operacji")
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        context.coordinator.reload(tv, text: text, generation: generation)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.update(tv, scroll: scroll, text: text, generation: generation)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var generation = Int.min
        private var length = 0  // UTF-8 bytes shown

        static var attributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
             .foregroundColor: NSColor.textColor]
        }

        func reload(_ tv: NSTextView, text: String, generation: Int) {
            tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
            self.generation = generation
            length = text.utf8.count
        }

        func update(_ tv: NSTextView, scroll: NSScrollView, text: String, generation: Int) {
            let count = text.utf8.count
            if generation == self.generation && count == length { return }
            let clip = scroll.contentView
            let atBottom = clip.bounds.maxY >= (tv.frame.height - 24)
            if generation == self.generation && count > length {
                let u = text.utf8
                let tail = String(decoding: u[u.index(u.startIndex, offsetBy: length)...], as: UTF8.self)
                tv.textStorage?.append(NSAttributedString(string: tail, attributes: Self.attributes))
                length = count
            } else {
                reload(tv, text: text, generation: generation)
            }
            if atBottom { tv.scrollToEndOfDocument(nil) }
        }
    }
}

struct OutputView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Results of the last action started from a given section.
struct LastBatchView: View {
    @EnvironmentObject var model: AppModel
    let section: AppSection

    var body: some View {
        if let batch = model.lastBatch[section] {
            VStack(alignment: .leading, spacing: 6) {
                Text("Wynik ostatniej operacji").font(.headline)
                BatchResultsView(batch: batch)
            }
            .id(batch.id)
        }
    }
}

// MARK: - File pickers

enum Pickers {
    static func files(allowFolders: Bool = true, types: [UTType]? = nil, message: String? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowFolders
        panel.treatsFilePackagesAsDirectories = false
        if let types { panel.allowedContentTypes = types }
        panel.message = message ?? ""
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func folder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func save(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Editable list of local files with drag & drop.
struct FileListEditor: View {
    @Binding var items: [URL]
    var placeholder = "Przeciągnij tutaj pliki lub foldery albo użyj „Dodaj…”."
    var types: [UTType]?
    @ViewState private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if items.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    ForEach(items, id: \.self) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(url.lastPathComponent)
                            Text(url.deletingLastPathComponent().path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                items.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            DispatchQueue.main.async { if !items.contains(url) { items.append(url) } }
                        }
                    }
                }
                return true
            }
            HStack {
                Button("Dodaj…") {
                    for url in Pickers.files(types: types) where !items.contains(url) { items.append(url) }
                }
                Button("Wyczyść") { items.removeAll() }.disabled(items.isEmpty)
            }
        }
    }
}

/// Small label with a key/value pair used in the dashboard and details.
struct InfoPair: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }
}

/// Plain-text editor for shell code: no smart quotes/dashes or autocorrect, which would break scripts.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.delegate = context.coordinator
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = scroll.documentView as? NSTextView, tv.string != text {
            tv.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView { parent.text = tv.string }
        }
    }
}
