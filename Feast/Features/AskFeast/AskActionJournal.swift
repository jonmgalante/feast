import Foundation
import SQLite3
import CryptoKit
import Darwin

/// Local, lossless storage, independent of the Core Data / CloudKit collection.
/// No payload cache and no lifetime count/byte ceiling. Only a bounded page of
/// IDs and one bounded entry are decoded at a time. Chat deletion never erases it.
@MainActor final class AskActionJournal {
    static let maximumEntryBytes=8*1024*1024
    static let pageSize=64
    let legacyURL:URL
    var directory:URL {legacyURL.appendingPathExtension("journal-v2")}
    var databaseURL:URL {directory.appendingPathComponent("actions.sqlite3")}
    var backupURL:URL {directory.appendingPathComponent("legacy-v1.json")}
    private var intentURL:URL {directory.appendingPathComponent("migration.json")}
    private var db:OpaquePointer?
    private var depth=0
    private var databaseIdentity:UInt64?
    private var checkedDataVersion:Int64?
    private var manifest:Manifest?
    private var backupStamp:Date?
    private struct Manifest:Codable,Equatable {
        var version=2
        let databaseID:String
        let legacyDigest:String?
        let legacyCount:Int
        // Deliberately decodable but unsupported by old readers. Never v1 data.
        var entries:[Int]=[]
    }
    private struct Header:Codable {
        let sequence:Int64,id:String,revision:Int64,phase:String
        let turn:String?,chat:String?,recovery:String?
        let dismissed:Int64,targetCount:Int64,payloadBytes:Int64,digest:String,targets:[String],images:[ImageReference]
    }
    private struct ImageReference:Codable {
        let phase:String,ordinal:Int64,digest:String,bytes:Int64
    }
    private enum Value {case text(String),integer(Int64),blob(Data),null}
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
#if FEAST_TESTS
    /// Faults are per store, never global, and never ship in the app.
    var fault:((String)throws->Void)?
    private(set) var decodedPayloads=0
    private(set) var largestIDPage=0
    private(set) var maximumTargetFullScanSteps:Int32=0
    func testMaximumPages(_ pages:Int64?=nil)throws {
        let limit=try pages ?? scalar("PRAGMA page_count")
        _ = try scalar("PRAGMA max_page_count=\(limit)")
    }
#endif
    init(url:URL) {legacyURL=url}
    deinit {if let db {sqlite3_close_v2(db)}}
    func boundary(_ point:String)throws {
#if FEAST_TESTS
        try fault?(point)
#endif
    }
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    private func fail() -> AskChangeError {.journal}
    private func protected(_ url:URL,directory:Bool=false)throws {
        // Preserve the legacy Application Support backup-inclusion policy.
        // The DB, marker, migration manifest and backup must travel together.
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
#endif
    }
    private func syncDirectory(_ url:URL)throws {
        try boundary("directory-sync")
        let fd=open(url.path,O_RDONLY);guard fd>=0 else {throw fail()};defer {close(fd)}
        guard fsync(fd)==0 else {throw fail()}
    }
    private func syncFile(_ url:URL)throws {
        try boundary("file-sync")
        let fd=open(url.path,O_RDONLY);guard fd>=0 else {throw fail()};defer {close(fd)}
        guard fsync(fd)==0 else {throw fail()}
    }
    /// Synchronized, same-directory rename. A failed final sync is an unknown
    /// outcome, never permission to proceed with a collection mutation.
    private func write(_ data:Data,to url:URL,immutable:Bool=false)throws {
        let temp=url.deletingLastPathComponent().appendingPathComponent(".journal-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        try boundary("file-write")
        try data.write(to:temp,options:.withoutOverwriting);try protected(temp);try syncFile(temp)
        guard try Data(contentsOf:temp)==data else {throw fail()}
        if immutable {
            if link(temp.path,url.path) != 0 {
                guard errno==EEXIST,try Data(contentsOf:url)==data else {throw fail()}
            }
            // Immutable to this implementation: never replaced or rewritten.
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:url.path)
        } else {guard rename(temp.path,url.path)==0 else {throw fail()}}
        try protected(url);try syncDirectory(url.deletingLastPathComponent())
    }
    /// A process-wide file lock spans intent -> collection save -> receipt,
    /// including reads that reconcile intents. SQLite transactions alone cannot
    /// protect that two-store protocol. Nested facade calls share this lock.
    func withLock<T>(_ work:()throws->T)throws->T {
        if depth>0 {return try work()}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try protected(directory,directory:true)
        let lock=directory.appendingPathComponent("writer.lock")
        let fd=open(lock.path,O_CREAT|O_RDWR,0o600);guard fd>=0 else {throw fail()}
        defer {flock(fd,LOCK_UN);close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else {throw fail()};try protected(lock)
        depth=1;defer {depth=0}
        try openIfPresent(create:false)
        return try work()
    }
    private func statement<T>(_ sql:String,_ values:[Value]=[],_ work:(OpaquePointer)throws->T)throws->T {
        guard let db else {throw fail()};var s:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&s,nil)==SQLITE_OK,let s else {throw fail()};defer {sqlite3_finalize(s)}
        for (i,v) in values.enumerated() {
            let status:Int32
            switch v {
            case .text(let text):status=sqlite3_bind_text(s,Int32(i+1),text,-1,transient)
            case .integer(let n):status=sqlite3_bind_int64(s,Int32(i+1),n)
            case .blob(let data):status=data.withUnsafeBytes {sqlite3_bind_blob(s,Int32(i+1),$0.baseAddress,Int32(data.count),transient)}
            case .null:status=sqlite3_bind_null(s,Int32(i+1))
            }
            guard status==SQLITE_OK else {throw fail()}
        }
        return try work(s)
    }
    private func execute(_ sql:String,_ values:[Value]=[])throws {try statement(sql,values) {guard sqlite3_step($0)==SQLITE_DONE else {throw fail()}}}
    private func scalar(_ sql:String,_ values:[Value]=[])throws->Int64 {try statement(sql,values) {guard sqlite3_step($0)==SQLITE_ROW else {throw fail()};return sqlite3_column_int64($0,0)}}
    private func string(_ s:OpaquePointer,_ index:Int32)->String? {guard sqlite3_column_type(s,index) != SQLITE_NULL,let p=sqlite3_column_text(s,index) else {return nil};return String(cString:p)}
    private func textScalar(_ sql:String)throws->String {try statement(sql) {guard sqlite3_step($0)==SQLITE_ROW,let value=string($0,0) else {throw fail()};return value}}
    private func connect(create:Bool)throws {
        guard db==nil else {return}
        var connection:OpaquePointer?
        let flags=SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX|(create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(databaseURL.path,&connection,flags,nil)==SQLITE_OK,let connection else {if let connection {sqlite3_close_v2(connection)};throw fail()}
        db=connection
        do {
            sqlite3_busy_timeout(connection,5000)
            try execute("PRAGMA foreign_keys=ON")
            // DELETE mode avoids persistent WAL/SHM files. The protected parent
            // also covers a transient rollback journal and any recovery sidecars.
            guard try textScalar("PRAGMA journal_mode=DELETE")=="delete" else {throw fail()}
            try execute("PRAGMA synchronous=FULL");try execute("PRAGMA fullfsync=ON")
            try execute("PRAGMA cache_size=-1024");try execute("PRAGMA temp_store=MEMORY")
            try protected(databaseURL)
            databaseIdentity=(try FileManager.default.attributesOfItem(atPath:databaseURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        }catch {sqlite3_close_v2(connection);db=nil;throw error}
    }
    private func legacyBytes()throws->Data {
        guard let size=try legacyURL.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=8*1024*1024 else {throw fail()}
        return try Data(contentsOf:legacyURL)
    }
    private func decodeLegacy(_ data:Data)throws->AskChangeArchive {
        let old=try JSONDecoder().decode(AskChangeArchive.self,from:data)
        guard old.version==1,old.entries.count<=200,Set(old.entries.map(\.id)).count==old.entries.count,Set(old.entries.compactMap(\.recoveryOperationID)).count==old.entries.compactMap(\.recoveryOperationID).count,old.entries.allSatisfy(AskCollectionChangeEngine.validEntry) else {throw fail()}
        return old
    }
    private func openIfPresent(create:Bool)throws {
        let fm=FileManager.default
        if let manifest,db != nil {
            guard fm.fileExists(atPath:legacyURL.path),fm.fileExists(atPath:databaseURL.path),fm.fileExists(atPath:intentURL.path),
                  try readManifest()==manifest,
                  try JSONDecoder().decode(Manifest.self,from:legacyBytes())==manifest,
                  try textScalar("SELECT database_id FROM journal_meta WHERE singleton=1")==manifest.databaseID,
                  (try fm.attributesOfItem(atPath:databaseURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value==databaseIdentity else {throw fail()}
            if let digest=manifest.legacyDigest {
                guard fm.fileExists(atPath:backupURL.path) else {throw fail()}
                let stamp=try backupURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
                if stamp != backupStamp {
                    guard let size=try backupURL.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=Self.maximumEntryBytes,Self.digest(try Data(contentsOf:backupURL))==digest else {throw fail()}
                    backupStamp=stamp
                }
            }
            try auditIfChanged();return
        }
        let hasLegacy=fm.fileExists(atPath:legacyURL.path),hasIntent=fm.fileExists(atPath:intentURL.path),hasDB=fm.fileExists(atPath:databaseURL.path)
        if !hasLegacy && !hasIntent && !hasDB && !create {return}
        let bytes=hasLegacy ? try legacyBytes() : nil
        let active=bytes.flatMap {try? JSONDecoder().decode(Manifest.self,from:$0)}
        var old:AskChangeArchive?
        if active==nil,let bytes {old=try decodeLegacy(bytes)}
        let intent:Manifest
        if hasIntent {
            intent=try readManifest()
            guard intent.version==2,intent.entries.isEmpty,UUID(uuidString:intent.databaseID) != nil else {throw fail()}
            if let active {guard active==intent,hasDB else {throw fail()}}
            else {guard intent.legacyDigest==bytes.map(Self.digest),intent.legacyCount==(old?.entries.count ?? 0) else {throw fail()}}
        } else {
            // Never infer empty history from an orphaned DB or activation marker.
            guard active==nil,!hasDB,!fm.fileExists(atPath:backupURL.path) else {throw fail()}
            intent=Manifest(databaseID:UUID().uuidString,legacyDigest:bytes.map(Self.digest),legacyCount:old?.entries.count ?? 0)
            try write(JSONEncoder().encode(intent),to:intentURL,immutable:true)
        }
        if let fingerprint=intent.legacyDigest {
            if !fm.fileExists(atPath:backupURL.path) {
                guard active==nil,let bytes,Self.digest(bytes)==fingerprint else {throw fail()}
                try write(bytes,to:backupURL,immutable:true)
            }
            guard let size=try backupURL.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=8*1024*1024,Self.digest(try Data(contentsOf:backupURL))==fingerprint else {throw fail()}
        }
        try boundary("migration-backup")
        try connect(create:active==nil)
        if active==nil {
            let tables=try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            if tables==0 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE journal_meta (singleton INTEGER PRIMARY KEY CHECK(singleton=1), database_id TEXT NOT NULL, generation INTEGER NOT NULL, entry_count INTEGER NOT NULL, digest TEXT NOT NULL)")
                    try execute("CREATE TABLE actions (sequence INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL, phase TEXT NOT NULL, turn_id TEXT, chat_id TEXT, dismissed INTEGER NOT NULL, recovery_key TEXT UNIQUE, target_count INTEGER NOT NULL, payload BLOB NOT NULL, digest TEXT NOT NULL, header_digest TEXT NOT NULL DEFAULT '')")
                    try execute("CREATE TABLE targets (target TEXT NOT NULL, sequence INTEGER NOT NULL REFERENCES actions(sequence), PRIMARY KEY(target,sequence)) WITHOUT ROWID")
                    try execute("CREATE INDEX actions_turn ON actions(turn_id,sequence)")
                    try execute("CREATE INDEX actions_chat ON actions(chat_id,sequence)")
                    try execute("CREATE INDEX targets_sequence ON targets(sequence,target)")
                    try execute("CREATE TABLE snapshots (digest TEXT PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID")
                    try execute("CREATE TABLE action_images (sequence INTEGER NOT NULL REFERENCES actions(sequence), phase TEXT NOT NULL, ordinal INTEGER NOT NULL, digest TEXT NOT NULL REFERENCES snapshots(digest), PRIMARY KEY(sequence,phase,ordinal)) WITHOUT ROWID")
                    try execute("INSERT INTO journal_meta VALUES(1,?,0,0,'')",[.text(intent.databaseID)])
                    for entry in old?.entries ?? [] {try insertRow(entry)}
                    // Migration is not a user mutation generation.
                    try execute("UPDATE journal_meta SET generation=0");try writeMeta()
                    try boundary("migration-before-commit")
                    try execute("COMMIT")
                }catch {try? execute("ROLLBACK");throw error}
            }
            guard try scalar("SELECT generation FROM journal_meta WHERE singleton=1")==0,
                  try scalar("SELECT entry_count FROM journal_meta WHERE singleton=1")==intent.legacyCount else {throw fail()}
            for (offset,entry) in (old?.entries ?? []).enumerated() {
                guard let saved=try load(id:entry.id),try encoded(saved)==encoded(entry),try scalar("SELECT sequence FROM actions WHERE id=?",[.text(entry.id.uuidString)])==offset+1 else {throw fail()}
                if let key=entry.recoveryOperationID {guard try recoveryID(key)==entry.id else {throw fail()}}
            }
            try audit(force:true);try syncFile(databaseURL);try syncDirectory(directory)
            try boundary("migration-database")
            // Recheck the exact source immediately before cutover. Old writers
            // are unsupported; a divergent stale archive is never re-imported.
            guard fm.fileExists(atPath:legacyURL.path)==hasLegacy,try (hasLegacy ? Data(contentsOf:legacyURL) : nil)==bytes else {throw fail()}
            try write(JSONEncoder().encode(intent),to:legacyURL)
            try boundary("migration-activated")
        }
        guard try textScalar("SELECT database_id FROM journal_meta WHERE singleton=1")==intent.databaseID else {throw fail()}
        try audit(force:true)
        // Visible bytes after a failed activation fsync are not proof of a
        // durable cutover. Establish it again before accepting any mutation.
        try syncFile(databaseURL);try syncDirectory(directory)
        try syncFile(legacyURL);try syncDirectory(legacyURL.deletingLastPathComponent())
        if intent.legacyDigest != nil {backupStamp=try backupURL.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate}
        manifest=intent
    }
    private func readManifest()throws->Manifest {
        guard let size=try intentURL.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=4096 else {throw fail()}
        return try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:intentURL))
    }
    private func auditIfChanged()throws {try audit(force:false)}
    private func audit(force:Bool)throws {
        let version=try scalar("PRAGMA data_version")
        guard force || checkedDataVersion != version else {return}
        guard try textScalar("PRAGMA integrity_check")=="ok",
              try scalar("SELECT count(*) FROM journal_meta")==1,
              try scalar("SELECT count(*) FROM actions")==scalar("SELECT entry_count FROM journal_meta WHERE singleton=1"),
              try scalar("SELECT coalesce(max(sequence),0) FROM actions")==scalar("SELECT entry_count FROM journal_meta WHERE singleton=1"),
              try scalar("SELECT count(*) FROM targets")==scalar("SELECT coalesce(sum(target_count),0) FROM actions"),
              try scalar("SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('actions_turn','actions_chat','targets_sequence')")==3 else {throw fail()}
        try statement("PRAGMA foreign_key_check") {guard sqlite3_step($0)==SQLITE_DONE else {throw fail()}}
        try verifyMeta()
        // Negative indexed lookups are authority too: audit lightweight headers
        // before trusting them. A changed key/turn/target must not hide a receipt
        // just because its payload was never selected. No history payload load.
        try statement("SELECT sequence FROM actions ORDER BY sequence") {s in
            while true {
                let status=sqlite3_step(s);if status==SQLITE_DONE {break}
                guard status==SQLITE_ROW else {throw fail()}
                try verifyHeader(sequence:sqlite3_column_int64(s,0))
            }
        }
        checkedDataVersion=version
    }
    private func metaDigest()throws->String {
        try statement("SELECT database_id,generation,entry_count FROM journal_meta WHERE singleton=1") {s in
            guard sqlite3_step(s)==SQLITE_ROW,let id=string(s,0),UUID(uuidString:id) != nil else {throw fail()}
            let generation=sqlite3_column_int64(s,1),count=sqlite3_column_int64(s,2)
            guard generation>=0,count>=0 else {throw fail()}
            return Self.digest(Data("\(id):\(generation):\(count)".utf8))
        }
    }
    private func writeMeta()throws {try execute("UPDATE journal_meta SET digest=? WHERE singleton=1",[.text(try metaDigest())])}
    private func verifyMeta()throws {guard try metaDigest()==textScalar("SELECT digest FROM journal_meta WHERE singleton=1") else {throw fail()}}
    private func header(sequence:Int64)throws->(Header,String) {
        try statement("SELECT id,revision,phase,turn_id,chat_id,recovery_key,dismissed,target_count,length(payload),digest,header_digest FROM actions WHERE sequence=?",[.integer(sequence)]) {s in
            guard sqlite3_step(s)==SQLITE_ROW,let id=string(s,0),let phase=string(s,2),let digest=string(s,9),let checksum=string(s,10) else {throw fail()}
            let h=Header(sequence:sequence,id:id,revision:sqlite3_column_int64(s,1),phase:phase,turn:string(s,3),chat:string(s,4),recovery:string(s,5),dismissed:sqlite3_column_int64(s,6),targetCount:sqlite3_column_int64(s,7),payloadBytes:sqlite3_column_int64(s,8),digest:digest,targets:try targetPage(sequence:sequence),images:try imageReferences(sequence:sequence))
            return (h,checksum)
        }
    }
    private func headerDigest(_ header:Header)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        return Self.digest(try encoder.encode(header))
    }
    private func verifyHeader(sequence:Int64)throws {
        let (h,digest)=try header(sequence:sequence)
        guard h.sequence>0,UUID(uuidString:h.id) != nil,h.revision>=0,h.payloadBytes>0,h.payloadBytes<=Self.maximumEntryBytes,h.targetCount==h.targets.count,try headerDigest(h)==digest else {throw fail()}
    }
    private func writeHeader(sequence:Int64)throws {
        let (h,_)=try header(sequence:sequence)
        try execute("UPDATE actions SET header_digest=? WHERE sequence=?",[.text(try headerDigest(h)),.integer(sequence)])
    }
    private func encoded<T:Encodable>(_ value:T)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    /// A receipt's three image sets are independent immutable evidence, not a
    /// growing monolithic envelope. The Undo budget is derived from its exact
    /// before image plus the maximum encoding of the updatedAt timestamp that
    /// restoration introduces; preserved legacy strings never need truncation.
    private func undoBudget(_ entry:AskChangeEntry)throws->Int {
        var bytes=0
        for image in entry.before {
            var dates=image.dates;dates["updatedAt"]=Date(timeIntervalSinceReferenceDate:-Double.greatestFiniteMagnitude)
            let future=AskChangeSnapshot(entity:image.entity,id:image.id,store:image.store,strings:image.strings,dates:dates,links:image.links)
            bytes += try encoded(future).count
        }
        return max(Self.maximumEntryBytes,bytes)
    }
    private func parts(_ entry:AskChangeEntry)throws->(Data,[(String,[Data])]) {
        guard AskCollectionChangeEngine.validEntry(entry) else {throw fail()}
        var thin=entry;thin.before=[];thin.after=[];thin.undoAfter=entry.undoAfter==nil ? nil : []
        let payload=try encoded(thin);guard payload.count<=Self.maximumEntryBytes else {throw fail()}
        var sets:[(String,[Data])]=[]
        for (phase,images) in [("before",Optional(entry.before)),("after",Optional(entry.after)),("undo",entry.undoAfter)] {
            guard let images else {continue}
            let data=try images.map {try encoded($0)}
            let limit=try phase=="undo" ? undoBudget(entry) : Self.maximumEntryBytes
            guard data.reduce(0,{$0+$1.count})<=limit else {throw fail()}
            sets.append((phase,data))
        }
        return (payload,sets)
    }
    private func ensureFutureMetadataFits(_ entry:AskChangeEntry)throws {
        var future=entry;future.before=[];future.after=[];future.undoAfter=[]
        future.phase="undo-intent";future.action.state = .needsConfirmation
        future.action.undoable=false;future.action.committedChange=false;future.recoveryDismissed=false
        if entry.proposal.operation=="create",future.action.targetIDs.isEmpty {
            future.action.targetIDs=["00000000-0000-0000-0000-000000000000"]
        }
        guard try encoded(future).count<=Self.maximumEntryBytes else {throw fail()}
    }
    private func imageReferences(sequence:Int64)throws->[ImageReference] {
        try statement("SELECT i.phase,i.ordinal,i.digest,length(s.payload) FROM action_images i LEFT JOIN snapshots s ON i.digest=s.digest WHERE i.sequence=? ORDER BY i.phase,i.ordinal",[.integer(sequence)]) {s in
            var values:[ImageReference]=[]
            while true {
                let status=sqlite3_step(s);if status==SQLITE_DONE {return values}
                guard status==SQLITE_ROW,let phase=string(s,0),["before","after","undo"].contains(phase),let digest=string(s,2),sqlite3_column_type(s,3) != SQLITE_NULL,values.count<3000 else {throw fail()}
                values.append(.init(phase:phase,ordinal:sqlite3_column_int64(s,1),digest:digest,bytes:sqlite3_column_int64(s,3)))
            }
        }
    }
    private func writeImages(sequence:Int64,sets:[(String,[Data])])throws {
        // References change only inside the same CAS transaction as the receipt.
        // Immutable snapshot blobs are never deleted, including superseded intent
        // evidence, dismissed chats, and successfully undone actions.
        try execute("DELETE FROM action_images WHERE sequence=?",[.integer(sequence)])
        for (phase,images) in sets {
            for (ordinal,data) in images.enumerated() {
                let digest=Self.digest(data)
                try execute("INSERT OR IGNORE INTO snapshots(digest,payload) VALUES(?,?)",[.text(digest),.blob(data)])
                guard try snapshotBytes(digest)==data else {throw fail()}
                try execute("INSERT INTO action_images VALUES(?,?,?,?)",[.integer(sequence),.text(phase),.integer(Int64(ordinal)),.text(digest)])
            }
        }
    }
    private func snapshotBytes(_ digest:String)throws->Data {
        try statement("SELECT payload FROM snapshots WHERE digest=?",[.text(digest)]) {s in
            guard sqlite3_step(s)==SQLITE_ROW else {throw fail()}
            let length=sqlite3_column_bytes(s,0)
            // A restored snapshot can add one bounded updatedAt representation.
            guard length>0,length<=Self.maximumEntryBytes+128,let raw=sqlite3_column_blob(s,0) else {throw fail()}
            let data=Data(bytes:raw,count:Int(length));guard Self.digest(data)==digest else {throw fail()};return data
        }
    }
    private func readImages(sequence:Int64,phase:String)throws->[AskChangeSnapshot] {
        let refs=try imageReferences(sequence:sequence).filter {$0.phase==phase}
        var images:[AskChangeSnapshot]=[]
        for (ordinal,ref) in refs.enumerated() {
            guard ref.ordinal==ordinal else {throw fail()}
            images.append(try JSONDecoder().decode(AskChangeSnapshot.self,from:snapshotBytes(ref.digest)))
        }
        return images
    }
    private func targetIDs(_ entry:AskChangeEntry)->[String] {
        Set(entry.action.targetIDs+entry.proposal.targetIDs+(entry.proposal.operation=="create" ? entry.after.map(\.id) : [])).sorted()
    }
    private func values(_ e:AskChangeEntry,_ data:Data)->[Value] {
        [.text(e.phase),e.action.originatingTurn.map {.text($0.uuidString)} ?? .null,e.chatID.map {.text($0.uuidString)} ?? .null,.integer(e.recoveryDismissed==true ? 1 : 0),e.recoveryOperationID.map {.text($0)} ?? .null,.integer(Int64(targetIDs(e).count)),.blob(data),.text(Self.digest(data))]
    }
    private func insertRow(_ entry:AskChangeEntry)throws {
        let (data,sets)=try parts(entry),sequence=try scalar("SELECT entry_count+1 FROM journal_meta WHERE singleton=1")
        try execute("INSERT INTO actions(sequence,id,revision,phase,turn_id,chat_id,dismissed,recovery_key,target_count,payload,digest) VALUES(?,?,0,?,?,?,?,?,?,?,?)",[.integer(sequence),.text(entry.id.uuidString)]+values(entry,data))
        for target in targetIDs(entry) {try execute("INSERT INTO targets VALUES(?,?)",[.text(target),.integer(sequence)])}
        try writeImages(sequence:sequence,sets:sets)
        try writeHeader(sequence:sequence)
        try execute("UPDATE journal_meta SET entry_count=entry_count+1,generation=generation+1 WHERE singleton=1");try writeMeta()
    }
    private func transaction(_ work:()throws->Void,verify:()throws->Bool)throws {
        try openIfPresent(create:false)
        try execute("BEGIN IMMEDIATE")
        var commitAttempted=false
        do {
            try boundary("write");try work();try boundary("before-commit")
            commitAttempted=true
            try execute("COMMIT");try boundary("after-commit")
        }catch {
            // COMMIT can have an unknown outcome. Roll back only an open
            // transaction, then inspect the actual durable candidate. No cache
            // is promoted and no write is blindly replayed.
            if let db,sqlite3_get_autocommit(db)==0 {try? execute("ROLLBACK")}
            guard commitAttempted,let connection=db,sqlite3_get_autocommit(connection) != 0 else {throw error}
            // Do not establish an unknown outcome from the writer connection's
            // page cache. Reopen, validate, and inspect the durable candidate.
            guard sqlite3_close(connection)==SQLITE_OK else {throw error}
            db=nil;checkedDataVersion=nil
            try connect(create:false);try audit(force:true)
            guard let manifest,try textScalar("SELECT database_id FROM journal_meta WHERE singleton=1")==manifest.databaseID,try verify() else {throw error}
            try syncFile(databaseURL);try syncDirectory(directory)
        }
    }
    func insert(_ entry:AskChangeEntry)throws {
        _ = try parts(entry) // Reject before publishing a fresh store/entry.
        try ensureFutureMetadataFits(entry)
        try openIfPresent(create:true)
        let generation=try scalar("SELECT generation FROM journal_meta WHERE singleton=1")
        try transaction({
            guard try scalar("SELECT generation FROM journal_meta WHERE singleton=1")==generation else {throw AskChangeError.conflict}
            try insertRow(entry)
        },verify:{guard let actual=try self.load(id:entry.id) else {return false};return try actual.revision==0 && self.encoded(actual)==self.encoded(entry)})
    }
    @discardableResult func replace(_ entry:AskChangeEntry,expectedPhase:String)throws->AskChangeEntry {
        let (data,sets)=try parts(entry),next=entry.revision+1
        // Also applies to a prepared legacy entry before any collection commit.
        if entry.phase=="intent" {try ensureFutureMetadataFits(entry)}
        try transaction({
            try execute("UPDATE actions SET revision=?,phase=?,turn_id=?,chat_id=?,dismissed=?,recovery_key=?,target_count=?,payload=?,digest=? WHERE id=? AND revision=? AND phase=?",[.integer(next)]+values(entry,data)+[.text(entry.id.uuidString),.integer(entry.revision),.text(expectedPhase)])
            guard sqlite3_changes(db)==1 else {throw AskChangeError.conflict}
            let seq=try scalar("SELECT sequence FROM actions WHERE id=?",[.text(entry.id.uuidString)])
            try execute("DELETE FROM targets WHERE sequence=?",[.integer(seq)])
            for target in targetIDs(entry) {try execute("INSERT INTO targets VALUES(?,?)",[.text(target),.integer(seq)])}
            try writeImages(sequence:seq,sets:sets)
            try writeHeader(sequence:seq)
            try execute("UPDATE journal_meta SET generation=generation+1 WHERE singleton=1");try writeMeta()
        },verify:{guard let actual=try self.load(id:entry.id) else {return false};return try actual.revision==next && self.encoded(actual)==self.encoded(entry)})
        var result=entry;result.revision=next;return result
    }
    func dismiss(chat:UUID)throws {
        guard db != nil else {return}
        let generation=try scalar("SELECT generation FROM journal_meta WHERE singleton=1")
        try transaction({
            try visit(.chat(chat)) {id in
                guard var entry=try load(id:id) else {throw fail()}
                entry.recoveryDismissed=true
                let (data,_)=try parts(entry)
                try execute("UPDATE actions SET revision=revision+1,dismissed=1,payload=?,digest=? WHERE id=? AND revision=?",[.blob(data),.text(Self.digest(data)),.text(id.uuidString),.integer(entry.revision)])
                guard sqlite3_changes(db)==1 else {throw AskChangeError.conflict}
                try writeHeader(sequence:scalar("SELECT sequence FROM actions WHERE id=?",[.text(id.uuidString)]));return true
            }
            try execute("UPDATE journal_meta SET generation=generation+1 WHERE singleton=1");try writeMeta()
        },verify:{try self.scalar("SELECT generation FROM journal_meta WHERE singleton=1")==generation+1 && self.scalar("SELECT count(*) FROM actions WHERE chat_id=? AND dismissed=0",[.text(chat.uuidString)])==0})
    }
    func load(id:UUID)throws->AskChangeEntry? {
        guard db != nil else {return nil}
        return try statement("SELECT sequence,revision,phase,turn_id,chat_id,dismissed,recovery_key,target_count,payload,digest FROM actions WHERE id=?",[.text(id.uuidString)]) {s in
            let status=sqlite3_step(s);if status==SQLITE_DONE {return nil};guard status==SQLITE_ROW else {throw fail()}
            try verifyHeader(sequence:sqlite3_column_int64(s,0))
            let size=sqlite3_column_bytes(s,8)
            guard size>0,size<=Self.maximumEntryBytes,let blob=sqlite3_column_blob(s,8) else {throw fail()}
            let data=Data(bytes:blob,count:Int(size));guard Self.digest(data)==string(s,9) else {throw fail()}
            var entry=try JSONDecoder().decode(AskChangeEntry.self,from:data)
            guard entry.before.isEmpty,entry.after.isEmpty,entry.undoAfter==nil || entry.undoAfter!.isEmpty else {throw fail()}
            let sequence=sqlite3_column_int64(s,0)
            entry.before=try readImages(sequence:sequence,phase:"before")
            entry.after=try readImages(sequence:sequence,phase:"after")
            if entry.undoAfter != nil {entry.undoAfter=try readImages(sequence:sequence,phase:"undo")}
            else {guard try !imageReferences(sequence:sequence).contains(where:{$0.phase=="undo"}) else {throw fail()}}
            _ = try parts(entry)
#if FEAST_TESTS
            decodedPayloads+=1
#endif
            guard AskCollectionChangeEngine.validEntry(entry),entry.id==id,entry.phase==string(s,2),entry.action.originatingTurn?.uuidString==string(s,3),entry.chatID?.uuidString==string(s,4),(entry.recoveryDismissed==true ? 1 : 0)==sqlite3_column_int(s,5),entry.recoveryOperationID==string(s,6) else {throw fail()}
            let targets=try targetPage(sequence:sqlite3_column_int64(s,0))
            guard targets==targetIDs(entry),targets.count==sqlite3_column_int(s,7) else {throw fail()}
            entry.revision=sqlite3_column_int64(s,1);guard entry.revision>=0 else {throw fail()};return entry
        }
    }
    private func targetPage(sequence:Int64)throws->[String] {
        try statement("SELECT target FROM targets WHERE sequence=? ORDER BY target",[.integer(sequence)]) {s in
            var targets:[String]=[]
            while true {let r=sqlite3_step(s);if r==SQLITE_DONE {return targets};guard r==SQLITE_ROW,let target=string(s,0),targets.count<=Self.maximumEntryBytes/36 else {throw fail()};targets.append(target)}
        }
    }
    func recoveryID(_ key:String)throws->UUID? {
        guard db != nil else {return nil}
        return try statement("SELECT id FROM actions WHERE recovery_key=?",[.text(key)]) {s in let r=sqlite3_step(s);if r==SQLITE_DONE {return nil};guard r==SQLITE_ROW,let text=string(s,0),let id=UUID(uuidString:text) else {throw fail()};return id}
    }
    enum Query {case all,turn(UUID),chat(UUID),target(String)}
    /// Returns IDs only; callers decode each row on demand. Mutation of a phase
    /// does not change the stable sequence cursor or cause skipped receipts.
    func page(_ query:Query,after:Int64=0,descending:Bool=false)throws->[(Int64,UUID)] {
        guard db != nil else {return []}
        var values:[Value]=[],filter:String
        var source="SELECT sequence,id FROM actions"
        switch query {
        case .all:filter="1=1"
        case .turn(let id):filter="turn_id=?";values=[.text(id.uuidString)]
        case .chat(let id):filter="chat_id=?";values=[.text(id.uuidString)]
        case .target(let target):
            // Walk the (target,sequence) primary key directly. An IN subquery
            // could materialize every historical match before applying LIMIT.
            source="SELECT sequence,(SELECT id FROM actions WHERE actions.sequence=targets.sequence) FROM targets"
            filter="target=?";values=[.text(target)]
        }
        filter += descending ? " AND sequence<?" : " AND sequence>?";values.append(.integer(descending && after==0 ? Int64.max : after))
        return try statement(source+" WHERE "+filter+" ORDER BY sequence "+(descending ? "DESC" : "ASC")+" LIMIT \(Self.pageSize)",values) {s in
            var result:[(Int64,UUID)]=[]
            while true {let r=sqlite3_step(s);if r==SQLITE_DONE {break};guard r==SQLITE_ROW,let text=string(s,1),let id=UUID(uuidString:text) else {throw fail()};result.append((sqlite3_column_int64(s,0),id))}
#if FEAST_TESTS
            largestIDPage=max(largestIDPage,result.count)
            if case .target = query {maximumTargetFullScanSteps=max(maximumTargetFullScanSteps,sqlite3_stmt_status(s,SQLITE_STMTSTATUS_FULLSCAN_STEP,0))}
#endif
            return result
        }
    }
    func visit(_ query:Query,descending:Bool=false,_ visit:(UUID)throws->Bool)throws {
        var cursor:Int64=0
        while true {
            let page=try page(query,after:cursor,descending:descending);if page.isEmpty {return}
            for (sequence,id) in page {cursor=sequence;if try !visit(id) {return}}
        }
    }
}
