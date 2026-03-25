import Foundation

enum FeastTag {
    static func collapsed(_ rawValue: String) -> String? {
        let collapsed = rawValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed.isEmpty ? nil : collapsed
    }

    static func normalizedDisplay(_ rawValue: String) -> String? {
        guard let collapsed = collapsed(rawValue) else {
            return nil
        }

        return collapsed.capitalized(with: .current)
    }

    static func normalizedKey(for rawValue: String) -> String? {
        guard let collapsed = collapsed(rawValue) else {
            return nil
        }

        return collapsed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    static func normalizedTags(_ values: [String]) -> [String] {
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

    static func catalog(from tagCollections: [[String]]) -> [String] {
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

    static func suggestions(
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
