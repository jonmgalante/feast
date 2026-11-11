import Foundation
import SQLite3

/// Fixtures are new, isolated legacy files, never edits to an active v2 marker.
/// This deliberately exercises the real migration reader for compatibility tests.
@MainActor enum AskJournalTestSupport {
    static func legacyCopy(from engine:AskCollectionChangeEngine,to url:URL,edit:(inout [[String:Any]])throws->Void={_ in})throws {
        var entries:[AskChangeEntry]=[]
        try engine.journal.withLock {try engine.journal.visit(.all) {id in
            guard let entry=try engine.journal.load(id:id) else {throw AskChangeError.journal}
            entries.append(entry);return true
        }}
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(AskChangeArchive(entries:entries))) as! [String:Any]
        var raw=object["entries"] as! [[String:Any]];try edit(&raw);object["entries"]=raw
        try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:url,options:.withoutOverwriting)
    }
    static func sql(_ url:URL,_ sql:String)throws {
        var db:OpaquePointer?
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK,let db else {throw AskChangeError.journal}
        defer {sqlite3_close(db)}
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw AskChangeError.journal}
    }
    static func scalar(_ url:URL,_ sql:String)throws->Int64 {
        var db:OpaquePointer?,statement:OpaquePointer?
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,let db else {throw AskChangeError.journal}
        defer {sqlite3_close(db)}
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement else {throw AskChangeError.journal}
        defer {sqlite3_finalize(statement)}
        guard sqlite3_step(statement)==SQLITE_ROW else {throw AskChangeError.journal}
        return sqlite3_column_int64(statement,0)
    }
}
