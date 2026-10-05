import CMCRCore
import SwiftUI

struct CommandsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var savingSnippet = false
    @ViewState private var showHelp = false
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .commands,
                         subtitle: "Polecenia Terminala (skrypt bash) wykonywane naraz na zaznaczonych komputerach, na koncie administratora – jak cmcr-exec.")
                .alignedWithGroupedForm()
                .padding([.horizontal, .top], 20)
            Form {
                scriptSection
                if !model.settings.snippets.isEmpty {
                    snippetsSection
                }
                if let batch = model.lastBatch[.commands] {
                    Section {
                        BatchResultsView(batch: batch)
                    } header: {
                        Label("Wynik ostatniej operacji", systemImage: "list.bullet.rectangle")
                    }
                    .id(batch.id)
                }
            }
            .formStyle(.grouped)
        }
        .groupedFormPageBackground()
        .sheet(isPresented: $savingSnippet) { SnippetSaveSheet() }
        .confirmation($confirm)
    }

    // MARK: Script

    var scriptSection: some View {
        Section {
            LabeledContent {
                snippetMenu
            } label: {
                Text("Gotowe polecenia")
                Text("Sprawdzone polecenia z cmcr-helpers i Twoje zapisane fragmenty.")
            }
            CodeEditor(text: $model.commandDraft)
                .frame(minHeight: 140, idealHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Treść polecenia")
            Toggle(isOn: $model.commandAsRoot) {
                Text("Z uprawnieniami administratora")
                Text("Potrzebne do zmian w systemie. Aplikacja sama poda hasło administratora zapisane w Pęku kluczy.")
            }
            .help("Polecenie zostanie wykonane jako root (sudo).")
            HStack(spacing: 10) {
                Button {
                    savingSnippet = true
                } label: {
                    Label("Zapisz jako fragment…", systemImage: "bookmark")
                }
                .disabled(model.commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Zapisz to polecenie na liście „Moje fragmenty”, aby użyć go ponownie")
                Button {
                    model.selectedMachines.prefix(4).forEach(model.openTerminal)
                } label: {
                    Label("Otwórz w Terminalu", systemImage: "terminal")
                }
                .disabled(model.selection.isEmpty)
                .help("Otwiera okno Terminala z połączeniem (SSH) do zaznaczonych komputerów – najwyżej 4 naraz (jak cmcr-go)")
                Spacer(minLength: 12)
                TargetButton(title: "Uruchom polecenie", icon: "play.fill") { run() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            DisclosureGroup(isExpanded: $showHelp) {
                helpText
                    .padding(.top, 4)
            } label: {
                Label("Polecenia specjalne dostępne w skrypcie", systemImage: "questionmark.circle")
            }
        } header: {
            Label("Polecenie do wykonania", systemImage: "chevron.left.forwardslash.chevron.right")
        }
    }

    func run() {
        let text = model.commandDraft, root = model.commandAsRoot
        let risks = CommandRisk.risks(in: text)
        if CommandRisk.usesRoot(text, asRoot: root) && !risks.isEmpty {
            confirm = ConfirmRequest(
                title: "Uruchomić ryzykowne polecenie z uprawnieniami administratora?",
                message: "Skrypt zawiera: \(risks.joined(separator: ", ")). Zostanie wykonany jako root \(Polish.onComputers(model.actionTargets.count)).",
                button: "Uruchom") {
                model.runCommand(text, asRoot: root, on: model.selectedMachines)
            }
        } else {
            model.runCommand(text, asRoot: root, on: model.selectedMachines)
        }
    }

    var snippetMenu: some View {
        let all = Snippet.builtIn + model.settings.snippets
        let categories = all.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
        return Menu {
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(all.filter { $0.category == category }) { s in
                        Button { use(s) } label: {
                            if s.asRoot {
                                Label(s.name, systemImage: "lock.fill")
                            } else {
                                Text(s.name)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Wstaw polecenie", systemImage: "text.badge.plus")
        }
        .fixedSize()
        .help("Wstaw do edytora gotowe polecenie (z kłódką – wymaga uprawnień administratora)")
    }

    var helpText: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            helpRow("asroot polecenie…", "wykonaj jako root (z hasłem administratora z Pęku kluczy, przez sudo)")
            helpRow("as_console_user polecenie…", "wykonaj w sesji zalogowanego użytkownika (np. open, osascript)")
            helpRow("with_askpass polecenie…", "dla narzędzi, które same pytają o hasło przez sudo -A (np. Homebrew)")
            helpRow("$CONSOLE_USER, $CONSOLE_UID", "zalogowany użytkownik i jego numer")
            helpRow("$CMCR_ADMIN_USER, $CMCR_TMP", "konto administratora i folder tymczasowy")
        }
        .font(.callout)
    }

    func helpRow(_ code: String, _ text: String) -> some View {
        GridRow {
            Text(code)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func use(_ s: Snippet) {
        model.commandDraft = s.command
        model.commandAsRoot = s.asRoot
    }

    // MARK: Snippets

    var snippetsSection: some View {
        Section {
            ForEach(model.settings.snippets) { s in
                HStack(spacing: 10) {
                    Image(systemName: s.asRoot ? "lock.fill" : "text.alignleft")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .help(s.asRoot ? "Wymaga uprawnień administratora" : "Zwykłe polecenie")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text(s.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Button {
                        use(s)
                    } label: {
                        Label("Wstaw", systemImage: "arrow.up.doc")
                    }
                    .help("Wstaw to polecenie do edytora powyżej")
                    Button(role: .destructive) {
                        confirm = ConfirmRequest(title: "Usunąć fragment „\(s.name)”?",
                                                 message: "Zapisane polecenie zniknie z listy „Moje fragmenty”.",
                                                 button: "Usuń", targets: []) {
                            model.settings.snippets.removeAll { $0.id == s.id }
                        }
                    } label: {
                        Label("Usuń fragment „\(s.name)”", systemImage: "trash")
                            .destructiveLabel()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Usuń zapisany fragment")
                }
            }
        } header: {
            Label("Moje fragmenty", systemImage: "bookmark")
        }
    }
}

/// "Zapisz jako fragment": stores the current command in "Moje fragmenty".
struct SnippetSaveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var category = "Moje"

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Nazwa", text: $name, prompt: Text("np. Wyczyść Biurko ucznia"))
                    TextField("Kategoria", text: $category, prompt: Text("Moje"))
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zapisz jako fragment")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Fragment pojawi się w menu „Wstaw polecenie” i na liście „Moje fragmenty”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
                Section("Polecenie") {
                    Text(model.commandDraft)
                        .font(.callout.monospaced())
                        .lineLimit(5)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.commandAsRoot {
                        Label("Z uprawnieniami administratora", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Anuluj", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Zapisz") {
                    model.settings.snippets.append(Snippet(category: category.isEmpty ? "Moje" : category,
                                                           name: trimmedName, command: model.commandDraft,
                                                           asRoot: model.commandAsRoot))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 340)
    }
}
