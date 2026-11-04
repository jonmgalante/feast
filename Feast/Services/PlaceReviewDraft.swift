import CoreData
import Foundation

enum AddPlaceNeighborhoodSelection: Hashable {
    case unsorted
    case existing(NSManagedObjectID)
    case create(String)
    case manualEntry
}

/// Unsaved form values only, scoped to the Add Place presentation. Never persisted or sent anywhere.
struct PlaceReviewDraft: Equatable {
    var cityURI: String
    var status: PlaceStatus = .wantToTry
    var placeType: PlaceType
    var cuisinesText = ""
    var tags: [String] = []
    var note = ""
    var websiteURL: String
    var instagramURL: String
    var neighborhood: AddPlaceNeighborhoodSelection
    var committedNeighborhood: AddPlaceNeighborhoodSelection
    var newNeighborhoodName = ""

    init(place: ApplePlaceMatch, cityURI: String, neighborhood: AddPlaceNeighborhoodSelection) {
        self.cityURI = cityURI; placeType = place.suggestedPlaceType ?? .restaurant
        websiteURL = place.websiteURL ?? ""; instagramURL = place.instagramURL ?? ""
        self.neighborhood = neighborhood; committedNeighborhood = neighborhood
    }
    func forDestination(_ cityURI: String, suggested: AddPlaceNeighborhoodSelection) -> Self {
        var result = self
        if self.cityURI != cityURI {
            result.cityURI = cityURI; result.neighborhood = suggested
            result.committedNeighborhood = suggested; result.newNeighborhoodName = ""
        }
        return result
    }
}
struct PlaceReviewDraftCache {
    private var drafts: [String: PlaceReviewDraft] = [:]
    private var order: [String] = []
    func draft(for placeID: String) -> PlaceReviewDraft? { drafts[placeID] }
    mutating func store(_ draft: PlaceReviewDraft, for placeID: String) {
        order.removeAll { $0 == placeID }; order.append(placeID); drafts[placeID] = draft
        if order.count > 16 { drafts.removeValue(forKey: order.removeFirst()) }
    }
}
