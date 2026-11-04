import Foundation

struct ApplePlaceMatch: Identifiable, Hashable {
    let applePlaceID: String
    let displayName: String
    let secondaryText: String
    let coordinate: ApplePlaceCoordinate?
    let suggestedSectionPath: ApplePlaceSectionPathSuggestion
    let websiteURL: String?
    let instagramURL: String?

    var localityIdentity: ApplePlaceLocalityIdentity? = nil
    var suggestedPlaceType: PlaceType? = nil

    var id: String { applePlaceID }
}

struct ApplePlaceSectionPathSuggestion: Hashable {
    let cityOrRegion: String?
    let neighborhood: String?

    var displayText: String? {
        let components = [cityOrRegion, neighborhood].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        guard !components.isEmpty else {
            return nil
        }

        return components.joined(separator: " • ")
    }
}
