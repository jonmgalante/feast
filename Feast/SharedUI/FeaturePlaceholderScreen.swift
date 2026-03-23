import SwiftUI

struct FeaturePlaceholderScreen<Content: View>: View {
    private let title: String
    private let subtitle: String
    private let systemImage: String
    private let content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FeastTheme.Spacing.large) {
                heroCard
                content
            }
            .padding(.horizontal, FeastTheme.Spacing.large)
            .padding(.vertical, FeastTheme.Spacing.xLarge)
        }
        .background(FeastTheme.Colors.appBackground.ignoresSafeArea())
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: FeastTheme.Spacing.medium) {
            HStack(spacing: FeastTheme.Spacing.medium) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FeastTheme.Colors.primaryText)
                    .frame(width: 44, height: 44)
                    .background(FeastTheme.Colors.primaryAccent.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: FeastTheme.CornerRadius.medium, style: .continuous))

                Text("Feast v1 shell")
                    .font(FeastTheme.Typography.eyebrow)
                    .foregroundStyle(FeastTheme.Colors.secondaryAccent)
            }

            Text(title)
                .font(FeastTheme.Typography.screenTitle)
                .foregroundStyle(FeastTheme.Colors.primaryText)

            Text(subtitle)
                .font(FeastTheme.Typography.body)
                .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FeastTheme.Spacing.large)
        .background(FeastTheme.Colors.groupedSurface)
        .overlay {
            RoundedRectangle(cornerRadius: FeastTheme.CornerRadius.large, style: .continuous)
                .stroke(FeastTheme.Colors.divider, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: FeastTheme.CornerRadius.large, style: .continuous))
    }
}
