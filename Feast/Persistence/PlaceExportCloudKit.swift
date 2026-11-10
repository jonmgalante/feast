import CloudKit
import CoreData
import Foundation

extension PlaceExport {
    /// Local metadata only. This neither fetches remote changes nor creates or modifies a share.
    @MainActor static func capture(context: NSManagedObjectContext, persistence: PersistenceController?) throws -> PlaceExport {
        var archive = try capture(context: context)
        let cities = try context.fetch(FeastList.fetchRequest())
        let neighborhoods = try context.fetch(ListSection.fetchRequest())
        let places = try context.fetch(SavedPlace.fetchRequest())
        // A second read must still describe the graph captured above, not a newer partial snapshot.
        guard Set(cities.compactMap(\.id)) == Set(archive.cities.map(\.id)),
              Set(neighborhoods.compactMap(\.id)) == Set(archive.neighborhoods.map(\.id)),
              Set(places.compactMap(\.id)) == Set(archive.places.map(\.id)),
              cities.allSatisfy({ $0.id != nil }), neighborhoods.allSatisfy({ $0.id != nil }),
              places.allSatisfy({ $0.id != nil }) else { throw ExportError.invalidContents }
        var shares: [NSManagedObjectID: CKShare] = [:]
        var sharingLookupSucceeded = false
        if let persistence, case .cloudKit = persistence.storeMode {
            do {
                shares = try persistence.container.fetchShares(matching: cities.map(\.objectID))
                sharingLookupSucceeded = true
            } catch {
                // Preserve the library even when local sharing metadata is unavailable.
            }
        }
        func scope(_ object: NSManagedObject) -> StoreScope {
            guard let store = object.objectID.persistentStore, let persistence else { return .unknown }
            if store === persistence.privateCloudKitStore || store === persistence.localPersistentStore { return .privateLibrary }
            if store === persistence.sharedCloudKitStore { return .sharedLibrary }
            return .unknown
        }
        let records = cities.map { RecordSource(entity: "FeastList", id: $0.id!, store: scope($0)) }
            + neighborhoods.map { RecordSource(entity: "ListSection", id: $0.id!, store: scope($0)) }
            + places.map { RecordSource(entity: "SavedPlace", id: $0.id!, store: scope($0)) }
        let sharing = cities.map { city -> CitySharing in
            var share: CKShare?
            var status: SharingStatus = .unavailable
            if let persistence {
                switch persistence.storeMode {
                case .localOnly:
                    status = scope(city) == .privateLibrary ? .notShared : .unavailable
                case .localFallback:
                    // Failed CloudKit setup cannot establish that a city was never shared.
                    status = .unavailable
                case .cloudKit:
                    if sharingLookupSucceeded {
                        share = shares[city.objectID]
                        // A shared-store city without a visible share is not evidence of no sharing.
                        status = share != nil ? .shared : (scope(city) == .privateLibrary ? .notShared : .unavailable)
                    }
                }
            }
            var details = CitySharing(cityID: city.id!, status: status,
                ownerRecordName: share?.owner.userIdentity.userRecordID?.recordName,
                currentUserRole: share?.currentUserParticipant.map { role($0.role) },
                currentUserPermission: share?.currentUserParticipant.map { permission($0.permission) },
                publicPermission: share.map { permission($0.publicPermission) },
                participants: share?.participants.map {
                    Participant(userRecordName: $0.userIdentity.userRecordID?.recordName,
                        role: role($0.role), permission: permission($0.permission),
                        acceptanceStatus: acceptance($0.acceptanceStatus))
                } ?? [])
            details.shareRecordName = share?.recordID.recordName
            details.zoneName = share?.recordID.zoneID.zoneName
            details.zoneOwnerName = share?.recordID.zoneID.ownerName
            return details
        }
        archive.provenance = Provenance(capturedAt: Date(), records: records, cities: sharing)
        try archive.validate()
        return archive
    }

    private static func role(_ value: CKShare.ParticipantRole) -> String {
        if #available(iOS 26.0, *), value == .administrator { return "administrator" }
        switch value {
        case .owner: return "owner"
        case .privateUser: return "privateUser"
        case .publicUser: return "publicUser"
        case .unknown: return "unknown"
        default: return "unknown(\(value.rawValue))"
        }
    }

    private static func permission(_ value: CKShare.ParticipantPermission) -> String {
        switch value {
        case .none: return "none"
        case .readOnly: return "readOnly"
        case .readWrite: return "readWrite"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private static func acceptance(_ value: CKShare.ParticipantAcceptanceStatus) -> String {
        switch value {
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .removed: return "removed"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
