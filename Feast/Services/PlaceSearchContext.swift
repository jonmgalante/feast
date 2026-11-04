import Foundation

enum PlaceSearchContext {
    static func query(_ query: String, cityName: String?) -> String {
        guard let cityName, !cityName.isEmpty,
              !query.localizedCaseInsensitiveContains(cityName) else { return query }
        return "\(query), \(cityName)"
    }
    @MainActor static func search(
        _ originalQuery: String,
        cityName: String?,
        lookup: (String) async throws -> [ApplePlaceMatch]
    ) async throws -> [ApplePlaceMatch] {
        let contextualQuery = query(originalQuery, cityName: cityName)
        let matches = try await lookup(contextualQuery)
        try Task.checkCancellation()
        guard matches.isEmpty, contextualQuery != originalQuery else { return matches }
        let fallback = try await lookup(originalQuery)
        try Task.checkCancellation()
        return fallback
    }
}
