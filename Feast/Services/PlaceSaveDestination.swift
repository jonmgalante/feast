import Foundation

/// Verified locality components from the user's selected Apple Maps match, never a discovery name guess.
struct ApplePlaceLocalityIdentity: Codable, Hashable, Sendable {
    let locality: String
    let administrativeArea: String
    let countryCode: String
    var key: String? {
        let parts = [locality, administrativeArea, countryCode].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 120 && !$0.contains("|") }), parts[2].count == 2 else { return nil }
        return parts.joined(separator: "|")
    }
}
/// Learns only after explicit successful Save. Multiple destinations for one locality stay ambiguous.
struct PlaceSaveDestinationMemory {
    let defaults: UserDefaults
    private let storageKey = "FeastReviewedMapsDestinations.v1"
    func cityID(for identity: ApplePlaceLocalityIdentity?, available: Set<UUID>) -> UUID? {
        guard let key = identity?.key, let raw = defaults.dictionary(forKey: storageKey)?[key] as? [String] else { return nil }
        let ids = Set(raw.compactMap(UUID.init(uuidString:)))
        guard ids.count == 1, let id = ids.first, available.contains(id) else { return nil }
        return id
    }
    func record(identity: ApplePlaceLocalityIdentity?, cityID: UUID?) {
        guard let key = identity?.key, let cityID else { return }
        var map = defaults.dictionary(forKey: storageKey) ?? [:]
        var ids = Set((map[key] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        ids.insert(cityID); map[key] = ids.map(\.uuidString).sorted()
        guard map.count <= 100 else { return }
        defaults.set(map, forKey: storageKey)
    }
}
