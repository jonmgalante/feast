import CloudKit
import CoreData
import Foundation
import SwiftUI
import os

enum FeastListSharingRole: String, Equatable {
    case owner = "Owner"
    case editor = "Editor"
}

enum FeastListSharingState: Equatable {
    case localOnly
    case shared(role: FeastListSharingRole)

    var isShared: Bool {
        if case .shared = self {
            return true
        }

        return false
    }

    var canManageSharing: Bool {
        switch self {
        case .localOnly, .shared(role: .owner):
            return true
        case .shared(role: .editor):
            return false
        }
    }

    var canDeleteList: Bool {
        switch self {
        case .shared(role: .editor):
            return false
        case .localOnly, .shared(role: .owner):
            return true
        }
    }

    var roleBadgeText: String? {
        switch self {
        case .localOnly:
            return nil
        case let .shared(role):
            return "Shared • \(role.rawValue)"
        }
    }

    var shareActionTitle: String {
        switch self {
        case .localOnly:
            return "Share List"
        case .shared(role: .owner):
            return "Manage Sharing"
        case .shared(role: .editor):
            return "Shared by Owner"
        }
    }
}

struct PreparedFeastListShare: Identifiable {
    let id = UUID()
    let feastListObjectID: NSManagedObjectID
    let feastListName: String
    let share: CKShare
    let container: CKContainer
}

final class PersistenceController {
    struct CloudKitSyncConfiguration {
        static let infoPlistKey = "FeastCloudKitContainerIdentifier"

        let containerIdentifier: String

        static func liveFromInfoPlist(in bundle: Bundle) -> CloudKitSyncConfiguration? {
            guard
                let rawValue = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
                let containerIdentifier = normalized(rawValue)
            else {
                return nil
            }

            return CloudKitSyncConfiguration(containerIdentifier: containerIdentifier)
        }

        private static func normalized(_ rawValue: String) -> String? {
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }
    }

    enum StoreMode: Equatable {
        case localOnly
        case cloudKit(containerIdentifier: String)
        case localFallback(containerIdentifier: String)
    }

