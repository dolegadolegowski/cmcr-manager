import AppKit
import CMCRCore
import SwiftUI

/// Renders every section into PNG files without a visible window (works while the screen is locked), for UI
/// review and documentation: CMCR_SNAPSHOT_DIR=<dir> [CMCR_SNAPSHOT_SECTIONS=files,apps] [CMCR_SNAPSHOT_WAIT=2]
/// [CMCR_SNAPSHOT_SIZE=1440x900] [CMCR_SNAPSHOT_TEXT=1] [CMCR_SNAPSHOT_WINDOWS=wall,screen]. The app quits when done.
/// Use together with CMCR_CONFIG_DIR. `CMCR_SNAPSHOT_WINDOWS` also captures the screen wall window (`wall`) and the
/// window of the first Mac on the list (`screen`); `CMCR_SNAPSHOT_SECTIONS=none` skips the sections.
/// Optional state and sheets for the Files/Apps/Updates pages: see SnapshotSheets.
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

        let restore = applyDefaults(env["CMCR_SNAPSHOT_DEFAULTS"] ?? "")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let model = AppModel.shared else { exit(3) }
            defer { restore() }
            prepare(model, env: env)
            SnapshotSheets.prepare(model, env: env)
            let window = makeWindow(size: size, title: "CMCR Manager", root: ContentView(), model: model)
            // The app's own window shares saved state (e.g. the dashboard's column widths) – give it the same size.
            for other in NSApp.windows where other !== window && other.styleMask.contains(.titled) {
                other.setContentSize(size)
            }
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
                    if env["CMCR_SNAPSHOT_TEXT"] == "1" {
                        try? describe(window).write(to: output.appendingPathComponent("\(section.rawValue)-\(name).txt"),
                                                    atomically: true, encoding: .utf8)
                    }
                    capture(window, to: output.appendingPathComponent("\(section.rawValue)-\(name).png"))
                }
                if env["CMCR_SNAPSHOT_CONFIRM"] == "1" {
                    await captureConfirmation(model, appearance: appearance,
                                              to: output.appendingPathComponent("confirm-\(name).png"))
                }
                for (kind, w) in extra {
                    w.appearance = NSAppearance(named: appearance)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    capture(w, to: output.appendingPathComponent("window-\(kind)-\(name).png"))
                }
            }
            await SnapshotSheets.renderRequested(model, env: env, into: output, wait: wait)
            restore()
            exit(0)
        }
    }

    /// `CMCR_SNAPSHOT_DEFAULTS=classroom.tab=attention,screens.labels=false`: user defaults (e.g. the
    /// `@AppStorage` of a sub-tab) set for the capture; the returned closure puts the previous values back.
    private static func applyDefaults(_ spec: String) -> () -> Void {
        let defaults = UserDefaults.standard
        var previous: [(String, Any?)] = []
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            previous.append((kv[0], defaults.object(forKey: kv[0])))
            let value: Any = kv[1] == "true" ? true : kv[1] == "false" ? false
                : Int(kv[1]).map { $0 as Any } ?? Double(kv[1]).map { $0 as Any } ?? kv[1]
            defaults.set(value, forKey: kv[0])
        }
        return {
            for (key, value) in previous { defaults.set(value, forKey: key) }
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

    /// Optional state for the pictures: CMCR_SNAPSHOT_SELECT=imac01,imac03 checks only these Macs,
    /// CMCR_SNAPSHOT_COMMAND=<script> runs a command on the checked Macs first (only with a demo or test
    /// configuration!) [as an action of CMCR_SNAPSHOT_COMMAND_SECTION], CMCR_SNAPSHOT_CONFIRM=1 also renders the confirmation sheet (confirm-light.png …).
    private static func prepare(_ model: AppModel, env: [String: String]) {
        if let names = env["CMCR_SNAPSHOT_SELECT"] {
            let wanted = Set(names.split(separator: ",").map(String.init))
            model.selection = Set(model.machines.filter { wanted.contains($0.name) }.map(\.id))
        }
        if let command = env["CMCR_SNAPSHOT_COMMAND"], !command.isEmpty {
            // The result box of that section shows the batch (CMCR_SNAPSHOT_COMMAND_SECTION=apps).
            if let owner = env["CMCR_SNAPSHOT_COMMAND_SECTION"].flatMap(AppSection.init(rawValue:)) { model.section = owner }
            model.runCommand(command, asRoot: false, on: model.selectedMachines)
        }
    }

    /// CMCR_SNAPSHOT_TEXT=1: the toolbar items (with "(overflow)" for those that did not fit) and the menu bar
    /// with keyboard shortcuts, as text next to each picture – menus cannot be photographed offscreen.
    private static func describe(_ window: NSWindow) -> String {
        var lines = ["Pasek narzędzi:"]
        if let toolbar = window.toolbar {
            let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
            for item in toolbar.items where !item.label.isEmpty {
                lines.append("  \(item.label)\(visible.contains(item.itemIdentifier) ? "" : " (overflow)")")
            }
        }
        func tables(_ v: NSView) -> [NSTableView] {
            (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables)
        }
        for t in tables(window.contentView?.superview ?? NSView()) where t.tableColumns.count > 1 {
            let cols = t.tableColumns.filter { !$0.isHidden }.map { "\($0.title)=\(Int($0.width))" }
            let frame = t.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? .zero
            lines.append("Tabela (\(Int(frame.minX))…\(Int(frame.maxX)) pt, hidden \(t.isHiddenOrHasHiddenAncestor), "
                         + "tabela \(Int(t.frame.width)) pt): " + cols.joined(separator: ", "))
        }
        lines.append("Menu:")
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                var key = ""
                if !item.keyEquivalent.isEmpty {
                    let m = item.keyEquivalentModifierMask
                    key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
                        + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
                }
                lines.append(String(repeating: "  ", count: depth) + item.title + (key.isEmpty ? "" : "  [\(key)]"))
                if let sub = item.submenu, depth < 2 { walk(sub, depth: depth + 1) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, depth: 1) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A sheet is not attached to a window that is never shown, so the sheet's view is rendered on its own.
    private static func captureConfirmation(_ model: AppModel, appearance: NSAppearance.Name, to url: URL) async {
        let targets = model.selectedMachines
        let request = ConfirmRequest(title: "Uruchomić ponownie zaznaczone komputery?",
                                     message: "Niezapisana praca uczniów zostanie utracona.",
                                     button: "Uruchom ponownie", targets: targets) {}
        // The sheet's background comes from its window, which is not drawn here.
        let host = NSHostingView(rootView: ConfirmSheet(request: request, targets: targets) {}
            .environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor)))
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

/// Draws like the frontmost window (accent-coloured switches and buttons) although it is never on screen.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}
