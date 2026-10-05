import CMCRCore
import SwiftUI

/// What the preview may and may not do, in words a teacher understands.
struct ScreenRestrictionsBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(short: false)
            row(short: true)
            row(short: true).labelStyle(.iconOnly)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func row(short: Bool) -> some View {
        let s = model.settings
        let allowed = s.observeAllowedUserList
        return HStack(spacing: 16) {
            item("eye", short ? "Tylko podgląd" : "Tylko podgląd – bez sterowania",
                 "Aplikacja pokazuje obraz ekranu; nie może klikać ani pisać na komputerze ucznia.")
            item(s.notifyOnObserve ? "bell.badge" : "bell.slash",
                 s.notifyOnObserve ? (short ? "Powiadomienie" : "Uczeń dostaje powiadomienie") : "Bez powiadomienia",
                 s.notifyOnObserve
                    ? "Na początku podglądu uczeń widzi „Administrator rozpoczął podgląd Twojego ekranu” – raz na sesję podglądu i ponownie, gdy zaloguje się inna osoba."
                    : "Uczeń nie jest powiadamiany o podglądzie.")
            item("person.badge.shield.checkmark",
                 s.observeOnlyStandardAccounts ? (short ? "Konta standardowe" : "Tylko konta standardowe") : (short ? "Wszystkie konta" : "Także konta administratorów"),
                 s.observeOnlyStandardAccounts ? "Ekrany kont administratorów nie są pokazywane." : "Pokazywane są także ekrany kont administratorów.")
            if !allowed.isEmpty {
                item("person.2", short ? "\(allowed.count) dozwolone" : "Dozwolone konta: \(allowed.joined(separator: ", "))",
                     "Podgląd działa tylko dla kont: \(allowed.joined(separator: ", ")).")
            }
            item("photo", "≤ \(s.screenshotMaxSize) px",
                 "Największa szerokość miniatury; powiększony ekran może mieć do \(max(1600, s.screenshotMaxSize)) px.")
            Spacer(minLength: 8)
            Button(short ? "Zmień…" : "Zmień ograniczenia…") {
                model.section = .setup
                MainWindow.bringToFront(openWindow)
            }
            .buttonStyle(.link)
            .help("Ograniczenia podglądu ustawisz w Konfiguracji")
        }
    }

    private func item(_ symbol: String, _ text: String, _ help: String) -> some View {
        Label(text, systemImage: symbol)
            .help(help)
            .fixedSize()
    }
}

/// Short message shown on the student's screen as a dialog with an OK button.
struct MessageComposer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let targets: [Machine]
    @ViewState private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(targets.count == 1 ? "Wiadomość dla \(targets[0].name)"
                  : "Wiadomość dla \(targets.count) \(polishPlural(targets.count, "komputera", "komputerów", "komputerów"))",
                  systemImage: "text.bubble")
                .font(.headline)
            TextField("Treść wiadomości", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            Text("Pojawi się na ekranie zalogowanego ucznia jako okno z przyciskiem OK.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: send) { Label("Wyślij", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        model.runScript("Wiadomość: \(message.prefix(40))", on: targets, section: .screens) { _ in
            Scripts.message(title: "Wiadomość od nauczyciela", text: message, asDialog: true)
        }
        dismiss()
    }
}

/// Progress and result of the last action started from the screen preview (message, display sleep).
struct ScreenBatchBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let batch = model.lastBatch[.screens] {
            ScreenBatchBannerContent(batch: batch)
        }
    }
}

private struct ScreenBatchBannerContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var batch: Batch
    @ViewState private var hidden: UUID?

    var body: some View {
        if hidden != batch.id {
            let content = HStack(spacing: 8) {
                if !batch.finished {
                    ProgressView().controlSize(.small)
                } else if batch.failed == 0 {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Szczegóły") {
                    model.section = .jobs
                    MainWindow.bringToFront(openWindow)
                }
                .buttonStyle(.link)
                .help("Pokaż wyniki w sekcji Zadania")
                Button { hidden = batch.id } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Ukryj")
                    .accessibilityLabel("Ukryj")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 620)
            Group {
                if #available(macOS 26, *) {
                    content.glassEffect(.regular, in: .capsule)
                } else {
                    content.background(.regularMaterial, in: Capsule())
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: batch.finished) {
                guard batch.finished else { return }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                withAnimation { hidden = batch.id }
            }
        }
    }

    private var text: String {
        if !batch.finished { return "\(batch.title) – \(batch.completed) z \(batch.jobs.count)" }
        if batch.failed == 0 { return "\(batch.title) – wykonano (\(batch.succeeded))" }
        let first = batch.jobs.first { $0.state == .failed }.map { "\($0.machine.name): \($0.summary)" } ?? ""
        return "\(batch.title) – nie powiodło się na \(batch.failed) z \(batch.jobs.count). \(first)"
    }
}
