import SwiftUI

/// A row of a grouped form: what it does (title and a one-line explanation) on the left, its buttons on the
/// right – like the rows with buttons in System Settings.
struct FormActionRow<Buttons: View>: View {
    let title: String
    let caption: String
    let buttons: Buttons

    init(_ title: String, caption: String, @ViewBuilder buttons: () -> Buttons) {
        self.title = title
        self.caption = caption
        self.buttons = buttons()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            buttons
        }
    }
}

extension View {
    /// Red title and icon for a button that deletes or stops something (the action itself still asks for
    /// confirmation). Apply it to the button's label: bordered buttons on macOS ignore `.tint` and a colour set
    /// on the button itself. A disabled button keeps the usual dimmed look.
    func destructiveLabel() -> some View {
        modifier(DestructiveLabel())
    }
}

private struct DestructiveLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(.red)
        } else {
            content
        }
    }
}

/// Explanation under a section of a grouped form: small, secondary and aligned to the leading edge.
struct FormSectionNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
