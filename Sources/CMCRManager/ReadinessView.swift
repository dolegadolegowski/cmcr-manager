import AppKit
import CMCRCore
import SwiftUI

// MARK: - State

/// Results of the readiness check, kept while the user switches sections.
@MainActor
final class ReadinessStore: ObservableObject {
    static let shared = ReadinessStore()

    @Published private(set) var reports: [UUID: ReadinessReport] = [:]
    @Published private(set) var checking: Set<UUID> = []
    @Published private(set) var lastCheck: Date?

    func check(_ machines: [Machine], model: AppModel) {
        let settings = model.settings
        let ss = model.sshSettings
        let student = settings.studentUser
        let folder = settings.resolve(settings.sharedFolder)
        let script = Scripts.readiness(student: student, sharedFolder: folder, publicKey: model.managerPublicKey)
        let timeout = TimeInterval(settings.connectTimeout + 45)
        let jobs = machines.filter { !checking.contains($0.id) }.map { ($0, model.password(for: $0)) }
        guard !jobs.isEmpty else { return }
        checking.formUnion(jobs.map(\.0.id))
        Task {
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for (m, pw) in jobs {
                    if active >= 16 {
                        await group.next()
                        active -= 1
                    }
                    group.addTask {
                        let r = await SSH.run(script, on: m, password: pw, settings: ss, timeout: timeout)
                        let report = r.succeeded
                            ? ReadinessReport.parse(r.stdoutText, student: student, sharedFolder: folder)
                            : ReadinessReport.unreachable(r)
                        await self.finish(m.id, report)
                    }
                    active += 1
                }
            }
        }
    }

    private func finish(_ id: UUID, _ report: ReadinessReport) {
        reports[id] = report
        checking.remove(id)
        lastCheck = Date()
    }
}

/// Hides the machine-readable JSON block of the setup report from the job log (the app reads it from stdout).
final class SetupReportFilter: @unchecked Sendable {
    private let forward: Operations.Output
    private let decoder = UTF8StreamDecoder()
    private let lock = NSLock()
    private var pending = ""
    private var inJSON = false

    init(_ forward: @escaping Operations.Output) { self.forward = forward }

    var callback: Operations.Output {
        { [self] channel, data in
            guard channel == .stdout else { forward(channel, data); return }
            lock.lock()
            pending += decoder.decode(data)
            var out = ""
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending.removeSubrange(...nl)
                if line == SetupScript.reportBegin { inJSON = true; continue }
                if line == SetupScript.reportEnd { inJSON = false; continue }
                if !inJSON { out += line + "\n" }
            }
            lock.unlock()
            if !out.isEmpty { forward(.stdout, Data(out.utf8)) }
        }
    }
}

enum ReadinessFix {
    case key, folder, wol, vnc
}

extension AppModel {
    /// Public key of the SSH identity this app uses (installed on the iMacs by the setup script).
    var managerPublicKey: String? {
        SSHKeys.currentPrivateKey(settings: settings).flatMap { SSHKeys.publicKey(for: $0) }
    }

    /// Runs setup/cmcr-imac-setup.sh as root on the targets, then re-checks their readiness.
    func runSetupScript(_ options: SetupOptions, mode: SetupScript.Mode, on targets: [Machine]) {
        let key = managerPublicKey
        let settings = self.settings
        let title = mode == .apply
            ? "Konfiguracja iMaców (skrypt \(SetupScript.version))"
            : "Sprawdzenie konfiguracji iMaców (bez zmian)"
        runBatch(title, on: targets, section: .setup, operation: { m, job in
            let script = SetupScript.remote(options, host: m, settings: settings, publicKey: key, mode: mode)
            let filter = SetupReportFilter(OutputSink(job).callback)
            let r = await SSH.run(script, on: m, password: self.password(for: m), settings: self.sshSettings,
                                  handle: job.handle, onOutput: filter.callback)
            if let report = SetupReport.parse(r.stdoutText) {
                job.note(report.summary)
            } else if r.exitCode == SetupScript.ExitCode.badOptions {
                job.note("Skrypt odrzucił opcje – szczegóły powyżej.")
            }
            return r
        }, completion: { batch in
            ReadinessStore.shared.check(batch.jobs.map(\.machine), model: self)
        })
    }

