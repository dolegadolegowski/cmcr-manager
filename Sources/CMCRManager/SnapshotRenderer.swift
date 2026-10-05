import AppKit
import CMCRCore
import SwiftUI

/// Renders every section into PNG files without a visible window (works while the screen is locked), for UI
/// review and documentation: CMCR_SNAPSHOT_DIR=<dir> [CMCR_SNAPSHOT_SECTIONS=files,apps] [CMCR_SNAPSHOT_WAIT=2]
/// [CMCR_SNAPSHOT_SIZE=1440x900]. The app quits when done. Use together with CMCR_CONFIG_DIR.
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
            prepare(model, env: env)
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
                if env["CMCR_SNAPSHOT_CONFIRM"] == "1" {
                    await captureConfirmation(model, appearance: appearance,
                                              to: output.appendingPathComponent("confirm-\(name).png"))
                }
            }
            exit(0)
        }
    }

    /// Optional state for the pictures: CMCR_SNAPSHOT_SELECT=imac01,imac03 checks only these Macs,
    /// CMCR_SNAPSHOT_COMMAND=<script> runs a command on the checked Macs first (only with a demo or test
    /// configuration!), CMCR_SNAPSHOT_CONFIRM=1 also renders the confirmation sheet (confirm-light.png …).
    private static func prepare(_ model: AppModel, env: [String: String]) {
        if let names = env["CMCR_SNAPSHOT_SELECT"] {
            let wanted = Set(names.split(separator: ",").map(String.init))
            model.selection = Set(model.machines.filter { wanted.contains($0.name) }.map(\.id))
        }
        if let command = env["CMCR_SNAPSHOT_COMMAND"], !command.isEmpty {
            model.runCommand(command, asRoot: false, on: model.selectedMachines)
        }
    }

    /// A sheet is not attached to a window that is never shown, so the sheet's view is rendered on its own.
    private static func captureConfirmation(_ model: AppModel, appearance: NSAppearance.Name, to url: URL) async {
        let targets = model.selectedMachines
        let request = ConfirmRequest(title: "Uruchomić ponownie zaznaczone komputery?",
                                     message: "Niezapisana praca uczniów zostanie utracona.",
                                     button: "Uruchom ponownie", targets: targets) {}
        let host = NSHostingView(rootView: ConfirmSheet(request: request, targets: targets) {}
            .environmentObject(model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        try? await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}
