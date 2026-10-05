import AppKit
import CMCRCore
import SwiftUI

/// Renders every section into PNG files from the window's own drawing (works while the screen is locked), for UI
/// review and documentation: CMCR_SNAPSHOT_DIR=<dir> [CMCR_SNAPSHOT_SECTIONS=files,apps] [CMCR_SNAPSHOT_WAIT=2]
/// [CMCR_SNAPSHOT_SIZE=1440x900]. The app quits when done. Use together with CMCR_CONFIG_DIR.
///
/// An entry may name a sub-page after a colon (`setup:access`): it is posted as `subpageNotification` and views
/// with tabs or sheets switch to it (an empty sub-page means "back to the default"). A sheet attached to the
/// window is captured too (`setup-access-sheet-light.png`). The entry `settings[:tab]` captures the Settings
/// window (⌘,).
@MainActor
enum SnapshotRenderer {
    static let subpageNotification = Notification.Name("CMCRSnapshotSubpage")

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CMCR_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let output = URL(fileURLWithPath: expandTilde(dir), isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let entries = (env["CMCR_SNAPSHOT_SECTIONS"].map { $0.split(separator: ",").map(String.init) }
            ?? AppSection.allCases.map(\.rawValue))
        let wait = Double(env["CMCR_SNAPSHOT_WAIT"] ?? "") ?? 2.5
        let size = env["CMCR_SNAPSHOT_SIZE"].flatMap { spec -> NSSize? in
            let p = spec.split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? NSSize(width: p[0], height: p[1]) : nil
        } ?? NSSize(width: 1440, height: 900)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let model = AppModel.shared else { exit(3) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "CMCR Manager"
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ContentView()
                .environmentObject(model)
                .environmentObject(model.screens)
                .frame(width: size.width, height: size.height))
            window.contentView = host
            // Key and in front (also while the screen is locked): controls render active and sheets can attach.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                for entry in entries {
                    let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                    let sub = parts.count > 1 ? parts[1] : ""
                    let file = entry.replacingOccurrences(of: ":", with: "-")
                    if parts[0] == "settings" {
                        await captureSettings(sub: sub, wait: wait, to: output.appendingPathComponent("\(file)-\(name).png"))
                        window.makeKeyAndOrderFront(nil)
                        continue
                    }
                    guard let section = AppSection(rawValue: parts[0]) else { continue }
                    model.section = section
                    // Twice: views that appear after the first post (a newly selected tab) get the second one.
                    for _ in 0..<2 {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        NotificationCenter.default.post(name: subpageNotification, object: sub)
                    }
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    // A system prompt (e.g. local network access) may have taken focus meanwhile.
                    if window.attachedSheet == nil {
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    capture(window, to: output.appendingPathComponent("\(file)-\(name).png"))
                    if let sheet = window.attachedSheet {
                        capture(sheet, to: output.appendingPathComponent("\(file)-sheet-\(name).png"))
                    }
                    if !sub.isEmpty {
                        NotificationCenter.default.post(name: subpageNotification, object: "")
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                }
            }
            exit(0)
        }
    }

    private static func captureSettings(sub: String, wait: Double, to url: URL) async {
        // The app menu's "Settings…" item (⌘,), exactly as the user opens it.
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        if let menu = NSApp.mainMenu?.items.first?.submenu,
           let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            menu.performActionForItem(at: index)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let window = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.contentView != nil })
                ?? NSApp.windows.first(where: { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }) else {
            FileHandle.standardError.write(Data("Brak okna Ustawień: \(NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") \($0.title)" })\n".utf8))
            return
        }
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<2 {
            NotificationCenter.default.post(name: subpageNotification, object: sub)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        capture(window, to: url)
        window.close()
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("Brak bufora dla \(url.lastPathComponent) (\(view.bounds))\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}

extension View {
    /// Lets the snapshot renderer switch this view's tab or open its sheet (see `SnapshotRenderer`).
    func onSnapshotSubpage(perform action: @escaping (String) -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: SnapshotRenderer.subpageNotification)) { note in
            action(note.object as? String ?? "")
        }
    }
}