    /// Small targeted fixes for single readiness problems (no full setup run).
    func applyReadinessFix(_ fix: ReadinessFix, on targets: [Machine]) {
        let recheck: @MainActor (Machine, CommandResult) -> Void = { m, _ in
            ReadinessStore.shared.check([m], model: self)
        }
        switch fix {
        case .key:
            guard let pub = managerPublicKey else { NSSound.beep(); return }
            runScript("Instalacja klucza SSH", on: targets, section: .setup,
                      script: { _ in Scripts.distributeKey(pub) }, onResult: recheck)
        case .folder:
            let path = settings.resolve(settings.sharedFolder), owner = settings.studentUser
            runScript("Folder ucznia \(path)", on: targets, section: .setup,
                      script: { _ in Scripts.createStudentFolder(path, owner: owner) }, onResult: recheck)
        case .wol:
            runScript("Włącz Wake-on-LAN", on: targets, section: .setup,
                      script: { _ in Scripts.enableWakeOnLAN() }, onResult: recheck)
        case .vnc:
            runScript("Włącz Udostępnianie ekranu", on: targets, section: .setup,
                      script: { _ in Scripts.enableScreenSharing() }, onResult: recheck)
        }
    }
}

// MARK: - Presentation helpers

extension ReadinessState {
    var icon: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .off: return "minus.circle"
        case .unknown: return "questionmark.circle"
        case .manual: return "hand.raised.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .off, .unknown: return .secondary
        case .manual: return .blue
        case .warning: return .orange
        case .problem: return .red
        }
    }

    var legend: String {
        switch self {
        case .ok: return "Gotowe"
        case .warning: return "Do poprawy"
        case .problem: return "Problem"
        case .manual: return "Wymaga wizyty przy komputerze"
        case .off: return "Wyłączone (opcjonalne)"
        case .unknown: return "Nie sprawdzono"
        }
    }
}

extension ReadinessCheck {
    /// Name shown in the app, without jargon (the core `title` keeps the technical name for the CLI).
    var displayTitle: String {
        switch self {
        case .ssh: return "Połączenie i klucz"
        case .sudo: return "Hasło administratora"
        case .wol: return "Budzenie przez sieć"
        case .filevault: return "Szyfrowanie FileVault"
        case .setup: return "Wersja konfiguracji"
        default: return title
        }
    }

    /// Column header broken into lines, so no title is truncated in the matrix.
    var header: String {
        switch self {
        case .ssh: return "Połączenie\ni klucz"
        case .sudo: return "Hasło\nadministratora"
        case .folder: return "Folder\nucznia"
        case .wol: return "Budzenie\nprzez sieć"
        case .vnc: return "Udostępnianie\nekranu"
        case .screen: return "Nagrywanie\nekranu"
        case .fda: return "Pełny dostęp\ndo dysku"
        case .filevault: return "FileVault"
        case .setup: return "Wersja\nkonfiguracji"
        }
    }

    /// Tooltip of the column: the explanation plus the technical name where the display name hides it.
    var tooltip: String {
        switch self {
        case .ssh: return "Połączenie zdalne (SSH). " + explanation
        case .sudo: return "Uprawnienia administratora (sudo). " + explanation
        case .wol: return "Wake-on-LAN. " + explanation
        default: return explanation
        }
    }
}

extension View {
    /// Tile behind a summary count: a quiet fill with a hairline, readable in both appearances.
    func readinessChipBackground() -> some View {
        background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

/// Steps that macOS allows only at the computer, with exact System Settings paths.
enum ManualStep: String, CaseIterable, Identifiable {
    case fullDiskAccess, screenRecording, screenSharing, fileVault, localNetwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: return "Pełny dostęp do dysku dla sesji zdalnych"
        case .screenRecording: return "Nagrywanie ekranu dla podglądu"
        case .screenSharing: return "Udostępnianie ekranu – czarny obraz"
        case .fileVault: return "FileVault – odblokowanie po restarcie"
        case .localNetwork: return "Na tym Macu: dostęp do sieci lokalnej"
        }
    }

