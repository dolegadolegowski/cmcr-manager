import AppKit
import SwiftUI

/// Sheets that SnapshotRenderer renders on their own (CMCR_SNAPSHOT_SHEETS=name,…): a sheet is a separate
/// window, so the snapshot of the main window does not include it. Files: sheet-<name>-light/dark.png.
@MainActor
enum SnapshotSheets {
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
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
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
