import Foundation

struct NotesImportReviewDestination: Identifiable, Hashable {
    let id = UUID()
    let cityURIString: String
    let reviewState: NotesImportReviewState
}

enum NotesImportReviewBucket: String, CaseIterable, Identifiable {
    case matched = "Matched"
    case needsReview = "Needs Review"
    case skipped = "Skipped"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .matched:
            return "Likely Apple Maps matches ready for a final import pass"
        case .needsReview:
            return "Places that still need a match or a clearer assignment"
        case .skipped:
            return "Items you chose not to bring in right now"
        }
    }
}

struct NotesImportReviewItem: Identifiable, Hashable {
    let id: UUID
    let sourceLineNumber: Int
    var parsedPlaceName: String
    let status: PlaceStatus
    let placeType: PlaceType?
    let cuisines: [String]
    let tags: [String]
    let note: String?
    let websiteURL: String?
    let instagramURL: String?
    let parsedNeighborhoodName: String?
    var selectedNeighborhoodName: String?
    var matchedPlace: ApplePlaceMatch?
    var suggestedMatches: [ApplePlaceMatch]
    var isSkipped: Bool
    var matchingErrorMessage: String?

    var bucket: NotesImportReviewBucket {
        if isSkipped {
            return .skipped
        }

        return matchedPlace == nil ? .needsReview : .matched
    }

    var neighborhoodLabel: String? {
        selectedNeighborhoodName
            ?? parsedNeighborhoodName
            ?? matchedPlace?.suggestedSectionPath.neighborhood
    }

    var notePreview: String? {
        guard let note else {
            return nil
        }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.count <= 120 {
            return trimmed
        }

        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 120)
        return "\(trimmed[..<endIndex])…"
    }
}

enum NotesImportReviewBuilder {
    static func makeItems(
        from reviewState: NotesImportReviewState,
        in feastList: FeastList
    ) -> [NotesImportReviewItem] {
        var items: [NotesImportReviewItem] = []

        for place in reviewState.unassignedPlaces {
            items.append(item(from: place, neighborhoodName: nil, in: feastList))
        }

        for neighborhood in reviewState.neighborhoods {
            for place in neighborhood.places {
                items.append(
                    item(
                        from: place,
                        neighborhoodName: neighborhood.name,
                        in: feastList
                    )
                )
            }
        }

        return items.sorted { lhs, rhs in
            lhs.sourceLineNumber < rhs.sourceLineNumber
        }
    }

    private static func item(
        from place: NotesImportCandidatePlace,
        neighborhoodName: String?,
        in feastList: FeastList
    ) -> NotesImportReviewItem {
        let canonicalNeighborhoodName = canonicalNeighborhoodName(for: neighborhoodName)
        let selectedNeighborhoodName = matchedNeighborhoodName(
            for: canonicalNeighborhoodName,
            in: feastList
        )

        return NotesImportReviewItem(
            id: place.id,
            sourceLineNumber: place.sourceLineNumber,
            parsedPlaceName: place.displayNameSnapshot,
            status: place.status,
            placeType: place.placeType,
            cuisines: place.cuisines,
            tags: place.tags,
            note: place.note,
            websiteURL: place.websiteURL,
            instagramURL: place.instagramURL,
            parsedNeighborhoodName: canonicalNeighborhoodName,
            selectedNeighborhoodName: selectedNeighborhoodName,
            matchedPlace: nil,
            suggestedMatches: [],
            isSkipped: false,
            matchingErrorMessage: nil
        )
    }

    static func matchedNeighborhoodName(
        for proposedNeighborhood: String?,
        in feastList: FeastList
    ) -> String? {
        matchedNeighborhoodName(
            for: proposedNeighborhood,
            in: feastList.neighborhoodSections.map(\.displayName)
        )
    }

    static func matchedNeighborhoodName(
        for proposedNeighborhood: String?,
        in neighborhoodNames: [String]
    ) -> String? {
        FeastNeighborhoodName.matchedExistingName(
            for: proposedNeighborhood,
            in: neighborhoodNames
        )
    }

    static func canonicalNeighborhoodName(for rawValue: String?) -> String? {
        FeastNeighborhoodName.canonicalDisplayName(for: rawValue)
    }

    static func suggestedNeighborhoodName(for item: NotesImportReviewItem) -> String? {
        canonicalNeighborhoodName(for: item.parsedNeighborhoodName)
    }

