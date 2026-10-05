import CMCRCore
import SwiftUI

extension View {
    /// Presents `AppModel.hostTrustReview` (first contact with a Mac, or a changed host key).
    func hostTrustUI() -> some View { modifier(HostTrustUI()) }
}

private struct HostTrustUI: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.hostTrustReview) { review in
            HostTrustSheet(review: review)
                .environmentObject(model)
        }
    }
}

/// Shows the fingerprint of each Mac's SSH key and trusts the ticked ones. Until then the app refuses to
/// connect to the Mac, so the admin password never reaches a device that only took over its name.
struct HostTrustSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var review: HostTrustReview

    private var count: Int { review.chosenScans.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: review.hasChangedKey ? "exclamationmark.shield.fill" : "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(review.hasChangedKey ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(review.hasChangedKey ? "Klucz komputera się zmienił" : "Potwierdź klucze komputerów")
                        .font(.headline)
                    Text("Hasło administratora jest wysyłane tylko do komputerów, których klucz SSH potwierdzisz. "
                         + "Urządzenie, które w sieci podszyje się pod iMaca (np. pod nazwę imac07.local), nie dostanie hasła.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Odcisk możesz porównać przy iMacu – w Terminalu: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            List(review.entries) { entry in row(entry) }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: min(320, CGFloat(review.entries.count) * 64 + 12))
            HStack {
                if review.isScanning || review.saving {
                    ProgressView().controlSize(.small)
                    Text(review.saving ? "Zapisywanie…" : "Odczytywanie kluczy…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(review.automatic ? "Nie teraz" : "Anuluj", role: .cancel) {
                    model.postponeHostTrust(review)
                    model.hostTrustReview = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(count > 0 ? "Zaufaj (\(count))" : "Zaufaj") {
                    Task { await model.trustHostKeys(in: review) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0 || review.saving)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    func row(_ e: HostTrustReview.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { e.chosen }, set: { review.setChosen(e.id, $0) }))
                .labelsHidden()
                .disabled(!e.canTrust || review.saving)
                .accessibilityLabel("Zaufaj kluczowi \(e.machine.name)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.machine.name).fontWeight(.medium)
                    Text(e.machine.address).foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    stateLabel(e)
                }
                if let scan = e.scan {
                    ForEach(scan.keys, id: \.self) { key in
                        Text("\(key.type)  \(key.fingerprint)")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if case .changed(let previous) = scan.state {
                        Text("Poprzednio zaufany: " + previous.map { "\($0.type) \($0.fingerprint)" }.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Zaufaj tylko, jeśli ten iMac był reinstalowany lub wymieniony – inaczej ktoś może się pod niego podszywać.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = scan.error {
                        Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error = e.saveError {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder func stateLabel(_ e: HostTrustReview.Entry) -> some View {
        if e.trusted {
            Label("zaufany", systemImage: "checkmark.shield.fill").foregroundStyle(.green).font(.callout)
        } else if e.scan == nil {
            ProgressView().controlSize(.small)
        } else {
            switch e.state {
            case .new?: Label("nowy klucz", systemImage: "key").font(.callout)
            case .changed?: Label("ZMIENIONY", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            case .trusted?: Label("już zaufany", systemImage: "checkmark.shield").foregroundStyle(.secondary).font(.callout)
            case nil: Label("brak połączenia", systemImage: "wifi.slash").foregroundStyle(.secondary).font(.callout)
            }
        }
    }
}
