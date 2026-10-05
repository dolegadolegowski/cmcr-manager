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
        modifier(DestructiveLabelStyle())
    }
}

extension View {
    /// For the page header above a grouped Form: since macOS 26 the form's sections stop growing at a fixed
    /// width and stay centred in a wide window, so the header keeps the same width to stay aligned with them.
    func alignedWithGroupedForm() -> some View {
        modifier(GroupedFormWidth())
    }

    /// Background of a page made of a header and a grouped Form: the form's own background, so the header does
    /// not sit on a separate grey band.
    func groupedFormPageBackground() -> some View {
        background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct GroupedFormWidth: ViewModifier {
    /// Width of a grouped form section in a wide window (measured on macOS 27).
    static let sectionWidth: CGFloat = 704

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .frame(maxWidth: Self.sectionWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

private struct DestructiveLabelStyle: ViewModifier {
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
