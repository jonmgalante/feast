import SwiftUI

struct SavedPlaceListRow: View {
    let place: SavedPlace
    var isNested = false
    var showsLocationContext = false

    var body: some View {
        NavigationLink {
            SavedPlaceDetailView(savedPlace: place)
        } label: {
            HStack(alignment: .top, spacing: FeastTheme.Spacing.small) {
                if isNested {
                    Color.clear
                        .frame(width: FeastTheme.Spacing.small, height: 1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    if showsLocationContext, let locationContext {
                        metadataText(
                            locationContext,
                            font: FeastTheme.Typography.rowUtility,
                            color: FeastTheme.Colors.tertiaryText
                        )
                    }

                    Text(place.displayName)
                        .font(FeastTheme.Typography.rowTitle)
                        .foregroundStyle(FeastTheme.Colors.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                        .multilineTextAlignment(.leading)

                    statusAndTypeLine

                    if let preview = place.cuisineTagPreview {
                        metadataText(
                            preview,
                            font: FeastTheme.Typography.rowUtility,
                            color: FeastTheme.Colors.tertiaryText
                        )
                    }
                }
                .padding(.vertical, 6)

                Spacer(minLength: 0)
            }
        }
    }

    private var statusAndTypeLine: some View {
        Text("\(Text(place.placeStatus.rawValue).fontWeight(.semibold)) • \(Text(place.placeTypeValue.rawValue))")
            .font(FeastTheme.Typography.rowMetadata)
            .foregroundStyle(FeastTheme.Colors.secondaryText)
            .lineLimit(2)
            .truncationMode(.tail)
            .minimumScaleFactor(0.9)
    }

    private func metadataText(
        _ text: String,
        font: Font,
        color: Color
    ) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(2)
            .truncationMode(.tail)
            .allowsTightening(true)
            .minimumScaleFactor(0.9)
    }

    private var locationContext: String? {
        let sectionPath = place.listSection?.pathDisplay

        if let sectionPath, !sectionPath.isEmpty {
            return "\(place.displayListName) • \(sectionPath)"
        }

        return place.displayListName
    }
}
