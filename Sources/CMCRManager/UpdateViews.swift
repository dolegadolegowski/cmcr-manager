import AppKit
import CMCRCore
import SwiftUI

// MARK: - App menu

/// "CMCR Manager › Sprawdź uaktualnienia…", right below "O programie".
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Sprawdź uaktualnienia…") { Updater.shared.checkNow() }
        }
    }
}

// MARK: - Sidebar banner

/// Card at the bottom of the sidebar while a newer version is available.
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 0) { card }
            .animation(.easeInOut(duration: 0.25), value: updater.showsBanner)
    }

    @ViewBuilder private var card: some View {
        if updater.showsBanner, let c = updater.candidate {
            Button {
                updater.isSheetPresented = true
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label {
                        Text("Dostępna nowa wersja \(c.manifest.version)")
                    } icon: {
                        Image(systemName: updater.phase == .ready ? "arrow.down.app.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .modifier(BannerBackground())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .help("Pokaż, co nowego, i zainstaluj uaktualnienie")
            .accessibilityLabel("Dostępna nowa wersja \(c.manifest.version). \(subtitle)")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var subtitle: String {
        switch updater.phase {
        case .downloading(let got, let total): return "Pobieranie… \(total > 0 ? Int(Double(got) / Double(total) * 100) : 0)%"
        case .verifying: return "Sprawdzanie podpisu…"
        case .ready: return updater.installOnQuit ? "Zostanie zainstalowana przy zamknięciu" : "Gotowa do instalacji"
        case .installing: return "Instalowanie…"
        default: return "Kliknij, aby zobaczyć zmiany"
        }
    }
}

private struct BannerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(Color.accentColor.opacity(0.18)).interactive(),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            content.background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.12)))
        }
    }
}

// MARK: - Sheet

