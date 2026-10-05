import CMCRCore
import SwiftUI

struct CommandsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var savingSnippet = false
    @ViewState private var snippetName = ""
    @ViewState private var snippetCategory = "Moje"
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        Page {
            TargetHeader(section: .commands,
                         subtitle: "Odpowiednik cmcr-exec: skrypt bash wykonywany przez SSH na każdym zaznaczonym iMacu (na koncie administracyjnym).")

            SectionBox(title: "Skrypt", icon: "chevron.left.forwardslash.chevron.right") {
                HStack {
                    snippetMenu
                    Spacer()
                    Toggle("Uruchom jako root (sudo)", isOn: $model.commandAsRoot)
                        .toggleStyle(.switch)
                }
                CodeEditor(text: $model.commandDraft)
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    TargetButton(title: "Uruchom na zaznaczonych") {
                        let text = model.commandDraft, root = model.commandAsRoot
                        let risks = CommandRisk.risks(in: text)
                        if CommandRisk.usesRoot(text, asRoot: root) && !risks.isEmpty {
                            confirm = ConfirmRequest(
                                title: "Uruchomić jako root ryzykowne polecenie?",
                                message: "Skrypt zawiera: \(risks.joined(separator: ", ")). Zostanie wykonany z uprawnieniami administratora \(Polish.onComputers(model.actionTargets.count)).",
                                button: "Uruchom") {
                                model.runCommand(text, asRoot: root, on: model.selectedMachines)
                            }
                        } else {
                            model.runCommand(text, asRoot: root, on: model.selectedMachines)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    Button("Zapisz jako fragment…") {
                        snippetName = ""
                        savingSnippet = true
                    }
                    .disabled(model.commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button {
                        model.selectedMachines.prefix(4).forEach(model.openTerminal)
                    } label: {
                        Label("Sesja interaktywna (cmcr-go)", systemImage: "terminal")
                    }
                    .disabled(model.selection.isEmpty)
                    .help("Otwiera ssh w aplikacji Terminal dla maks. 4 zaznaczonych komputerów")
                }
                helpText
            }

            if !model.settings.snippets.isEmpty {
                SectionBox(title: "Moje fragmenty", icon: "bookmark") {
                    ForEach(model.settings.snippets) { s in
                        HStack {
                            Image(systemName: s.asRoot ? "lock.fill" : "chevron.right.2")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(s.name)
                                Text(s.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Wstaw") { use(s) }
                            Button {
                                confirm = ConfirmRequest(title: "Usunąć fragment „\(s.name)”?",
                                                         message: "Zapisane polecenie zniknie z listy „Moje fragmenty”.",
                                                         button: "Usuń", targets: []) {
                                    model.settings.snippets.removeAll { $0.id == s.id }
                                }
                            } label: {
                                Label("Usuń fragment", systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Usuń zapisany fragment")
                        }
                    }
                }
            }

            LastBatchView(section: .commands)
        }
        .sheet(isPresented: $savingSnippet) { saveSheet }
        .confirmation($confirm)
    }

    var snippetMenu: some View {
        let all = Snippet.builtIn + model.settings.snippets
        let categories = all.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
        return Menu {
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(all.filter { $0.category == category }) { s in
                        Button((s.asRoot ? "🔒 " : "") + s.name) { use(s) }
                    }
                }
            }
        } label: {
            Label("Gotowe polecenia", systemImage: "text.badge.plus")
        }
        .fixedSize()
    }

    var helpText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dostępne w skrypcie:").font(.caption.weight(.semibold))
            Group {
                Text("asroot polecenie… – wykonaj jako root (hasło z Pęku kluczy, przez sudo)")
                Text("as_console_user polecenie… – wykonaj w sesji zalogowanego użytkownika (np. open, osascript)")
                Text("with_askpass polecenie… – dla narzędzi wołających sudo -A (Homebrew)")
                Text("$CONSOLE_USER, $CONSOLE_UID, $CMCR_ADMIN_USER, $CMCR_TMP (katalog tymczasowy)")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    func use(_ s: Snippet) {
        model.commandDraft = s.command
        model.commandAsRoot = s.asRoot
    }

    var saveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zapisz fragment").font(.headline)
            TextField("Nazwa", text: $snippetName)
            TextField("Kategoria", text: $snippetCategory)
            Text(model.commandDraft).font(.caption.monospaced()).lineLimit(4).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Anuluj") { savingSnippet = false }
                Button("Zapisz") {
                    model.settings.snippets.append(Snippet(category: snippetCategory.isEmpty ? "Moje" : snippetCategory,
                                                           name: snippetName, command: model.commandDraft,
                                                           asRoot: model.commandAsRoot))
                    savingSnippet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snippetName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
