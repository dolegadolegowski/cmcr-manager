import CMCRCore
import Foundation

/// Host keys shown to the user before they are trusted (HostTrustSheet): what each Mac presents now and, for
/// a changed key, what was trusted before. Mutated on the main thread only.
@MainActor
final class HostTrustReview: ObservableObject, Identifiable {
    struct Entry: Identifiable {
        let machine: Machine
        /// nil while the key is being fetched.
        var scan: HostTrust.Scan?
        /// Ticked to be trusted. A new key starts ticked, a changed one never does (it needs a deliberate look).
        var chosen = false
        /// Saved while this sheet was open.
        var trusted = false
        var saveError: String?

        init(machine: Machine) { self.machine = machine }

        var id: UUID { machine.id }
        var state: HostTrust.State? { scan?.state }
        /// A key that can be trusted: fetched, and not trusted already.
        var canTrust: Bool {
            guard !trusted, let state else { return false }
            return state != .trusted
        }
    }

    let id = UUID()
    /// Offered by the app after a status check (first contact), not opened by the user.
    let automatic: Bool
    @Published var entries: [Entry]
    @Published var saving = false

    init(machines: [Machine], automatic: Bool = false) {
        self.automatic = automatic
        entries = machines.map { Entry(machine: $0) }
    }

    var isScanning: Bool { entries.contains { $0.scan == nil } }
    var hasChangedKey: Bool { entries.contains { if case .changed = $0.state { return true } else { return false } } }

    /// Exactly the keys the user saw, for the ticked Macs.
    var chosenScans: [HostTrust.Scan] {
        entries.filter { $0.chosen && $0.canTrust }.compactMap(\.scan)
    }

    func setScan(_ scan: HostTrust.Scan) {
        guard let i = entries.firstIndex(where: { $0.id == scan.host.id }) else { return }
        entries[i].scan = scan
        entries[i].chosen = scan.state == .new
    }

    func setChosen(_ id: UUID, _ chosen: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].canTrust else { return }
        entries[i].chosen = chosen
    }

    func markTrusted(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].trusted = true
        entries[i].chosen = false
        entries[i].saveError = nil
    }

    func setError(_ id: UUID, _ message: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].saveError = message.isEmpty ? "Nie udało się zapisać klucza." : message
    }
}