struct UpdateSheet: View {
    @ObservedObject private var updater = Updater.shared
    @EnvironmentObject var model: AppModel
    @ViewState private var confirmRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let c = updater.candidate {
                ScrollView {
                    ReleaseNotesView(text: c.notes.isEmpty ? "Brak opisu zmian." : c.notes)
                        .padding(12)
                }
                .frame(minHeight: 140, maxHeight: 280)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                notices
            }
            statusRow
            if updater.isChecking, updater.phase != .checking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Sprawdzanie, czy jest jeszcze nowsza wersja…").foregroundStyle(.secondary)
                }
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .alert("Przerwać trwające zadania?", isPresented: $confirmRestart) {
            Button("Zainstaluj i uruchom ponownie", role: .destructive) { updater.install() }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Na iMacach \(runningJobs(model.runningJobCount)). Ponowne uruchomienie aplikacji je przerwie.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        if updater.candidate != nil { return "Dostępna jest nowa wersja CMCR Manager" }
        switch updater.phase {
        case .checking: return "Sprawdzanie uaktualnień…"
        case .failed: return "Nie udało się sprawdzić uaktualnień"
        case .idle: return "Uaktualnienia CMCR Manager"
        default: return "Masz najnowszą wersję"
        }
    }

    private var subtitle: String {
        if let c = updater.candidate {
            var s = "Wersja \(c.manifest.version) — zainstalowana: \(updater.currentVersionText)"
            if let d = c.publishedAt { s += " · " + d.formatted(date: .long, time: .omitted) }
            return s
        }
        if updater.phase == .checking { return "Łączenie z GitHubem…" }
        let last = updater.lastCheck.map { " Ostatnio sprawdzono: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
        return "CMCR Manager \(updater.currentVersionText).\(last)"
    }

    @ViewBuilder private var notices: some View {
        if let reason = updater.notInstallableReason {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if updater.needsAdminPassword {
            Label("Aplikacja jest w folderze chronionym – podczas instalacji macOS poprosi o hasło administratora tego Maca.",
                  systemImage: "lock.fill")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.runningJobCount > 0 {
            Label("Na iMacach \(runningJobs(model.runningJobCount)) – ponowne uruchomienie aplikacji je przerwie.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.phase {
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Sprawdzanie…").foregroundStyle(.secondary) }
        case .downloading(let got, let total):
            HStack(spacing: 10) {
                ProgressView(value: Double(got), total: Double(max(total, 1)))
                Text("\(bytes(got)) z \(bytes(total))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Anuluj", systemImage: "xmark") { updater.cancelDownload() }
                    .controlSize(.small)
                    .help("Przerwij pobieranie")
            }
        case .verifying:
            HStack { ProgressView().controlSize(.small); Text("Sprawdzanie podpisu cyfrowego i sumy kontrolnej…").foregroundStyle(.secondary) }
        case .ready:
            Label(updater.installOnQuit
                  ? "Pobrano i sprawdzono. Zostanie zainstalowana automatycznie przy zamknięciu aplikacji."
                  : "Pobrano i sprawdzono (podpis Ed25519, suma SHA-256, podpis kodu).",
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Instalowanie – aplikacja zaraz uruchomi się ponownie…") }
        case .available:
            if let c = updater.candidate {
                Label("Rozmiar pobierania: \(bytes(c.manifest.size))", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .idle, .upToDate:
            EmptyView()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Sprawdzaj automatycznie (przy uruchomieniu i raz dziennie)", isOn: $updater.automaticChecks)
                if updater.canInstallOnQuit {
                    Toggle("Instaluj uaktualnienia automatycznie przy zamykaniu aplikacji", isOn: $updater.automaticInstall)
                        .help("Sprawdzone uaktualnienie zostanie zainstalowane, gdy zamkniesz CMCR Manager – bez pytania.")
                }
            }
            .toggleStyle(.checkbox)
            HStack {
                if updater.candidate != nil {
                    Button("Pomiń tę wersję") { updater.skipThisVersion() }
                        .help("Nie przypominaj o tej wersji – poinformuj dopiero o następnej")
                    Spacer()
                    Button("Przypomnij później") { updater.remindLater() }
                        .keyboardShortcut(.cancelAction)
                        .help("Ukryj powiadomienie na 24 godziny")
                    primaryButton
                } else {
                    Spacer()
                    if case .failed = updater.phase {
                        Button("Spróbuj ponownie") { updater.checkNow() }
                    }
                    Button("OK") { updater.isSheetPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if !updater.canInstall {
            Button("Pobierz ze strony") { updater.openReleasePage() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help("Otwórz stronę wydania na GitHubie")
        } else {
            Button(updater.phase.isFailed ? "Spróbuj ponownie" : "Zainstaluj i uruchom ponownie") {
                if model.runningJobCount > 0 { confirmRestart = true } else { updater.install() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(updater.phase.isBusy)
            .help(updater.needsAdminPassword
                  ? "Pobierz, sprawdź i zainstaluj nową wersję (wymaga hasła administratora), potem uruchom aplikację ponownie"
                  : "Pobierz, sprawdź i zainstaluj nową wersję, potem uruchom aplikację ponownie")
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// "trwa 1 zadanie", "trwają 3 zadania", "trwa 5 zadań", "trwają 22 zadania".
    private func runningJobs(_ n: Int) -> String {
        if n == 1 { return "trwa 1 zadanie" }
        if (2...4).contains(n % 10), !(12...14).contains(n % 100) { return "trwają \(n) zadania" }
        return "trwa \(n) zadań"
    }
}

private extension Updater.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Release notes (GitHub Markdown subset)

struct ReleaseNotesView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    @ViewBuilder private func row(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Color.clear.frame(height: 2)
        } else if line.hasPrefix("#") {
            Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                .font(.headline)
                .padding(.top, 4)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(line.dropFirst(2))))
            }
        } else {
            Text(inline(line))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Settings (Konfiguracja › Ustawienia and the Settings window)

struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section {
            LabeledContent {
                Text(updater.currentVersionText).foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Zainstalowana wersja", caption: lastCheckText, icon: "app.badge.checkmark.fill", color: .blue)
            }
            OptionToggle(title: "Sprawdzaj automatycznie", icon: "arrow.triangle.2.circlepath", color: .blue,
                         detail: "Przy uruchomieniu aplikacji i raz dziennie (wydania na GitHubie)",
                         isOn: $updater.automaticChecks)
            OptionToggle(title: "Pobieraj uaktualnienia w tle", icon: "arrow.down.circle.fill", color: .green,
                         detail: "Instalacja i tak wymaga Twojej zgody",
                         isOn: $updater.automaticDownloads)
            OptionToggle(title: "Instaluj automatycznie", icon: "checkmark.seal.fill", color: .indigo,
                         detail: automaticInstallNote, isOn: $updater.automaticInstall)
                .disabled(!updater.canInstallOnQuit)
            OptionToggle(title: "Proponuj wersje testowe (beta)", icon: "testtube.2", color: .orange,
                         detail: "Tylko do sprawdzania nowych funkcji przed resztą pracowni",
                         isOn: $updater.includePrereleases)
            SettingLabel(title: "Lokalizacja aplikacji", caption: locationText, icon: "folder.fill", color: .gray)
                .textSelection(.enabled)
            HStack {
                Button("Sprawdź teraz", systemImage: "arrow.clockwise") { updater.checkNow() }
                    .disabled(!updater.isConfigured)
                    .help("Sprawdź od razu, czy jest nowa wersja CMCR Manager (także menu CMCR Manager › Sprawdź uaktualnienia…)")
                Button("Historia wersji", systemImage: "clock.arrow.circlepath") {
                    NSWorkspace.shared.open(updater.configuration.releasesPageURL)
                }
                .help("Otwórz listę wydań na GitHubie")
                Spacer()
                Button("Dziennik uaktualnień", systemImage: "doc.text.magnifyingglass") { updater.openLog() }
                    .help("Pokaż dziennik instalacji uaktualnień")
            }
        } header: {
            Text("Uaktualnienia CMCR Manager")
        } footer: {
            if !updater.isConfigured {
                Label("Ta kompilacja nie ma wpisanego klucza publicznego do sprawdzania podpisu (UpdateKeys.swift) – automatyczne uaktualnienia są wyłączone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lastCheckText: String {
        "Ostatnio sprawdzono: " + (updater.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "jeszcze nie sprawdzano")
    }

    private var automaticInstallNote: String {
        switch updater.location {
        case .writable: return "Sprawdzone uaktualnienie zostanie zainstalowane przy zamykaniu aplikacji"
        case .requiresAdmin: return "Niedostępne: instalacja w tym folderze wymaga hasła administratora"
        case .unsupported: return "Niedostępne dla tej kopii aplikacji (patrz Lokalizacja aplikacji)"
        }
    }

    private var locationText: String {
        switch updater.location {
        case .writable(let u): return u.path
        case .requiresAdmin(let u): return u.path + " (instalacja wymaga hasła administratora tego Maca)"
        case .unsupported(let why): return why
        }
    }
}

// MARK: - Result after an update

/// Short-lived confirmation shown after a successful update; failures use an alert.
struct UpdateToast: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let o = updater.outcome, o.success {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.title).font(.callout.weight(.semibold))
                    Text(o.message).font(.caption).foregroundStyle(.secondary)
                }
                Button("Co nowego", systemImage: "sparkles") { updater.openReleasePage() }
                    .controlSize(.small)
                    .help("Otwórz opis zmian tej wersji")
                Button {
                    updater.outcome = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Zamknij")
                .accessibilityLabel("Zamknij")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 8, y: 2)
            .padding(16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: o.id) {
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                withAnimation { if updater.outcome?.id == o.id { updater.outcome = nil } }
            }
        }
    }
}

extension View {
    /// Wires the updater UI into the main window: sheet, failure alert and success toast.
    func updaterUI(model: AppModel) -> some View {
        modifier(UpdaterUIModifier(model: model))
    }
}

private struct UpdaterUIModifier: ViewModifier {
    @ObservedObject private var updater = Updater.shared
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { UpdateToast() }
            .sheet(isPresented: $updater.isSheetPresented) {
                UpdateSheet().environmentObject(model)
            }
            .onSnapshotSubpage { sub in updater.isSheetPresented = sub == "updater" }
            .alert(updater.outcome?.title ?? "",
                   isPresented: Binding(get: { updater.outcome?.success == false },
                                        set: { if !$0 { updater.outcome = nil } })) {
                Button("Pokaż dziennik") { updater.openLog() }
                Button("OK", role: .cancel) {}
            } message: {
                Text(updater.outcome?.message ?? "")
            }
    }
}
