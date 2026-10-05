import AppKit
import CMCRCore
import SwiftUI

/// Job history from disk (earlier sessions and archived jobs of this one).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var batches: [HistoryBatch] = []
    @Published private(set) var loading = false

    func load() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let loaded = JobHistory.batches(JobHistory.load())
            await MainActor.run {
                self.batches = loaded
                self.loading = false
            }
        }
    }
}

/// Master-detail view of operations: running, this session and history; per-host table and fast log.
struct JobsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var history = HistoryStore()
    @ViewState private var selectedID: UUID?
    @ViewState private var search = ""

    var body: some View {
        Group {
            if model.batches.isEmpty && history.batches.isEmpty {
                ContentUnavailableView {
                    Label("Brak zadań", systemImage: AppSection.jobs.icon)
                } description: {
                    Text("Każda operacja uruchomiona na komputerach pojawi się tutaj z wynikiem dla każdego iMaca. Historia zapisuje się na dysku.")
                }
            } else {
                HSplitView {
                    batchList
                        .frame(minWidth: 250, idealWidth: 300, maxWidth: 440)
                    detail
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            history.load()
            selectedID = model.focusedBatchID ?? selectedID ?? model.batches.first?.id
        }
        .onChange(of: model.focusedBatchID) { _, id in
            if let id { selectedID = id }
        }
        .onChange(of: model.batches.count) { _, _ in
            if selectedID == nil { selectedID = model.batches.first?.id }
        }
    }

    // MARK: List

    var liveIDs: Set<UUID> { Set(model.batches.map(\.id)) }

    func matches(_ batch: Batch) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return batch.title.localizedCaseInsensitiveContains(needle)
            || batch.jobs.contains { $0.machine.name.localizedCaseInsensitiveContains(needle)
                || $0.summary.localizedCaseInsensitiveContains(needle) }
    }

    func matches(_ batch: HistoryBatch) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return batch.title.localizedCaseInsensitiveContains(needle)
            || batch.records.contains { $0.host.localizedCaseInsensitiveContains(needle)
                || $0.summary.localizedCaseInsensitiveContains(needle) }
    }

    var batchList: some View {
        let running = model.batches.filter { !$0.finished && matches($0) }
        let done = model.batches.filter { $0.finished && matches($0) }
        let live = liveIDs
        let older = history.batches.filter { !live.contains($0.id) && matches($0) }
        return VStack(spacing: 0) {
            SearchField(prompt: "Szukaj: operacja, komputer, wynik", text: $search)
                .padding(8)
            List(selection: $selectedID) {
                if !running.isEmpty {
                    Section("W toku") {
                        ForEach(running) { BatchListRow(batch: $0).tag($0.id) }
                    }
                }
                if !done.isEmpty {
                    Section("Ta sesja") {
                        ForEach(done) { BatchListRow(batch: $0).tag($0.id) }
                    }
                }
                if !older.isEmpty {
                    Section("Historia") {
                        ForEach(older) { HistoryListRow(batch: $0).tag($0.id) }
                    }
                }
            }
            .overlay {
                if running.isEmpty && done.isEmpty && older.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.clearFinishedBatches()
                } label: {
                    Label("Wyczyść zakończone", systemImage: "trash")
                }
                .disabled(!model.batches.contains { $0.finished })
                .help("Usuwa zakończone operacje z tej listy (zostają w historii na dysku)")
                Spacer()
                Menu {
                    Button("Odśwież historię") { history.load() }
                    Button("Pokaż folder historii w Finderze") {
                        let dir = JobHistory.directory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    Button("Otwórz dziennik działań") {
                        let url = ConfigStore.logURL
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.open(url)
                        } else {
                            NSSound.beep()
                        }
                    }
                } label: {
                    Label("Więcej", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Historia i dziennik działań")
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    // MARK: Detail

    @ViewBuilder var detail: some View {
        if let batch = model.batch(selectedID) {
            BatchDetailView(batch: batch).id(batch.id)
        } else if let past = history.batches.first(where: { $0.id == selectedID }) {
            HistoryDetailView(batch: past).id(past.id)
        } else {
            ContentUnavailableView {
                Label("Wybierz operację", systemImage: "sidebar.left")
            } description: {
                Text("Po lewej są operacje w toku, z tej sesji i z historii.")
            }
        }
    }
}

// MARK: - List rows

private struct BatchListRow: View {
    @ObservedObject var batch: Batch

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BatchStatusIcon(batch: batch)
            VStack(alignment: .leading, spacing: 3) {
                Text(batch.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(batch.createdAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text(Polish.computers(batch.jobs.count))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if batch.finished { BatchCounts(batch: batch).font(.caption) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryListRow: View {
    let batch: HistoryBatch

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: batch.failed > 0 ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(batch.failed > 0 ? Color.red : Color.green)
                .frame(width: 18, height: 18)
                .accessibilityLabel(batch.failed > 0 ? "Z błędami" : "Zakończono")
            VStack(alignment: .leading, spacing: 3) {
                Text(batch.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(batch.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(Polish.computers(batch.records.count))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Live batch

struct BatchDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var batch: Batch
    @ViewState private var jobID: UUID?
    @ViewState private var grouped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            if grouped {
                GroupedResultsView(batch: batch)
            } else {
                VSplitView {
                    jobTable
                        .frame(minHeight: 120, idealHeight: 240)
                    logPane
                        .frame(minHeight: 120, idealHeight: 320, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if jobID == nil { jobID = (batch.jobs.first { $0.state == .failed } ?? batch.jobs.first)?.id }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(batch.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                BatchCounts(batch: batch)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(timing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !batch.finished {
                ProgressView(value: Double(batch.completed), total: Double(max(1, batch.jobs.count)))
            }
            HStack(spacing: 8) {
                BatchActions(batch: batch)
                Spacer()
                Picker("Widok", selection: $grouped) {
                    Label("Komputery", systemImage: "list.bullet").tag(false)
                    Label("Identyczne wyniki", systemImage: "square.stack.3d.up").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Grupuje komputery, które zwróciły ten sam wynik")
                Menu {
                    Button("Kopiuj wyniki wszystkich komputerów") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(BatchExport.text(batch), forType: .string)
                    }
                    Button("Eksportuj do pliku…") { BatchExport.save(batch) }
                } label: {
                    Label("Eksportuj", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .disabled(!batch.finished)
                .help("Zapisuje wyniki wszystkich komputerów do pliku tekstowego")
            }
            .controlSize(.regular)
        }
    }

    var timing: String {
        var parts = ["Rozpoczęto \(batch.createdAt.formatted(date: .omitted, time: .standard))"]
        parts.append((batch.finished ? "trwało " : "trwa ") + DurationText.format(batch.duration))
        parts.append(Polish.computers(batch.jobs.count))
        return parts.joined(separator: " · ")
    }

    var jobTable: some View {
        Table(batch.jobs, selection: $jobID) {
            TableColumn("Komputer") { job in
                JobCell(job: job, kind: .name)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Stan") { job in
                JobCell(job: job, kind: .state)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Czas") { job in
                JobCell(job: job, kind: .duration)
            }
            .width(min: 55, ideal: 70)
            TableColumn("Wynik") { job in
                JobCell(job: job, kind: .summary)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let jobs = batch.jobs.filter { ids.contains($0.id) }
            if !jobs.isEmpty {
                Button("Zaznacz na liście komputerów") { model.selection = Set(jobs.map(\.machine.id)) }
                if batch.finished, let rerun = batch.rerun {
                    Button("Powtórz na \(jobs.count == 1 ? jobs[0].machine.name : Polish.ofComputers(jobs.count))") {
                        rerun(jobs.map(\.machine))
                    }
                }
                Button("Kopiuj wynik") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jobs.map(\.output).joined(separator: "\n"), forType: .string)
                }
            }
        }
    }

    @ViewBuilder var logPane: some View {
        if let job = batch.jobs.first(where: { $0.id == jobID }) {
            VStack(spacing: 0) {
                JobLogView(job: job)
                Divider()
                HStack {
                    Label(job.machine.name, systemImage: "desktopcomputer")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    JobLogButtons(job: job)
                }
                .controlSize(.small)
                .padding(8)
            }
            .id(job.id)
        } else {
            ContentUnavailableView {
                Label("Wybierz komputer", systemImage: "desktopcomputer")
            } description: {
                Text("Zaznacz wiersz powyżej, aby zobaczyć pełny wynik.")
            }
        }
    }
}

private struct JobCell: View {
    enum Kind { case name, state, duration, summary }
    @ObservedObject var job: Job
    let kind: Kind

    var body: some View {
        switch kind {
        case .name:
            Text(job.machine.name).fontWeight(.medium).lineLimit(1)
        case .state:
            HStack(spacing: 6) {
                JobStateIcon(state: job.state)
                Text(job.state.label).lineLimit(1)
            }
        case .duration:
            if job.state == .running {
                TimelineView(.periodic(from: .now, by: 1)) { _ in durationText }
            } else {
                durationText
            }
        case .summary:
            Text(job.state == .running ? job.lastLine : job.summary)
                .lineLimit(1)
                .foregroundStyle(job.state == .failed ? Color.red : Color.primary)
                .help(job.state == .running ? job.lastLine : job.summary)
        }
    }

    var durationText: some View {
        Text(job.duration.map(DurationText.format) ?? "—")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// Finished jobs grouped by identical result: "Ten sam wynik na 12 komputerach".
struct GroupedResultsView: View {
    @ObservedObject var batch: Batch

    struct ResultGroup: Identifiable {
        let id: String
        let state: Job.State
        let output: String
        let jobs: [Job]
    }

    var groups: [ResultGroup] {
        let finished = batch.jobs.filter(\.isFinished)
        let byKey = Dictionary(grouping: finished) { job in
            "\(job.state.historyName)\u{1}\(job.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return byKey.map { key, jobs in
            ResultGroup(id: key, state: jobs[0].state, output: jobs[0].output, jobs: jobs)
        }
        .sorted { a, b in
            let fa = a.state == .failed, fb = b.state == .failed
            if fa != fb { return fa }
            return a.jobs.count != b.jobs.count ? a.jobs.count > b.jobs.count : a.id < b.id
        }
    }

    var body: some View {
        let groups = self.groups
        let pending = batch.jobs.count - batch.jobs.filter(\.isFinished).count
        List {
            if pending > 0 {
                Label("W toku lub w kolejce: \(Polish.computers(pending))", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                DisclosureGroup {
                    LogView(text: group.output.isEmpty ? "(brak wyjścia)" : group.output, generation: group.id.hashValue)
                        .frame(minHeight: 80, idealHeight: 160, maxHeight: 260)
                } label: {
                    HStack(spacing: 8) {
                        JobStateIcon(state: group.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(group))
                            Text(group.jobs.map(\.machine.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty && pending == 0 {
                ContentUnavailableView("Brak wyników", systemImage: "tray")
            }
        }
    }

    func title(_ g: ResultGroup) -> String {
        let n = g.jobs.count
        let state = g.state.label.lowercased()
        return n == 1 ? "Wynik tylko na \(g.jobs[0].machine.name) (\(state))"
                      : "Ten sam wynik \(Polish.onComputers(n)) (\(state))"
    }
}

// MARK: - History batch

struct HistoryDetailView: View {
    @EnvironmentObject var model: AppModel
    let batch: HistoryBatch
    @ViewState private var recordID: UUID?
    @ViewState private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            VSplitView {
                Table(batch.records, selection: $recordID) {
                    TableColumn("Komputer") { r in Text(r.host).fontWeight(.medium) }
                        .width(min: 100, ideal: 130)
                    TableColumn("Stan") { r in
                        let state = Job.State(historyName: r.state)
                        HStack(spacing: 6) {
                            JobStateIcon(state: state)
                            Text(state.label)
                        }
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Kod") { r in
                        Text(r.exitCode.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 40, ideal: 50)
                    TableColumn("Czas") { r in
                        Text(r.durationMs.map { DurationText.format(Double($0) / 1000) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 55, ideal: 70)
                    TableColumn("Wynik") { r in
                        Text(r.summary).lineLimit(1).help(r.summary)
                    }
                }
                .frame(minHeight: 120, idealHeight: 240)
                Group {
                    if recordID == nil {
                        ContentUnavailableView {
                            Label("Wybierz komputer", systemImage: "desktopcomputer")
                        } description: {
                            Text("Zaznacz wiersz powyżej, aby zobaczyć zapisany wynik.")
                        }
                    } else {
                        LogView(text: output, generation: recordID?.hashValue ?? 0)
                    }
                }
                .frame(minHeight: 120, idealHeight: 320, maxHeight: .infinity)
            }
        }
        .onAppear {
            if recordID == nil { recordID = (batch.records.first { $0.state == "failed" } ?? batch.records.first)?.id }
        }
        .task(id: recordID) { output = await load(recordID) }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(batch.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Label("\(batch.succeeded)", systemImage: Job.State.succeeded.symbol).foregroundStyle(.green)
                    if batch.failed > 0 {
                        Label("\(batch.failed)", systemImage: Job.State.failed.symbol).foregroundStyle(.red)
                    }
                }
                .monospacedDigit()
                .fixedSize()
            }
            Text(info)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                let failedIDs = Set(batch.records.filter { !$0.succeeded }.map(\.hostID))
                let existing = model.machines.filter { failedIDs.contains($0.id) }
                Button {
                    model.selection = Set(existing.map(\.id))
                } label: {
                    Label("Zaznacz nieudane", systemImage: "checklist")
                }
                .disabled(existing.isEmpty)
                .help("Zaznacza na liście komputery, na których operacja się nie udała")
                Spacer()
                Button {
                    BatchExport.save(batch)
                } label: {
                    Label("Eksportuj…", systemImage: "square.and.arrow.up")
                }
                .help("Zapisuje wyniki wszystkich komputerów do pliku tekstowego")
            }
        }
    }

    var info: String {
        let operatorName = batch.records.first?.operatorName ?? ""
        return "\(batch.startedAt.formatted(date: .abbreviated, time: .standard)) · \(Polish.computers(batch.records.count))"
            + (operatorName.isEmpty ? "" : " · uruchomił(a): \(operatorName)")
    }

    func load(_ id: UUID?) async -> String {
        guard let record = batch.records.first(where: { $0.id == id }) else { return "" }
        guard let url = JobHistory.outputURL(for: record) else { return "(brak zapisanego wyniku)" }
        return await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? "(nie można odczytać \(url.path))"
        }.value
    }
}

extension Job.State {
    init(historyName: String) {
        switch historyName {
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "skipped": self = .skipped
        case "running": self = .running
        default: self = .queued
        }
    }
}

// MARK: - Export

enum BatchExport {
    static func text(_ batch: Batch) -> String {
        var s = "\(batch.title)\nRozpoczęto: \(batch.createdAt.formatted(date: .abbreviated, time: .standard))\n\n"
        for job in batch.jobs {
            s += "=== \(job.machine.name) – \(job.state.label)\(job.exitCode.map { ", kod \($0)" } ?? "") ===\n"
            let full = job.logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? job.output
            s += full.hasSuffix("\n") || full.isEmpty ? full : full + "\n"
            s += "\n"
        }
        return s
    }

    static func text(_ batch: HistoryBatch) -> String {
        var s = "\(batch.title)\nRozpoczęto: \(batch.startedAt.formatted(date: .abbreviated, time: .standard))\n\n"
        for r in batch.records {
            s += "=== \(r.host) – \(Job.State(historyName: r.state).label)\(r.exitCode.map { ", kod \($0)" } ?? "") ===\n"
            let full = JobHistory.outputURL(for: r).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? r.summary
            s += full.hasSuffix("\n") || full.isEmpty ? full : full + "\n"
            s += "\n"
        }
        return s
    }

    static func save(_ batch: Batch) { write(text(batch), title: batch.title, date: batch.createdAt) }
    static func save(_ batch: HistoryBatch) { write(text(batch), title: batch.title, date: batch.startedAt) }

    private static func write(_ text: String, title: String, date: Date) {
        let safe = String(title.prefix(40).map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        guard let url = Pickers.save(name: "cmcr-\(safe)-\(stamp).txt") else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }
}