    static func suggestedNeighborhoodSuggestion(
        for item: NotesImportReviewItem,
        matchedPlace: ApplePlaceMatch?,
        cityName: String,
        existingNeighborhoodNames: [String]
    ) -> FeastNeighborhoodName.Suggestion? {
        FeastNeighborhoodName.suggestion(
            primary: item.parsedNeighborhoodName,
            fallback: matchedPlace?.suggestedSectionPath.neighborhood,
            existingNeighborhoodNames: existingNeighborhoodNames,
            rejectedContextNames: [
                cityName,
                matchedPlace?.suggestedSectionPath.cityOrRegion
            ]
            .compactMap { $0 }
        )
    }

    static func sessionNeighborhoodNames(
        existingNeighborhoodNames: [String],
        reviewItems: [NotesImportReviewItem]
    ) -> [String] {
        var orderedNeighborhoodNames: [String] = []
        var seenKeys: Set<String> = []

        for rawValue in existingNeighborhoodNames {
            guard
                let displayName = canonicalNeighborhoodName(for: rawValue),
                let key = normalizedKey(for: displayName),
                !seenKeys.contains(key)
            else {
                continue
            }

            seenKeys.insert(key)
            orderedNeighborhoodNames.append(displayName)
        }

        for item in reviewItems {
            guard
                let displayName = canonicalNeighborhoodName(for: item.selectedNeighborhoodName),
                let key = normalizedKey(for: displayName),
                !seenKeys.contains(key)
            else {
                continue
            }

            seenKeys.insert(key)
            orderedNeighborhoodNames.append(displayName)
        }

        return orderedNeighborhoodNames
    }

    static func normalizedKey(for rawValue: String?) -> String? {
        FeastNeighborhoodName.normalizedKey(for: rawValue)
    }
}

enum NotesImportMatcher {
    @MainActor
    static func match(
        _ item: NotesImportReviewItem,
        cityName: String,
        neighborhoodNames: [String],
        using applePlacesService: ApplePlacesService
    ) async -> NotesImportReviewItem {
        guard !item.isSkipped else {
            return item
        }

        let queries = searchQueries(for: item, cityName: cityName)
        var uniqueMatches: [ApplePlaceMatch] = []
        var seenIDs: Set<String> = []

        do {
            for query in queries {
                let matches = try await applePlacesService.search(query: query)

                for match in matches where !seenIDs.contains(match.applePlaceID) {
                    seenIDs.insert(match.applePlaceID)
                    uniqueMatches.append(match)
                }

                if uniqueMatches.count >= 8 {
                    break
                }
            }
        } catch {
            var failedItem = item
            failedItem.matchingErrorMessage = error.localizedDescription
            return failedItem
        }

        let rankedMatches = rankedMatches(
            for: uniqueMatches,
            item: item,
            cityName: cityName
        )
        let suggestedMatches = Array(rankedMatches.map(\.match).prefix(6))

        var matchedItem = item
        matchedItem.suggestedMatches = suggestedMatches
        matchedItem.matchingErrorMessage = nil

        if let autoMatch = confidentAutoMatch(from: rankedMatches) {
            matchedItem.matchedPlace = autoMatch

            if matchedItem.selectedNeighborhoodName == nil,
               let parsedNeighborhoodName = matchedItem.parsedNeighborhoodName {
                matchedItem.selectedNeighborhoodName = matchedNeighborhoodName(
                    for: parsedNeighborhoodName,
                    in: neighborhoodNames
                )
            }
        }

        return matchedItem
    }

    static func searchQueries(for item: NotesImportReviewItem, cityName: String) -> [String] {
        let placeName = item.parsedPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !placeName.isEmpty else {
            return []
        }

        let proposedNeighborhood = item.parsedNeighborhoodName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cityName = cityName.trimmingCharacters(in: .whitespacesAndNewlines)

        var queries: [String] = []

        if let proposedNeighborhood, !proposedNeighborhood.isEmpty, !cityName.isEmpty {
            queries.append("\(placeName), \(proposedNeighborhood), \(cityName)")
        }

        if !cityName.isEmpty {
            queries.append("\(placeName), \(cityName)")
        }

        if let proposedNeighborhood, !proposedNeighborhood.isEmpty {
            queries.append("\(placeName), \(proposedNeighborhood)")
        }

        queries.append(placeName)

        var uniqueQueries: [String] = []
        var seenQueries: Set<String> = []

        for query in queries {
            let normalizedQuery = query
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard !normalizedQuery.isEmpty, !seenQueries.contains(normalizedQuery) else {
                continue
            }

            seenQueries.insert(normalizedQuery)
            uniqueQueries.append(query)
        }

        return uniqueQueries
    }

