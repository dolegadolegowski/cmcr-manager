import CMCRCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var sortOrder = [KeyPathComparator(\Machine.name)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TargetHeader(section: .dashboard,
                         subtitle: "Stan pracowni. Zaznaczenie w tabeli i na liście po lewej jest wspólne dla wszystkich działów.")
            summaryTiles
            quickActions
            table
        }
        .padding(20)
    }

    var summaryTiles: some View {
        let all = model.machines
        let statuses = all.map { model.status($0) }
        let online = statuses.filter { $0.reachability == .online }.count
        let users = statuses.compactMap(\.consoleUser).count
        let problems = statuses.filter { [.authFailed, .error].contains($0.reachability) }.count
        let checking = statuses.filter { $0.reachability == .checking }.count
        return HStack(spacing: 12) {
            Tile(title: "Online", value: "\(online)/\(all.count)", icon: "wifi", color: .green)
            Tile(title: "Zalogowani użytkownicy", value: "\(users)", icon: "person.2.fill", color: .blue)
            Tile(title: "Wymaga uwagi", value: "\(problems)", icon: "exclamationmark.triangle.fill",
                 color: problems > 0 ? .orange : .secondary)
            Tile(title: "Sprawdzanie", value: "\(checking)", icon: "arrow.triangle.2.circlepath", color: .secondary)
        }
    }

    var quickActions: some View {
        HStack {
            Button {
                model.refreshStatus(model.selection.isEmpty ? nil : model.selectedMachines)
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            Button {
                model.selectedMachines.prefix(4).forEach(model.openTerminal)
            } label: {
                Label("Terminal SSH", systemImage: "terminal")
            }
            .disabled(model.selection.isEmpty)
            Button {
                model.selectedMachines.prefix(4).forEach(model.openScreenSharing)
            } label: {
                Label("VNC", systemImage: "rectangle.on.rectangle")
            }
            .disabled(model.selection.isEmpty)
            Button {
                model.section = .screens
            } label: {
                Label("Podgląd ekranów", systemImage: "eye")
            }
            .disabled(model.selection.isEmpty)
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var table: some View {
        Table(sortedMachines, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Stan") { m in
                HStack(spacing: 6) {
                    StatusDot(reachability: model.status(m).reachability)
                    Text(model.status(m).reachability.label).font(.caption)
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Nazwa", value: \.name)
                .width(min: 70, ideal: 90)
            TableColumn("Konto SSH", value: \.destination)
                .width(min: 140, ideal: 170)
            TableColumn("Zalogowany") { m in
                Text(model.status(m).consoleUser ?? "—")
            }
            .width(min: 70, ideal: 90)
            TableColumn("macOS") { m in
                Text(model.status(m).osVersion ?? "—")
            }
            .width(min: 50, ideal: 60)
            TableColumn("Model") { m in
                Text(model.status(m).model ?? "—").lineLimit(1)
            }
            .width(min: 70, ideal: 90)
            TableColumn("IP / MAC") { m in
                let st = model.status(m)
                Text("\(st.ip ?? "—")\n\(st.mac ?? (m.macAddress.isEmpty ? "—" : m.macAddress))")
                    .font(.caption.monospaced())
            }
            .width(min: 110, ideal: 130)
            TableColumn("Czas pracy") { m in
                Text(model.status(m).uptimeText ?? "—")
            }
            .width(min: 60, ideal: 80)
            TableColumn("Dysk") { m in
                Text(model.status(m).diskText ?? "—").lineLimit(1)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Uwagi") { m in
                let st = model.status(m)
                Text(st.message.isEmpty ? (st.updatedAt.map { "sprawdzono \($0.formatted(date: .omitted, time: .shortened))" } ?? "") : st.message)
                    .foregroundStyle(st.message.isEmpty ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .help(st.message)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let m = model.machine(id) {
                MachineContextMenu(machine: m)
            }
        } primaryAction: { ids in
            ids.compactMap(model.machine).prefix(4).forEach(model.openTerminal)
        }
    }

    var sortedMachines: [Machine] {
        model.machines.sorted(using: sortOrder)
    }
}

struct Tile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.weight(.semibold).monospacedDigit())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }
}
