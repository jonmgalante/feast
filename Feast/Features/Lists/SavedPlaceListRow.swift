import SwiftUI

struct SavedPlaceListRow: View {
    let place: SavedPlace
    var isNested = false
    var showsLocationContext = false

    var body: some View {
        NavigationLink {
            SavedPlaceDetailView(savedPlace: place)
        } label: {
            HStack(alignment: .top, spacing: FeastTheme.Spacing.medium) {
                if isNested {
                    Color.clear
                        .frame(width: FeastTheme.Spacing.medium, height: 1)
                }

                VStack(alignment: .leading, spacing: FeastTheme.Spacing.xSmall) {
                    Text(place.displayName)
                        .font(FeastTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(FeastTheme.Colors.primaryText)

                    if showsLocationContext, let locationContext {
                        Text(locationContext)
                            .font(FeastTheme.Typography.caption)
                            .foregroundStyle(FeastTheme.Colors.secondaryNeutral)
                    }

                    Text(place.statusAndTypeSummary)
                        .font(FeastTheme.Typography.supporting)
                        .foregroundStyle(FeastTheme.Colors.secondaryNeutral)

                    if let preview = place.cuisineTagPreview {
                        Text(preview)
                            .font(FeastTheme.Typography.caption)
                            .foregroundStyle(FeastTheme.Colors.secondaryAccent)
                    }
                }
                .padding(.vertical, FeastTheme.Spacing.xSmall)

                Spacer(minLength: 0)
            }
        }
    }

    private var locationContext: String? {
        let sectionPath = place.listSection?.pathDisplay

        if let sectionPath, !sectionPath.isEmpty {
            return "\(place.displayListName) • \(sectionPath)"
        }

        return place.displayListName
    }
}
