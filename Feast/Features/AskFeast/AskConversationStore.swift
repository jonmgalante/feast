import Foundation
import CryptoKit
import Darwin

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
    // Absent in older histories: use neutral stopped copy rather than guessing a cause.
    let interrupted:Bool?
    init(_ turn: AskTurn) {
        id = turn.id; mode = turn.request.mode; question = turn.request.text; context = turn.request.previousQuestion
        response = turn.response ?? .init(summary: "", candidates: []); sources = turn.sources
        if case .failed(let message)=turn.status {failure=String(message.prefix(2000))}else{failure=nil}
        stopped=turn.status == .stopped ? true : nil
        interrupted=turn.status == .stopped && turn.wasInterrupted ? true : nil
    }
    var turn: AskTurn { .init(id: id, request: .init(mode: mode, text: question, fromOCR: false, previousQuestion: context,performanceID:id), response: response, sources: sources, status: failure.map { .failed($0) } ?? (stopped==true ? .stopped : .complete), wasInterrupted: interrupted == true) }
}
struct AskConversationSnapshot: Codable {
    static let maximumTurns=100
    var version = 1
    var draft = ""
    var turns: [AskArchivedTurn] = []
    /// Present only for an interrupted request's synthesized composer fallback.
    /// Old archives have no provenance and are never cleared by a guess.
    var fallbackDraftTurnID:UUID? = nil
}
struct AskChatArchive: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var conversation: AskConversationSnapshot
    var lastActivityAt:Date? = nil
    /// Nil in older archives; only an explicit Rename marks a title as manual.
    var hasCustomTitle:Bool? = nil
}
extension AskChatArchive {
    private enum CodingKeys:String,CodingKey {case id,title,updatedAt,conversation,lastActivityAt,hasCustomTitle}
    init(from decoder:any Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id)
        title=try c.decodeIfPresent(String.self,forKey:.title) ?? "New chat"
        updatedAt=try c.decodeIfPresent(Date.self,forKey:.updatedAt) ?? .distantPast
        conversation=try c.decode(AskConversationSnapshot.self,forKey:.conversation)
        lastActivityAt=try c.decodeIfPresent(Date.self,forKey:.lastActivityAt)
        hasCustomTitle=try c.decodeIfPresent(Bool.self,forKey:.hasCustomTitle)
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
    enum Preservation {case canonical,pending,unsaved}
    static let maximumPendingBytes=16*1024*1024
    private static let maximumPieceBytes=8*1024*1024,maximumManifestBytes=1024*1024,maximumPendingTurns=5000
    var pendingDirectory:URL {url.appendingPathExtension("pending-history-v1")}
    private var pendingURL:URL {pendingDirectory.appendingPathComponent("current.json")}
    private var blobsURL:URL {pendingDirectory.appendingPathComponent("payloads")}
    private(set) var preservation:Preservation = .canonical
    private(set) var maintenanceWarning:String?
    private(set) var unsavedNotice:String?
    private var noticeURL:URL {pendingDirectory.appendingPathComponent("unsaved.json")}
    private struct UnsavedNotice:Codable {var version=1;let id:UUID,token:Token,titles:[String];var unresolvedRemoval:Bool?=nil}
    private var ownedNotices=Set<UUID>()
    private struct Token:Hashable,Codable {let canonical:String,manifest:String}
    private struct Piece:Codable,Hashable {let digest:String,bytes:Int}
    private struct TurnPiece:Codable {let id:UUID,piece:Piece}
    private struct PendingChat:Codable {
        let id:UUID,title:String,updatedAt:Date,lastActivityAt:Date?,version:Int,fallbackDraftTurnID:UUID?
        let draft:Piece,turns:[TurnPiece]
        var hasCustomTitle:Bool? = nil
    }
    private struct PendingLibrary:Codable {let version:Int,activeID:UUID,chats:[PendingChat],migration:AskChatMigration?}
    private struct PendingRoot:Codable {
        var version=1
        let revision:UUID,canonical:String,replacement:String?,library:PendingLibrary?,totalBytes:Int
        var removedChatIDs:[UUID]?=nil
        var retired:[Piece]?=nil
        var pieces:[Piece] {library?.chats.flatMap {[$0.draft]+$0.turns.map(\.piece)} ?? []}
    }
    private struct SealedRoot:Codable {let payload:Data,digest:String}
    private struct State {let token:Token,canonical:Data?,manifest:Data?,root:PendingRoot?}
    private var expected=Set<Token>()
    private var committed:Token?
    private var writerID:UUID?
    private struct UnresolvedRemoval {let id:UUID,owner:UUID,removed:Set<UUID>,tokens:Set<Token>}
    private var unresolved:UnresolvedRemoval?
    private var attempted=Set<Token>()
    private var cleanupFilesRemaining=32,cleanupBytesRemaining=8*1024*1024
    var unresolvedRemovalWarning:String? {unresolved == nil ? nil : "The saved outcome of Clear or Delete couldn’t be verified. Keep the app open. This screen and any newer edits are still available here; restarting may show the removal instead."}
    private func own(_ token:Token) {expected.insert(token);attempted.insert(token)}
#if FEAST_TESTS
    var historyFault:((String)throws->Void)?
    private(set) var historyBytesWritten=0
    private(set) var historyCleanupFilesInspected=0
    private(set) var historyCleanupBytesRead=0
#endif
    private func boundary(_ point:String)throws {
#if FEAST_TESTS
        try historyFault?(point)
#endif
    }
    private static func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting = .sortedKeys;return try e.encode(value)}
    private func readFile(_ path:URL,maximum:Int,exactSize:Int?=nil)throws->Data? {
        let fd=Darwin.open(path.path,O_RDONLY|O_NOFOLLOW)
        if fd<0 {if errno==ENOENT {return nil};throw AskHistoryError.unreadable}
        defer{Darwin.close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,(info.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG),info.st_size>=0,info.st_size<=off_t(maximum) else{throw AskHistoryError.unreadable}
        if let exactSize {guard exactSize>=0,exactSize<=maximum,info.st_size==off_t(exactSize) else{throw AskHistoryError.unreadable}}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let bytes=try handle.read(upToCount:exactSize ?? (maximum+1)) ?? Data()
        guard bytes.count==Int(info.st_size) else{throw AskHistoryError.unreadable}
        if let exactSize {
            var after=stat()
            guard fstat(fd,&after)==0,after.st_size==off_t(exactSize) else{throw AskHistoryError.unreadable}
        }
        return bytes
    }
    private func state()throws->State {
        let canonical=try readFile(url,maximum:8*1024*1024),manifest=try readFile(pendingURL,maximum:2*Self.maximumManifestBytes)
        var root:PendingRoot?
        if let manifest {
            let envelope=try JSONDecoder().decode(SealedRoot.self,from:manifest)
            guard envelope.payload.count<=Self.maximumManifestBytes,Self.fingerprint(envelope.payload)==envelope.digest else{throw AskHistoryError.unreadable}
            let value=try JSONDecoder().decode(PendingRoot.self,from:envelope.payload)
            guard value.version==1 else{throw AskHistoryError.unreadable};root=value
        }
        return .init(token:.init(canonical:canonical.map(Self.fingerprint) ?? "absent",manifest:manifest.map(Self.fingerprint) ?? "absent"),canonical:canonical,manifest:manifest,root:root)
    }
    /// Equality-only recheck of an already decoded/validated authority. Never
    /// returns or adopts a new token. Initial/successor state reads and the
    /// independent whole-library equality/payload verification remain required.
    private func verifyUnchanged(_ token:Token)throws {
        let canonical=try readFile(url,maximum:8*1024*1024),manifest=try readFile(pendingURL,maximum:2*Self.maximumManifestBytes)
        let observed=Token(canonical:canonical.map(Self.fingerprint) ?? "absent",manifest:manifest.map(Self.fingerprint) ?? "absent")
        guard observed==token else{throw AskHistoryError.unreadable}
    }
    private func protect(_ path:URL)throws {
        var path=path,values=URLResourceValues();values.isExcludedFromBackup=true;try path.setResourceValues(values)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:path.path)
#endif
    }
    private func sync(_ path:URL)throws {
        try boundary("sync")
        let fd=Darwin.open(path.path,O_RDONLY);guard fd>=0 else{throw AskHistoryError.unreadable};defer{Darwin.close(fd)}
        guard fsync(fd)==0 else{throw AskHistoryError.unreadable}
    }
    private func withHistoryLock<T>(_ body:()throws->T)throws->T {
        let folder=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        // Never exclude the shared AskFeast parent: its action journal has a
        // different, deliberately backup-included policy.
        let lock=url.appendingPathExtension("history-lock"),fd=Darwin.open(lock.path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else{throw AskHistoryError.unreadable};defer{Darwin.close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else{throw AskHistoryError.unreadable};defer{flock(fd,LOCK_UN)}
        try protect(lock);return try body()
    }
    private func atomic(_ data:Data,to destination:URL,point:String)throws {
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".history-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temporary)}
        try boundary(point+"-before-write")
        try Data().write(to:temporary,options:.withoutOverwriting);try protect(temporary)
        let handle=try FileHandle(forWritingTo:temporary)
        do {try handle.write(contentsOf:data);try handle.close()}catch {try? handle.close();throw error}
        try sync(temporary)
        guard try Data(contentsOf:temporary)==data else{throw AskHistoryError.unreadable}
        try boundary(point+"-before-rename")
        guard Darwin.rename(temporary.path,destination.path)==0 else{throw AskHistoryError.unreadable}
#if FEAST_TESTS
        historyBytesWritten+=data.count
#endif
        try boundary(point+"-after-rename");try sync(destination.deletingLastPathComponent());try boundary(point+"-after-sync")
    }
    private func rootBytes(_ root:PendingRoot)throws->Data {
        let payload=try Self.encode(root);guard payload.count<=Self.maximumManifestBytes else{throw AskHistoryError.limit}
        return try Self.encode(SealedRoot(payload:payload,digest:Self.fingerprint(payload)))
    }
    private func validatePiece(_ piece:Piece)throws {
        // SHA-256 filenames are ASCII lowercase hex. Do not construct a URL
        // merely to validate thousands of non-authoritative cleanup references.
        guard piece.digest.utf8.count==64,piece.digest.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),piece.bytes>=0,piece.bytes<=Self.maximumPieceBytes else{throw AskHistoryError.unreadable}
    }
    private func payloadURL(_ piece:Piece)throws->URL {
        try validatePiece(piece)
        return blobsURL.appendingPathComponent(piece.digest+".blob")
    }
    private func validate(_ root:PendingRoot)throws {
        guard (root.removedChatIDs?.count ?? 0)<=50,Set(root.removedChatIDs ?? []).count==(root.removedChatIDs?.count ?? 0),(0...Self.maximumPendingBytes).contains(root.totalBytes) else{throw AskHistoryError.unreadable}
        guard (root.retired?.count ?? 0)<=10_100,Set((root.retired ?? []).map(\.digest)).count==(root.retired?.count ?? 0) else{throw AskHistoryError.unreadable}
        do {_ = try retiredPlan(root.retired ?? [],keeping:root.pieces)}catch {throw AskHistoryError.unreadable}
        guard let library=root.library else {guard root.totalBytes==0,root.replacement==nil else{throw AskHistoryError.unreadable};return}
        guard library.version==2,(1...50).contains(library.chats.count),Set(library.chats.map(\.id)).count==library.chats.count,
              library.chats.contains(where:{$0.id==library.activeID}),library.chats.reduce(0,{$0+$1.turns.count})<=Self.maximumPendingTurns else{throw AskHistoryError.unreadable}
        var total=0
        for chat in library.chats {
            guard chat.version==1,!chat.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,chat.title.count<=80,Set(chat.turns.map(\.id)).count==chat.turns.count else{throw AskHistoryError.unreadable}
            for piece in [chat.draft]+chat.turns.map(\.piece) {
                let path=try payloadURL(piece)
                guard total<=Self.maximumPendingBytes-piece.bytes else{throw AskHistoryError.unreadable};total+=piece.bytes
                var info=stat()
                guard lstat(path.path,&info)==0,(info.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG),info.st_size==off_t(piece.bytes) else{throw AskHistoryError.unreadable}
            }
        }
        guard total==root.totalBytes else{throw AskHistoryError.unreadable}
    }
    private func payload(_ piece:Piece)throws->Data {
        guard let data=try readFile(payloadURL(piece),maximum:Self.maximumPieceBytes),data.count==piece.bytes,Self.fingerprint(data)==piece.digest else{throw AskHistoryError.unreadable};return data
    }
    private func materialize(_ root:PendingRoot)throws->AskChatLibrary {
        try validate(root);guard let library=root.library else{throw AskHistoryError.unreadable}
        let chats=try library.chats.map {chat->AskChatArchive in
            guard let draft=String(data:try payload(chat.draft),encoding:.utf8) else{throw AskHistoryError.unreadable}
            let turns=try chat.turns.map {entry->AskArchivedTurn in
                let turn=try JSONDecoder().decode(AskArchivedTurn.self,from:payload(entry.piece));guard turn.id==entry.id else{throw AskHistoryError.unreadable};return turn
            }
            return .init(id:chat.id,title:chat.title,updatedAt:chat.updatedAt,conversation:.init(version:chat.version,draft:draft,turns:turns,fallbackDraftTurnID:chat.fallbackDraftTurnID),lastActivityAt:chat.lastActivityAt,hasCustomTitle:chat.hasCustomTitle)
        }
        return .init(version:library.version,activeID:library.activeID,chats:chats,migration:library.migration)
    }
    private func authoritative(_ state:State)throws->AskChatLibrary {
        guard let root=state.root else{return try loadCanonicalLibrary()}
        guard root.canonical==state.token.canonical || root.replacement==state.token.canonical else{throw AskHistoryError.unreadable}
        if root.library != nil {return try materialize(root)}
        try validate(root);return try loadCanonicalLibrary()
    }
    func loadLibrary(forSession owner:UUID?=nil)throws->AskChatLibrary {
        try withHistoryLock {
            let current=try state(),value=try authoritative(current),loaded=try state()
            try synchronize(loaded)
            // Inspection of a live Session’s store must not grant that Session
            // a newer foreign revision or revoke its exact unresolved capability.
            if writerID != nil,owner==nil {return value}
            if let owner {writerID=owner;unresolved=nil}
            ownedNotices=[];expected=[loaded.token];committed=nil;maintenanceWarning=nil
            if !(loaded.root?.retired ?? []).isEmpty {maintenanceWarning="An older local history copy still needs cleanup."}
            preservation=loaded.root?.library == nil ? .canonical : .pending
            unsavedNotice=noticeMessage(for:loaded.token)
            return value
        }
    }
    private func readNotice()throws->UnsavedNotice? {
        guard let bytes=try readFile(noticeURL,maximum:64*1024) else{return nil}
        let envelope=try JSONDecoder().decode(SealedRoot.self,from:bytes)
        guard Self.fingerprint(envelope.payload)==envelope.digest else{throw AskHistoryError.unreadable}
        let notice=try JSONDecoder().decode(UnsavedNotice.self,from:envelope.payload)
        guard notice.version==1,notice.titles.count<=50,notice.titles.allSatisfy({$0.count<=80}) else{throw AskHistoryError.unreadable};return notice
    }
    private func noticeMessage(for token:Token)->String? {
        do {
            guard let notice=try readNotice() else{return nil}
            if notice.unresolvedRemoval==true {return "A previous Clear or Delete couldn’t be verified before the app closed. The saved history is shown. Newer changes on that screen may not have been saved."}
            // Legacy notice labels are never displayed: collection access may
            // have changed since the notice was saved.
            if notice.token==token {return "Only earlier saved history was restored. Newer changes were not saved before the app closed."}
            return "An earlier session reported changes that were not saved. The currently saved history is shown."
        }catch {return "An unsaved-history notice couldn’t be verified. Only the earlier saved history is shown."}
    }
    private func recordUnsaved(_ value:AskChatLibrary) {
        try? withHistoryLock {
            let visible=try state();guard expected.contains(visible.token) else{return}
            // An imported notice describes RAM already lost in another session.
            // A new failure/success cannot acknowledge that earlier loss.
            let previous=try readNotice()
            if let previous,!ownedNotices.contains(previous.id) {return}
            let notice=UnsavedNotice(id:previous?.id ?? UUID(),token:visible.token,titles:[],unresolvedRemoval:unresolved == nil ? nil : true),payload=try Self.encode(notice)
            ownedNotices=[notice.id]
            guard payload.count<=32*1024 else{return}
            try FileManager.default.createDirectory(at:pendingDirectory,withIntermediateDirectories:true);try protect(pendingDirectory)
            try atomic(Self.encode(SealedRoot(payload:payload,digest:Self.fingerprint(payload))),to:noticeURL,point:"unsaved-notice")
            try sync(pendingDirectory.deletingLastPathComponent())
        }
    }
    private func clearNotice(known:Set<Token>,current:Token) {
        do {
            // Only this still-live store can know it just saved its own failed
            // RAM candidate. A notice imported after restart is historical and
            // survives automatic writes/navigation until the user dismisses it.
            if let notice=try readNotice(),known.contains(notice.token),ownedNotices.contains(notice.id) {
                try FileManager.default.removeItem(at:noticeURL);try sync(pendingDirectory);ownedNotices.remove(notice.id)
            }
            unsavedNotice=noticeMessage(for:current)
        }catch {maintenanceWarning="An older unsaved-status notice couldn’t be cleared."}
    }
    func acknowledgeUnsavedNotice()->Bool {
        do {return try withHistoryLock {
            let current=try state();guard expected.contains(current.token),try readNotice() != nil else{return false}
            try FileManager.default.removeItem(at:noticeURL);try sync(pendingDirectory);unsavedNotice=nil;return true
        }}catch{return false}
    }
    private func retiredPlan(_ pieces:[Piece],keeping:[Piece])throws->[Piece] {
        let live=Set(keeping.map(\.digest));var result:[String:Piece]=[:],ordered:[Piece]=[],total=0
        for piece in pieces {
            try validatePiece(piece)
            guard !live.contains(piece.digest) else{throw AskHistoryError.unreadable}
            if let old=result[piece.digest] {guard old==piece else{throw AskHistoryError.unreadable};continue}
            guard result.count<10_100,total<=2*Self.maximumPendingBytes-piece.bytes else{throw AskHistoryError.limit}
            result[piece.digest]=piece;ordered.append(piece);total+=piece.bytes
        }
        return ordered
    }
    private func obsolete(_ old:[Piece],keeping:[Piece])throws->[Piece] {
        let live=Set(keeping.map(\.digest))
        return try retiredPlan(old.filter {!live.contains($0.digest)},keeping:keeping)
    }
    private func stage(_ value:AskChatLibrary,canonical:String,replacement:String?,removed:Set<UUID>,prior:PendingRoot?,fits:Bool)throws->PendingRoot {
        guard value.version==2,(1...50).contains(value.chats.count),Set(value.chats.map(\.id)).count==value.chats.count,value.chats.contains(where:{$0.id==value.activeID}),value.chats.reduce(0,{$0+$1.conversation.turns.count})<=Self.maximumPendingTurns else{throw AskHistoryError.limit}
        var total=0,blobs:[String:Data]=[:]
        func piece(_ bytes:Data)throws->Piece {
            guard bytes.count<=Self.maximumPieceBytes,total<=Self.maximumPendingBytes-bytes.count else{throw AskHistoryError.limit}
            total+=bytes.count;let hash=Self.fingerprint(bytes);blobs[hash]=bytes;return .init(digest:hash,bytes:bytes.count)
        }
        let chats=try value.chats.map {chat->PendingChat in
            guard chat.conversation.version==1,chat.conversation.draft.utf8.count<=Self.maximumPieceBytes,!chat.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,chat.title.count<=80,Set(chat.conversation.turns.map(\.id)).count==chat.conversation.turns.count else{throw AskHistoryError.limit}
            return .init(id:chat.id,title:chat.title,updatedAt:chat.updatedAt,lastActivityAt:chat.lastActivityAt,version:chat.conversation.version,fallbackDraftTurnID:chat.conversation.fallbackDraftTurnID,draft:try piece(Data(chat.conversation.draft.utf8)),turns:try chat.conversation.turns.map {.init(id:$0.id,piece:try piece(Self.encode($0)))},hasCustomTitle:chat.hasCustomTitle)
        }
        var root=PendingRoot(revision:UUID(),canonical:canonical,replacement:replacement,library:.init(version:value.version,activeID:value.activeID,chats:chats,migration:value.migration),totalBytes:total,removedChatIDs:removed.isEmpty ? nil : removed.sorted {$0.uuidString<$1.uuidString})
        let debt=prior?.retired ?? []
        root.retired=try obsolete(debt+(prior?.pieces ?? []),keeping:root.pieces)
        _ = try rootBytes(root) // Preflight both authority and retirement metadata before writing.
        if fits { _ = try rootBytes(PendingRoot(revision:UUID(),canonical:replacement!,replacement:nil,library:nil,totalBytes:0,removedChatIDs:root.removedChatIDs,retired:try obsolete(debt+(prior?.pieces ?? [])+root.pieces,keeping:[]))) }
        for folder in [pendingDirectory,blobsURL] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try protect(folder)}
        for (hash,data) in blobs {
            let path=blobsURL.appendingPathComponent(hash+".blob")
            if let old=try readFile(path,maximum:Self.maximumPieceBytes) {guard old==data else{throw AskHistoryError.unreadable}}
            else {try atomic(data,to:path,point:"payload")}
        }
        try sync(pendingDirectory);try sync(pendingDirectory.deletingLastPathComponent());try validate(root)
        return root
    }
    private func activate(_ root:PendingRoot,canonical:String)throws->Token {
        let bytes=try rootBytes(root),token=Token(canonical:canonical,manifest:Self.fingerprint(bytes))
        own(token) // A visible rename followed by failed sync is ours, not an unknown foreign revision.
        try atomic(bytes,to:pendingURL,point:root.library==nil ? "retire" : "activate")
        guard try state().token==token else{throw AskHistoryError.unreadable};return token
    }
    /// The plan is non-authoritative bookkeeping, never a history fallback.
    /// It remains sealed until every exact obsolete payload is removed and synced.
    private func finishMaintenance(_ initial:State)throws->State {
        guard let root=initial.root else{return initial}
        let debt=root.retired ?? []
        var remaining:[Piece]=[],failed:[Piece]=[],processed=0
        for piece in debt {
            // Bound filesystem work across the entire save, including catch
            // reconciliation. Remaining debt is still in the sealed authority.
            guard cleanupFilesRemaining>0,piece.bytes<=cleanupBytesRemaining else{remaining.append(piece);continue}
            cleanupFilesRemaining-=1;cleanupBytesRemaining-=piece.bytes;processed+=1
#if FEAST_TESTS
            historyCleanupFilesInspected+=1
#endif
            do {
                let path=try payloadURL(piece)
                if let bytes=try readFile(path,maximum:piece.bytes,exactSize:piece.bytes) {
#if FEAST_TESTS
                    historyCleanupBytesRead+=bytes.count
#endif
                    guard bytes.count==piece.bytes,Self.fingerprint(bytes)==piece.digest else{throw AskHistoryError.unreadable}
                    try boundary("cleanup");try FileManager.default.removeItem(at:path)
                }
            }catch {failed.append(piece)}
        }
        // Keep every divergent ref, but rotate attempted failures behind debt
        // not visited this pass. The sealed order survives later saves/restart.
        remaining += failed
        if processed>0 || root.library==nil {
            do {try sync(blobsURL)}catch {
                maintenanceWarning="An older local history copy couldn’t be cleared.";return initial
            }
        }
        if !remaining.isEmpty {maintenanceWarning="An older local history copy still needs cleanup."}
        if root.library==nil,remaining.isEmpty {
            try verifyUnchanged(initial.token)
            let clean=Token(canonical:initial.token.canonical,manifest:"absent");own(clean)
            try boundary("marker-before-remove");try FileManager.default.removeItem(at:pendingURL)
            try boundary("marker-after-remove");try sync(pendingDirectory);try boundary("marker-after-sync")
            let result=try state();guard result.token==clean else{throw AskHistoryError.unreadable};return result
        }
        guard remaining != debt else{return initial}
        let revised=PendingRoot(revision:UUID(),canonical:root.canonical,replacement:root.replacement,library:root.library,totalBytes:root.totalBytes,removedChatIDs:root.removedChatIDs,retired:remaining.isEmpty ? nil : remaining)
        let bytes=try rootBytes(revised),token=Token(canonical:initial.token.canonical,manifest:Self.fingerprint(bytes));own(token)
        try verifyUnchanged(initial.token)
        try atomic(bytes,to:pendingURL,point:"cleanup-plan")
        let result=try state();guard result.token==token else{throw AskHistoryError.unreadable};return result
    }
    private func finish(_ visible:State,candidate:Data)throws->Preservation {
        // Reuse the exact candidate encoding, but retain the independent whole
        // authoritative-library decode/encode equality check before any cleanup.
        guard expected.contains(visible.token),try Self.encode(authoritative(visible))==candidate else{throw AskHistoryError.unreadable}
        try synchronize(visible)
        try verifyUnchanged(visible.token)
        let final=try finishMaintenance(visible)
        try boundary("final-before-sync");try sync(url.deletingLastPathComponent().deletingLastPathComponent());try boundary("final-after-sync")
        try verifyUnchanged(final.token)
        if let root=final.root,!(root.removedChatIDs ?? []).isEmpty,root.replacement != final.token.canonical {
            maintenanceWarning="The chat was removed from pending history, but an older local copy couldn’t be cleared."
        }
        clearNotice(known:expected.union([final.token]),current:final.token)
        expected=[final.token];committed=final.token;unresolved=nil
        return final.root?.library == nil ? .canonical : .pending
    }
    /// Canonical admission is unchanged. Pending is exact preservation only.
    @discardableResult func preserveLibrary(_ value:AskChatLibrary,removingChatIDs:Set<UUID>=[],session owner:UUID?=nil)->Preservation {
        guard writerID==owner else{return .unsaved}
        committed=nil;maintenanceWarning=nil;attempted=[];cleanupFilesRemaining=32;cleanupBytesRemaining=8*1024*1024
#if FEAST_TESTS
        historyCleanupFilesInspected=0;historyCleanupBytesRead=0
#endif
        var candidateBytes:Data?
        let previousUnresolved=unresolved
        var operationRemoved=removingChatIDs
        if let previousUnresolved,previousUnresolved.owner==owner {operationRemoved.formUnion(previousUnresolved.removed)}
        do {return try withHistoryLock {
            guard writerID==owner else{throw AskHistoryError.unreadable}
            let prior=try state();guard expected.contains(prior.token) else{throw AskHistoryError.unreadable}
            let superseding=previousUnresolved.map {$0.owner==owner && $0.tokens.contains(prior.token)} ?? false
            if let root=prior.root {guard root.canonical==prior.token.canonical || root.replacement==prior.token.canonical else{throw AskHistoryError.unreadable};try validate(root)}
            let canonical=Self.valid(value) ? try Self.encode(value) : nil
            candidateBytes=canonical
            let fits=canonical.map {$0.count<=8*1024*1024} ?? false
            var canonicalWrite=fits ? canonical : nil
            var inherited=Set(prior.root?.removedChatIDs ?? [])
            if superseding {inherited.subtract(previousUnresolved!.removed)}
            var removed=removingChatIDs.union(inherited)
            guard removed.isDisjoint(with:Set(value.chats.map(\.id))) else{throw AskHistoryError.unreadable}
            if let original=prior.canonical,!removed.isEmpty {
                var baseline=try JSONDecoder().decode(AskChatLibrary.self,from:original)
                removed.formIntersection(Set(baseline.chats.map(\.id)))
                if !fits,!removed.isEmpty {
                    baseline.chats.removeAll {removed.contains($0.id)}
                    if baseline.chats.isEmpty {
                        let active=value.chats.first {$0.id==value.activeID}!
                        baseline.chats=[.init(id:active.id,title:active.title,updatedAt:active.updatedAt,conversation:.init(),lastActivityAt:active.lastActivityAt,hasCustomTitle:active.hasCustomTitle)]
                    }
                    if !baseline.chats.contains(where:{$0.id==baseline.activeID}) {baseline.activeID=baseline.chats[0].id}
                    if let migration=baseline.migration,removed.contains(migration.chatID) {baseline.migration=nil}
                    canonicalWrite=try Self.encode(baseline)
                    guard canonicalWrite!.count<=8*1024*1024 else{throw AskHistoryError.limit}
                }
            } else {removed=[]}
            if fits,prior.root==nil,removingChatIDs.isEmpty,let bytes=canonical {
                let token=Token(canonical:Self.fingerprint(bytes),manifest:prior.token.manifest);own(token)
                try atomic(bytes,to:url,point:"canonical");guard try state().token==token else{throw AskHistoryError.unreadable}
                preservation=try finish(state(),candidate:candidateBytes!);return preservation
            }
            let next=try stage(value,canonical:prior.token.canonical,replacement:canonicalWrite.map(Self.fingerprint),removed:removed,prior:prior.root,fits:fits)
            if candidateBytes==nil {candidateBytes=try Self.encode(value)}
            var token=try activate(next,canonical:prior.token.canonical)
            if let bytes=canonicalWrite {
                let newCanonical=Self.fingerprint(bytes);own(.init(canonical:newCanonical,manifest:token.manifest))
                try atomic(bytes,to:url,point:"canonical")
                guard try readFile(url,maximum:8*1024*1024)==bytes else{throw AskHistoryError.unreadable}
                token = .init(canonical:newCanonical,manifest:token.manifest)
                if fits {
                    let retired=try obsolete((next.retired ?? [])+next.pieces,keeping:[])
                    _ = try activate(.init(revision:UUID(),canonical:newCanonical,replacement:nil,library:nil,totalBytes:0,removedChatIDs:next.removedChatIDs,retired:retired),canonical:newCanonical)
                }
            }
            preservation=try finish(state(),candidate:candidateBytes!);return preservation
        }}catch {
            // A rename may have succeeded before an acknowledgement/sync error.
            // Only our exact known candidate can be promoted, after fresh full
            // verification and synchronization. Never retry a foreign revision.
            if let candidateBytes,let recovered=try? withHistoryLock({()throws->Preservation in
                guard writerID==owner else{throw AskHistoryError.unreadable}
                return try finish(state(),candidate:candidateBytes)
            }) {preservation=recovered;return recovered}
            // A capability exists only for the exact visible candidate of this
            // still-live Session. It is neither persisted nor inferred from IDs.
            // Superseding it saves that Session's full current RAM, including any
            // newer edits, against the current owned old/new canonical digest.
            if let owner,writerID==owner,!operationRemoved.isEmpty,
               let visible=try? withHistoryLock({try state()}),
               attempted.contains(visible.token) || previousUnresolved?.tokens.contains(visible.token)==true {
                unresolved = .init(id:previousUnresolved?.id ?? UUID(),owner:owner,removed:operationRemoved,tokens:[visible.token])
                expected=[visible.token]
            }
            if unresolved==nil,removingChatIDs.isEmpty,writerID==owner {
                // An admission failure must not permanently trap already-known
                // cleanup debt. This never commits the rejected RAM candidate.
                try? withHistoryLock {
                    let visible=try state();guard expected.contains(visible.token) else{return}
                    _ = try authoritative(visible);try synchronize(visible)
                    let cleaned=try finishMaintenance(visible);expected=[cleaned.token]
                }
            }
            // There is no asynchronous write left after the lock exits. Keep
            // only the exact observed owned outcome, not every failed revision.
            if let visible=try? withHistoryLock({try state()}),expected.contains(visible.token) {expected=[visible.token]}
            recordUnsaved(value);preservation = .unsaved;return .unsaved
        }
    }
    private func synchronize(_ current:State)throws {
        if let root=current.root {
            try validate(root)
            for piece in root.pieces {_ = try payload(piece);try sync(payloadURL(piece))}
            try sync(pendingURL);try sync(blobsURL);try sync(pendingDirectory)
        }
        if current.canonical != nil {try sync(url)}
        try sync(url.deletingLastPathComponent());try sync(url.deletingLastPathComponent().deletingLastPathComponent())
    }
    /// Releases redundant checkpoints only for this exact successful revision.
    func durableLibrary()throws->AskChatLibrary {
        try withHistoryLock {
            let current=try state();guard let committed,current.token==committed else{throw AskHistoryError.unreadable}
            let value=try authoritative(current)
            try synchronize(current)
            try verifyUnchanged(committed);return value
        }
    }
    private static func valid(_ value:AskConversationSnapshot) -> Bool {
        value.version == 1 && value.draft.count <= 4000 && value.turns.count <= AskConversationSnapshot.maximumTurns &&
        Set(value.turns.map(\.id)).count == value.turns.count &&
        value.turns.allSatisfy { $0.question.count <= 4000 && ($0.context?.count ?? 0) <= 2000 && $0.response.hasArchiveCompatibleBounds && $0.sources.count <= $0.response.maximumArchiveSources && ($0.response.publicResearch ?? []).allSatisfy {research in research.result.nativeEvidence.map {(try? $0.checked()) != nil} ?? true} }
    }
    private func loadCanonicalLibrary() throws -> AskChatLibrary {
        let source:URL
        if FileManager.default.fileExists(atPath:url.path) { source = url }
        else if let legacyURL, FileManager.default.fileExists(atPath:legacyURL.path) { source = legacyURL }
        else { return .empty() }
        guard let data=try readFile(source,maximum:8*1024*1024) else {throw AskHistoryError.unreadable}
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
            if !FileManager.default.fileExists(atPath:backup.path) {try FileManager.default.copyItem(at:url,to:backup);try protect(backup);try sync(backup);try sync(backup.deletingLastPathComponent())}
        }
        guard saveLibrary(library) else { throw AskHistoryError.unreadable }
        return library
    }
    private static func fingerprint(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    /// Explicit deletion of the migrated chat also removes its verified recovery copy, never a changed/new legacy file.
    func removeMigrationCopy(_ migration:AskChatMigration) -> Bool {
        let copy = legacyURL ?? url.appendingPathExtension("v1-backup")
        guard FileManager.default.fileExists(atPath:copy.path) else { return true }
        guard let data=try? readFile(copy,maximum:8*1024*1024),Self.fingerprint(data)==migration.fingerprint else{return false}
        do {try FileManager.default.removeItem(at:copy);try sync(copy.deletingLastPathComponent());return true}catch{return false}
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
