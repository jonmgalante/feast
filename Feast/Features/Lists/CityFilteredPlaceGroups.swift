import CoreData

/// A read-only presentation of already-filtered city records.
struct CityFilteredPlaceGroups {
    struct Neighborhood: Identifiable {
        let section: ListSection
        let places: [SavedPlace]
        var id: NSManagedObjectID { section.objectID }
    }

    let neighborhoods: [Neighborhood]
    let unsorted: [SavedPlace]
    let otherMatches: [SavedPlace]

    init(matchingPlaces: [SavedPlace], neighborhoods: [ListSection]) {
        let visibleIDs = Set(neighborhoods.map(\.objectID))
        var grouped: [NSManagedObjectID: [SavedPlace]] = [:]
        var unsorted: [SavedPlace] = []
        var otherMatches: [SavedPlace] = []

        for place in matchingPlaces {
            if let sectionID = place.listSection?.objectID {
                if visibleIDs.contains(sectionID) {
                    grouped[sectionID, default: []].append(place)
                } else {
                    // Keep legacy or temporarily unavailable assignments visible;
                    // displaying results must never repair or discard records.
                    otherMatches.append(place)
                }
            } else {
                unsorted.append(place)
            }
        }

        self.neighborhoods = neighborhoods.compactMap { section in
            guard let places = grouped[section.objectID], !places.isEmpty else { return nil }
            return Neighborhood(section: section, places: places)
        }
        self.unsorted = unsorted
        self.otherMatches = otherMatches
    }
}
