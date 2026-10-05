import CMCRCore
import SwiftUI

/// "Harmonogram zasilania": `pmset repeat` with weekday toggles and time pickers, plus the power policy.
struct EnergyScheduleSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var classroom = ClassroomModel.shared
    @ViewState private var confirmClear = false

    private var s: Binding<EnergySchedule> { $classroom.config.schedule }

    var body: some View {
        Section {
            Toggle(isOn: s.powerOnEnabled) {
                Label("Automatyczne budzenie lub włączanie", systemImage: "sunrise")
            }
            if s.wrappedValue.powerOnEnabled {
                Picker("Rodzaj", selection: s.onType) {
                    ForEach(EnergySchedule.OnType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .padding(.leading, 28)
                DatePicker("Godzina", selection: time(\.onTime), displayedComponents: .hourAndMinute)
                    .padding(.leading, 28)
                LabeledContent("Dni") { WeekdayPicker(days: s.onDays) }
                    .padding(.leading, 28)
            }

            Toggle(isOn: s.powerOffEnabled) {
                Label("Automatyczne usypianie lub wyłączanie", systemImage: "moon.zzz")
            }
            if s.wrappedValue.powerOffEnabled {
                Picker("Rodzaj", selection: s.offType) {
                    ForEach(EnergySchedule.OffType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .padding(.leading, 28)
                DatePicker("Godzina", selection: time(\.offTime), displayedComponents: .hourAndMinute)
                    .padding(.leading, 28)
                LabeledContent("Dni") { WeekdayPicker(days: s.offDays) }
                    .padding(.leading, 28)
                if s.wrappedValue.offType == .shutdown {
                    Label("Po wyłączeniu Wake-on-LAN nie zadziała – komputery włączy tylko harmonogram („Obudź lub włącz”). Na Macach z procesorem Apple włączanie z wyłączenia bywa zawodne, dlatego bezpieczniej jest usypiać.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.leading, 28)
                }
            }

            Toggle("Włącz ponownie po zaniku zasilania", isOn: $classroom.config.autoRestartAfterPowerLoss)
                .help("pmset autorestart – przydatne, gdy listwy zasilające są wyłączane na noc.")
            Toggle("Budź przez sieć (Wake-on-LAN)", isOn: $classroom.config.wakeOnLAN)
                .help("pmset womp – opcja „Budź przy dostępie do sieci”.")

            HStack {
                Text(s.wrappedValue.validationError ?? s.wrappedValue.summary)
                    .font(.callout)
                    .foregroundStyle(s.wrappedValue.validationError == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                TargetButton(title: "Pokaż obecny", icon: "calendar", prominent: false) {
                    classroom.loadSchedules(model, model.selectedMachines)
                }
                .help("Odczytaj harmonogram zapisany na zaznaczonych komputerach")
                TargetButton(title: "Usuń", icon: "calendar.badge.minus", role: .destructive, prominent: false) {
                    confirmClear = true
                }
                .help("Usuń powtarzający się harmonogram z zaznaczonych komputerów")
                TargetButton(title: "Zastosuj", icon: "calendar.badge.checkmark", prominent: false) {
                    classroom.applySchedule(model, model.selectedMachines)
                }
                .disabled(s.wrappedValue.validationError != nil)
                .help("Zapisz harmonogram na zaznaczonych komputerach (pmset repeat)")
            }

            ForEach(model.selectedMachines.filter { classroom.schedules[$0.id] != nil }) { m in
                LabeledContent(m.name) {
                    Text(describe(classroom.schedules[m.id]!))
                        .foregroundStyle(classroom.schedules[m.id]?.error == nil ? Color.secondary : Color.red)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Label("Harmonogram zasilania", systemImage: "calendar.badge.clock")
        } footer: {
            Text("macOS pozwala na jedno powtarzające się włączanie i jedno wyłączanie. Harmonogram jest zapisany na samym komputerze i działa także bez tej aplikacji. Na Macach z FileVault włączenie po wyłączeniu zatrzyma się na ekranie odblokowania dysku.")
                .foregroundStyle(.secondary)
        }
        .alert("Usunąć harmonogram zasilania?", isPresented: $confirmClear) {
            Button("Usuń harmonogram", role: .destructive) {
                classroom.cancelSchedule(model, model.selectedMachines)
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Komputery (\(model.selection.count)) przestaną same się włączać i wyłączać.")
        }
    }

    private func time(_ kp: WritableKeyPath<EnergySchedule, ClockTime>) -> Binding<Date> {
        Binding(
            get: {
                let t = classroom.config.schedule[keyPath: kp]
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                classroom.config.schedule[keyPath: kp] = ClockTime(c.hour ?? 0, c.minute ?? 0)
            })
    }

    private func describe(_ info: ScheduleInfo) -> String {
        if let e = info.error { return e }
        var parts = info.events.isEmpty ? ["brak harmonogramu"] : info.events.map(\.text)
        if let a = info.policy["autorestart"] { parts.append("po zaniku zasilania: \(a == "1" ? "włącza się" : "nie")") }
        if let w = info.policy["womp"] { parts.append("Wake-on-LAN: \(w == "1" ? "tak" : "nie")") }
        return parts.joined(separator: "\n")
    }
}

/// Seven toggle buttons Pn…Nd.
struct WeekdayPicker: View {
    @Binding var days: Set<Weekday>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Weekday.allCases, id: \.self) { day in
                Toggle(isOn: Binding(
                    get: { days.contains(day) },
                    set: { if $0 { days.insert(day) } else { days.remove(day) } })) {
                    Text(day.shortLabel).frame(minWidth: 22)
                }
                .toggleStyle(.button)
                .help(day.label)
            }
            Menu {
                Button("Dni robocze") { days = Weekday.workdays }
                Button("Codziennie") { days = Set(Weekday.allCases) }
                Button("Weekendy") { days = [.saturday, .sunday] }
            } label: {
                Label("Szybki wybór", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Szybki wybór dni")
        }
        .controlSize(.small)
    }
}
