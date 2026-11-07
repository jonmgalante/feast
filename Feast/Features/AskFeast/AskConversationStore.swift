import Foundation
import CryptoKit

/// A separate, bounded local journal. Never stores photos, credentials or pending requests to replay.
struct AskArchivedTurn: Codable {
    let id: UUID
    let mode: AskMode
    let question: String
    let context: String?
    let response: AskResponse
    let sources: [AskSource]
    let failure:String?
    let stopped:Bool?
    init(_ turn: AskTurn) {
        id = turn.id; mode = turn.request.mode; question = turn.request.text; context = turn.request.previousQuestion
        response = turn.response ?? .init(summary: "", candidates: []); sources = turn.sources
        if case .failed(let message)=turn.status {failure=String(message.prefix(2000))}else{failure=nil}
        stopped=turn.status == .stopped ? true : nil
    }
    var turn: AskTurn { .init(id: id, request: .init(mode: mode, text: question, fromOCR: false, previousQuestion: context,performanceID:id), response: response, sources: sources, status: failure.map { .failed($0) } ?? (stopped==true ? .stopped : .complete)) }
}
struct AskConversationSnapshot: Codable {
    var version = 1
    var draft = ""
    var turns: [AskArchivedTurn] = []
}
struct AskChatArchive: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var conversation: AskConversationSnapshot
    var lastActivityAt:Date? = nil
}
extension AskChatArchive {
    private enum CodingKeys:String,CodingKey {case id,title,updatedAt,conversation,lastActivityAt}
    init(from decoder:any Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id)
        title=try c.decodeIfPresent(String.self,forKey:.title) ?? "New chat"
        updatedAt=try c.decodeIfPresent(Date.self,forKey:.updatedAt) ?? .distantPast
        conversation=try c.decode(AskConversationSnapshot.self,forKey:.conversation)
        lastActivityAt=try c.decodeIfPresent(Date.self,forKey:.lastActivityAt)
    }
}
struct AskChatMigration: Codable {
    let chatID: UUID
    let fingerprint: String
}
struct AskChatLibrary: Codable {
    var version = 2
    var activeID: UUID
    var chats: [AskChatArchive]
    var migration: AskChatMigration? = nil
    static func empty() -> Self {
        let chat = AskChatArchive(id:UUID(),title:"New chat",updatedAt:Date(),conversation:.init())
        return .init(activeID:chat.id,chats:[chat])
    }
}
enum AskHistoryError: LocalizedError {
    case unreadable, limit
    var errorDescription: String? {
        switch self {
        case .unreadable: "Chat history couldn’t be opened. Its saved file has been kept unchanged."
        case .limit: "Chat history is full. Delete an older chat to make room; nothing was removed automatically."
        }
    }
}
@MainActor final class AskConversationStore {
    let url: URL
    private let legacyURL: URL?
    init(url: URL, legacyURL: URL? = nil) { self.url = url; self.legacyURL = legacyURL }
    static func applicationStore() -> AskConversationStore? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("AskFeast")
        return .init(url:folder.appendingPathComponent("chats-v2.json"),legacyURL:folder.appendingPathComponent("conversation-v1.json"))
    }
    private static func valid(_ value:AskConversationSnapshot) -> Bool {
        value.version == 1 && value.draft.count <= 4000 && value.turns.count <= 100 &&
        Set(value.turns.map(\.id)).count == value.turns.count &&
        value.turns.allSatisfy { $0.question.count <= 4000 && ($0.context?.count ?? 0) <= 2000 && $0.response.summary.count <= 3000 && $0.response.candidates.count <= ($0.response.collectionPage != nil ? AskCollectionPage.maximumRenderedRecords : $0.response.usesLocalCatalog ? 200 : 6) && $0.response.paragraphs.count <= ($0.response.collectionPage != nil ? 4001 : $0.response.usesLocalCatalog ? 201 : 6) && $0.sources.count <= ($0.response.collectionPage != nil ? AskCollectionPage.maximumRenderedRecords : $0.response.usesLocalCatalog ? 200 : 60) && ($0.response.publicResearch ?? []).allSatisfy {research in research.result.nativeEvidence.map {(try? $0.checked()) != nil} ?? true} }
    }
    func loadLibrary() throws -> AskChatLibrary {
        let source:URL
        if FileManager.default.fileExists(atPath:url.path) { source = url }
        else if let legacyURL, FileManager.default.fileExists(atPath:legacyURL.path) { source = legacyURL }
        else { return .empty() }
        guard let size = try? source.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 8*1024*1024,
              let data = try? Data(contentsOf:source) else { throw AskHistoryError.unreadable }
        if let library = try? JSONDecoder().decode(AskChatLibrary.self,from:data) {
            guard Self.valid(library) else { throw AskHistoryError.unreadable }; return library
        }
        guard let old = try? JSONDecoder().decode(AskConversationSnapshot.self,from:data), Self.valid(old) else { throw AskHistoryError.unreadable }
        // Leave the legacy file intact. Commit the new representation before accepting any edits.
        let first = old.turns.first?.question.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let title = first.isEmpty ? "New chat" : first
        let savedAt=(try? source.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let chat = AskChatArchive(id:UUID(),title:String(title.prefix(80)),updatedAt:savedAt,conversation:old)
        let library = AskChatLibrary(activeID:chat.id,chats:[chat],migration:.init(chatID:chat.id,fingerprint:Self.fingerprint(data)))
        if source == url {
            let backup = url.appendingPathExtension("v1-backup")
            if !FileManager.default.fileExists(atPath:backup.path) { try FileManager.default.copyItem(at:url,to:backup) }
        }
        guard saveLibrary(library) else { throw AskHistoryError.unreadable }
        return library
    }
    private static func fingerprint(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    /// Explicit deletion of the migrated chat also removes its verified recovery copy, never a changed/new legacy file.
    func removeMigrationCopy(_ migration:AskChatMigration) -> Bool {
        let copy = legacyURL ?? url.appendingPathExtension("v1-backup")
        guard FileManager.default.fileExists(atPath:copy.path) else { return true }
        guard let data = try? Data(contentsOf:copy),Self.fingerprint(data) == migration.fingerprint else { return false }
        do { try FileManager.default.removeItem(at:copy);return true } catch { return false }
    }
    private static func valid(_ value:AskChatLibrary) -> Bool {
        value.version == 2 && (1...50).contains(value.chats.count) && Set(value.chats.map(\.id)).count == value.chats.count &&
        value.chats.contains { $0.id == value.activeID } && value.chats.allSatisfy { !$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.title.count <= 80 && valid($0.conversation) }
    }
    func load() -> AskConversationSnapshot {
        guard let library = try? loadLibrary() else { return .init() }
        return library.chats.first { $0.id == library.activeID }?.conversation ?? .init()
    }
    @discardableResult func saveLibrary(_ value:AskChatLibrary) -> Bool {
        guard Self.valid(value) else { return false }; return write(value)
    }
    /// Compatibility for existing single-conversation test fixtures. Product writes use saveLibrary.
    @discardableResult func save(_ value: AskConversationSnapshot) -> Bool {
        guard Self.valid(value) else { return false }; return write(value)
    }
    private func write<T:Encodable>(_ value:T) -> Bool {
        let started=DispatchTime.now().uptimeNanoseconds
        defer {AskPipelineScope.record(.persistence,since:started)}
        guard let data = try? JSONEncoder().encode(value),data.count <= 8*1024*1024 else { return false }
        do {
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:url,options:.atomic)
            var local=url; var resource=URLResourceValues();resource.isExcludedFromBackup=true;try local.setResourceValues(resource)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
#endif
            return true
        } catch { return false }
    }
    @discardableResult func clear() -> Bool {
        guard FileManager.default.fileExists(atPath:url.path) else { return true }
        do { try FileManager.default.removeItem(at:url);return true } catch { return false }
    }
}
