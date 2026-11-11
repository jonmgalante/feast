import Foundation
import CryptoKit

@MainActor enum AskHistoryCleanupTests {
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    private static func root(_ store:AskConversationStore)throws->[String:Any] {
        let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:store.pendingDirectory.appendingPathComponent("current.json"))) as! [String:Any]
        return try JSONSerialization.jsonObject(with:Data(base64Encoded:envelope["payload"] as! String)!) as! [String:Any]
    }
    private static func write(_ root:[String:Any],store:AskConversationStore)throws {
        let payload=try JSONSerialization.data(withJSONObject:root,options:.sortedKeys)
        let bytes=try JSONSerialization.data(withJSONObject:["payload":payload.base64EncodedString(),"digest":digest(payload)],options:.sortedKeys)
        try bytes.write(to:store.pendingDirectory.appendingPathComponent("current.json"),options:.atomic)
    }
    static func run(directory:URL)throws {
        let folder=directory.appendingPathComponent("navigation-cleanup");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        func check(_ value:Bool,_ label:String){precondition(value,label);print("PASS history cleanup: "+label)}
        // Explicit synthetic protocol fixture: many obsolete, independently
        // hashed blobs, not a fabricated user response or an automatic expiry.
        let seed=AskConversationStore(url:folder.appendingPathComponent("debt.json"));var value=try seed.loadLibrary();value.chats[0].conversation.draft=String(repeating:"active ",count:700)
        check(seed.preserveLibrary(value) == .pending,"seed active pending authority")
        let blobs=seed.pendingDirectory.appendingPathComponent("payloads"),unowned=blobs.appendingPathComponent("unowned.blob")
        try Data("Never in a cleanup plan".utf8).write(to:unowned)
        var manifest=try root(seed),retired:[[String:Any]]=[]
        for i in 0..<9_500 {
            let data=Data("Previously authoritative obsolete fixture payload \(i)".utf8),hash=digest(data)
            try data.write(to:blobs.appendingPathComponent(hash+".blob"));retired.append(["digest":hash,"bytes":data.count])
        }
        manifest["retired"]=retired;try write(manifest,store:seed)
        check(try JSONSerialization.data(withJSONObject:manifest).count<1024*1024,"near retired-reference bound fits existing 1-MiB metadata envelope")
        let store=AskConversationStore(url:seed.url);_ = try store.loadLibrary()
        var times:[Double]=[]
        for i in 0..<3 {
            value.chats[0].conversation.draft=String(repeating:"active ",count:700)+" Edit \(i)"
            let start=DispatchTime.now().uptimeNanoseconds;check(store.preserveLibrary(value) == .pending,"newer current draft remains durable with bounded cleanup debt")
            times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
            check(store.historyCleanupFilesInspected<=32,"at most 32 filesystem payload inspections per entire save")
            check(store.maintenanceWarning != nil,"unfinished debt remains visible")
        }
        print("DIAGNOSTIC 9500-reference cleanup debt individual save ms \(times), worst \(times.max()!)")
        let reload=AskConversationStore(url:store.url),loaded=try reload.loadLibrary()
        check(Array(loaded.chats[0].conversation.draft.utf8)==Array(value.chats[0].conversation.draft.utf8) && reload.maintenanceWarning != nil,"newest draft and bounded unfinished debt survive restart")
        check(FileManager.default.fileExists(atPath:unowned.path),"cleanup never infers ownership from a directory listing")
        // Corrupt metadata is rejected before payload access, including Unicode
        // lookalikes and path forms that are not canonical SHA-256 identifiers.
        let intact=try root(store)
        for malformed in [String(repeating:"A",count:64),String(repeating:"g",count:64),String(repeating:"ａ",count:64),"../"+String(repeating:"a",count:61),"/"+String(repeating:"a",count:63),"%2f"+String(repeating:"a",count:61),String(repeating:"a",count:63),String(repeating:"a",count:65),String(repeating:"a",count:32)+"\0"+String(repeating:"a",count:31)] {
            var corrupt=intact;corrupt["retired"]=[["digest":malformed,"bytes":0]];try write(corrupt,store:store)
            do {_ = try AskConversationStore(url:store.url).loadLibrary();preconditionFailure("Malformed digest admitted")}catch {}
            check(FileManager.default.fileExists(atPath:unowned.path),"malformed Unicode/path/length digest rejected without filesystem cleanup")
        }
        for (label,refs) in [("count",(0..<10_101).map {["digest":String(format:"%064x",$0),"bytes":0] as [String:Any]}),("bytes",(0..<5).map {["digest":String(format:"%064x",$0),"bytes":8*1024*1024] as [String:Any]})] {
            var corrupt=intact;corrupt["retired"]=refs;try write(corrupt,store:store)
            do {_ = try AskConversationStore(url:store.url).loadLibrary();preconditionFailure("Retired metadata bound admitted")}catch {}
            check(true,"retired metadata "+label+" bound remains enforced")
        }
        // A claimed active ref in the debt list must fail before any deletion.
        var bad=intact
        let library=bad["library"] as! [String:Any],chat=(library["chats"] as! [[String:Any]])[0],active=chat["draft"] as! [String:Any]
        bad["retired"]=[active];try write(bad,store:store)
        do {_ = try AskConversationStore(url:store.url).loadLibrary();preconditionFailure("Active payload accepted as retired")}catch {}
        check(FileManager.default.fileExists(atPath:blobs.appendingPathComponent((active["digest"] as! String)+".blob").path),"active/nonobsolete payload is never removed")
        for boundary in ["cleanup","cleanup-plan-after-rename"] {
            let seed=AskConversationStore(url:folder.appendingPathComponent(boundary+".json"));var old=try seed.loadLibrary();old.chats[0].conversation.draft=String(repeating:"old ",count:1500)
            check(seed.preserveLibrary(old) == .pending,"seed failed cleanup boundary")
            var next=old;next.chats[0].conversation.draft=String(repeating:"new ",count:1500)
            var hit=false;seed.historyFault={point in if point==boundary {hit=true;throw CocoaError(.fileWriteUnknown)}}
            _ = seed.preserveLibrary(next);check(hit,"inject "+boundary)
            seed.historyFault=nil
            let reopened=AskConversationStore(url:seed.url);var current=try reopened.loadLibrary();current.chats[0].conversation.draft += " newest after restart"
            check(reopened.preserveLibrary(current) == .pending,"failed cleanup then restart and newer save retains authority")
            check(try (root(reopened)["retired"] as? [Any] ?? []).isEmpty,"exact obsolete cleanup obligation is eventually discharged")
            let files=try FileManager.default.contentsOfDirectory(at:reopened.pendingDirectory.appendingPathComponent("payloads"),includingPropertiesForKeys:nil)
            check(files.filter {$0.pathExtension=="blob"}.count==1,"old authoritative blobs actually removed, not merely forgotten")
        }
        do {
            let seed=AskConversationStore(url:folder.appendingPathComponent("corrupt-obsolete.json"));var value=try seed.loadLibrary();value.chats[0].conversation.draft=String(repeating:"old ",count:1500)
            let oldBytes=Data(value.chats[0].conversation.draft.utf8);check(seed.preserveLibrary(value) == .pending,"seed exact obsolete hash proof")
            let oldPath=seed.pendingDirectory.appendingPathComponent("payloads/"+digest(oldBytes)+".blob")
            seed.historyFault={if $0=="cleanup" {throw CocoaError(.fileWriteUnknown)}};value.chats[0].conversation.draft=String(repeating:"new ",count:1500)
            check(seed.preserveLibrary(value) == .pending,"current authority saved while cleanup fails")
            var damaged=oldBytes;damaged[0] ^= 1;try damaged.write(to:oldPath);seed.historyFault=nil
            let fresh=AskConversationStore(url:seed.url);value=try fresh.loadLibrary();value.chats[0].conversation.draft += " newest"
            check(fresh.preserveLibrary(value) == .pending && fresh.maintenanceWarning != nil,"changed obsolete bytes retain durable warning across newer save")
            check(try Data(contentsOf:oldPath)==damaged,"cleanup never erases divergent bytes by filename alone")
        }
        do {
            let seed=AskConversationStore(url:folder.appendingPathComponent("cleanup-sync.json"));var value=try seed.loadLibrary();value.chats[0].conversation.draft=String(repeating:"old ",count:1500)
            check(seed.preserveLibrary(value) == .pending,"seed cleanup directory-sync interruption")
            var armed=false;seed.historyFault={if $0=="cleanup" {armed=true};if armed && $0=="sync" {throw CocoaError(.fileWriteUnknown)}}
            value.chats[0].conversation.draft=String(repeating:"new ",count:1500)
            check(seed.preserveLibrary(value) == .unsaved && armed,"unknown post-unlink sync never claims newest durability")
            seed.historyFault=nil;let fresh=AskConversationStore(url:seed.url),actual=try fresh.loadLibrary()
            check(Array(actual.chats[0].conversation.draft.utf8)==Array(value.chats[0].conversation.draft.utf8) && fresh.maintenanceWarning != nil,"restart keeps visible newest authority and unsynced cleanup obligation")
            let saved=fresh.preserveLibrary(actual),refreshed=try root(fresh)
            check(saved == .pending && (refreshed["retired"] as? [Any] ?? []).isEmpty,"sync recovery discharges only verified missing obsolete references")
        }
    }
}
