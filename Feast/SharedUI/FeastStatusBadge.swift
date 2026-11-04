import SwiftUI

struct FeastStatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: PlaceStatus

    var body: some View {
        let colors = FeastTheme.StatusBadges.colors(for: status, dark: colorScheme == .dark)
        Text(status.rawValue)
            .font(FeastTheme.Typography.rowMetadata.weight(.semibold))
            .foregroundStyle(colors.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colors.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Only the status receives color. At large text sizes the remaining metadata
/// moves below it instead of shrinking or truncating the status label.
struct FeastStatusMetadata: View {
    let status: PlaceStatus
    var prefix: String? = nil
    var detail: String? = nil

    private var label: String {
        [prefix, status.rawValue, detail].compactMap { value in
            guard let value, !value.isEmpty else { return nil }; return value
        }.joined(separator: " • ")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: FeastTheme.Spacing.xSmall) {
                if let prefix, !prefix.isEmpty { Text(prefix + " •") }
                FeastStatusBadge(status: status)
                if let detail, !detail.isEmpty { Text("• " + detail) }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 3) {
                if let prefix, !prefix.isEmpty { Text(prefix) }
                FeastStatusBadge(status: status)
                if let detail, !detail.isEmpty { Text(detail).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .font(FeastTheme.Typography.rowMetadata)
        .foregroundStyle(FeastTheme.Colors.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
