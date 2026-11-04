import Foundation

/// Session-scoped successes only. Failures stay retryable, and cancelled work must
/// neither publish a result nor populate the cache used by a subsequent request.
@MainActor final class MapPlaceLookup {
    private var cache: [String: ApplePlaceMatch] = [:]

    func resolve(placeID: String, lookup: (String) async throws -> ApplePlaceMatch?) async throws -> ApplePlaceMatch? {
        try Task.checkCancellation()
        if let cached = cache[placeID] { return cached }
        let match = try await lookup(placeID)
        try Task.checkCancellation()
        if let match, match.coordinate != nil { cache[placeID] = match }
        return match
    }
}
