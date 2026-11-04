import Foundation

extension ApplePlacesService {
    static let previewMatches: [ApplePlaceMatch] = [
        ApplePlaceMatch(applePlaceID: "preview-harbor-bakery", displayName: "Harbor Bakery (fictional)", secondaryText: "Fictional address for offline QA", coordinate: nil,
            suggestedSectionPath: .init(cityOrRegion: "New York", neighborhood: "Chelsea"), websiteURL: nil, instagramURL: nil,
            localityIdentity: .init(locality: "New York", administrativeArea: "NY", countryCode: "US"), suggestedPlaceType: .bakery),
        ApplePlaceMatch(
            applePlaceID: "applemaps-rolo-s-ridgewood",
            displayName: "Rolo's",
            secondaryText: "Ridgewood, Queens, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7068, longitude: -73.9215),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "NYC",
                neighborhood: "Ridgewood"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-dhamaka-les",
            displayName: "Dhamaka",
            secondaryText: "Lower East Side, New York, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7180, longitude: -73.9897),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "NYC",
                neighborhood: "Lower East Side"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-librae-bakery",
            displayName: "Librae Bakery",
            secondaryText: "East Williamsburg, Brooklyn, NY",
            coordinate: ApplePlaceCoordinate(latitude: 40.7147, longitude: -73.9377),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "NYC",
                neighborhood: "East Williamsburg"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-st-john-soho",
            displayName: "St. JOHN",
            secondaryText: "Soho, London",
            coordinate: ApplePlaceCoordinate(latitude: 51.5146, longitude: -0.1357),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "London",
                neighborhood: "Soho"
            ),
            websiteURL: nil,
            instagramURL: nil
        ),
        ApplePlaceMatch(
            applePlaceID: "applemaps-middle-child-clubhouse",
            displayName: "Middle Child Clubhouse",
            secondaryText: "Fishtown, Philadelphia, PA",
            coordinate: ApplePlaceCoordinate(latitude: 39.9692, longitude: -75.1336),
            suggestedSectionPath: ApplePlaceSectionPathSuggestion(
                cityOrRegion: "Philadelphia",
                neighborhood: "Fishtown"
            ),
            websiteURL: nil,
            instagramURL: nil
        )
    ]

}