    var icon: String {
        switch self {
        case .fullDiskAccess: return "externaldrive.badge.checkmark"
        case .screenRecording: return "record.circle"
        case .screenSharing: return "rectangle.on.rectangle"
        case .fileVault: return "lock.doc"
        case .localNetwork: return "network"
        }
    }

    var color: Color {
        switch self {
        case .fullDiskAccess: return .gray
        case .screenRecording: return .red
        case .screenSharing: return .indigo
        case .fileVault: return .blue
        case .localNetwork: return .blue
        }
    }

    var summary: String {
        switch self {
        case .fullDiskAccess: return "Pobieranie prac z Biurka i Dokumentów ucznia, czyszczenie folderów, podmiana aplikacji."
        case .screenRecording: return "Bez tego podgląd ekranów pokazuje tylko tapetę."
        case .screenSharing: return "Tylko gdy Udostępnianie ekranu (VNC) pokazuje czarny obraz."
        case .fileVault: return "Z FileVault iMac po restarcie jest niedostępny, dopóki ktoś go nie odblokuje."
        case .localNetwork: return "Jednorazowa zgoda macOS dla CMCR Manager."
        }
    }

    var steps: [String] {
        switch self {
        case .fullDiskAccess:
            return ["Zaloguj się na iMacu na konto administratora (imacNN).",
                    "Otwórz Ustawienia systemowe › Ogólne › Udostępnianie.",
                    "Kliknij ⓘ obok „Zdalne logowanie”.",
                    "Włącz „Daj użytkownikom zdalnym pełny dostęp do dysku” i kliknij OK."]
        case .screenRecording:
            return ["Otwórz Ustawienia systemowe › Prywatność i ochrona › Nagrywanie ekranu i dźwięku systemowego (w macOS 14 i starszych: Nagrywanie ekranu).",
                    "Kliknij „+” pod listą i podaj hasło administratora.",
                    "Naciśnij ⌘⇧G, wpisz /usr/libexec/sshd-keygen-wrapper i kliknij Otwórz.",
                    "Sprawdź, czy przełącznik przy sshd-keygen-wrapper jest włączony."]
        case .screenSharing:
            return ["Otwórz Ustawienia systemowe › Ogólne › Udostępnianie.",
                    "Wyłącz i ponownie włącz „Udostępnianie ekranu”.",
                    "Kliknij ⓘ i sprawdź, czy w „Dopuszczaj” są „Administratorzy”."]
        case .fileVault:
            return ["Po każdym restarcie odblokuj iMaca przy ekranie hasłem konta z dostępem do FileVault – dopiero wtedy działa SSH.",
                    "Jeśli szkoła nie potrzebuje szyfrowania: Ustawienia systemowe › Prywatność i ochrona › FileVault › Wyłącz."]
        case .localNetwork:
            return ["Przy pierwszym połączeniu macOS zapyta, czy CMCR Manager może łączyć się z urządzeniami w sieci lokalnej – kliknij „Zezwól”.",
                    "Jeśli wcześniej odmówiono: Ustawienia systemowe › Prywatność i ochrona › Sieć lokalna › włącz CMCR Manager."]
        }
    }

    var notes: [String] {
        switch self {
        case .fullDiskAccess:
            return ["macOS chroni to ustawienie – nie da się go włączyć zdalnie ani skryptem (tylko przy komputerze lub przez MDM)."]
        case .screenRecording:
            return ["W macOS 26.1–26.2 dodane narzędzie może nie być widoczne na liście – to błąd systemu, uprawnienie działa.",
                    "Od macOS 15 system co jakiś czas pyta zalogowanego użytkownika o zgodę na nagrywanie; wyłączyć to można tylko profilem MDM."]
        case .screenSharing:
            return ["Od macOS 12.1 usługa włączona zdalnie potrafi pokazywać czarny ekran, dopóki ktoś raz jej nie przełączy."]
        case .fileVault:
            return ["Wyłączenie FileVault to decyzja szkoły: szyfrowanie chroni dane w razie kradzieży komputera."]
        case .localNetwork:
            return []
        }
    }

