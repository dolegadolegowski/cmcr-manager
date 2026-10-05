import AppKit
import CMCRCore
import SwiftUI

/// Renders every section into PNG files without a visible window (works while the screen is locked), for UI
/// review and documentation: CMCR_SNAPSHOT_DIR=<dir> [CMCR_SNAPSHOT_SECTIONS=files,apps] [CMCR_SNAPSHOT_WAIT=2]
/// [CMCR_SNAPSHOT_SIZE=1440x900] [CMCR_SNAPSHOT_WINDOWS=wall,screen]. The app quits when done. Use together
/// with CMCR_CONFIG_DIR. `CMCR_SNAPSHOT_WINDOWS` also captures the screen wall window (`wall`) and the window
/// of the first Mac on the list (`screen`); `CMCR_SNAPSHOT_SECTIONS=none` skips the sections.
@MainActor
enum SnapshotRenderer {
    /// True while rendering snapshots: the off-screen window counts as visible and active (live screen tiles).
    nonisolated static var isActive: Bool {
        !(ProcessInfo.processInfo.environment["CMCR_SNAPSHOT_DIR"] ?? "").isEmpty
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CMCR_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let output = URL(fileURLWithPath: expandTilde(dir), isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sections = env["CMCR_SNAPSHOT_SECTIONS"].map {
            $0.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        } ?? AppSection.allCases
        let windows = (env["CMCR_SNAPSHOT_WINDOWS"] ?? "").split(separator: ",").map(String.init)
        let wait = Double(env["CMCR_SNAPSHOT_WAIT"] ?? "") ?? 2.5
        let size = env["CMCR_SNAPSHOT_SIZE"].flatMap { spec -> NSSize? in
            let p = spec.split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? NSSize(width: p[0], height: p[1]) : nil
        } ?? NSSize(width: 1440, height: 900)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let model = AppModel.shared else { exit(3) }
            let window = makeWindow(size: size, title: "CMCR Manager", root: ContentView(), model: model)
            var extra: [(name: String, window: NSWindow)] = []
            for name in windows {
                switch name {
                case "wall":
                    extra.append((name, makeWindow(size: size, title: "Ściana ekranów", root: ScreenWallView(), model: model)))
                case "screen":
                    let root = ScreenWindowView(machineID: model.machines.first?.id)
                    extra.append((name, makeWindow(size: NSSize(width: 1100, height: 720),
                                                   title: model.machines.first?.name ?? "", root: root, model: model)))
                default:
                    FileHandle.standardError.write(Data("Nieznane okno: \(name)\n".utf8))
                }
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for section in sections {
                    model.section = section
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    capture(window, to: output.appendingPathComponent("\(section.rawValue)-\(name).png"))
                }
                for (kind, w) in extra {
                    w.appearance = NSAppearance(named: appearance)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    capture(w, to: output.appendingPathComponent("window-\(kind)-\(name).png"))
                }
            }
            exit(0)
        }
    }

    private static func makeWindow<Root: View>(size: NSSize, title: String, root: Root, model: AppModel) -> NSWindow {
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root
            .environmentObject(model)
            .environmentObject(model.screens)
            .frame(width: size.width, height: size.height))
        return window
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let host = window.contentView else { return }
        let view: NSView = host.superview ?? host
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

/// Draws like the frontmost window (accent-coloured switches and buttons) although it is never on screen.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}
