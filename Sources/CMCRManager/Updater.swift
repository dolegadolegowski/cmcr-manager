import AppKit
import CMCRCore
import SwiftUI

/// Checks GitHub Releases for a newer signed build, downloads and verifies it, and hands the swap to the
/// installer helper. Preferences and state live in UserDefaults (per installation, not exported with config).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(received: Int64, expected: Int64)
        case verifying
        case ready
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing: return true
            default: return false
            }
        }
    }

    struct Outcome: Identifiable {
        let id = UUID()
        let success: Bool
        let title: String
        let message: String
    }

    static let checkInterval: TimeInterval = 24 * 3600

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidate: UpdateCandidate?
    @Published private(set) var lastCheck: Date?
    /// A check is running. While a verified or announced update waits (.ready/.available) the phase stays as it
    /// is, so the banner and the installation at quit are not interrupted by the daily re-check.
    @Published private(set) var isChecking = false
    /// The verified update is installed when the app quits (set by "Instaluj automatycznie").
    @Published private(set) var installOnQuit = false
    @Published var isSheetPresented = false
    @Published var outcome: Outcome?

    @Published var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: Keys.automaticChecks) }
    }
    @Published var automaticDownloads: Bool {
        didSet { defaults.set(automaticDownloads, forKey: Keys.automaticDownloads) }
    }
    @Published var automaticInstall: Bool {
        didSet {
            defaults.set(automaticInstall, forKey: Keys.automaticInstall)
            updateInstallOnQuit()
        }
    }
    @Published var includePrereleases: Bool {
        didSet { defaults.set(includePrereleases, forKey: Keys.prereleases) }
    }

    let currentVersion = SemanticVersion.running
    let location = InstallLocation.of(Bundle.main.bundleURL)
    let configuration = UpdateConfiguration.standard

    private let defaults: UserDefaults
    private lazy var feed = UpdateFeed(configuration: configuration, userAgent: userAgent)
    private var preparedArchive: URL?
    private var installWhenReady = false
    /// The app is quitting because "Zainstaluj i uruchom ponownie" started the installer. Running jobs were
    /// confirmed in the update sheet already, so the app delegate quits without asking a second time (a modal
    /// question would also outlast the installer, which waits only 60 s for the app to quit).
    private(set) var isQuittingForUpdate = false
    /// The user agreed in the update sheet that running jobs may be interrupted.
    private(set) var jobsConfirmed = false
    /// The installer started as this user; stopped again when quitting is cancelled after all.
    private var helperProcess: Process?
    /// A root installer (folder that needs an administrator) cannot be stopped: until it gave up waiting for this
    /// process, a second installation must not start next to it.
    private var privilegedHelperBusyUntil: Date?
    private var work: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var checkGeneration = 0
    private var phaseBeforeCheck: Phase = .idle
    private var downloadTask: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?

    private enum Keys {
        static let automaticChecks = "update.automaticChecks"
        static let automaticDownloads = "update.automaticDownloads"
        static let automaticInstall = "update.automaticInstall"
        static let prereleases = "update.includePrereleases"
        static let lastCheck = "update.lastCheck"
        static let skipped = "update.skippedVersion"
        static let snoozedUntil = "update.snoozedUntil"
        static let cache = "update.apiCache"
        static let pendingVersion = "update.pendingVersion"
        static let pendingFrom = "update.pendingFrom"
    }

    /// `defaults`: tests pass their own suite; the app uses the standard one.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.automaticChecks: true, Keys.automaticDownloads: true, Keys.automaticInstall: false])
        automaticChecks = defaults.bool(forKey: Keys.automaticChecks)
        automaticDownloads = defaults.bool(forKey: Keys.automaticDownloads)
        automaticInstall = defaults.bool(forKey: Keys.automaticInstall)
        includePrereleases = defaults.bool(forKey: Keys.prereleases)
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    var userAgent: String { "CMCR-Manager/\(currentVersion?.description ?? "dev") (macOS)" }
    var currentVersionText: String { currentVersion?.description ?? "wersja deweloperska" }
    var isConfigured: Bool { configuration.isConfigured }

    var canInstall: Bool {
        if case .unsupported = location { return false }
        return true
    }

    var notInstallableReason: String? {
        if case .unsupported(let why) = location { return why }
        return nil
    }

    var needsAdminPassword: Bool {
        if case .requiresAdmin = location { return true }
        return false
    }

    /// "Instaluj automatycznie" works only where no administrator password is needed (no dialogs while quitting).
    var canInstallOnQuit: Bool {
        if case .writable = location { return true }
        return false
    }

    /// The sidebar banner is shown for a pending update unless the user skipped or snoozed it.
    var showsBanner: Bool {
        guard let candidate, !isSheetPresented else { return false }
        if defaults.string(forKey: Keys.skipped) == candidate.manifest.version { return false }
        if let until = defaults.object(forKey: Keys.snoozedUntil) as? Date, until > Date() { return false }
        switch phase {
        case .available, .downloading, .verifying, .ready, .installing: return true
        default: return false
        }
    }

    // MARK: - Lifecycle

    /// First half of the start confirmation for an update helper that may be waiting (an update started from the
    /// app or from `cmcrctl app-update install --relaunch`). Called at the very top of the App's init, before the
    /// model reads the Keychain, which after an update can keep the main thread in a macOS dialog.
    nonisolated static func confirmStart() {
        guard let version = SemanticVersion.running?.description else { return }
        UpdateInstaller.confirmLaunch(version: version, finished: false)
    }

    /// Called from applicationDidFinishLaunching: completes the start confirmation (see `confirmStart`).
    func applicationDidLaunch() {
        if let version = currentVersion?.description {
            UpdateInstaller.confirmLaunch(version: version, finished: true)
        }
        if let pending = defaults.string(forKey: Keys.pendingVersion) {
            let from = defaults.string(forKey: Keys.pendingFrom) ?? "?"
            defaults.removeObject(forKey: Keys.pendingVersion)
            defaults.removeObject(forKey: Keys.pendingFrom)
            if pending == currentVersion?.description {
                ConfigStore.log("Uaktualnienie aplikacji: \(from) → \(pending) – uruchomiono nową wersję")
                outcome = Outcome(success: true, title: "Zaktualizowano do wersji \(pending)",
                                  message: "CMCR Manager działa w nowej wersji (poprzednia: \(from)).")
            } else {
                let status = (try? String(contentsOf: UpdateInstaller.statusFile, encoding: .utf8))?
                    .precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reason = status.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
                ConfigStore.log("Uaktualnienie aplikacji do \(pending) nie powiodło się: \(status)")
                outcome = Outcome(success: false, title: "Nie udało się zainstalować wersji \(pending)",
                                  message: (reason.map { "Powód: \($0).\n" } ?? "")
                                      + "Działa poprzednia wersja \(currentVersionText). Szczegóły są w dzienniku uaktualnień.")
            }
            try? FileManager.default.removeItem(at: UpdateInstaller.statusFile)
        }
        removeLeftovers()
        startScheduler()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMCR_UPDATE_CHECK_ON_LAUNCH"] == "1" { checkNow() }
        #endif
    }

    /// Called from applicationWillTerminate: installs a verified update when "Instaluj automatycznie" is on.
    func applicationWillTerminate() {
        guard installOnQuit, phase == .ready, canInstallOnQuit else { return }
        do {
            try launchHelper(relaunch: false)
        } catch {
            ConfigStore.log("Uaktualnienie aplikacji: instalacja przy zamknięciu nie powiodła się – \(error.localizedDescription)")
        }
    }

    /// Checks shortly after launch, then once a day while the app stays open.
    private func startScheduler() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)   // let the first status refresh go first
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticChecks, self.isConfigured, self.currentVersion != nil, !self.isChecking, first || self.isDue {
                    await self.startCheck(userInitiated: false).value
                }
                first = false
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    private var isDue: Bool {
        guard let lastCheck else { return true }
        return Date().timeIntervalSince(lastCheck) >= Self.checkInterval
    }

    // MARK: - Actions

    /// "Sprawdź uaktualnienia…" (app menu, settings).
    func checkNow() {
        isSheetPresented = true
        guard !isTransferring else { return }
        startCheck(userInitiated: true)
    }

    /// Every check runs as `checkTask`, so a new one (e.g. from the menu) cancels the scheduled one.
    @discardableResult
    private func startCheck(userInitiated: Bool) -> Task<Void, Never> {
        checkTask?.cancel()
        let task = Task { await check(userInitiated: userInitiated) }
        checkTask = task
        return task
    }

    /// Downloading, verifying or installing: a check must not change the candidate under it.
    private var isTransferring: Bool {
        switch phase {
        case .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    private func check(userInitiated: Bool) async {
        guard !isTransferring else { return }
        checkGeneration += 1
        let generation = checkGeneration
        isChecking = true
        defer { if generation == checkGeneration { isChecking = false } }
        switch phase {
        case .ready, .available, .checking: break
        default:
            phaseBeforeCheck = phase
            phase = .checking
        }
        let cache = defaults.data(forKey: Keys.cache).flatMap { try? JSONDecoder().decode(UpdateFeed.Cache.self, from: $0) }
        do {
            let (result, newCache) = try await feed.check(current: currentVersion, includePrereleases: includePrereleases, cache: cache)
            // A newer check replaced this one, or a download started meanwhile (the user clicked "Zainstaluj").
            guard generation == checkGeneration, !isTransferring else { return }
            if let newCache, let data = try? JSONEncoder().encode(newCache) { defaults.set(data, forKey: Keys.cache) }
            lastCheck = Date()
            defaults.set(lastCheck, forKey: Keys.lastCheck)
            switch result {
            case .upToDate:
                candidate = nil
                preparedArchive = nil
                phase = .upToDate
            case .available(let c):
                if candidate?.manifest != c.manifest { preparedArchive = nil }
                candidate = c
                if preparedArchive != nil {
                    phase = .ready
                } else {
                    phase = .available
                    ConfigStore.log("Uaktualnienie aplikacji: dostępna wersja \(c.manifest.version) (podpis zweryfikowany)")
                    let skipped = defaults.string(forKey: Keys.skipped) == c.manifest.version
                    if automaticDownloads, canInstall, !skipped || userInitiated { startDownload() }
                }
            }
            updateInstallOnQuit()
        } catch {
            guard generation == checkGeneration else { return }
            if (error as? UpdateError) == .cancelled {
                if phase == .checking { phase = phaseBeforeCheck }
                return
            }
            ConfigStore.log("Uaktualnienie aplikacji: sprawdzanie nie powiodło się – \(error.localizedDescription)")
            // Background checks fail quietly; a waiting update (.ready/.available) stays offered. The sheet shows
            // the reason only when the user asked and there is nothing else to show.
            if phase == .checking { phase = userInitiated ? .failed(error.localizedDescription) : phaseBeforeCheck }
        }
    }

    /// Downloads the archive, verifies size and SHA-256 against the signed manifest, extracts it and checks
    /// the bundle's identity and code signature before offering "Zainstaluj i uruchom ponownie".
    func download() async {
        guard let c = candidate else { return }
        phase = .downloading(received: 0, expected: c.manifest.size)
        do {
            let folder = try stagingFolder(for: c.manifest.version)
            let zip = folder.appendingPathComponent(c.manifest.file)
            if (try? UpdateVerifier.verifyArchive(zip, manifest: c.manifest)) == nil {
                _ = try await FileDownloader.download(c.archiveURL, to: zip, maxBytes: c.manifest.size, userAgent: userAgent) { got, total in
                    Task { @MainActor in
                        let updater = Updater.shared
                        if case .downloading = updater.phase {
                            updater.phase = .downloading(received: got, expected: total > 0 ? total : c.manifest.size)
                        }
                    }
                }
            }
            phase = .verifying
            try await Task.detached(priority: .userInitiated) {
                try await UpdateVerifier.verifyDownload(zip, manifest: c.manifest, workDirectory: folder)
            }.value
            preparedArchive = zip
            phase = .ready
            ConfigStore.log("Uaktualnienie aplikacji: pobrano i zweryfikowano \(c.manifest.version) (Ed25519, SHA-256, podpis kodu)")
            updateInstallOnQuit()
            if installWhenReady {
                installWhenReady = false
                installAndRelaunch()
            }
        } catch UpdateError.cancelled {
            installWhenReady = false
            jobsConfirmed = false
            phase = .available
        } catch {
            installWhenReady = false
            jobsConfirmed = false
            preparedArchive = nil
            ConfigStore.log("Uaktualnienie aplikacji: odrzucono \(c.manifest.version) – \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Primary action of the sheet: downloads first when needed, then installs and relaunches.
    /// `jobsConfirmed`: the user answered "Przerwać trwające zadania?" in the sheet.
    func install(jobsConfirmed: Bool = false) {
        if jobsConfirmed { self.jobsConfirmed = true }
        switch phase {
        case .ready:
            installAndRelaunch()
        case .available, .failed:
            installWhenReady = true
            startDownload()
        default:
            break
        }
    }

    private func startDownload() {
        downloadTask?.cancel()
        downloadTask = Task { await download() }
    }

    func cancelDownload() {
        installWhenReady = false
        jobsConfirmed = false
        downloadTask?.cancel()
    }

    /// Jobs (or a lesson countdown) are running and the user has not agreed in the sheet to interrupt them.
    var needsJobsConfirmation: Bool { (AppModel.shared?.hasRunningWork ?? false) && !jobsConfirmed }

    /// "Zainstaluj i uruchom ponownie". Asks about running work in the sheet first – also when jobs started while
    /// the update was downloading – and never after the installer is running.
    func installAndRelaunch() {
        guard phase == .ready else { return }
        if needsJobsConfirmation {
            ConfigStore.log("Uaktualnienie aplikacji: instalacja czeka – trwają zadania na iMacach")
            isSheetPresented = true
            return
        }
        if let until = privilegedHelperBusyUntil, until > Date() {
            phase = .failed("Poprzednia próba instalacji jeszcze się nie zakończyła – spróbuj ponownie za minutę.")
            return
        }
        work = Task {
            phase = .installing
            do {
                switch location {
                case .writable:
                    try launchHelper(relaunch: true)
                case .requiresAdmin:
                    guard let request = installRequest(relaunch: true) else { throw UpdateError.notInstallable("Brak pobranego uaktualnienia.") }
                    try await UpdateInstaller.launchPrivileged(
                        request, prompt: "CMCR Manager chce zainstalować uaktualnienie do wersji \(request.version).")
                    markPending(request.version)
                case .unsupported(let why):
                    throw UpdateError.notInstallable(why)
                }
                isQuittingForUpdate = true
                NSApp.terminate(nil)             // the helper waits for this process to exit
                // Reached only when quitting was cancelled after all.
                quitForUpdateCancelled()
            } catch UpdateError.cancelled {
                jobsConfirmed = false
                phase = .ready
            } catch {
                jobsConfirmed = false
                ConfigStore.log("Uaktualnienie aplikacji: instalacja nie powiodła się – \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The app did not quit after the installer had started: stop that installer when possible and forget the
    /// pending version, so the next start does not report a failed update, and offer the installation again.
    func quitForUpdateCancelled() {
        isQuittingForUpdate = false
        jobsConfirmed = false
        defaults.removeObject(forKey: Keys.pendingVersion)
        defaults.removeObject(forKey: Keys.pendingFrom)
        if let helper = helperProcess {
            helperProcess = nil
            if helper.isRunning { helper.terminate() }
            ConfigStore.log("Uaktualnienie aplikacji: zamknięcie anulowane – instalacja nie została rozpoczęta")
            phase = .ready
        } else {
            // The root installer gives up by itself once it has waited 60 s for this process.
            privilegedHelperBusyUntil = Date().addingTimeInterval(75)
            ConfigStore.log("Uaktualnienie aplikacji: zamknięcie anulowane – instalator administratora zakończy się sam")
            phase = .failed("Aplikacja nie została zamknięta, więc uaktualnienia nie zainstalowano. Spróbuj ponownie za minutę.")
        }
        updateInstallOnQuit()
    }

    func skipThisVersion() {
        if let v = candidate?.manifest.version {
            defaults.set(v, forKey: Keys.skipped)
            ConfigStore.log("Uaktualnienie aplikacji: pominięto wersję \(v)")
        }
        cancelDownload()
        isSheetPresented = false
        updateInstallOnQuit()
        objectWillChange.send()
    }

    func remindLater() {
        defaults.set(Date().addingTimeInterval(24 * 3600), forKey: Keys.snoozedUntil)
        isSheetPresented = false
        objectWillChange.send()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(candidate?.releasePageURL ?? configuration.releasesPageURL)
    }

    func openLog() {
        let log = UpdateInstaller.logURL
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: log.path) ? log : ConfigStore.logURL)
    }

    // MARK: - Helpers

    private func updateInstallOnQuit() {
        let skipped = candidate.map { defaults.string(forKey: Keys.skipped) == $0.manifest.version } ?? true
        let scheduled = automaticInstall && canInstallOnQuit && phase == .ready && !skipped
        if scheduled && !installOnQuit, let v = candidate?.manifest.version {
            ConfigStore.log("Uaktualnienie aplikacji: wersja \(v) zostanie zainstalowana przy zamknięciu aplikacji")
        }
        installOnQuit = scheduled
    }

    private func installRequest(relaunch: Bool) -> UpdateInstaller.Request? {
        guard let c = candidate, let zip = preparedArchive, let target = location.url else { return nil }
        return UpdateInstaller.Request(archive: zip, sha256: c.manifest.sha256, target: target,
                                       version: c.manifest.version, bundleIdentifier: c.manifest.bundleIdentifier,
                                       relaunch: relaunch)
    }

    private func launchHelper(relaunch: Bool) throws {
        guard let request = installRequest(relaunch: relaunch) else { throw UpdateError.notInstallable("Brak pobranego uaktualnienia.") }
        helperProcess = try UpdateInstaller.launch(request)
        markPending(request.version)
    }

    private func markPending(_ version: String) {
        try? FileManager.default.removeItem(at: UpdateInstaller.statusFile)
        defaults.set(version, forKey: Keys.pendingVersion)
        defaults.set(currentVersion?.description, forKey: Keys.pendingFrom)
        defaults.synchronize()
        ConfigStore.log("Uaktualnienie aplikacji: instalacja \(version) (\(needsAdminPassword ? "jako administrator" : "bez uprawnień administratora"))")
    }

    private func stagingFolder(for version: String) throws -> URL {
        let url = Self.cachesFolder.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cachesFolder: URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["CMCR_UPDATE_STATE_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("Updates")
        }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("pl.cmcr.manager/Updates")
    }

    /// Only an installed copy with a known version cleans the update cache. A bare executable (`swift run`, UI
    /// snapshots, the demo lab) or an isolated run (`CMCR_CONFIG_DIR`) shares the cache folder with the installed
    /// app, whose verified update may be waiting there to be installed when it quits.
    static func cleansUpdateCache(version: SemanticVersion?, location: InstallLocation,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard version != nil, location.url != nil else { return false }
        return environment["CMCR_SNAPSHOT_DIR"] == nil && environment["CMCR_CONFIG_DIR"] == nil
    }

    /// Removes downloaded archives of other versions and stale backups left by an interrupted helper.
    func removeLeftovers() {
        guard Self.cleansUpdateCache(version: currentVersion, location: location),
              let current = currentVersion?.description else { return }
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: Self.cachesFolder, includingPropertiesForKeys: nil)) ?? []
            where dir.lastPathComponent != current {
            try? fm.removeItem(at: dir)
        }
        guard case .writable(let app) = location else { return }
        let parent = app.deletingLastPathComponent()
        let prefixes = [".\(app.lastPathComponent).old-", ".\(app.lastPathComponent).new-"]
        for item in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where prefixes.contains(where: item.hasPrefix) {
            let url = parent.appendingPathComponent(item)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: url) }
        }
    }
}
