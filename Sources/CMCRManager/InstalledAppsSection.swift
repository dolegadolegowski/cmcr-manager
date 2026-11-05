import AppKit
import CMCRCore
import SwiftUI

/// „Zainstalowane aplikacje” (Aplikacje): every app on the checked Macs with version, size, place and on how many
/// Macs it is, optionally the package receipts, and „Odinstaluj…” with a dry run first (UninstallSheet).
struct InstalledAppsSection: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var filter = ""
    @ViewState private var selection: Set<String> = []
    @ViewState private var showProtected = false
    @ViewState private var showPackages = false
    @ViewState private var preview: UninstallPreview?

    /// One row of the table: the same path on several Macs, with the version each of them has.
    struct Row: Identifiable {
        let app: InstalledApp
        /// (Mac, version) for every Mac that has the app; the version is empty when the app has none.
        let hosts: [(host: String, version: String)]
        /// The checked Macs in list order (ranges in the version text never skip one of them).
        let order: [String]
        let sizeKB: Int64?
        var id: String { app.path }
        var count: Int { hosts.count }
        /// The distinct versions, the most common first.
        var versions: [String] { VersionSummary.groups(hosts, order: order).map(\.version) }
        /// One version: it („—” when the app has none). Several: each with its Macs, „12.1 (imac01–imac10), 12.0 (imac11)”.
        var versionText: String { VersionSummary.text(hosts, order: order) }
        /// Every Mac with its version, one per line (the column's help).
        var versionDetail: String {
            hosts.map { "\($0.host): \($0.version.isEmpty ? "—" : $0.version)" }.joined(separator: "\n")
        }
    }

    struct PackageRow: Identifiable {
        let package: InstalledPackage
        let count: Int
        var id: String { package.id }
    }

    var body: some View {
        let machines = model.selectedMachines
        let checked = machines.filter { model.installedApps[$0.id] != nil }.count
        let loading = machines.filter { model.installedAppsLoading.contains($0.id) }.count
        let failed = machines.compactMap { m in model.installedAppsErrors[m.id].map { (m.name, $0) } }
        let all = Self.rows(machines.compactMap { m in model.installedApps[m.id].map { (m.name, $0) } },
                            order: machines.map(\.name))
        let rows = all.filter { showProtected || $0.app.isRemovable }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? rows : rows.filter {
            $0.app.name.localizedStandardContains(needle) || $0.app.bundleID.localizedStandardContains(needle)
        }
        let selected = shown.filter { selection.contains($0.id) }
        let removable = selected.map(\.app).filter(\.isRemovable)
        let mdm = machines.filter { model.installedApps[$0.id]?.mdmEnrolled == true }.count
        return Section {
            FormActionRow("Aplikacje na zaznaczonych komputerach",
                          caption: loading > 0
                              ? "Wczytywanie listy \(Polish.onComputers(loading))…"
                              : checked == 0
                              ? "Pobierz listę: nazwa, wersja, rozmiar i miejsce każdej aplikacji (także w folderze Aplikacje ucznia)."
                              : "Sprawdzono \(Polish.computers(checked)). Pomarańczowa liczba – aplikacji brakuje na części z nich.") {
                TargetButton(title: checked == 0 ? "Pobierz listę" : "Odśwież listę",
                             icon: "arrow.down.circle", prominent: false) {
                    model.refreshInstalledApps(machines)
                }
            }
            // Macs whose list could not be read say why, instead of quietly missing from the counts (AUDIT WSP-06).
            ForEach(failed.prefix(4), id: \.0) { name, error in
                Label("\(name): \(error)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if failed.count > 4 {
                Text("… i \(Polish.computers(failed.count - 4)) z błędem").font(.callout).foregroundStyle(.secondary)
            }
            if !all.isEmpty {
                HStack(spacing: 12) {
                    SearchField(text: $filter, prompt: "Szukaj aplikacji lub identyfikatora")
                        .accessibilityLabel("Szukaj aplikacji")
                    Toggle("Systemowe i Apple", isOn: $showProtected)
                        .help("Pokaż także aplikacje macOS i Apple (np. Safari, Pages) – można je uruchomić, ale nie odinstalować")
                        .fixedSize()
                }
                table(shown, checked: checked, filter: needle)
                    .frame(height: 320)
                actions(selected: selected, removable: removable)
                if let note = selectedNote(selected) {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                packagesRow(machines, checked: checked)
            }
        } header: {
            Label("Zainstalowane aplikacje", systemImage: "square.grid.2x2")
        } footer: {
            if mdm > 0 {
                FormSectionNote("\(Polish.computers(mdm)) jest w MDM: aplikacje przydzielane przez MDM mogą wrócić po odinstalowaniu – takie usuwaj w konsoli MDM.")
            }
        }
        .sheet(item: $preview) { p in UninstallSheet(preview: p) }
    }

    // MARK: Table

    func table(_ shown: [Row], checked: Int, filter: String) -> some View {
        Table(shown, selection: $selection) {
            TableColumn("Aplikacja") { row in
                HStack(spacing: 8) {
                    Image(nsImage: AppIcons.icon(forBundlePath: row.app.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                        .opacity(row.app.isRemovable ? 1 : 0.6)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(row.app.name).lineLimit(1)
                            if !row.app.kindLabel.isEmpty {
                                Text(row.app.kindLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        if !row.app.bundleID.isEmpty {
                            Text(row.app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .help(row.app.path)
            }
            .width(min: 170, ideal: 230)
            TableColumn("Wersja") { row in
                Text(row.versionText)
                    .monospacedDigit()
                    .foregroundStyle(row.versions.count > 1 ? Color.orange : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.versions.count > 1 ? "Na komputerach są różne wersje:\n\(row.versionDetail)" : row.versionDetail)
            }
            .width(min: 70, ideal: 110, max: 260)
            TableColumn("Rozmiar") { row in
                Text(AppInventory.sizeText(row.sizeKB))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 75, max: 100)
            TableColumn("Jest") { row in
                Text("na \(row.count) z \(checked)")
                    .monospacedDigit()
                    .foregroundStyle(row.count == checked ? Color.secondary : Color.orange)
                    .help("Zainstalowana \(Polish.onComputers(row.count)) z \(checked) sprawdzonych")
            }
            .width(min: 70, ideal: 80, max: 110)
            TableColumn("Miejsce") { row in
                Text(row.app.locationLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.app.path)
            }
            .width(min: 100, ideal: 160)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = shown.filter { ids.contains($0.id) }
            if let first = picked.first {
                Button { model.launchApp(first.app.path, on: model.selectedMachines) } label: {
                    Label("Uruchom na zaznaczonych komputerach", systemImage: "play.fill")
                }
                .disabled(model.actionTargets.isEmpty || first.app.kind == .unity)
                let removable = picked.map(\.app).filter(\.isRemovable)
                if !removable.isEmpty {
                    Divider()
                    Button(role: .destructive) { startUninstall(removable) } label: {
                        Label("Odinstaluj…", systemImage: "trash")
                    }
                    .disabled(model.actionTargets.isEmpty)
                }
            }
        }
        .overlay {
            if shown.isEmpty {
                if filter.isEmpty {
                    ContentUnavailableView("Brak aplikacji do odinstalowania", systemImage: "square.grid.2x2",
                                           description: Text("Zaznacz „Systemowe i Apple”, aby zobaczyć wszystkie."))
                } else {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .accessibilityLabel("Zainstalowane aplikacje")
    }

    func actions(selected: [Row], removable: [InstalledApp]) -> some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                startUninstall(removable)
            } label: {
                Label("Odinstaluj…", systemImage: "trash")
                    .destructiveLabel()
            }
            .disabled(removable.isEmpty || model.actionTargets.isEmpty)
            .help(removable.isEmpty
                  ? (selected.isEmpty ? "Zaznacz aplikację na liście." : "Tych aplikacji nie można odinstalować.")
                  : "Podgląd, co zostanie usunięte z zaznaczonych komputerów – potem potwierdzenie")
            Divider().frame(height: 18)
            Text(selected.isEmpty ? "Zaznacz aplikację na liście (⌘ – kilka)."
                 : "Zaznaczone: \(selected.map(\.app.name).joined(separator: ", "))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button {
                if let first = selected.first { model.launchApp(first.app.path, on: model.selectedMachines) }
            } label: {
                Label("Uruchom", systemImage: "play.fill")
            }
            .disabled(selected.count != 1 || selected.first?.app.kind == .unity || model.actionTargets.isEmpty)
            .help(selected.first.map { "Uruchom \($0.app.name) na zaznaczonych komputerach" } ?? "Zaznacz aplikację na liście.")
        }
    }

    /// The versions of the selected apps on the checked Macs (the column may be too narrow for all of them), then why
    /// they cannot be removed or what is special about removing them.
    func selectedNote(_ selected: [Row]) -> String? {
        let versions = selected.prefix(3).map { "\($0.app.name) – wersja: \($0.versionText)" }
        let notes = versions + selected.compactMap { row -> String? in
            if let reason = row.app.reasonNotRemovable { return "\(row.app.name): \(reason)" }
            return row.app.uninstallNote.map { "\(row.app.name): \($0)" }
        }
        let unique = notes.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.prefix(6).joined(separator: "\n")
    }

    func startUninstall(_ apps: [InstalledApp]) {
        guard !apps.isEmpty, !model.selectedMachines.isEmpty else { return }
        let p = UninstallPreview(apps: apps, targets: model.selectedMachines, model: model)
        p.load()
        preview = p
    }

    // MARK: Packages

    @ViewBuilder func packagesRow(_ machines: [Machine], checked: Int) -> some View {
        Toggle(isOn: Binding(get: { model.installedAppsWithPackages }, set: { on in
            model.installedAppsWithPackages = on
            if on { model.refreshInstalledApps(machines) }
        })) {
            Text("Pokaż pakiety instalacyjne (pkgutil)")
            Text("Wpisy pakietów .pkg spoza Apple – przy odinstalowaniu aplikacji CMCR wyrejestrowuje też jej pakiet.")
        }
        if model.installedAppsWithPackages {
            let packages = Self.packageRows(machines.compactMap { model.installedApps[$0.id] })
            DisclosureGroup(isExpanded: $showPackages) {
                if packages.isEmpty {
                    Text(checked == 0 ? "Pobierz listę." : "Brak pakietów spoza Apple (albo lista sprzed włączenia tej opcji – odśwież ją).")
                        .foregroundStyle(.secondary)
                }
                ForEach(packages) { row in
                    HStack {
                        Text(row.package.id).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(row.package.version).foregroundStyle(.secondary).monospacedDigit()
                        if let date = row.package.installed {
                            Text(date.formatted(date: .numeric, time: .omitted)).foregroundStyle(.tertiary).font(.caption)
                        }
                        Text("na \(row.count) z \(checked)")
                            .monospacedDigit()
                            .foregroundStyle(row.count == checked ? Color.secondary : Color.orange)
                    }
                    .font(.callout)
                }
            } label: {
                Text("Pakiety spoza Apple: \(packages.count)")
            }
        }
    }

    // MARK: Data

    /// One row per app path over the Macs (`name` = the Mac's name), sorted by app name.
    static func rows(_ inventories: [(name: String, inventory: HostInventory)], order: [String]) -> [Row] {
        var paths: [String] = []
        var first: [String: InstalledApp] = [:]
        var hosts: [String: [(host: String, version: String)]] = [:]
        var sizes: [String: Int64] = [:]
        for (name, inv) in inventories {
            for app in inv.apps {
                if first[app.path] == nil { first[app.path] = app; paths.append(app.path) }
                hosts[app.path, default: []].append((name, app.version))
                if let kb = app.sizeKB { sizes[app.path] = max(sizes[app.path] ?? 0, kb) }
            }
        }
        return paths.compactMap { path in
            first[path].map { Row(app: $0, hosts: hosts[path] ?? [], order: order, sizeKB: sizes[path]) }
        }
        .sorted {
            let order = $0.app.name.localizedStandardCompare($1.app.name)
            return order == .orderedSame ? $0.app.path < $1.app.path : order == .orderedAscending
        }
    }

    static func packageRows(_ inventories: [HostInventory]) -> [PackageRow] {
        var first: [String: InstalledPackage] = [:]
        var counts: [String: Int] = [:]
        for inv in inventories {
            for p in inv.packages {
                if first[p.id] == nil { first[p.id] = p }
                counts[p.id, default: 0] += 1
            }
        }
        return first.values.sorted { $0.id < $1.id }.map { PackageRow(package: $0, count: counts[$0.id] ?? 0) }
    }
}
