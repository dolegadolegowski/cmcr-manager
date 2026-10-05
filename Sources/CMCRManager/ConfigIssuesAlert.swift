import AppKit
import CMCRCore
import SwiftUI

/// Tells the user at start that hosts.json or settings.json was damaged and where the original was kept,
/// and that a password could not be saved in the Keychain.
struct ConfigIssuesAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ViewState private var showsSample = false

    /// Keychain Access, to unlock the "login" keychain (nil when macOS does not have it).
    private var keychainAccess: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess")
    }

    func body(content: Content) -> some View {
        content.alert("Nie udało się wczytać części konfiguracji", isPresented: Binding(
            get: { !model.configIssues.isEmpty },
            set: { if !$0 { model.configIssues = [] } }
        )) {
            Button("Pokaż pliki w Finderze") {
                NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directory])
                model.configIssues = []
            }
            Button("OK", role: .cancel) { model.configIssues = [] }
        } message: {
            Text(model.configIssues.joined(separator: "\n\n")
                 + "\n\nSprawdź listę komputerów i ustawienia w dziale Konfiguracja.")
        }
        .alert("Problem z Pękiem kluczy", isPresented: Binding(
            get: { model.keychainError != nil },
            set: { if !$0 { model.keychainError = nil } }
        )) {
            if let app = keychainAccess {
                Button("Otwórz Dostęp do pęku kluczy") {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                    model.keychainError = nil
                }
            }
            Button("OK", role: .cancel) { model.keychainError = nil }
        } message: {
            Text(model.keychainError ?? "")
        }
        .onSnapshotSubpage { sub in
            // Sample texts, only for the UI snapshots (see SnapshotRenderer); removed again with the sub-page.
            switch sub {
            case "configissues":
                model.configIssues = ["Lista komputerów (hosts.json) jest uszkodzona – wczytano listę domyślną. Oryginał zachowano jako hosts.json.damaged w \(ConfigStore.directory.path)."]
                showsSample = true
            case "keychain":
                model.keychainError = "Nie udało się zapisać hasła w Pęku kluczy. Sprawdź, czy pęk kluczy „login” jest odblokowany (aplikacja Dostęp do pęku kluczy), i spróbuj ponownie."
                showsSample = true
            default:
                if showsSample {
                    model.configIssues = []
                    model.keychainError = nil
                    showsSample = false
                }
            }
        }
    }
}
