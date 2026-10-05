import AppKit
import SwiftUI

/// Extra state and sheets for SnapshotRenderer (UI review of Pliki, Przeglądarka plików, Polecenia, Aplikacje,
/// Instalacja, Aktualizacje):
/// - CMCR_SNAPSHOT_BROWSE=<remote folder> opens it in the file browser (and the folder picker) first;
/// - CMCR_SNAPSHOT_PRELOAD=updates,installed,command fills the pages first: checks macOS updates, reads the
///   installed apps, runs `echo` from Polecenia – only with a demo or test configuration (Tests/ui/demo-env.sh);
/// - CMCR_SNAPSHOT_SHEETS=folder-picker,save-snippet also renders those sheets on their own: a sheet is a separate
///   window, so the snapshot of the main window does not include it. Files: sheet-<name>-light/dark.png.
@MainActor
enum SnapshotSheets {
    static func prepare(_ model: AppModel, env: [String: String]) {
        if let path = env["CMCR_SNAPSHOT_BROWSE"], !path.isEmpty {
            model.files.browser.open(path, on: model.files.browser.preferredHostID())
        }
        let preload = Set((env["CMCR_SNAPSHOT_PRELOAD"] ?? "").split(separator: ",").map(String.init))
        let targets = model.selectedMachines
        guard !preload.isEmpty, !targets.isEmpty else { return }
        let section = model.section
        if preload.contains("installed") { model.refreshInstalledApps(targets) }
        if preload.contains("updates") {
            model.section = .updates
            model.checkUpdates(targets)
        }
        if preload.contains("command") {
            model.section = .commands
            model.runCommand("echo \"Gotowe na $(hostname -s)\"", asRoot: false, on: targets)
        }
        model.section = section
    }

    static func renderRequested(_ model: AppModel, env: [String: String], into output: URL, wait: Double) async {
        for name in (env["CMCR_SNAPSHOT_SHEETS"] ?? "").split(separator: ",").map(String.init) {
            await render(name, model: model, into: output, wait: wait)
        }
    }

    static func view(_ name: String, model: AppModel) -> (view: AnyView, size: NSSize?)? {
        switch name {
        case "folder-picker":
            let start = ProcessInfo.processInfo.environment["CMCR_SNAPSHOT_BROWSE"] ?? model.files.destination
            let request = RemoteFolderRequest(purpose: .pushDestination, initialPath: start) { _ in }
            return (AnyView(RemoteFolderPicker(app: model, request: request)), NSSize(width: 1020, height: 680))
        case "save-snippet":
            return (AnyView(SnippetSaveSheet()), nil)
        default:
            return nil
        }
    }

    static func render(_ name: String, model: AppModel, into output: URL, wait: Double) async {
        guard let sheet = view(name, model: model) else {
            FileHandle.standardError.write(Data("Nieznany arkusz: \(name)\n".utf8))
            return
        }
        let host = NSHostingView(rootView: sheet.view
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(model)
            .environmentObject(model.screens))
        let size = sheet.size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        // Borderless like a sheet: no title bar above the content.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = output.appendingPathComponent("sheet-\(name)-\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
    }
}
