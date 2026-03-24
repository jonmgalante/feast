import Foundation

struct PreviewFeastList: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let neighborhoodSummary: String
    let savedPlaceCount: Int
}

struct PreviewSavedPlace: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let statusLabel: String
    let listName: String
    let neighborhoodName: String
}

enum PreviewMocks {
    static let feastLists: [PreviewFeastList] = [
        PreviewFeastList(
            name: "NYC",
            neighborhoodSummary: "Ridgewood, Lower East Side, East Williamsburg",
            savedPlaceCount: 18
        ),
        PreviewFeastList(
            name: "London",
            neighborhoodSummary: "Soho, Clerkenwell, Notting Hill",
            savedPlaceCount: 11
        ),
        PreviewFeastList(
            name: "Philadelphia",
            neighborhoodSummary: "Fishtown, Center City, South Philly",
            savedPlaceCount: 9
        )
    ]

    static let savedPlaces: [PreviewSavedPlace] = [
        PreviewSavedPlace(
            name: "Rolo's",
            statusLabel: PlaceStatus.love.rawValue,
            listName: "NYC",
            neighborhoodName: "Ridgewood"
        ),
        PreviewSavedPlace(
            name: "Dhamaka",
            statusLabel: PlaceStatus.been.rawValue,
            listName: "NYC",
            neighborhoodName: "Lower East Side"
        ),
        PreviewSavedPlace(
            name: "St. JOHN",
            statusLabel: PlaceStatus.wantToTry.rawValue,
            listName: "London",
            neighborhoodName: "Soho"
        )
    ]
}
