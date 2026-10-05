import SwiftUI

/// System Settings–style row icon: a white SF Symbol on a coloured rounded square.
struct SettingsIcon: View {
    let symbol: String
    var color: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Form row label: icon, title and an optional plain-language explanation under it.
struct SettingLabel: View {
    let title: String
    var caption: String?
    let icon: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Switch with an icon and a one-line explanation under the title.
struct OptionToggle: View {
    let title: String
    let icon: String
    var color: Color = .accentColor
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingLabel(title: title, caption: detail, icon: icon, color: color)
        }
        .toggleStyle(.switch)
    }
}

/// Form row label without an explanation, aligned with `OptionToggle` rows.
struct FormLabel: View {
    let title: String
    let icon: String
    var color: Color = .accentColor

    var body: some View {
        SettingLabel(title: title, icon: icon, color: color)
    }
}

/// Section footer, left-aligned as in System Settings (grouped forms put footers at the trailing edge).
struct FormFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Status line with a coloured symbol, e.g. "Zapisane w Pęku kluczy".
struct StatusText: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}

/// Title row at the top of a Konfiguracja page: icon, title, explanation and optional trailing content.
struct PageHeader<Trailing: View>: View {
    let title: String
    let icon: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    titleLabel
                    Spacer(minLength: 16)
                    trailing
                }
                VStack(alignment: .leading, spacing: 6) {
                    titleLabel
                    trailing
                }
            }
            // No fixedSize: outside a scroll view a vertically fixed text would inflate the window's minimum height.
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    var titleLabel: some View {
        Label(title, systemImage: icon)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, icon: String, subtitle: String) {
        self.init(title: title, icon: icon, subtitle: subtitle) { EmptyView() }
    }
}

/// Number with a unit and a stepper, the way System Settings edits numbers; typed values are kept in `range`.
struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(name, value: clamped, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 56)
            if !unit.isEmpty {
                Text(unit).foregroundStyle(.secondary)
            }
            Stepper(name, value: clamped, in: range, step: step)
                .labelsHidden()
        }
        .fixedSize()
        .help("Od \(range.lowerBound) do \(range.upperBound)\(unit.isEmpty ? "" : " \(unit)")")
    }

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}
