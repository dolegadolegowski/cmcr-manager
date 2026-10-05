import AppKit
import CMCRCore
import SwiftUI

/// Tells the user at start that hosts.json or settings.json was damaged and where the original was kept,
/// and that a password could not be saved in the Keychain.
struct ConfigIssuesAlert: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content.alert("Problem z plikami konfiguracji", isPresented: Binding(
            get: { !model.configIssues.isEmpty },
            set: { if !$0 { model.configIssues = [] } }
        )) {
            Button("Pokaż w Finderze") {
                NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directory])
                model.configIssues = []
            }
            Button("OK", role: .cancel) { model.configIssues = [] }
        } message: {
            Text(model.configIssues.joined(separator: "\n\n"))
        }
        .alert("Pęk kluczy", isPresented: Binding(
            get: { model.keychainError != nil },
            set: { if !$0 { model.keychainError = nil } }
        )) {
            Button("OK", role: .cancel) { model.keychainError = nil }
        } message: {
            Text(model.keychainError ?? "")
        }
    }
}
