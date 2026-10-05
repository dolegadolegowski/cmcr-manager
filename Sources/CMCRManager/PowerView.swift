import CMCRCore
import SwiftUI

struct PowerView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var title = "Wiadomość od administratora"
    @ViewState private var text = ""
    @ViewState private var asDialog = true
    @ViewState private var confirm: ConfirmRequest?

    var body: some View {
        Page {
            TargetHeader(section: .power,
                         subtitle: "Komunikaty dla użytkowników, wylogowanie, usypianie, restart, wyłączanie i budzenie przez sieć.")

            SectionBox(title: "Wiadomość dla zalogowanych użytkowników", icon: "text.bubble") {
                TextField("Tytuł", text: $title)
                TextEditor(text: $text)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Picker("Forma", selection: $asDialog) {
                        Text("Okno dialogowe").tag(true)
                        Text("Powiadomienie").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                    Spacer()
                    TargetButton(title: "Wyślij", icon: "paperplane.fill") {
                        let t = title, m = text, d = asDialog
                        model.runScript("Wiadomość: \(m.prefix(40))", on: model.selectedMachines) { _ in
                            Scripts.message(title: t, text: m, asDialog: d)
                        }
                    }
                    .disabled(text.isEmpty)
                }
            }

            SectionBox(title: "Sesja użytkownika", icon: "person.crop.circle") {
                HStack {
                    TargetButton(title: "Uśpij ekran", icon: "moon", prominent: false) {
                        model.power(.displaySleep, on: model.selectedMachines)
                    }
                    TargetButton(title: "Wyloguj", icon: "rectangle.portrait.and.arrow.right", prominent: false) {
                        model.runScript("Wylogowanie (z zapisem)", on: model.selectedMachines) { _ in Scripts.logoutUser(force: false) }
                    }
                    .help("Jak „Wyloguj” w menu Apple: aplikacje mogą zapytać ucznia o zapisanie zmian i wstrzymać wylogowanie.")
                    TargetButton(title: "Wyloguj natychmiast", icon: "rectangle.portrait.and.arrow.right.fill", role: .destructive, prominent: false) {
                        confirm = ConfirmRequest(
                            title: "Wylogować użytkowników natychmiast?",
                            message: "Zalogowani użytkownicy na \(model.selection.count) komputerach zostaną natychmiast wylogowani – niezapisane dane przepadną.",
                            button: "Wyloguj") {
                            model.runScript("Wylogowanie użytkownika", on: model.selectedMachines) { _ in Scripts.logoutUser() }
                        }
                    }
                    .help("Kończy sesję od razu, bez pytania o zapisanie dokumentów.")
                }
            }

            SectionBox(title: "Zasilanie", icon: "power") {
                HStack {
                    TargetButton(title: "Obudź (Wake-on-LAN)", icon: "sunrise", prominent: false) {
                        model.wake(model.selectedMachines)
                    }
                    TargetButton(title: "Uśpij", icon: "moon.zzz", prominent: false) {
                        ask(.sleep)
                    }
                    TargetButton(title: "Uruchom ponownie", icon: "arrow.clockwise.circle", role: .destructive, prominent: false) {
                        ask(.restart)
                    }
                    TargetButton(title: "Wyłącz", icon: "power.circle", role: .destructive, prominent: false) {
                        ask(.shutdown)
                    }
                }
                Text("Wake-on-LAN wymaga adresu MAC (zbierany automatycznie przy odświeżaniu stanu), połączenia Ethernet i opcji „Budź przy dostępie do sieci” (Konfiguracja › Przygotowanie).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LastBatchView(section: .power)
        }
        .confirmation($confirm)
    }

    func ask(_ action: PowerAction) {
        confirm = ConfirmRequest(
            title: "\(action.label) – \(model.selection.count) komputerów?",
            message: "Zalogowani użytkownicy mogą stracić niezapisane dane.",
            button: action.label) {
            model.power(action, on: model.selectedMachines)
        }
    }
}