    private static func rankedMatches(
        for matches: [ApplePlaceMatch],
        item: NotesImportReviewItem,
        cityName: String
    ) -> [ScoredMatch] {
        matches
            .map { match in
                score(match, for: item, cityName: cityName)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }

                return lhs.match.displayName.localizedCaseInsensitiveCompare(rhs.match.displayName) == .orderedAscending
            }
    }

    private static func confidentAutoMatch(from rankedMatches: [ScoredMatch]) -> ApplePlaceMatch? {
        guard let topMatch = rankedMatches.first else {
            return nil
        }

        let runnerUpScore = rankedMatches.dropFirst().first?.score ?? 0
        let confidenceGap = topMatch.score - runnerUpScore

        guard topMatch.isExactNameMatch else {
            return nil
        }

        guard topMatch.score >= 115 else {
            return nil
        }

        if topMatch.matchesLocationContext {
            return topMatch.match
        }

        return confidenceGap >= 18 ? topMatch.match : nil
    }

    private static func score(
        _ match: ApplePlaceMatch,
        for item: NotesImportReviewItem,
        cityName: String
    ) -> ScoredMatch {
        let parsedNameKey = NotesImportReviewBuilder.normalizedKey(for: item.parsedPlaceName) ?? ""
        let matchNameKey = NotesImportReviewBuilder.normalizedKey(for: match.displayName) ?? ""
        let proposedNeighborhoodKey = NotesImportReviewBuilder.normalizedKey(for: item.parsedNeighborhoodName)
        let matchNeighborhoodKey = NotesImportReviewBuilder.normalizedKey(for: match.suggestedSectionPath.neighborhood)
        let cityKey = NotesImportReviewBuilder.normalizedKey(for: cityName)
        let matchCityKey = NotesImportReviewBuilder.normalizedKey(for: match.suggestedSectionPath.cityOrRegion)
        let secondaryTextKey = NotesImportReviewBuilder.normalizedKey(for: match.secondaryText) ?? ""

        let isExactNameMatch = !parsedNameKey.isEmpty && parsedNameKey == matchNameKey
        let isPrefixNameMatch = !parsedNameKey.isEmpty && (
            matchNameKey.hasPrefix(parsedNameKey)
                || parsedNameKey.hasPrefix(matchNameKey)
        )
        let sharedTokens = sharedTokenCount(lhs: parsedNameKey, rhs: matchNameKey)
        let neighborhoodMatches = proposedNeighborhoodKey != nil && (
            proposedNeighborhoodKey == matchNeighborhoodKey
                || secondaryTextKey.contains(proposedNeighborhoodKey ?? "")
        )
        let cityMatches = cityKey != nil && (
            cityKey == matchCityKey
                || secondaryTextKey.contains(cityKey ?? "")
        )

        var score = 0

        if isExactNameMatch {
            score += 100
        } else if isPrefixNameMatch {
            score += 72
        } else if sharedTokens > 0 {
            score += min(sharedTokens * 18, 54)
        }

        if neighborhoodMatches {
            score += 22
        }

        if cityMatches {
            score += 16
        }

        if match.secondaryText.isEmpty == false {
            score += 4
        }

        return ScoredMatch(
            match: match,
            score: score,
            isExactNameMatch: isExactNameMatch,
            matchesLocationContext: neighborhoodMatches || cityMatches
        )
    }

    private static func sharedTokenCount(lhs: String, rhs: String) -> Int {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        return lhsTokens.intersection(rhsTokens).count
    }

    private static func matchedNeighborhoodName(
        for proposedNeighborhood: String?,
        in neighborhoodNames: [String]
    ) -> String? {
        NotesImportReviewBuilder.matchedNeighborhoodName(
            for: proposedNeighborhood,
            in: neighborhoodNames
        )
    }

    private struct ScoredMatch {
        let match: ApplePlaceMatch
        let score: Int
        let isExactNameMatch: Bool
        let matchesLocationContext: Bool
    }
}
