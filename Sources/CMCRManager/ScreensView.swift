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
            VStack(alignment: .leading, spacing: 10) {
                TargetHeader(section: .screens,
                             subtitle: "Ekrany zalogowanych uczniów na żywo – tylko podgląd, bez przejmowania sterowania. Kliknij ekran dwukrotnie albo naciśnij spację, aby go powiększyć; strzałki przechodzą między komputerami.")
                ScreenRestrictionsBar()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
                controls(targets)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 6)
            if targets.isEmpty {
                ContentUnavailableView {
                    Label("Nie zaznaczono komputerów", systemImage: "display.2")
                } description: {
                    Text("Zaznacz komputery na liście obok, aby zobaczyć ich ekrany. Ściana ekranów w osobnym oknie pokazuje wszystkie komputery naraz – także na drugim monitorze.")
                } actions: {
                    Button("Zaznacz wszystkie komputery") { model.selection = Set(model.machines.map(\.id)) }
                    OpenScreenWallButton()
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScreenGrid(machines: targets, layout: layout, tileWidth: tileWidth, interval: interval,
                           showLabels: showLabels)
                    .padding(.horizontal, 6)
            }
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

    private func controls(_ targets: [Machine]) -> some View {
        HStack(spacing: 12) {
            Picker(selection: $layout) {
                ForEach(ScreenGridLayout.allCases) { l in Label(l.label, systemImage: l.symbol).tag(l) }
            } label: {
                Text("Układ")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Dopasuj do okna – wszystkie ekrany bez przewijania; według rozmiaru – suwak; albo stała liczba kolumn")
            if layout == .adaptive {
                Slider(value: $tileWidth, in: 200...800) {
                    Text("Rozmiar")
                } minimumValueLabel: {
                    Image(systemName: "square.grid.3x3").help("Mniejsze kafelki")
                } maximumValueLabel: {
                    Image(systemName: "square").help("Większe kafelki")
                }
                .frame(width: 200)
            }
            Toggle("Podpisy", isOn: $showLabels)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .help("Nazwa komputera, użytkownik i aplikacja na pierwszym planie na kafelkach")
            Spacer(minLength: 12)
            ScreenRefreshMenu(interval: $interval)
            Button {
                center.refresh(targets.map(\.id))
            } label: {
                Label("Odśwież teraz", systemImage: "arrow.clockwise")
            }
            .disabled(targets.isEmpty)
            .help("Pobierz nowe obrazy od razu")
            OpenScreenWallButton()
                .buttonStyle(.borderedProminent)
        }
    }
}
