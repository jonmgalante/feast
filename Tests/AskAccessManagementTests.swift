import Foundation
@MainActor private final class ManagementMemory:AskManagementStoring {
    var token=String(repeating:"o",count:43),pending:AskAccessPending?,failSave=false,failClear=false
    func activeToken()throws->String{token}
    func managementPending()throws->AskAccessPending?{pending}
    func saveManagementPending(_ p:AskAccessPending)throws{if failSave{throw AskActivationError.keychain};precondition(pending==nil);pending=p}
    func clearManagementPending()throws{if failClear{throw AskActivationError.keychain};pending=nil}
}
@MainActor enum AskAccessManagementTests {
    static func run()async throws {
        let config=AskHostedConfiguration(environment:.production,endpoint:URL(string:"https://feast-proxy-production.jonmgalante.workers.dev/v1/answer")!,scope:.savedMetadata,productionHost:"feast-proxy-production.jonmgalante.workers.dev")
        let store=ManagementMemory();let code=String(repeating:"j",count:43);var bodies=[Data]()
        func response(_ request:URLRequest,_ value:[String:Any],status:Int=200)throws->(Data,HTTPURLResponse){
            (try JSONSerialization.data(withJSONObject:value),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        }
        func entry(_ p:AskAccessPending,state:String="invited")->[String:Any]{["id":p.id.uuidString.lowercased(),"label":p.label ?? "Member","role":"member","state":state,"createdAt":1000,"expiresAt":86401000,"activatedAt":NSNull()]}
        let first=AskAccessManagement(store:store,send:{request in
            precondition(store.pending != nil && request.url?.path=="/v1/access/manage")
            let body=request.httpBody!;bodies.append(body);precondition(!String(data:body,encoding:.utf8)!.contains(code));throw URLError(.timedOut)
        },makeToken:{code})
        await first.create(label:"Juliet",configuration:config)
        precondition(store.pending != nil && first.confirmed==nil && !first.canDiscardPending)
        await first.create(label:"Second",configuration:config);precondition(bodies.count==1)
        let restored=AskAccessManagement(store:store,send:{request in
            bodies.append(request.httpBody!);return try response(request,["version":1,"entry":entry(store.pending!)])
        },makeToken:{preconditionFailure("Minted again after timeout")})
        await restored.retry(configuration:config);precondition(bodies.count==2 && bodies[0]==bodies[1] && restored.confirmed?.label=="Juliet")
        restored.finishInvitation();precondition(store.pending==nil)
        print("PASS owner invitation persists before dispatch, sends hash only, resumes exact operation after relaunch and only exposes a verified code")
        let invalid=AskAccessManagement(store:store,send:{_ in preconditionFailure("Invalid label sent")},makeToken:{preconditionFailure("Invalid label minted")})
        await invalid.create(label:String(repeating:"😀",count:41),configuration:config);precondition(store.pending==nil)
        await invalid.create(label:"bad\nlabel",configuration:config);precondition(store.pending==nil)
        store.failSave=true
        let failed=AskAccessManagement(store:store,send:{_ in preconditionFailure("Dispatched before Keychain")},makeToken:{code})
        await failed.create(label:"Member",configuration:config);precondition(store.pending==nil);store.failSave=false
        print("PASS management label limits match server UTF-16 bounds; malformed input and Keychain failure do not dispatch")
        let rejected=AskAccessManagement(store:store,send:{request in try response(request,["error":"operation_conflict"],status:409)},makeToken:{code})
        await rejected.create(label:"Member",configuration:config);precondition(rejected.canDiscardPending && store.pending != nil)
        rejected.discardRejectedPending();precondition(store.pending==nil)
        print("PASS definitive rejection can be cleared explicitly; uncertain pending operations remain retained")
        store.pending=AskAccessPending(kind:"invite",id:UUID(),label:"Old",invitation:code,actorHash:AskAccessPending.digest(store.token))
        store.token=String(repeating:"n",count:43)
        let recovered=AskAccessManagement(store:store,send:{request in
            precondition(String(data:request.httpBody!,encoding:.utf8)==#"{"kind":"list"}"#)
            return try response(request,["version":1,"entries":[]])
        },makeToken:{preconditionFailure()})
        await recovered.retry(configuration:config);precondition(!recovered.canDiscardPending && store.pending != nil)
        await recovered.refresh(configuration:config);precondition(recovered.canDiscardPending)
        recovered.discardRejectedPending();precondition(store.pending==nil)
        print("PASS owner replacement cannot replay old mutations and requires a fresh owner-authorized directory before local pending recovery")
        let revoked=AskAccessManagement(store:store,send:{request in try response(request,["version":1,"entry":entry(store.pending!,state:"revoked")])},makeToken:{code})
        let e=AskAccessEntry(id:UUID(),label:"Member",role:"member",state:"active",createdAt:1000,expiresAt:86401000,activatedAt:2000)
        await revoked.revoke(e,configuration:config);precondition(store.pending==nil && revoked.entries.first?.state=="revoked")
        store.failClear=true
        await revoked.revoke(e,configuration:config)
        precondition(revoked.confirmed?.state=="revoked" && revoked.message?.contains("Access was revoked")==true && store.pending != nil)
        store.failClear=false;await revoked.retry(configuration:config);precondition(store.pending==nil)
        let owner=AskAccessEntry(id:UUID(),label:"Owner",role:"owner",state:"active",createdAt:1000,expiresAt:86401000,activatedAt:2000)
        await revoked.revoke(owner,configuration:config);precondition(store.pending==nil)
        let parts=URLComponents(url:AskAccessRequest.url,resolvingAgainstBaseURL:false)!
        precondition(parts.scheme=="mailto" && parts.path=="jonmgalante@gmail.com" && parts.queryItems?.count==2)
        precondition(parts.queryItems?.first(where:{$0.name=="body"})?.value==AskAccessRequest.body)
        print("PASS confirmed revocation clears its journal, owner self-revocation is unavailable, and access email has only static editable subject/body")
    }
}
