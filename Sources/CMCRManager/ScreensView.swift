import AppKit
import CMCRCore
import SwiftUI

struct ScreensView: View {
    @EnvironmentObject var model: AppModel
    @State private var autoRefresh = true
    @State private var tileWidth: Double = 320
    @State private var focused: Machine?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TargetHeader(section: .screens,
                         subtitle: "Podgląd ekranów zalogowanych użytkowników – wyłącznie do odczytu, bez przejmowania sterowania.")
            restrictionsBar
            controls
            if model.selectedMachines.isEmpty {
                Spacer()
                Text("Zaznacz komputery na liście, aby zobaczyć ich ekrany.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 12)], spacing: 12) {
                        ForEach(model.selectedMachines) { m in
                            ScreenTile(machine: m, state: model.screenState(for: m.id))
                                .onTapGesture(count: 2) { focused = m }
                                .contextMenu {
                                    Button("Powiększ") { focused = m }
                                    Button("Odśwież") { Task { await model.captureScreen(m, maxSize: thumbSize) } }
                                    Button("Udostępnianie ekranu (VNC)") { model.openScreenSharing(m) }
                                }
                        }
                    }
                }
            }
        }
        .padding(20)
        .task(id: refreshKey) { await refreshLoop() }
        .onDisappear { model.endObservation() }
        .sheet(item: $focused) { m in
            ScreenDetail(machine: m).environmentObject(model)
        }
    }

    var thumbSize: Int { min(model.settings.screenshotMaxSize, Int(tileWidth * 2)) }

    var refreshKey: String {
        "\(autoRefresh)-\(model.selection.sorted { $0.uuidString < $1.uuidString })-\(model.settings.screenshotInterval)-\(thumbSize)"
    }

    func refreshLoop() async {
        await captureAll()
        while autoRefresh && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(max(3, model.settings.screenshotInterval)) * 1_000_000_000)
            if Task.isCancelled { break }
            await captureAll()
        }
    }

    func captureAll() async {
        let targets = model.selectedMachines
        let size = thumbSize
        await withTaskGroup(of: Void.self) { group in
            for m in targets {
                group.addTask { await model.captureScreen(m, maxSize: size) }
            }
        }
    }

    var restrictionsBar: some View {
        let s = model.settings
        let allowed = s.observeAllowedUserList
        return HStack(spacing: 14) {
            Label("Tylko podgląd", systemImage: "eye")
            Label(s.notifyOnObserve ? "Użytkownik jest powiadamiany" : "Bez powiadomień",
                  systemImage: s.notifyOnObserve ? "bell.fill" : "bell.slash")
            Label(s.observeOnlyStandardAccounts ? "Tylko konta standardowe" : "Wszystkie konta",
                  systemImage: "person.badge.shield.checkmark")
            if !allowed.isEmpty {
                Label("Konta: \(allowed.joined(separator: ", "))", systemImage: "person.2")
            }
            Label("≤ \(s.screenshotMaxSize) px, co \(s.screenshotInterval) s", systemImage: "photo")
            Spacer()
            Button("Zmień ograniczenia…") { model.section = .setup }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    var controls: some View {
        HStack {
            Toggle("Odświeżaj automatycznie", isOn: $autoRefresh)
                .toggleStyle(.switch)
            Button {
                Task { await captureAll() }
            } label: {
                Label("Odśwież teraz", systemImage: "arrow.clockwise")
            }
            Spacer()
            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
            Slider(value: $tileWidth, in: 220...640)
                .frame(width: 160)
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
        }
    }
}

struct ScreenTile: View {
    let machine: Machine
    @ObservedObject var state: ScreenState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
                if let image = state.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let message = state.message {
                    VStack(spacing: 6) {
                        Image(systemName: "eye.slash").font(.title2)
                        Text(message).font(.caption).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
                if state.loading && state.image != nil {
                    VStack {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.mini).padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(machine.name).fontWeight(.medium)
                if let user = state.user {
                    Label(user, systemImage: "person.fill").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let t = state.updatedAt {
                    Text(t.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
        .help("Kliknij dwukrotnie, aby powiększyć")
    }
}

/// Enlarged, faster refreshing view of one screen with a few quick actions.
struct ScreenDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let machine: Machine
    @State private var message = ""

    var body: some View {
        let state = model.screenState(for: machine.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(machine.name).font(.title2.weight(.semibold))
                Text(machine.destination).foregroundStyle(.secondary)
                Spacer()
                Button("Udostępnianie ekranu (VNC)") { model.openScreenSharing(machine) }
                Button("Zamknij") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScreenTile(machine: machine, state: state)
                .frame(minWidth: 900, minHeight: 560)
            HStack {
                TextField("Wiadomość dla użytkownika", text: $message)
                Button("Wyślij") {
                    model.runScript("Wiadomość", on: [machine]) { _ in
                        Scripts.message(title: "Wiadomość od administratora", text: message, asDialog: true)
                    }
                    message = ""
                }
                .disabled(message.isEmpty)
                Divider().frame(height: 18)
                Button("Uśpij ekran") { model.power(.displaySleep, on: [machine]) }
                Button("Aplikacje…") {
                    model.selection = [machine.id]
                    model.section = .apps
                    dismiss()
                }
            }
        }
        .padding(20)
        .task {
            // Larger image and faster refresh while focused.
            while !Task.isCancelled {
                await model.captureScreen(machine, maxSize: max(1600, model.settings.screenshotMaxSize))
                try? await Task.sleep(nanoseconds: UInt64(max(3, model.settings.screenshotInterval / 2)) * 1_000_000_000)
            }
        }
    }
}
