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
        case .unknown: return Color.secondary.opacity(0.4)
        }
    }
}

struct StatusDot: View {
    let reachability: Reachability

    var body: some View {
        Circle()
            .fill(reachability.color)
            .frame(width: 9, height: 9)
            .help(reachability.label)
    }
}

/// Header shown on every action page: which Macs the action will target.
struct TargetHeader: View {
    @EnvironmentObject var model: AppModel
    let section: AppSection
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(section.title, systemImage: section.icon)
                    .font(.title2.weight(.semibold))
                Spacer()
                TargetSummary()
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
}

struct TargetSummary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let selected = model.selectedMachines
        if selected.isEmpty {
            Label("Zaznacz komputery na liście", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        } else {
            let names = selected.prefix(6).map(\.name).joined(separator: ", ")
            Text("Cel: \(selected.count) z \(model.machines.count) — \(names)\(selected.count > 6 ? "…" : "")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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

/// Primary action button that is disabled without a target selection.
struct TargetButton: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var icon: String = "play.fill"
    var role: ButtonRole?
    var prominent = true
    let action: () -> Void

    var body: some View {
        let button = Button(role: role, action: action) {
            Label("\(title) (\(model.selection.count))", systemImage: icon)
        }
        .disabled(model.selection.isEmpty)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

// MARK: - Confirmation

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    var destructive = true
    let action: () -> Void
}

extension View {
    func confirmation(_ request: Binding<ConfirmRequest?>) -> some View {
        alert(request.wrappedValue?.title ?? "",
              isPresented: Binding(get: { request.wrappedValue != nil },
                                   set: { if !$0 { request.wrappedValue = nil } }),
              presenting: request.wrappedValue) { r in
            Button(r.button, role: r.destructive ? .destructive : nil) { r.action() }
            Button("Anuluj", role: .cancel) {}
        } message: { r in
            Text(r.message)
        }
    }
}

// MARK: - Results

struct BatchResultsView: View {
    @ObservedObject var batch: Batch
    @ViewState private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(batch.title).font(.headline).lineLimit(1)
                Spacer()
                if !batch.finished {
                    ProgressView(value: Double(batch.completed), total: Double(max(1, batch.jobs.count)))
                        .frame(width: 120)
                    Button("Anuluj") { batch.cancel() }
                        .controlSize(.small)
                }
                Text("\(batch.completed)/\(batch.jobs.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if batch.finished {
                    Label("\(batch.succeeded)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if batch.failed > 0 {
                        Label("\(batch.failed)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                Button {
                    if expanded.count == batch.jobs.count { expanded = [] } else { expanded = Set(batch.jobs.map(\.id)) }
                } label: {
                    Image(systemName: expanded.count == batch.jobs.count ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .buttonStyle(.borderless)
                .help("Rozwiń/zwiń wszystkie")
            }
            ForEach(batch.jobs) { job in
                JobRow(job: job, expanded: Binding(
                    get: { expanded.contains(job.id) },
                    set: { if $0 { expanded.insert(job.id) } else { expanded.remove(job.id) } }))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
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
                    stateIcon
                    Text(job.machine.name).fontWeight(.medium).frame(width: 110, alignment: .leading)
                    Text(job.state == .running ? job.lastLine : job.summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(job.state == .failed ? .red : .secondary)
                    Spacer()
                    if let start = job.startedAt {
                        Text(durationText(start: start, end: job.finishedAt))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                OutputView(text: job.output.isEmpty ? "(brak wyjścia)" : job.output)
                    .frame(minHeight: 60, maxHeight: 280)
                HStack {
                    Spacer()
                    Button("Kopiuj wynik") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(job.output, forType: .string)
                    }
                    .controlSize(.small)
                    if !job.isFinished {
                        Button("Przerwij") { job.handle.cancel() }.controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder var stateIcon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small).frame(width: 16, height: 16)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.orange)
        }
    }

    func durationText(start: Date, end: Date?) -> String {
        let s = Int((end ?? Date()).timeIntervalSince(start))
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
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
