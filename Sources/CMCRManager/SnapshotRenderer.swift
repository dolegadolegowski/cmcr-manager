import AppKit
import CMCRCore
import SwiftUI

/// Renders every section into PNG files without a visible window (works while the screen is locked), for UI
/// review and documentation: CMCR_SNAPSHOT_DIR=<dir> [CMCR_SNAPSHOT_SECTIONS=files,apps] [CMCR_SNAPSHOT_WAIT=2]
/// [CMCR_SNAPSHOT_SIZE=1440x900]. The app quits when done. Use together with CMCR_CONFIG_DIR.
/// Optional state and sheets for the Files/Apps/Updates pages: see SnapshotSheets.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CMCR_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let output = URL(fileURLWithPath: expandTilde(dir), isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sections = env["CMCR_SNAPSHOT_SECTIONS"].map {
            $0.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        } ?? AppSection.allCases
        let wait = Double(env["CMCR_SNAPSHOT_WAIT"] ?? "") ?? 2.5
        let size = env["CMCR_SNAPSHOT_SIZE"].flatMap { spec -> NSSize? in
            let p = spec.split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? NSSize(width: p[0], height: p[1]) : nil
        } ?? NSSize(width: 1440, height: 900)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let model = AppModel.shared else { exit(3) }
            SnapshotSheets.prepare(model, env: env)
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
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for section in sections {
                    model.section = section
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    let view: NSView = window.contentView?.superview ?? host
                    view.layoutSubtreeIfNeeded()
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        FileHandle.standardError.write(Data("Brak bufora dla \(section.rawValue) (\(view.bounds))\n".utf8))
                        continue
                    }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = output.appendingPathComponent("\(section.rawValue)-\(name).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print(url.path)
                }
            }
            await SnapshotSheets.renderRequested(model, env: env, into: output, wait: wait)
            exit(0)
        }
    }
}
