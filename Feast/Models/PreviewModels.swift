import Foundation

struct PreviewFeastList: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let sectionSummary: String
    let savedPlaceCount: Int
}

struct PreviewSavedPlace: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let statusLabel: String
    let listName: String
    let sectionPath: String
}

enum PreviewMocks {
    static let feastLists: [PreviewFeastList] = [
        PreviewFeastList(
            name: "NYC",
            sectionSummary: "Brooklyn, Manhattan, Queens",
            savedPlaceCount: 18
        ),
        PreviewFeastList(
            name: "USA",
            sectionSummary: "Los Angeles, San Francisco, New Orleans",
            savedPlaceCount: 11
        ),
        PreviewFeastList(
            name: "International",
            sectionSummary: "Tokyo, Paris, Mexico City",
            savedPlaceCount: 9
        )
    ]

    static let savedPlaces: [PreviewSavedPlace] = [
        PreviewSavedPlace(
            name: "Rolo's",
            statusLabel: PlaceStatus.love.rawValue,
            listName: "NYC",
            sectionPath: "Brooklyn • Ridgewood"
        ),
        PreviewSavedPlace(
            name: "Dhamaka",
            statusLabel: PlaceStatus.been.rawValue,
            listName: "NYC",
            sectionPath: "Manhattan • Lower East Side"
        ),
        PreviewSavedPlace(
            name: "Bar Etoile",
            statusLabel: PlaceStatus.wantToTry.rawValue,
            listName: "USA",
            sectionPath: "California • Los Angeles"
        )
    ]
}