    enum SharingError: LocalizedError {
        case unavailable
        case missingCloudKitContainer
        case missingSharedPersistentStore
        case missingPersistentStore
        case failedToPrepareShare

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "iCloud sharing is unavailable for this Feast build."
            case .missingCloudKitContainer:
                return "Feast couldn't find its CloudKit container."
            case .missingSharedPersistentStore:
                return "Feast couldn't access the shared CloudKit store."
            case .missingPersistentStore:
                return "Feast couldn't determine which persistent store this list belongs to."
            case .failedToPrepareShare:
                return "Feast couldn't prepare sharing for this list."
            }
        }
    }

    private enum StoreKind {
        case local
        case privateCloudKit
        case sharedCloudKit
    }

    private struct ConfiguredStoreDescription {
        let kind: StoreKind
        let description: NSPersistentStoreDescription
    }

    private struct LoadedStoreReferences {
        var local: NSPersistentStore?
        var privateCloudKit: NSPersistentStore?
        var sharedCloudKit: NSPersistentStore?
    }

    let container: NSPersistentCloudKitContainer
    let storeMode: StoreMode
    let localPersistentStore: NSPersistentStore?
    let privateCloudKitStore: NSPersistentStore?
    let sharedCloudKitStore: NSPersistentStore?

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    var cloudKitContainerIdentifier: String? {
        switch storeMode {
        case .localOnly:
            return nil
        case let .cloudKit(containerIdentifier), let .localFallback(containerIdentifier):
            return containerIdentifier
        }
    }

    var cloudKitContainer: CKContainer? {
        guard let cloudKitContainerIdentifier else {
            return nil
        }

        return CKContainer(identifier: cloudKitContainerIdentifier)
    }

    var supportsSharing: Bool {
        cloudKitContainer != nil && privateCloudKitStore != nil && sharedCloudKitStore != nil
    }

    init(
        inMemory: Bool = false,
        cloudKitSyncConfiguration: CloudKitSyncConfiguration? = nil
    ) {
        let model = Self.managedObjectModel()
        let preferredCloudKitSyncConfiguration = inMemory ? nil : cloudKitSyncConfiguration
        let configuredStoreDescriptions = Self.makeStoreDescriptions(
            inMemory: inMemory,
            cloudKitSyncConfiguration: preferredCloudKitSyncConfiguration
        )

        let configuredContainer = Self.makeContainer(
            managedObjectModel: model,
            storeDescriptions: configuredStoreDescriptions.map(\.description)
        )

        let loadedStores: LoadedStoreReferences

        do {
            try Self.loadPersistentStores(in: configuredContainer)
            container = configuredContainer
            loadedStores = Self.capturePersistentStores(
                in: configuredContainer,
                matching: configuredStoreDescriptions
            )

            if let preferredCloudKitSyncConfiguration {
                storeMode = .cloudKit(containerIdentifier: preferredCloudKitSyncConfiguration.containerIdentifier)
            } else {
                storeMode = .localOnly
            }
        } catch {
            guard let preferredCloudKitSyncConfiguration else {
                fatalError("Failed to load persistent stores: \(error.localizedDescription)")
            }

            Self.logger.error(
                "CloudKit store setup failed for \(preferredCloudKitSyncConfiguration.containerIdentifier, privacy: .public). Falling back to local storage. Error: \(error.localizedDescription, privacy: .public)"
            )

            let fallbackStoreDescriptions = Self.makeStoreDescriptions(
                inMemory: inMemory,
                cloudKitSyncConfiguration: nil
            )
            let fallbackContainer = Self.makeContainer(
                managedObjectModel: model,
                storeDescriptions: fallbackStoreDescriptions.map(\.description)
            )

            do {
                try Self.loadPersistentStores(in: fallbackContainer)
            } catch {
                fatalError("Failed to load persistent stores: \(error.localizedDescription)")
            }

            container = fallbackContainer
            loadedStores = Self.capturePersistentStores(
                in: fallbackContainer,
                matching: fallbackStoreDescriptions
            )
            storeMode = .localFallback(containerIdentifier: preferredCloudKitSyncConfiguration.containerIdentifier)
        }

        localPersistentStore = loadedStores.local
        privateCloudKitStore = loadedStores.privateCloudKit
        sharedCloudKitStore = loadedStores.sharedCloudKit

        Self.configureViewContext(container.viewContext)
    }

    static let shared = PersistenceController(
        cloudKitSyncConfiguration: CloudKitSyncConfiguration.liveFromInfoPlist(in: .main)
    )
    static let preview = PersistenceController(inMemory: true)

    private static let logger = Logger(subsystem: "com.jongalante.Feast", category: "Persistence")

    private static func managedObjectModel() -> NSManagedObjectModel {
        guard let model = NSManagedObjectModel.mergedModel(from: [Bundle.main]) else {
            fatalError("Failed to locate the Feast Core Data model in the main bundle.")
        }

        return model
    }

    private static func makeContainer(
        managedObjectModel: NSManagedObjectModel,
        storeDescriptions: [NSPersistentStoreDescription]
    ) -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(
            name: "FeastDataModel",
            managedObjectModel: managedObjectModel
        )

        container.persistentStoreDescriptions = storeDescriptions
        return container
    }

    private static func makeStoreDescriptions(
        inMemory: Bool,
        cloudKitSyncConfiguration: CloudKitSyncConfiguration?
    ) -> [ConfiguredStoreDescription] {
        if inMemory {
            let description = NSPersistentStoreDescription()
            description.url = URL(fileURLWithPath: "/dev/null")
            applyCommonOptions(to: description)

            return [
                ConfiguredStoreDescription(kind: .local, description: description)
            ]
        }

        if let cloudKitSyncConfiguration {
            let privateDescription = NSPersistentStoreDescription(url: storeURL(named: "Feast.sqlite"))
            applyCommonOptions(to: privateDescription)
            let privateOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudKitSyncConfiguration.containerIdentifier
            )
            privateOptions.databaseScope = .private
            privateDescription.cloudKitContainerOptions = privateOptions

            let sharedDescription = NSPersistentStoreDescription(url: storeURL(named: "Feast-Shared.sqlite"))
            applyCommonOptions(to: sharedDescription)
            let sharedOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudKitSyncConfiguration.containerIdentifier
            )
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions

            return [
                ConfiguredStoreDescription(kind: .privateCloudKit, description: privateDescription),
                ConfiguredStoreDescription(kind: .sharedCloudKit, description: sharedDescription)
            ]
        }

        let description = NSPersistentStoreDescription(url: storeURL(named: "Feast.sqlite"))
        applyCommonOptions(to: description)

        return [
            ConfiguredStoreDescription(kind: .local, description: description)
        ]
    }

    private static func applyCommonOptions(to description: NSPersistentStoreDescription) {
        description.shouldInferMappingModelAutomatically = true
        description.shouldMigrateStoreAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    }

    private static func storeURL(named fileName: String) -> URL {
        NSPersistentContainer.defaultDirectoryURL().appendingPathComponent(fileName)
    }

    private static func loadPersistentStores(in container: NSPersistentCloudKitContainer) throws {
        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        container.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let loadError {
            throw loadError
        }
    }

    private static func capturePersistentStores(
        in container: NSPersistentCloudKitContainer,
        matching configuredStoreDescriptions: [ConfiguredStoreDescription]
    ) -> LoadedStoreReferences {
        let storesByURL: [URL: NSPersistentStore] = Dictionary(
            uniqueKeysWithValues: container.persistentStoreCoordinator.persistentStores.compactMap { store in
                guard let url = store.url else {
                    return nil
                }

                return (url, store)
            }
        )

        var references = LoadedStoreReferences()

        for configuredStoreDescription in configuredStoreDescriptions {
            guard let url = configuredStoreDescription.description.url else {
                continue
            }

            switch configuredStoreDescription.kind {
            case .local:
                references.local = storesByURL[url]
            case .privateCloudKit:
                references.privateCloudKit = storesByURL[url]
            case .sharedCloudKit:
                references.sharedCloudKit = storesByURL[url]
            }
        }

        return references
    }

    private static func configureViewContext(_ viewContext: NSManagedObjectContext) {
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        viewContext.undoManager = nil
    }

    func assignToDefaultStore(_ object: NSManagedObject) {
        guard
            let context = object.managedObjectContext,
            let store = defaultWriteStore
        else {
            return
        }

        context.assign(object, to: store)
    }

    func assign(_ object: NSManagedObject, toSameStoreAs referenceObject: NSManagedObject) {
        guard let context = object.managedObjectContext else {
            return
        }

        let store = referenceObject.objectID.persistentStore ?? defaultWriteStore
        guard let store else {
            return
        }

        context.assign(object, to: store)
    }

    func sharingState(for feastList: FeastList) -> FeastListSharingState {
        if feastList.objectID.persistentStore == sharedCloudKitStore {
            return .shared(role: .editor)
        }

        if let _ = try? share(for: feastList) {
            return .shared(role: .owner)
        }

        return .localOnly
    }

    func canDeleteFeastList(_ feastList: FeastList) -> Bool {
        let state = sharingState(for: feastList)
        guard state.canDeleteList else {
            return false
        }

        guard supportsSharing else {
            return true
        }

        return container.canDeleteRecord(forManagedObjectWith: feastList.objectID)
    }

    func share(for feastList: FeastList) throws -> CKShare? {
        guard supportsSharing else {
            return nil
        }

        return try container.fetchShares(matching: [feastList.objectID])[feastList.objectID]
    }

    func prepareShare(for feastList: FeastList) async throws -> PreparedFeastListShare {
        guard supportsSharing else {
            throw SharingError.unavailable
        }

        guard let cloudKitContainer else {
            throw SharingError.missingCloudKitContainer
        }

        let feastListName = feastList.displayName
        let feastListObjectID = feastList.objectID

        if let existingShare = try share(for: feastList) {
            existingShare[CKShare.SystemFieldKey.title] = feastListName as CKRecordValue
            return PreparedFeastListShare(
                feastListObjectID: feastListObjectID,
                feastListName: feastListName,
                share: existingShare,
                container: cloudKitContainer
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            container.share([feastList], to: nil) { _, share, resolvedContainer, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let share else {
                    continuation.resume(throwing: SharingError.failedToPrepareShare)
                    return
                }

                share[CKShare.SystemFieldKey.title] = feastListName as CKRecordValue

                continuation.resume(
                    returning: PreparedFeastListShare(
                        feastListObjectID: feastListObjectID,
                        feastListName: feastListName,
                        share: share,
                        container: resolvedContainer ?? cloudKitContainer
                    )
                )
            }
        }
    }

    func persistUpdatedShare(_ share: CKShare, forManagedObjectWith objectID: NSManagedObjectID) async throws {
        guard supportsSharing else {
            throw SharingError.unavailable
        }

        guard let persistentStore = objectID.persistentStore else {
            throw SharingError.missingPersistentStore
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.persistUpdatedShare(share, in: persistentStore) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func acceptShareInvitations(from metadata: [CKShare.Metadata]) async throws {
        guard supportsSharing else {
            throw SharingError.unavailable
        }

        guard let sharedCloudKitStore else {
            throw SharingError.missingSharedPersistentStore
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.acceptShareInvitations(from: metadata, into: sharedCloudKitStore) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        viewContext.refreshAllObjects()
    }

    private var defaultWriteStore: NSPersistentStore? {
        privateCloudKitStore ?? localPersistentStore ?? container.persistentStoreCoordinator.persistentStores.first
    }
}

private struct PersistenceControllerKey: EnvironmentKey {
    static let defaultValue: PersistenceController? = nil
}

extension EnvironmentValues {
    var persistenceController: PersistenceController? {
        get { self[PersistenceControllerKey.self] }
        set { self[PersistenceControllerKey.self] = newValue }
    }
}
