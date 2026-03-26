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
            return "Share City"
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
            if
                let rawValue = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
                let containerIdentifier = normalized(rawValue)
            {
                return CloudKitSyncConfiguration(containerIdentifier: containerIdentifier)
            }

            if
                let bundleIdentifier = normalized(bundle.bundleIdentifier ?? ""),
                let containerIdentifier = normalized("iCloud.\(bundleIdentifier)")
            {
                return CloudKitSyncConfiguration(containerIdentifier: containerIdentifier)
            }

            return nil
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
        case noCloudKitAccount
        case restrictedCloudKitAccount
        case cloudKitTemporarilyUnavailable
        case missingCloudKitContainer
        case missingSharedPersistentStore
        case missingPersistentStore
        case failedToPrepareShare
        case invalidInviteRecipient
        case shareParticipantNotFound
        case shareParticipantAlreadyAdded

        var isAvailabilityFailure: Bool {
            switch self {
            case .noCloudKitAccount, .restrictedCloudKitAccount, .cloudKitTemporarilyUnavailable:
                return true
            case
                    .unavailable,
                    .missingCloudKitContainer,
                    .missingSharedPersistentStore,
                    .missingPersistentStore,
                    .failedToPrepareShare,
                    .invalidInviteRecipient,
                    .shareParticipantNotFound,
                    .shareParticipantAlreadyAdded:
                return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Feast couldn't access its CloudKit sharing stores right now. Try reopening Feast and trying again."
            case .noCloudKitAccount:
                return "Sign into iCloud on this iPhone and try sharing again."
            case .restrictedCloudKitAccount:
                return "iCloud sharing is restricted on this iPhone."
            case .cloudKitTemporarilyUnavailable:
                return "Feast couldn't reach iCloud right now. Check your network connection and try again."
            case .missingCloudKitContainer:
                return "Feast couldn't find its CloudKit container."
            case .missingSharedPersistentStore:
                return "Feast couldn't access the shared CloudKit store."
            case .missingPersistentStore:
                return "Feast couldn't determine which persistent store this city belongs to."
            case .failedToPrepareShare:
                return "Feast couldn't prepare sharing for this city."
            case .invalidInviteRecipient:
                return "Enter the Apple Account email address or phone number for the person you want to invite."
            case .shareParticipantNotFound:
                return "Feast couldn't find an iCloud sharing participant for that email address or phone number."
            case .shareParticipantAlreadyAdded:
                return "That person is already invited to this city."
            }
        }
    }

    private enum StoreKind {
        case local
        case privateCloudKit
        case sharedCloudKit
    }

    private enum ShareParticipantLookup {
        case emailAddress(String)
        case phoneNumber(String)

        init?(rawValue: String) {
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else {
                return nil
            }

            if trimmedValue.contains("@") {
                self = .emailAddress(trimmedValue)
                return
            }

            let normalizedPhoneNumber = Self.normalizedPhoneNumber(from: trimmedValue)
            guard !normalizedPhoneNumber.isEmpty else {
                return nil
            }

            self = .phoneNumber(normalizedPhoneNumber)
        }

        var kindDescription: String {
            switch self {
            case .emailAddress:
                return "email"
            case .phoneNumber:
                return "phone"
            }
        }

        private static func normalizedPhoneNumber(from rawValue: String) -> String {
            var normalizedPhoneNumber = ""

            for character in rawValue {
                if character.isNumber {
                    normalizedPhoneNumber.append(character)
                } else if character == "+", normalizedPhoneNumber.isEmpty {
                    normalizedPhoneNumber.append(character)
                }
            }

            let containsDigits = normalizedPhoneNumber.contains(where: \.isNumber)
            return containsDigits ? normalizedPhoneNumber : ""
        }
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

    private struct PersistentStoreLoadCompletion {
        let description: NSPersistentStoreDescription
        let error: NSError?
    }

    private struct PersistentStoreLoadFailure {
        let description: NSPersistentStoreDescription
        let error: NSError
    }

    private struct PersistentStoreLoadError: LocalizedError {
        let expectedStoreCount: Int
        let completions: [PersistentStoreLoadCompletion]

        var failures: [PersistentStoreLoadFailure] {
            completions.compactMap { completion in
                guard let error = completion.error else {
                    return nil
                }

                return PersistentStoreLoadFailure(description: completion.description, error: error)
            }
        }

        var errorDescription: String? {
            if failures.count == 1 {
                return failures[0].error.localizedDescription
            }

            return "Failed to load \(failures.count) of \(expectedStoreCount) persistent stores."
        }
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

            Self.logCloudKitStoreSetupFailure(
                containerIdentifier: preferredCloudKitSyncConfiguration.containerIdentifier,
                error: error
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
        let expectedStoreCount = container.persistentStoreDescriptions.count
        guard expectedStoreCount > 0 else {
            return
        }

        let dispatchGroup = DispatchGroup()
        let lock = NSLock()
        var completions: [PersistentStoreLoadCompletion] = []

        for _ in 0..<expectedStoreCount {
            dispatchGroup.enter()
        }

        container.loadPersistentStores { description, error in
            lock.lock()
            completions.append(
                PersistentStoreLoadCompletion(
                    description: description,
                    error: error as NSError?
                )
            )
            lock.unlock()
            dispatchGroup.leave()
        }

        dispatchGroup.wait()

        let loadError = PersistentStoreLoadError(
            expectedStoreCount: expectedStoreCount,
            completions: completions
        )
        if !loadError.failures.isEmpty {
            throw loadError
        }
    }

    private static func logCloudKitStoreSetupFailure(
        containerIdentifier: String,
        error: Error
    ) {
        logger.error(
            """
            CloudKit store setup failed for \(containerIdentifier, privacy: .public). Falling back to local storage.
            \(persistentStoreLoadDiagnostics(for: error), privacy: .public)
            """
        )
    }

    private static func persistentStoreLoadDiagnostics(for error: Error) -> String {
        if let loadError = error as? PersistentStoreLoadError {
            var lines = [
                "Persistent store load diagnostics:",
                "expectedStoreCount: \(loadError.expectedStoreCount)",
                "completedStoreCount: \(loadError.completions.count)",
                "failureCount: \(loadError.failures.count)"
            ]

            for (index, completion) in loadError.completions.enumerated() {
                lines.append("completion[\(index)] store: \(describeStoreDescription(completion.description))")

                if let error = completion.error {
                    lines.append("completion[\(index)] error:")
                    lines.append(contentsOf: formatNSError(error, indent: "  "))
                } else {
                    lines.append("completion[\(index)] error: none")
                }
            }

            return lines.joined(separator: "\n")
        }

        var lines = [
            "Persistent store load diagnostics:",
            "unexpected load error:"
        ]
        lines.append(contentsOf: formatNSError(error as NSError, indent: "  "))
        return lines.joined(separator: "\n")
    }

    private static func describeStoreDescription(_ description: NSPersistentStoreDescription) -> String {
        var components = [
            "role=\(storeRoleDescription(for: description))",
            "type=\(description.type)"
        ]

        if let url = description.url {
            components.append("url=\(url.path)")
        } else {
            components.append("url=nil")
        }

        if let configuration = description.configuration {
            components.append("configuration=\(configuration)")
        }

        if let containerIdentifier = description.cloudKitContainerOptions?.containerIdentifier {
            components.append("containerIdentifier=\(containerIdentifier)")
        }

        return components.joined(separator: ", ")
    }

    private static func storeRoleDescription(for description: NSPersistentStoreDescription) -> String {
        guard let cloudKitOptions = description.cloudKitContainerOptions else {
            return "local"
        }

        switch cloudKitOptions.databaseScope {
        case .private:
            return "private"
        case .shared:
            return "shared"
        case .public:
            return "public"
        @unknown default:
            return "unknown"
        }
    }

    private static func formatNSError(
        _ error: NSError,
        indent: String,
        visited: inout Set<ObjectIdentifier>
    ) -> [String] {
        let identifier = ObjectIdentifier(error)
        guard visited.insert(identifier).inserted else {
            return ["\(indent)<already visited \(error.domain) code=\(error.code)>"]
        }

        var lines = [
            "\(indent)domain: \(error.domain)",
            "\(indent)code: \(error.code)",
            "\(indent)localizedDescription: \(error.localizedDescription)",
            "\(indent)localizedFailureReason: \(error.localizedFailureReason ?? "nil")"
        ]
        lines.append(contentsOf: formatUserInfo(error.userInfo, indent: indent))

        let nestedErrors = nestedErrors(in: error)
        if nestedErrors.isEmpty {
            lines.append("\(indent)nestedErrors: none")
        } else {
            for (index, nestedError) in nestedErrors.enumerated() {
                lines.append("\(indent)nestedError[\(index)]:")
                lines.append(
                    contentsOf: formatNSError(
                        nestedError,
                        indent: indent + "  ",
                        visited: &visited
                    )
                )
            }
        }

        return lines
    }

    private static func formatNSError(_ error: NSError, indent: String) -> [String] {
        var visited = Set<ObjectIdentifier>()
        return formatNSError(error, indent: indent, visited: &visited)
    }

    private static func formatUserInfo(_ userInfo: [String: Any], indent: String) -> [String] {
        guard !userInfo.isEmpty else {
            return ["\(indent)userInfo: {}"]
        }

        let sortedKeys = userInfo.keys.sorted()
        var lines = ["\(indent)userInfo:"]
        for key in sortedKeys {
            let valueDescription = String(describing: userInfo[key]!)
            lines.append("\(indent)  \(key): \(valueDescription)")
        }

        return lines
    }

    private static func nestedErrors(in error: NSError) -> [NSError] {
        error.userInfo.values.flatMap { nestedErrors(from: $0) }
    }

    private static func nestedErrors(from value: Any) -> [NSError] {
        switch value {
        case let error as NSError:
            return [error]
        case let error as Error:
            return [error as NSError]
        case let errors as [NSError]:
            return errors
        case let errors as [Error]:
            return errors.map { $0 as NSError }
        case let dictionary as [AnyHashable: Error]:
            return dictionary.values.map { $0 as NSError }
        case let dictionary as [AnyHashable: NSError]:
            return Array(dictionary.values)
        default:
            return []
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
        guard let cloudKitContainer else {
            throw SharingError.missingCloudKitContainer
        }

        try await ensureCloudKitAccountAvailable(for: cloudKitContainer)

        guard supportsSharing else {
            throw SharingError.unavailable
        }

        let feastListName = feastList.displayName
        let feastListObjectID = feastList.objectID

        if let existingShare = try share(for: feastList) {
            existingShare[CKShare.SystemFieldKey.title] = feastListName as CKRecordValue
            existingShare.publicPermission = .none
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
                share.publicPermission = .none

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

    func inviteParticipant(
        matching rawLookupValue: String,
        to preparedShare: PreparedFeastListShare
    ) async throws {
        guard supportsSharing else {
            throw SharingError.unavailable
        }

        guard let lookup = ShareParticipantLookup(rawValue: rawLookupValue) else {
            throw SharingError.invalidInviteRecipient
        }

        Self.logger.log(
            "Looking up CloudKit share participant by \(lookup.kindDescription, privacy: .public) for city \(preparedShare.feastListName, privacy: .public)."
        )

        let participant: CKShare.Participant

        do {
            guard let resolvedParticipant = try await fetchShareParticipant(
                matching: lookup,
                in: preparedShare.container
            ) else {
                Self.logger.error(
                    "No CloudKit share participant found for \(lookup.kindDescription, privacy: .public) lookup when inviting collaborators to city \(preparedShare.feastListName, privacy: .public)."
                )
                throw SharingError.shareParticipantNotFound
            }

            participant = resolvedParticipant
        } catch let sharingError as SharingError {
            throw sharingError
        } catch {
            Self.logger.error(
                "CloudKit share participant lookup failed for \(lookup.kindDescription, privacy: .public) when inviting collaborators to city \(preparedShare.feastListName, privacy: .public). Error: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        if shareAlreadyContainsParticipant(participant, in: preparedShare.share) {
            Self.logger.log(
                "Skipping duplicate CloudKit participant invite for city \(preparedShare.feastListName, privacy: .public)."
            )
            throw SharingError.shareParticipantAlreadyAdded
        }

        participant.permission = .readWrite
        preparedShare.share.publicPermission = .none
        preparedShare.share.addParticipant(participant)

        do {
            try await persistUpdatedShare(
                preparedShare.share,
                forManagedObjectWith: preparedShare.feastListObjectID
            )
            Self.logger.log(
                "Persisted updated private share for city \(preparedShare.feastListName, privacy: .public) after inviting collaborator by \(lookup.kindDescription, privacy: .public)."
            )
        } catch {
            preparedShare.share.removeParticipant(participant)
            Self.logger.error(
                "Failed to persist updated private share for city \(preparedShare.feastListName, privacy: .public) after inviting collaborator by \(lookup.kindDescription, privacy: .public). Error: \(error.localizedDescription, privacy: .public)"
            )
            throw error
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

    private func fetchShareParticipant(
        matching lookup: ShareParticipantLookup,
        in container: CKContainer
    ) async throws -> CKShare.Participant? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare.Participant?, Error>) in
            let completionHandler: @Sendable (CKShare.Participant?, Error?) -> Void = { participant, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: participant)
                }
            }

            switch lookup {
            case let .emailAddress(emailAddress):
                container.fetchShareParticipant(
                    withEmailAddress: emailAddress,
                    completionHandler: completionHandler
                )
            case let .phoneNumber(phoneNumber):
                container.fetchShareParticipant(
                    withPhoneNumber: phoneNumber,
                    completionHandler: completionHandler
                )
            }
        }
    }

    private func shareAlreadyContainsParticipant(
        _ participant: CKShare.Participant,
        in share: CKShare
    ) -> Bool {
        guard let userRecordID = participant.userIdentity.userRecordID else {
            return false
        }

        return share.participants.contains { existingParticipant in
            existingParticipant.userIdentity.userRecordID == userRecordID
        }
    }

    private func ensureCloudKitAccountAvailable(for container: CKContainer) async throws {
        do {
            let accountStatus = try await cloudKitAccountStatus(for: container)

            switch accountStatus {
            case .available:
                return
            case .noAccount:
                throw SharingError.noCloudKitAccount
            case .restricted:
                throw SharingError.restrictedCloudKitAccount
            case .couldNotDetermine, .temporarilyUnavailable:
                throw SharingError.cloudKitTemporarilyUnavailable
            @unknown default:
                throw SharingError.cloudKitTemporarilyUnavailable
            }
        } catch let sharingError as SharingError {
            throw sharingError
        } catch let cloudKitError as CKError {
            switch cloudKitError.code {
            case .notAuthenticated:
                throw SharingError.noCloudKitAccount
            case .permissionFailure:
                throw SharingError.restrictedCloudKitAccount
            default:
                throw SharingError.cloudKitTemporarilyUnavailable
            }
        } catch {
            throw SharingError.cloudKitTemporarilyUnavailable
        }
    }

    private func cloudKitAccountStatus(for container: CKContainer) async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { accountStatus, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: accountStatus)
                }
            }
        }
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