    /// Text worth copying while following the steps.
    var copyText: String? { self == .screenRecording ? "/usr/libexec/sshd-keygen-wrapper" : nil }

    func applies(to r: ReadinessReport) -> Bool {
        switch self {
        case .fullDiskAccess: return r[.fda].state == .manual
        case .screenRecording: return r[.screen].state == .manual
        case .screenSharing: return r[.vnc].state == .ok
        case .fileVault: return r[.filevault].state == .warning
        case .localNetwork: return false
        }
    }
}

// MARK: - Main view

struct ReadinessView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = ReadinessStore.shared
    @ViewState private var sheet: SetupSheetMode?
    @ViewState private var passwordFor: Machine?

    var body: some View {
        ScrollViewReader { proxy in
            page
                .onSnapshotSubpage { if $0 == "readiness+end" { proxy.scrollTo("manualSteps", anchor: .top) } }
        }
    }

    var page: some View {
        Page {
            PageHeader(title: "Gotowość iMaców", icon: "checklist",
                       subtitle: "Co jest już przygotowane na każdym iMacu. Większość ustawień włączysz stąd zdalnie jednym przyciskiem; dwa uprawnienia prywatności macOS trzeba raz włączyć przy komputerze.") {
                TargetSummary()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { primaryActions; secondaryActions; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { primaryActions }
                    HStack(spacing: 8) { secondaryActions }
                }
            }
            if model.machines.isEmpty {
                ContentUnavailableView("Brak komputerów", systemImage: "desktopcomputer",
                                       description: Text("Dodaj iMaki w zakładce Komputery, a potem sprawdź ich gotowość."))
            } else {
                summary
                ReadinessMatrix(store: store,
                                onConfigure: { sheet = .configure([$0]) },
                                onPassword: { passwordFor = $0 })
                legend
            }
            ManualStepsBox(store: store)
                .id("manualSteps")
            LastBatchView(section: .setup)
        }
        .sheet(item: $sheet) { mode in
            SetupOptionsSheet(mode: mode).environmentObject(model)
        }
        .sheet(item: $passwordFor) { m in
            HostPasswordSheet(machine: m).environmentObject(model)
        }
        .task {
            if store.reports.isEmpty && store.checking.isEmpty && !model.machines.isEmpty {
                store.check(model.machines, model: model)
            }
        }
        .onSnapshotSubpage { sub in
            switch sub {
            case "readiness+configure": sheet = .configure(model.selectedMachines)
            case "readiness+save": sheet = .save
            default: sheet = nil
            }
        }
    }

    @ViewBuilder var primaryActions: some View {
        Button {
            store.check(model.machines, model: model)
        } label: {
            Label("Sprawdź wszystkie", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .help("Sprawdza wszystkie iMaki – niczego nie zmienia i nie pokazuje uczniom żadnych okien (⌥⌘R)")
        .disabled(model.machines.isEmpty || !store.checking.isEmpty)
        // Counted like the target header: Macs skipped as unreachable are not configured.
        let targets = model.actionTargets.count
        Button {
            sheet = .configure(model.selectedMachines)
        } label: {
            Label(targets == 0 ? "Skonfiguruj zaznaczone…" : "Skonfiguruj zaznaczone (\(targets))…",
                  systemImage: "wrench.and.screwdriver")
        }
        .buttonStyle(.borderedProminent)
        .disabled(targets == 0)
        .help(targets == 0 ? "Najpierw zaznacz włączone komputery na liście."
              : "Włącza wybrane ustawienia \(Polish.onComputers(targets)) jednorazowym skryptem uruchamianym z uprawnieniami administratora – najpierw pokaże listę opcji.")
    }

    @ViewBuilder var secondaryActions: some View {
        Button {
            sheet = .save
        } label: {
            Label("Zapisz skrypt do pliku…", systemImage: "square.and.arrow.down")
        }
        .help("Zapisuje skrypt do uruchomienia przy iMacu (np. z pendrive’a) – gdy połączenie zdalne jeszcze nie działa.")
        Menu {
            Section("Na zaznaczonych komputerach") {
                Button("Zainstaluj klucz logowania", systemImage: "key.horizontal") {
                    model.applyReadinessFix(.key, on: model.selectedMachines)
                }
                .disabled(model.managerPublicKey == nil || model.actionTargets.isEmpty)
                Button("Utwórz folder ucznia", systemImage: "folder.badge.plus") {
                    model.applyReadinessFix(.folder, on: model.selectedMachines)
                }
                .disabled(model.actionTargets.isEmpty)
                Button("Włącz budzenie przez sieć (Wake-on-LAN)", systemImage: "dot.radiowaves.left.and.right") {
                    model.applyReadinessFix(.wol, on: model.selectedMachines)
                }
                .disabled(model.actionTargets.isEmpty)
                Button("Włącz Udostępnianie ekranu", systemImage: "rectangle.on.rectangle") {
                    model.applyReadinessFix(.vnc, on: model.selectedMachines)
                }
                .disabled(model.actionTargets.isEmpty)
            }
            Section("Klucze komputerów (pierwsze połączenie, reinstalacja)") {
                Button("Sprawdź klucz komputera…", systemImage: "lock.shield") {
                    model.reviewHostKeys(model.selectedMachines)
                }
                .help("Pokazuje odcisk klucza SSH zaznaczonych iMaców do potwierdzenia – przy pierwszym połączeniu albo po reinstalacji lub wymianie iMaca.")
            }
        } label: {
            Label("Szybkie naprawy", systemImage: "bandage")
        }
        .fixedSize()
        .disabled(model.selection.isEmpty)
        .help("Pojedyncze poprawki na zaznaczonych iMacach bez uruchamiania całego skryptu.")
    }

    @ViewBuilder var checkStatus: some View {
        if !store.checking.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sprawdzanie (\(store.checking.count))…").foregroundStyle(.secondary)
            }
        } else if let date = store.lastCheck {
            Text("Sprawdzono o \(date.formatted(date: .omitted, time: .shortened)). Kliknij liczbę, aby zaznaczyć te komputery.")
                .foregroundStyle(.secondary)
        }
    }

    var summary: some View {
        let pairs = model.machines.compactMap { m in store.reports[m.id].map { (m, $0) } }
        let ready = pairs.filter { $0.1.isReady }.map(\.0)
        let offline = pairs.filter { $0.1.values.isEmpty }.map(\.0)
        let configure = pairs.filter { !$0.1.values.isEmpty && !$0.1.fixableBySetup.isEmpty }.map(\.0)
        let visit = pairs.filter { !$0.1.needsVisit.isEmpty }.map(\.0)
        let chips = [
            ReadinessChip(title: "Gotowe", value: "\(ready.count) z \(model.machines.count)",
                          icon: "checkmark.seal.fill", color: .green, machines: ready),
            ReadinessChip(title: "Do skonfigurowania", value: "\(configure.count)",
                          icon: "wrench.and.screwdriver.fill", color: configure.isEmpty ? .secondary : .orange, machines: configure),
            ReadinessChip(title: "Wizyta przy komputerze", value: "\(visit.count)",
                          icon: "hand.raised.fill", color: visit.isEmpty ? .secondary : .blue, machines: visit),
            ReadinessChip(title: "Bez połączenia", value: "\(offline.count)",
                          icon: "wifi.slash", color: offline.isEmpty ? .secondary : .red, machines: offline),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            // One row only when every chip fits whole at the same width; otherwise two rows of two.
            ViewThatFits(in: .horizontal) {
                EqualWidthRow(spacing: 8) { ForEach(chips.indices, id: \.self) { chips[$0] } }
                VStack(spacing: 8) {
                    EqualWidthRow(spacing: 8) { chips[0]; chips[1] }
                    EqualWidthRow(spacing: 8) { chips[2]; chips[3] }
                }
            }
            checkStatus.font(.caption)
        }
    }

    var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach([ReadinessState.ok, .warning, .problem, .manual, .off, .unknown], id: \.self) { s in
                Label {
                    Text(s.legend)
                } icon: {
                    Image(systemName: s.icon).foregroundStyle(s.color)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Row of equally wide views: its ideal width is the widest ideal width times the count (so `ViewThatFits`
/// only picks it when nothing would be cut off), and it stretches evenly to the space it gets.
struct EqualWidthRow: Layout {
    var spacing: CGFloat = 8

    private func widest(_ subviews: Subviews) -> CGSize {
        subviews.reduce(.zero) { size, view in
            let s = view.sizeThatFits(.unspecified)
            return CGSize(width: max(size.width, s.width), height: max(size.height, s.height))
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(subviews.count - 1, 0)) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cell = widest(subviews)
        let ideal = cell.width * CGFloat(subviews.count) + gaps(subviews)
        guard let width = proposal.width, width.isFinite else { return CGSize(width: ideal, height: cell.height) }
        return CGSize(width: max(width, ideal), height: cell.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = (bounds.width - gaps(subviews)) / CGFloat(subviews.count)
        var x = bounds.minX
        for view in subviews {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// Count of Macs in one state; clicking selects them in the machine list.
struct ReadinessChip: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let value: String
    let icon: String
    let color: Color
    let machines: [Machine]

    var body: some View {
        Button {
            model.selection = Set(machines.map(\.id))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(title)
                    .fixedSize()
                Spacer(minLength: 4)
                Text(value)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .readinessChipBackground()
        }
        .buttonStyle(.plain)
        // Not disabled when empty: a dimmed count would be hard to read; the click then just does nothing.
        .help(machines.isEmpty ? "\(title): brak komputerów" : "Kliknij, aby zaznaczyć: \(machines.map(\.name).joined(separator: ", "))")
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Matrix

private struct CellRef: Hashable {
    let machine: UUID
    let check: ReadinessCheck
}

struct ReadinessMatrix: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: ReadinessStore
    var onConfigure: (Machine) -> Void
    var onPassword: (Machine) -> Void
    @ViewState private var popover: CellRef?

    var body: some View {
        GroupBox {
            // Full headers when they fit; in a narrow window icon headers with a key below, scrolling only as a last resort.
            ViewThatFits(in: .horizontal) {
                grid(compact: false)
                    .padding(8)
                compactLayout
                ScrollView(.horizontal) { compactLayout }
                    .scrollIndicators(.visible, axes: .horizontal)
            }
        }
    }

    var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            grid(compact: true)
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(ReadinessCheck.allCases) { c in
                    Label(c.displayTitle, systemImage: c.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(c.tooltip)
                }
            }
        }
        .padding(8)
    }

    func grid(compact: Bool) -> some View {
        Grid(alignment: .center, horizontalSpacing: compact ? 8 : 10, verticalSpacing: 6) {
            GridRow {
                Text("Komputer")
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.leading)
                ForEach(ReadinessCheck.allCases) { c in
                    VStack(spacing: 3) {
                        Image(systemName: c.icon).foregroundStyle(.secondary)
                        if !compact {
                            Text(c.header)
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .fixedSize()
                        }
                    }
                    .help("\(c.displayTitle): \(c.tooltip)")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(c.displayTitle)
                }
            }
            Divider()
            ForEach(model.machines) { m in
                GridRow {
                    nameCell(m)
                    ForEach(ReadinessCheck.allCases) { c in cell(m, c, compact: compact) }
                }
                Divider()
            }
        }
    }

    func nameCell(_ m: Machine) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { model.selection.contains(m.id) },
                set: { if $0 { model.selection.insert(m.id) } else { model.selection.remove(m.id) } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.name).fontWeight(.medium)
                    Text(subtitle(m))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .toggleStyle(.checkbox)
            .help("Zaznacz \(m.name) – akcje „Skonfiguruj zaznaczone” i „Szybkie naprawy” działają na zaznaczonych iMacach.")
            if store.checking.contains(m.id) {
                ProgressView().controlSize(.mini)
            }
        }
        .gridColumnAlignment(.leading)
    }

    func subtitle(_ m: Machine) -> String {
        guard let r = store.reports[m.id] else { return store.checking.contains(m.id) ? "sprawdzanie…" : "nie sprawdzono" }
        if r.values.isEmpty { return "brak połączenia" }
        if let user = r.consoleUser { return "zalogowany: \(user)" }
        return "nikt nie jest zalogowany"
    }

    @ViewBuilder func cell(_ m: Machine, _ c: ReadinessCheck, compact: Bool) -> some View {
        if let r = store.reports[m.id] {
            let item = r[c]
            let ref = CellRef(machine: m.id, check: c)
            Button {
                popover = ref
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: item.state.icon)
                        .font(.title3)
                        .foregroundStyle(item.state.color)
                    if !compact {
                        Text(item.short)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .frame(minWidth: compact ? 26 : 44)
                .contentShape(Rectangle())
                .opacity(store.checking.contains(m.id) ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .help("\(c.displayTitle): \(item.short). \(item.detail) Kliknij, aby zobaczyć szczegóły i naprawę.")
            .accessibilityLabel("\(m.name), \(c.displayTitle): \(item.short)")
            .popover(isPresented: Binding(get: { popover == ref }, set: { if !$0 { popover = nil } }),
                     arrowEdge: .bottom) {
                ReadinessCellDetail(machine: m, check: c, item: item, connectionFailure: r.connectionFailure,
                                    onConfigure: { popover = nil; onConfigure(m) },
                                    onPassword: { popover = nil; onPassword(m) },
                                    onDone: { popover = nil })
            }
        } else {
            Image(systemName: store.checking.contains(m.id) ? "ellipsis" : "minus")
                .foregroundStyle(.tertiary)
                .frame(minWidth: compact ? 26 : 44)
                .help(store.checking.contains(m.id) ? "Sprawdzanie…" : "Nie sprawdzono")
        }
    }
}

/// Popover for one cell: what was found, why it matters and how to fix it.
struct ReadinessCellDetail: View {
    @EnvironmentObject var model: AppModel
    let machine: Machine
    let check: ReadinessCheck
    let item: ReadinessItem
    var connectionFailure: ReadinessReport.ConnectionFailure?
    var onConfigure: () -> Void
    var onPassword: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(check.displayTitle) – \(machine.name)", systemImage: check.icon)
                .font(.headline)
            Label(item.short, systemImage: item.state.icon)
                .foregroundStyle(item.state.color)
            Text(item.detail)
                .fixedSize(horizontal: false, vertical: true)
            Text(check.tooltip)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let step = manualStep, item.state == .manual {
                Divider()
                ManualStepGuideContent(step: step)
            }
            HStack {
                Button {
                    ReadinessStore.shared.check([machine], model: model)
                    onDone()
                } label: {
                    Label("Sprawdź ponownie", systemImage: "arrow.clockwise")
                }
                Spacer()
                fixButton
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    var manualStep: ManualStep? {
        switch check {
        case .fda: return .fullDiskAccess
        case .screen: return .screenRecording
        default: return nil
        }
    }

    @ViewBuilder var fixButton: some View {
        switch (check, item.state) {
        case (_, .ok):
            EmptyView()
        case (.ssh, .warning):
            fix("Zainstaluj klucz logowania", "key.horizontal", .key)
        case (.ssh, .problem) where connectionFailure == .hostKeyChanged || connectionFailure == .hostKeyUnknown:
            // Trusting a key is offered only when ssh refused it; the sheet shows its fingerprint first.
            Button {
                model.reviewHostKeys([machine])
                onDone()
            } label: {
                Label("Sprawdź klucz komputera…", systemImage: "lock.shield")
            }
            .help(connectionFailure == .hostKeyChanged
                  ? "Tylko jeśli ten iMac był reinstalowany lub wymieniony – inaczej zmieniony klucz może oznaczać, że w sieci podszywa się pod niego inne urządzenie."
                  : "Pierwsze połączenie z tym iMakiem: pokaże odcisk jego klucza SSH do potwierdzenia.")
        case (.ssh, .problem) where connectionFailure == .authFailed:
            Button(action: onPassword) {
                Label("Hasło tego komputera…", systemImage: "key.fill")
            }
            .help("Odmowa dostępu: zapisz hasło administratora tego iMaca albo roześlij klucz logowania (Dostęp i hasła).")
        case (.sudo, .problem), (.sudo, .unknown):
            Button(action: onPassword) {
                Label("Hasło tego komputera…", systemImage: "key.fill")
            }
        case (.folder, .problem), (.folder, .warning):
            fix("Utwórz folder ucznia", "folder.badge.plus", .folder)
        case (.wol, .problem):
            fix("Włącz budzenie przez sieć", "dot.radiowaves.left.and.right", .wol)
        case (.vnc, .off):
            fix("Włącz Udostępnianie ekranu", "rectangle.on.rectangle", .vnc)
        case (.setup, _):
            Button(action: onConfigure) {
                Label("Skonfiguruj ten iMac…", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }

    func fix(_ title: String, _ icon: String, _ fix: ReadinessFix) -> some View {
        Button {
            model.applyReadinessFix(fix, on: [machine])
            onDone()
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Manual steps

struct ManualStepsBox: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: ReadinessStore

    var body: some View {
        SectionBox(title: "Do zrobienia przy komputerze (jednorazowo)", icon: "hand.raised") {
            Text("macOS chroni te ustawienia – nie da się ich włączyć zdalnie ani skryptem. Wykonaj je raz przy każdym iMacu, którego dotyczą.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ManualStep.allCases) { step in
                ManualStepRow(step: step, status: status(step))
                if step != ManualStep.allCases.last { Divider() }
            }
            Label {
                Text("Przy komputerze możesz też uruchomić zapisany skrypt poleceniem „\(SetupScript.localCommand) --guided” – sam otworzy właściwe panele Ustawień i poczeka, aż skończysz.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    func status(_ step: ManualStep) -> (text: String, attention: Bool) {
        if step == .localNetwork { return ("Dotyczy tego Maca (nie iMaców).", false) }
        let checked = model.machines.compactMap { m in store.reports[m.id].flatMap { $0.values.isEmpty ? nil : (m, $0) } }
        if checked.isEmpty { return ("Sprawdź gotowość, aby zobaczyć, których iMaców to dotyczy.", false) }
        let names = checked.filter { step.applies(to: $0.1) }.map(\.0.name)
        switch step {
        case .screenSharing:
            return names.isEmpty ? ("Udostępnianie ekranu nie jest włączone na sprawdzonych iMacach.", false)
                                 : ("Włączone na: \(names.joined(separator: ", ")).", false)
        case .fileVault:
            return names.isEmpty ? ("FileVault wyłączony na wszystkich sprawdzonych iMacach.", false)
                                 : ("FileVault włączony na: \(names.joined(separator: ", ")).", true)
        default:
            return names.isEmpty ? ("Gotowe na wszystkich sprawdzonych iMacach.", false)
                                 : ("Do zrobienia na: \(names.joined(separator: ", ")).", true)
        }
    }
}

struct ManualStepRow: View {
    let step: ManualStep
    let status: (text: String, attention: Bool)
    @ViewState private var showGuide = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsIcon(symbol: step.icon, color: step.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).fontWeight(.medium)
                Text(step.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(status.text, systemImage: status.attention ? "exclamationmark.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(status.attention ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                showGuide = true
            } label: {
                Label("Otwórz instrukcję", systemImage: "book")
            }
            .fixedSize()
            .popover(isPresented: $showGuide, arrowEdge: .leading) {
                ManualStepGuideContent(step: step)
                    .padding(16)
                    .frame(width: 440)
            }
        }
    }
}

struct ManualStepGuideContent: View {
    let step: ManualStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(step.title, systemImage: step.icon).font(.headline)
            ForEach(Array(step.steps.enumerated()), id: \.offset) { i, text in
                NumberedStep(n: i + 1, text: text)
            }
            if let copy = step.copyText {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                } label: {
                    Label("Kopiuj ścieżkę \(copy)", systemImage: "doc.on.doc")
                }
                .help("Przydaje się, gdy instrukcję czytasz na tym samym Macu, który konfigurujesz.")
            }
            ForEach(step.notes, id: \.self) { note in
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
