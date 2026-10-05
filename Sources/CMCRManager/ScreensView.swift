import AppKit
import CMCRCore
import SwiftUI

/// "Podgląd ekranów": live screens of the Macs selected in the list, plus the entry to the screen wall window.
struct ScreensView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var center: ScreenCenter
    @Environment(\.openWindow) private var openWindow
    @AppStorage("screens.layout") private var layout: ScreenGridLayout = .fit
    @AppStorage("screens.tileWidth") private var tileWidth: Double = 320
    @AppStorage("screens.interval") private var interval = 0
    @AppStorage("screens.labels") private var showLabels = true

    var body: some View {
        let targets = model.selectedMachines
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TargetHeader(section: .screens,
                             subtitle: "Ekrany zaznaczonych komputerów na żywo – tylko podgląd, bez przejmowania sterowania. Kliknij ekran dwukrotnie lub naciśnij spację, aby go powiększyć; strzałki przechodzą do kolejnych komputerów.")
                if !targets.isEmpty {
                    controls(targets)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 6)
            if targets.isEmpty {
                ContentUnavailableView {
                    Label("Nie zaznaczono komputerów", systemImage: "display.2")
                } description: {
                    Text("Zaznacz komputery na liście obok, aby zobaczyć ich ekrany. Ściana ekranów pokazuje wszystkie komputery naraz w osobnym oknie – także na drugim monitorze lub projektorze.")
                } actions: {
                    Button {
                        model.selection = Set(model.machines.map(\.id))
                    } label: {
                        Label("Zaznacz wszystkie komputery", systemImage: "checklist")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.machines.isEmpty)
                    .help("Zaznacz wszystkie komputery z listy (⇧⌘A)")
                    OpenScreenWallButton()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScreenGrid(machines: targets, layout: layout, tileWidth: tileWidth, interval: interval,
                           showLabels: showLabels)
                    .padding(.horizontal, 6)
            }
        }
        .overlay(alignment: .bottom) { ScreenBatchBanner().padding(16) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ScreenStatusBar(interval: $interval)
        }
        .screenScope(pausesWhenInactive: true)
        .task {
            // Start-up hook for scripted UI checks: CMCR_OPEN_SCREEN_WALL=1 opens the screen wall window.
            if ProcessInfo.processInfo.environment["CMCR_OPEN_SCREEN_WALL"] == "1", !Self.openedWall {
                Self.openedWall = true
                openWindow(id: ScreenWallView.windowID)
            }
        }
    }

    @MainActor private static var openedWall = false

    /// View options on the left, actions on the right; narrower windows get a more compact variant (never
    /// truncated labels).
    private func controls(_ targets: [Machine]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                viewOptions(compact: false)
                Spacer(minLength: 12)
                actions(targets)
            }
            HStack(spacing: 12) {
                viewOptions(compact: true)
                Spacer(minLength: 12)
                actions(targets)
            }
            VStack(alignment: .leading, spacing: 8) {
                viewOptions(compact: false)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    actions(targets)
                }
            }
        }
    }

    @ViewBuilder private func viewOptions(compact: Bool) -> some View {
        ScreenLayoutPicker(layout: $layout)
            .labelsHidden(compact)
        if layout == .adaptive {
            ScreenSizeSlider(tileWidth: $tileWidth, range: 200...800)
                .frame(width: compact ? 110 : 160)
        }
        Toggle("Podpisy", isOn: $showLabels)
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .help("Pokaż na ekranach nazwę komputera, zalogowanego ucznia i aplikację, której używa")
    }

    @ViewBuilder private func actions(_ targets: [Machine]) -> some View {
        Button {
            center.refresh(targets.map(\.id))
        } label: {
            Label("Odśwież teraz", systemImage: "arrow.clockwise")
        }
        .fixedSize()
        .help("Pobierz nowe obrazy ze wszystkich widocznych komputerów od razu")
        OpenScreenWallButton()
            .buttonStyle(.borderedProminent)
            .fixedSize()
    }
}

private extension View {
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}
