import AppKit
import CMCRCore
import SwiftUI

// MARK: - Window-wide toolbar items

/// Items shown in the main window's toolbar in every section (after the section's own items).
struct MainToolbar: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
        ToolbarItemGroup {
            RefreshToolbarButton()
            ScreenWallToolbarButton()
            ActivityToolbarButton()
        }
    }
}

/// "Odśwież": checks every Mac again (⌘R in the menu); its menu can limit that to the checked ones.
struct RefreshToolbarButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let checking = model.machines.contains { model.status($0).reachability == .checking }
        Menu {
            Button {
                model.refreshStatus()
            } label: {
                Label("Odśwież wszystkie komputery", systemImage: "arrow.clockwise")
            }
            Button {
                model.refreshStatus(model.selectedMachines)
            } label: {
                Label("Odśwież tylko zaznaczone (\(model.selection.count))", systemImage: "checklist")
            }
            .disabled(model.selection.isEmpty)
        } label: {
            Label(checking ? "Sprawdzanie…" : "Odśwież", systemImage: "arrow.clockwise")
        } primaryAction: {
            model.refreshStatus()
        }
        .help("Sprawdź, które komputery są włączone i kto jest zalogowany (⌘R). Strzałka obok: tylko zaznaczone.")
        .accessibilityLabel("Odśwież stan komputerów")
    }
}

/// Opens the separate "Ściana ekranów" window (also ⇧⌘E in the Okno menu).
struct ScreenWallToolbarButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: ScreenWallView.windowID)
        } label: {
            Label("Ściana ekranów", systemImage: "rectangle.split.3x3")
        }
        .help("Pokaż ekrany wszystkich zaznaczonych komputerów w osobnym oknie, np. na drugim monitorze (⇧⌘E)")
    }
}

// MARK: - Toolbar titles

/// Shows every toolbar item with its title under the icon ("Icon and Text"), so nobody has to guess what an
/// icon means. Put it in the background of the window's root view.
struct ToolbarTitlesShown: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    final class Probe: NSView {
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.toolbar, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.apply() }
            }
            apply()
        }

        func apply() {
            guard let toolbar = window?.toolbar, toolbar.displayMode != .iconAndLabel else { return }
            toolbar.displayMode = .iconAndLabel
        }
    }
}
