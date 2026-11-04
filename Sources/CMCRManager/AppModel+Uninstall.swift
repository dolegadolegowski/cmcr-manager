import CMCRCore
import Foundation

extension AppModel {
    /// Reading the list runs mdls/du on every app and pkgutil on every receipt: longer than other lists.
    static let inventoryTimeout: TimeInterval = 120

    /// Removes the apps (`Scripts.uninstallApps`) on `targets` as one job per Mac in Zadania. The job's log is the
    /// report in Polish – what was removed, left in place, refused or failed – and its last line the summary.
    @discardableResult
    func uninstall(_ apps: [InstalledApp], on targets: [Machine], packageFiles: Bool) -> Batch? {
        let paths = Self.uninstallPaths(apps)
        guard !paths.isEmpty else { return nil }
        let student = settings.studentUser
        return runBatch("Odinstaluj: \(Self.uninstallTitle(apps))", on: targets, section: .apps) { m, job in
            let script = Scripts.uninstallApps(paths, studentUser: student, packageFiles: packageFiles)
            let renderer = UninstallReport.StreamRenderer()
            let sink = OutputSink(job).callback
            let r = await SSH.run(script, on: m, password: self.password(for: m), settings: self.sshSettings,
                                  handle: job.handle, retry: .job, maxCapture: Self.jobCapture,
                                  onOutput: renderer.wrap(sink))
            for channel in [OutputChannel.stdout, .stderr] {
                let rest = renderer.finish(channel)
                if !rest.isEmpty { sink(channel, rest) }
            }
            self.refreshInstalledApps([m])
            return r
        }
    }

    /// The paths given to the script, each once (an app selected on several Macs is one row already).
    static func uninstallPaths(_ apps: [InstalledApp]) -> [String] {
        var seen = Set<String>()
        return apps.filter(\.isRemovable).map(\.path).filter { seen.insert($0).inserted }
    }

    static func uninstallTitle(_ apps: [InstalledApp]) -> String {
        let names = apps.map(\.name)
        return names.count <= 3 ? names.joined(separator: ", ") : names.prefix(2).joined(separator: ", ") + " i \(names.count - 2) innych"
    }
}

/// The dry run shown before uninstalling („Odinstaluj…”): what each selected Mac would remove, keep or refuse.
/// Nothing changes on the Macs until the teacher confirms; then `AppModel.uninstall` runs on the Macs that have
/// something to remove.
@MainActor
final class UninstallPreview: ObservableObject, Identifiable {
    enum Outcome {
        case report(UninstallReport)
        case error(String)
    }

    let id = UUID()
    let apps: [InstalledApp]
    let targets: [Machine]
    @Published var packageFiles: Bool {
        didSet { if packageFiles != oldValue { load() } }
    }
    @Published private(set) var results: [UUID: Outcome] = [:]
    @Published private(set) var loading: Set<UUID> = []
    private weak var model: AppModel?
    private var generation = 0

    init(apps: [InstalledApp], targets: [Machine], packageFiles: Bool = false, model: AppModel) {
        self.apps = apps
        self.targets = targets
        self.packageFiles = packageFiles
        self.model = model
    }

    var title: String { AppModel.uninstallTitle(apps) }
    var isLoading: Bool { !loading.isEmpty }

    /// Macs whose dry run found something to remove.
    var readyTargets: [Machine] {
        targets.filter { if case .report(let r) = results[$0.id] { return r.hasWork }; return false }
    }

    var plannedKB: Int64 {
        targets.reduce(0) { sum, m in
            if case .report(let r) = results[m.id] { return sum + (r.summary?.plannedKB ?? 0) }
            return sum
        }
    }

    /// Runs the dry run on every target again (also when „Usuń także pliki pakietu” changes).
    func load() {
        guard let model else { return }
        generation += 1
        let gen = generation
        let paths = AppModel.uninstallPaths(apps)
        let script = Scripts.uninstallApps(paths, studentUser: model.settings.studentUser, dryRun: true,
                                           packageFiles: packageFiles)
        let ss = model.sshSettings
        let jobs = targets.map { ($0, model.password(for: $0)) }
        results = [:]
        loading = Set(targets.map(\.id))
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (m, pw) in jobs {
                    group.addTask {
                        let r = await SSH.run(script, on: m, password: pw, settings: ss, timeout: AppModel.inventoryTimeout)
                        await MainActor.run {
                            guard gen == self.generation else { return }
                            self.loading.remove(m.id)
                            let report = UninstallReport.parse(r.stdoutText)
                            // A refusal (exit 2) or a failure still has a report to show; only a run without one
                            // (no connection, wrong password) is an error.
                            if report.summary != nil {
                                self.results[m.id] = .report(report)
                            } else {
                                self.results[m.id] = .error(SSH.diagnose(r).1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Runs the real uninstall on the Macs whose dry run had something to remove.
    @discardableResult
    func confirm() -> Batch? {
        guard let model, !readyTargets.isEmpty else { return nil }
        return model.uninstall(apps, on: readyTargets, packageFiles: packageFiles)
    }
}
