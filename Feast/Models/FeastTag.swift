import Foundation

enum FeastTag {
    nonisolated static func collapsed(_ rawValue: String) -> String? {
        let collapsed = rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed.isEmpty ? nil : collapsed
    }

    nonisolated static func normalizedDisplay(_ rawValue: String) -> String? {
        guard let collapsed = collapsed(rawValue) else {
            return nil
        }

        return collapsed.capitalized(with: .current)
    }

    nonisolated static func normalizedKey(for rawValue: String) -> String? {
        guard let collapsed = collapsed(rawValue) else {
            return nil
        }

        return collapsed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    nonisolated static func normalizedTags(_ values: [String]) -> [String] {
        var orderedTags: [String] = []
        var seenKeys: Set<String> = []

        for value in values {
            guard
                let displayValue = normalizedDisplay(value),
                let key = normalizedKey(for: displayValue),
                !seenKeys.contains(key)
            else {
                continue
            }

            seenKeys.insert(key)
            orderedTags.append(displayValue)
        }

        return orderedTags
    }

    nonisolated static func catalog(from tagCollections: [[String]]) -> [String] {
        var countsByKey: [String: Int] = [:]
        var displayByKey: [String: String] = [:]

        for tags in tagCollections {
            for tag in tags {
                guard
                    let displayValue = normalizedDisplay(tag),
                    let key = normalizedKey(for: displayValue)
                else {
                    continue
                }

                countsByKey[key, default: 0] += 1
                if displayByKey[key] == nil {
                    displayByKey[key] = displayValue
                }
            }
        }

        return displayByKey.keys
            .sorted { lhs, rhs in
                let lhsCount = countsByKey[lhs, default: 0]
                let rhsCount = countsByKey[rhs, default: 0]

                if lhsCount != rhsCount {
                    return lhsCount > rhsCount
                }

                return (displayByKey[lhs] ?? "")
                    .localizedCaseInsensitiveCompare(displayByKey[rhs] ?? "") == .orderedAscending
            }
            .compactMap { displayByKey[$0] }
    }

    nonisolated static func suggestions(
        matching rawValue: String,
        existingTags: [String],
        selectedTags: [String],
        limit: Int = 8
    ) -> [String] {
        let selectedKeys = Set(selectedTags.compactMap { normalizedKey(for: $0) })

        let availableTags = existingTags.filter { tag in
            guard let key = normalizedKey(for: tag) else {
                return false
            }

            return !selectedKeys.contains(key)
        }

        guard let query = normalizedKey(for: rawValue) else {
            return Array(availableTags.prefix(limit))
        }

        let prefixMatches = availableTags.filter { tag in
            normalizedKey(for: tag)?.hasPrefix(query) == true
        }

        let containsMatches = availableTags.filter { tag in
            guard let key = normalizedKey(for: tag) else {
                return false
            }

            return key.contains(query) && !key.hasPrefix(query)
        }

        return Array((prefixMatches + containsMatches).prefix(limit))
    }
}

enum FeastNeighborhoodName {
    struct Suggestion: Equatable {
        let displayName: String
        let existingMatch: String?
    }

    nonisolated private static let coarseAreaKeys: Set<String> = [
        "bronx",
        "brooklyn",
        "manhattan",
        "new york",
        "new york ny",
        "new york city",
        "nyc",
        "queens",
        "staten island",
        "the bronx",
        "united states",
        "united states of america",
        "us",
        "usa"
    ]

    nonisolated static func canonicalDisplayName(for rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        return FeastTag.collapsed(rawValue)
    }

    nonisolated static func normalizedKey(for rawValue: String?) -> String? {
        guard let displayName = canonicalDisplayName(for: rawValue) else {
            return nil
        }

        let folded = displayName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        let normalized = String(
            folded.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
            }
        )
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        return normalized.isEmpty ? nil : normalized
    }

    nonisolated static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard
            let lhsKey = normalizedKey(for: lhs),
            let rhsKey = normalizedKey(for: rhs)
        else {
            return false
        }

        return lhsKey == rhsKey
    }

    nonisolated static func matchedExistingName(
        for proposedNeighborhood: String?,
        in existingNeighborhoodNames: [String]
    ) -> String? {
        guard let proposedNeighborhoodKey = normalizedKey(for: proposedNeighborhood) else {
            return nil
        }

        return existingNeighborhoodNames.first { neighborhoodName in
            normalizedKey(for: neighborhoodName) == proposedNeighborhoodKey
        }
    }

    nonisolated static func suggestion(
        primary rawPrimaryNeighborhood: String?,
        fallback rawFallbackNeighborhood: String? = nil,
        existingNeighborhoodNames: [String],
        rejectedContextNames: [String] = []
    ) -> Suggestion? {
        if let primaryNeighborhood = trustworthyNeighborhood(
            from: rawPrimaryNeighborhood,
            rejectedContextNames: rejectedContextNames
        ) {
            return makeSuggestion(
                for: primaryNeighborhood,
                existingNeighborhoodNames: existingNeighborhoodNames
            )
        }

        if let fallbackNeighborhood = trustworthyNeighborhood(
            from: rawFallbackNeighborhood,
            rejectedContextNames: rejectedContextNames
        ) {
            return makeSuggestion(
                for: fallbackNeighborhood,
                existingNeighborhoodNames: existingNeighborhoodNames
            )
        }

        return nil
    }

    nonisolated static func trustworthyNeighborhood(
        from rawValue: String?,
        rejectedContextNames: [String] = []
    ) -> String? {
        guard
            let displayName = canonicalDisplayName(for: rawValue),
            let key = normalizedKey(for: displayName)
        else {
            return nil
        }

        if coarseAreaKeys.contains(key) {
            return nil
        }

        let rejectedKeys = Set(rejectedContextNames.compactMap { normalizedKey(for: $0) })
        if rejectedKeys.contains(key) {
            return nil
        }

        return displayName
    }

    nonisolated private static func makeSuggestion(
        for displayName: String,
        existingNeighborhoodNames: [String]
    ) -> Suggestion {
        let existingMatch = matchedExistingName(
            for: displayName,
            in: existingNeighborhoodNames
        )

        return Suggestion(
            displayName: existingMatch ?? displayName,
            existingMatch: existingMatch
        )
    }
}
