import CMCRCore
import SwiftUI

/// Confirmation of „Odinstaluj…”: the dry run of every selected Mac – exactly what would be removed and where, what
/// stays and why, what is refused – before anything changes. „Odinstaluj” runs it for real on the Macs with
/// something to remove (a job per Mac in Zadania).
struct UninstallSheet: View {
    @ObservedObject var preview: UninstallPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ready = preview.readyTargets
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Odinstalować \(preview.title)?")
                        .font(.headline)
                    Text("Podgląd – na komputerach nic jeszcze nie zostało zmienione. Uruchomiona aplikacja zostanie "
                         + "zamknięta (niezapisana praca przepadnie). Aplikacji systemowych, Apple i składników CMCR "
                         + "nie można usunąć.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $preview.packageFiles) {
                        Text("Usuń także pozostałe pliki pakietu instalacyjnego")
                        Text("Pliki, które pakiet (.pkg) zainstalował poza aplikacją, w /Library, /usr/local i /opt – tylko te, "
                             + "których nie ma w żadnym innym pakiecie. Bez tego zostają, a usuwana jest aplikacja, "
                             + "jej usługi (LaunchDaemons, LaunchAgents) i wpis pakietu.")
                    }
                    .disabled(preview.isLoading)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.targets) { m in machine(m) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(minHeight: 220, maxHeight: 420)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                if preview.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Sprawdzanie komputerów…").foregroundStyle(.secondary)
                } else {
                    Text(footer(ready))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    preview.confirm()
                    dismiss()
                } label: {
                    Text(ready.isEmpty ? "Odinstaluj" : "Odinstaluj \(Polish.onComputers(ready.count))")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(preview.isLoading || ready.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear { if preview.results.isEmpty && !preview.isLoading { preview.load() } }
    }

    func footer(_ ready: [Machine]) -> String {
        if ready.isEmpty { return "Na żadnym z komputerów nie ma czego usunąć." }
        var text = "Zostanie usunięte \(Polish.onComputers(ready.count))"
        if preview.plannedKB > 0 { text += " (razem \(AppInventory.sizeText(preview.plannedKB)))" }
        let rest = preview.targets.count - ready.count
        if rest > 0 { text += "; na \(Polish.count(rest, "pozostałym", "pozostałych", "pozostałych")) nic." }
        return text + "."
    }

    @ViewBuilder func machine(_ m: Machine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(m.name).fontWeight(.semibold)
                if preview.loading.contains(m.id) { ProgressView().controlSize(.mini) }
            }
            switch preview.results[m.id] {
            case .error(let message)?:
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            case .report(let report)?:
                ForEach(Array(report.records.enumerated()), id: \.offset) { _, r in
                    if let text = UninstallReport.line(r) {
                        Text(text.trimmingCharacters(in: .whitespaces))
                            .font(r.verb == .target ? .callout.weight(.medium) : .callout)
                            .foregroundStyle(Self.color(r.verb))
                            .padding(.leading, r.verb == .target || r.verb == .refused || r.verb == .missing ? 0 : 14)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                ForEach(report.other, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func color(_ verb: UninstallRecord.Verb) -> Color {
        switch verb {
        case .refused, .failed: return .red
        case .running, .kept: return .orange
        case .note, .missing: return .secondary
        default: return .primary
        }
    }
}
