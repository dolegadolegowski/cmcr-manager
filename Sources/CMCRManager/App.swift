import AppKit
import CMCRCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Allows running the bare executable (swift run) as a regular windowed app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CMCRManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        // Writing a password to an ssh that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup("CMCR Manager", id: MainWindow.id) {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.screens)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Odśwież stan komputerów") { model.refreshStatus() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Zaznacz wszystkie komputery") { model.selection = Set(model.machines.map(\.id)) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Zaznacz komputery online") {
                    model.selection = Set(model.machines.filter { model.status($0).reachability == .online }.map(\.id))
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Odznacz wszystkie") { model.selection = [] }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Przejdź") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: [.command])
                }
            }
            ScreenCommands(center: model.screens)
        }

        Window("Ściana ekranów", id: ScreenWallView.windowID) {
            ScreenWallView()
                .environmentObject(model)
                .environmentObject(model.screens)
        }
        .defaultSize(width: 1600, height: 1000)
        // Opened from ScreenCommands (with ⇧⌘E) instead of SwiftUI's own Window-menu item.
        .commandsRemoved()

        WindowGroup("Podgląd ekranu", id: ScreenWindowView.windowID, for: UUID.self) { $id in
            ScreenWindowView(machineID: id)
                .environmentObject(model)
                .environmentObject(model.screens)
        }
        .defaultSize(width: 1100, height: 720)
        .commandsRemoved()
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            MachineListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { OpenScreenWallButton() }
        }
        .task {
            model.refreshStatus()
            // Keep the overview fresh in the background.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                model.refreshStatus(quietly: true)
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.section) {
            Section("Zarządzanie") {
                row(.dashboard)
                row(.commands)
                row(.files)
                row(.apps)
                row(.install)
                row(.updates)
            }
            Section("Nadzór") {
                row(.screens)
                row(.power)
            }
            Section("System") {
                row(.jobs)
                row(.setup)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !model.hasSharedPassword {
                Button {
                    model.section = .setup
                } label: {
                    Label("Ustaw hasło administratora", systemImage: "key.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .padding(8)
            }
        }
    }

    func row(_ s: AppSection) -> some View {
        HStack {
            Label(s.title, systemImage: s.icon)
            if s == .jobs, model.runningJobCount > 0 {
                Spacer()
                Text("\(model.runningJobCount)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
            }
        }
        .tag(s)
    }
}

struct MachineListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.machines) { m in
                MachineRow(machine: m, status: model.status(m))
                    .tag(m.id)
                    .contextMenu { MachineContextMenu(machine: m) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Text("Zaznaczono \(model.selection.count)/\(model.machines.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Wszystkie") { model.selection = Set(model.machines.map(\.id)) }
                Button("Online") {
                    model.selection = Set(model.machines.filter { model.status($0).reachability == .online }.map(\.id))
                }
                Button("Żadne") { model.selection = [] }
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshStatus()
                } label: {
                    Label("Odśwież stan", systemImage: "arrow.clockwise")
                }
                .help("Odśwież stan wszystkich komputerów (⌘R)")
            }
        }
    }
}

struct MachineRow: View {
    let machine: Machine
    let status: HostStatus

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(reachability: status.reachability)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name).fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let user = status.consoleUser {
                Label(user, systemImage: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
        .help(status.message.isEmpty ? machine.destination : status.message)
    }

    var subtitle: String {
        switch status.reachability {
        case .online:
            return [status.osVersion.map { "macOS \($0)" }, status.ip].compactMap { $0 }.joined(separator: " · ")
        case .unknown, .checking:
            return machine.address
        default:
            return status.message.isEmpty ? status.reachability.label : status.message
        }
    }
}

struct MachineContextMenu: View {
    @EnvironmentObject var model: AppModel
    let machine: Machine

    var body: some View {
        Button("Odśwież stan") { model.refreshStatus([machine]) }
        Button("Sesja SSH w Terminalu (cmcr-go)") { model.openTerminal(machine) }
        Button("Udostępnianie ekranu (VNC)") { model.openScreenSharing(machine) }
        Button("Podgląd ekranu") {
            model.selection = [machine.id]
            model.section = .screens
        }
        OpenScreenWindowMenuItem(machine: machine)
        Divider()
        Button("Wake-on-LAN") { model.wake([machine]) }
        Button("Kopiuj adres") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(machine.destination, forType: .string)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.section ?? .dashboard {
            case .dashboard: DashboardView()
            case .commands: CommandsView()
            case .files: FilesView()
            case .apps: AppsView()
            case .install: InstallView()
            case .updates: UpdatesView()
            case .screens: ScreensView()
            case .power: PowerView()
            case .jobs: JobsView()
            case .setup: SetupView()
            }
        }
        .navigationTitle(model.section?.title ?? "CMCR Manager")
    }
}

/// Scrollable page container used by the action sections.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
