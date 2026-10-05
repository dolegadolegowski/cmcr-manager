import AppKit
import CMCRCore
import SwiftUI

// MARK: - Search field

/// Native search field (magnifier, clear button, Esc clears) usable inside lists and panes.
struct NativeSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
    }
}

// MARK: - ActionToast

/// "Uruchomiono … na 6 komputerach · Pokaż" right after an action starts.
struct ActionToastOverlay: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = model.toast {
                ActionToastView(toast: toast)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 18)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.toast)
    }
}

private struct ActionToastView: View {
    @EnvironmentObject var model: AppModel
    let toast: ActionToast

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: toast.icon)
                .foregroundStyle(toast.icon.hasPrefix("exclamationmark") ? Color.orange : Color.accentColor)
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(toast.message)
                .lineLimit(2)
                .frame(maxWidth: 460, alignment: .leading)
            if let id = toast.batchID, model.section != .jobs {
                Button("Pokaż") {
                    model.toast = nil
                    model.showJobs(id)
                }
                .help("Otwiera wyniki w sekcji Zadania")
            }
            Button {
                model.toast = nil
            } label: {
                Label("Zamknij", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Zamknij powiadomienie")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)

        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

// MARK: - Toolbar activity

/// Toolbar item: spinner with the number of running jobs and a popover of current/recent operations.
struct ActivityToolbarButton: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showing = false

    var body: some View {
        let running = model.runningJobCount
        Button {
            showing.toggle()
        } label: {
            if running > 0 {
                Label {
                    Text("Trwające zadania: \(running)")
                } icon: {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("\(running)").monospacedDigit()
                    }
                }
                .labelStyle(.iconOnly)
            } else {
                Label("Zadania", systemImage: "list.bullet.rectangle")
            }
        }
        .help(running > 0 ? "W toku: \(Polish.jobs(running)). Kliknij, aby zobaczyć postęp lub anulować."
                          : "Ostatnie operacje")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ActivityPopover(close: { showing = false })
                .environmentObject(model)
        }
        .disabled(model.batches.isEmpty)
    }
}

private struct ActivityPopover: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Operacje").font(.headline).padding([.horizontal, .top], 14).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.batches.prefix(8)) { batch in
                        ActivityRow(batch: batch) {
                            close()
                            model.showJobs(batch.id)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Wszystkie zadania") {
                    close()
                    model.showJobs(nil)
                }
            }
            .padding(10)
        }
        .frame(width: 380)
    }
}

private struct ActivityRow: View {
    @ObservedObject var batch: Batch
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            BatchStatusIcon(batch: batch)
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.title).lineLimit(1)
                if batch.finished {
                    BatchCounts(batch: batch).font(.caption)
                } else {
                    ProgressView(value: Double(batch.completed), total: Double(max(1, batch.jobs.count)))
                        .controlSize(.small)
                }
            }
            Spacer()
            if !batch.finished {
                Button(role: .destructive) { batch.cancel() } label: {
                    Label("Anuluj", systemImage: "stop.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Anuluj „\(batch.title)”")
            }
            Button(action: open) {
                Label("Pokaż", systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Pokaż wyniki")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

/// Circular progress while running, then the overall result.
struct BatchStatusIcon: View {
    @ObservedObject var batch: Batch

    var body: some View {
        Group {
            if !batch.finished {
                ProgressView(value: Double(batch.completed), total: Double(max(1, batch.jobs.count)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                BatchOutcomeIcon(outcome: outcome)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement()
        .accessibilityLabel(accessibility)
    }

    var outcome: BatchOutcome {
        BatchOutcome(succeeded: batch.succeeded, failed: batch.failed, cancelled: batch.cancelled, skipped: batch.skipped)
    }

    var accessibility: String {
        if !batch.finished { return "W toku: \(batch.completed) z \(batch.jobs.count)" }
        return "\(outcome.label): gotowe \(batch.succeeded), błędy \(batch.failed)"
    }
}

extension BatchOutcome {
    var label: String {
        switch self {
        case .failed: return "Z błędami"
        case .nothingRan: return "Nie uruchomiono (pominięte lub przerwane)"
        case .partial: return "Częściowo (część pominięta lub przerwana)"
        case .succeeded: return "Zakończono pomyślnie"
        }
    }
}

/// Status symbol of a finished batch – the same in the live list and in the history.
struct BatchOutcomeIcon: View {
    let outcome: BatchOutcome

    var body: some View {
        switch outcome {
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .nothingRan: Image(systemName: "forward.end.circle").foregroundStyle(.gray)
        case .partial: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: - Missing password

/// Banner on action pages when no administrator password is stored (sudo operations would fail).
struct PasswordBanner: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Brak hasła administratora – instalacje, aktualizacje i inne operacje wymagające uprawnień się nie powiodą.")
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Ustaw hasło…") { editing = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $editing) {
            MissingPasswordSheet().environmentObject(model)
        }
    }

    static func isNeeded(_ model: AppModel) -> Bool {
        !model.hasSharedPassword && (ProcessInfo.processInfo.environment["CMCR_PASSWORD"] ?? "").isEmpty
    }
}

struct MissingPasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var password = ""

    var body: some View {
        Form {
            Section {
                SecureField("Hasło", text: $password, prompt: Text("Hasło kont administracyjnych (imacNN)"))
            } header: {
                Text("Hasło administratora")
            } footer: {
                Text("Zapisywane w Pęku kluczy tego Maca. Wspólne dla wszystkich komputerów, które nie mają własnego hasła (Konfiguracja › Komputery).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Anuluj") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz") {
                    model.setSharedPassword(password)
                    dismiss()
                }
                .disabled(password.isEmpty)
            }
        }
    }
}

// MARK: - Groups

/// Menu items toggling membership of `ids` in every existing group, plus "Nowa grupa…".
struct GroupMembershipMenu: View {
    @EnvironmentObject var model: AppModel
    let ids: Set<UUID>
    var newGroup: (() -> Void)?

    var body: some View {
        let members = model.machines.filter { ids.contains($0.id) }
        ForEach(model.groups, id: \.self) { group in
            let inGroup = !members.isEmpty && members.allSatisfy { $0.isMember(of: group) }
            Toggle(group, isOn: Binding(
                get: { inGroup },
                set: { on in
                    if on { HostGroups.add(group, to: ids, in: &model.machines) }
                    else { HostGroups.remove(group, from: ids, in: &model.machines) }
                }))
        }
        if let newGroup {
            if !model.groups.isEmpty { Divider() }
            Button("Nowa grupa…", action: newGroup)
        } else if model.groups.isEmpty {
            Text("Brak grup – utwórz je w Konfiguracji › Komputery")
        }
    }
}

/// Asks for a group name; used to create a group from a set of hosts or to rename one.
struct GroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var initial = ""
    let save: (String) -> Void
    @ViewState private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("Nazwa", text: $name, prompt: Text("np. Rząd 1, Pracownia B, 3A"))
                    .onSubmit(commit)
            } header: {
                Text(title)
            } footer: {
                Text("Grupy pozwalają jednym kliknięciem zaznaczać lub filtrować komputery (np. rząd ławek, klasa).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = initial }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Anuluj") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zapisz", action: commit)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(trimmed)
        dismiss()
    }
}
