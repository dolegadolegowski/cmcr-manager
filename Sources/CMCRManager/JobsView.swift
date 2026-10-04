import AppKit
import CMCRCore
import SwiftUI

struct JobsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page {
            HStack {
                Label("Zadania", systemImage: AppSection.jobs.icon)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Dziennik działań") {
                    let url = ConfigStore.logURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSSound.beep()
                    }
                }
                Button("Wyczyść zakończone") { model.clearFinishedBatches() }
                    .disabled(!model.batches.contains { $0.finished })
            }
            if model.batches.isEmpty {
                Text("Brak zadań. Każda operacja uruchomiona na komputerach pojawi się tutaj z wynikiem dla każdego iMaca.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.batches) { batch in
                VStack(alignment: .leading, spacing: 4) {
                    Text(batch.createdAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BatchResultsView(batch: batch)
                }
            }
        }
    }
}
