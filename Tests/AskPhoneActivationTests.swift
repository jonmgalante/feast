import Foundation

@MainActor private final class ActivationMemoryStore:AskActivationStoring {
    var saved:AskPendingActivation?,credential:String?
    var failSave=false,failCommit=false,failCleanup=false
    func active()->Bool{credential != nil}
    func pending()throws->AskPendingActivation?{saved}
    func savePending(_ value:AskPendingActivation)throws{if failSave{throw AskActivationError.keychain};saved=value}
    func commit(_ value:AskPendingActivation)throws{if failCommit{throw AskActivationError.keychain};precondition(saved==value);credential=value.deviceToken;if failCleanup{throw AskActivationError.keychain};saved=nil}
    func removeRejectedPending()throws{saved=nil}
    func activeToken()throws->String{guard let credential else{throw AskActivationError.keychain};return credential}
    func removeRevokedCredential(_ token:String)throws{precondition(credential==token);credential=nil;if saved?.deviceToken==token{saved=nil}}
}
private actor ActivationGateProvider:AskFeastProvider {
    nonisolated let label="Offline activation flow fixture"
    private var gate:CheckedContinuation<Void,Never>?
    private var started=false
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        started=true
        await withCheckedContinuation{gate=$0}
        return .init(summary:"Retained answer",candidates:[])
    }
    func hasStarted()->Bool{started}
    func release(){gate?.resume();gate=nil}
}
@MainActor enum AskPhoneActivationTests {
    private static let code=String(repeating:"i",count:43),fakeToken=String(repeating:"t",count:43)
    private static var config:AskHostedConfiguration{.init(environment:.production,endpoint:URL(string:"https://feast-proxy-production.jonmgalante.workers.dev/v1/answer")!,scope:.savedMetadata,productionHost:"feast-proxy-production.jonmgalante.workers.dev")}
    private static func reply(_ request:URLRequest,_ p:AskPendingActivation)throws->(Data,HTTPURLResponse){
        let data=try JSONSerialization.data(withJSONObject:["version":1,"grantID":"00000000-0000-4000-8000-000000000001","deviceID":p.deviceID.uuidString.lowercased(),"activationID":p.activationID.uuidString.lowercased(),"activatedAt":1000])
        return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
    static func run()async throws {
        for (key,path) in [("FeastPrivacyPolicyURL","privacy"),("FeastSupportURL","support")] {
            let address="https://jonmgalante.github.io/feast-site/"+path+"/"
            precondition(AskPublicLinks.url(key,info:[key:address])?.absoluteString==address)
            for invalid in ["http://example.org/","file:///tmp/private","https://user:secret@example.org/","not a URL"] {
                precondition(AskPublicLinks.url(key,info:[key:invalid])==nil)
            }
            precondition(AskPublicLinks.url(key,info:[:])==nil)
        }
        precondition(AskPublicLinks.url("UnrelatedURL",info:["UnrelatedURL":"https://example.org/"])==nil)
        print("PASS activation and Settings share safe explicit public policy/support links without automatic requests")
        let initialConsent=AskPrivacy.onlineAllowed
        let store=ActivationMemoryStore();var requests=[Data](),minted=0
        let first=AskPhoneActivation(store:store,send:{r in
            guard let pending=store.saved else{preconditionFailure("Dispatch before durable state")}
            precondition(r.url?.absoluteString=="https://feast-proxy-production.jonmgalante.workers.dev/v1/access/activate")
            precondition(r.value(forHTTPHeaderField:"Authorization")==nil)
            let body=try JSONSerialization.jsonObject(with:r.httpBody!) as! [String:Any]
            precondition(Set(body.keys)==["version","invitation","credentialHash","deviceID","activationID"])
            precondition(!String(data:r.httpBody!,encoding:.utf8)!.contains(fakeToken))
            precondition(body["credentialHash"] as? String==pending.credentialHash)
            requests.append(r.httpBody!);throw URLError(.networkConnectionLost)
        },makeToken:{minted+=1;return fakeToken})
        await first.activate(code:"short",configuration:config);precondition(minted==0&&requests.isEmpty&&store.saved==nil)
        await first.activate(code:code,configuration:config);precondition(first.hasPending && !first.activated && minted==1 && requests.count==1)
        let persisted=store.saved!
        // Shared cross-language fixture: prevents client/server hash-domain drift.
        precondition(persisted.credentialHash=="c396c4020946c806167512d4b6078935565d30e573dc3a2356be36c984e122ea")
        // A new controller simulates relaunch. A changed text value cannot replace an uncertain attempt.
        let restored=AskPhoneActivation(store:store,send:{r in requests.append(r.httpBody!);return try reply(r,store.saved!)},makeToken:{preconditionFailure("New credential after uncertainty")})
        await restored.activate(code:String(repeating:"z",count:43),configuration:config)
        precondition(requests.count==2&&requests[0]==requests[1]&&restored.activated&&restored.didActivate&&restored.verifiedRole==nil&&store.saved==nil&&store.credential==fakeToken)
        precondition(AskPrivacy.onlineAllowed==initialConsent)
        await restored.activate(code:code,configuration:config);precondition(requests.count==2)
        print("PASS phone activation persists before dispatch, sends no collection/runtime secret, preserves consent and resumes the exact attempt after network failure/relaunch")

        for fault in 0..<4 {
            let memory=ActivationMemoryStore();memory.saved=persisted
            let controller=AskPhoneActivation(store:memory,send:{r in
                let (data,response)=try reply(r,persisted)
                if fault==0{return(data,HTTPURLResponse(url:URL(string:"https://other.example/v1/access/activate")!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)}
                if fault==1{return(Data("{}".utf8),response)}
                if fault==2{return(Data(repeating:32,count:4097),response)}
                memory.failCommit=true;return(data,response)
            },makeToken:{preconditionFailure()})
            await controller.activate(code:"",configuration:config)
            precondition(!controller.activated&&memory.saved==persisted&&memory.credential==nil)
        }
        let fail=ActivationMemoryStore();fail.failSave=true;var dispatched=false
        let blocked=AskPhoneActivation(store:fail,send:{_ in dispatched=true;preconditionFailure()},makeToken:{fakeToken})
        await blocked.activate(code:code,configuration:config);precondition(!dispatched)
        let expired=ActivationMemoryStore();expired.saved=persisted
        let rejected=AskPhoneActivation(store:expired,send:{r in(Data(#"{"error":"invitation_unavailable"}"#.utf8),HTTPURLResponse(url:r.url!,statusCode:403,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)},makeToken:{preconditionFailure()})
        await rejected.activate(code:"",configuration:config);precondition(expired.saved==nil && !rejected.activated)
        let partial=ActivationMemoryStore();partial.failCleanup=true
        let interruptedCleanup=AskPhoneActivation(store:partial,send:{r in try reply(r,partial.saved!)},makeToken:{fakeToken})
        await interruptedCleanup.activate(code:code,configuration:config)
        precondition(interruptedCleanup.activated && !interruptedCleanup.didActivate && interruptedCleanup.hasPending && partial.credential==fakeToken && partial.saved != nil)
        precondition(interruptedCleanup.message==AskActivationError.keychain.localizedDescription)
        print("PASS phone activation rejects mismatched/oversized/unverified replies, retains uncertain and failed-Keychain attempts, and never replaces an existing credential")

        let duplicate=ActivationMemoryStore();var continuation:CheckedContinuation<Void,Never>?,entered=false,calls=0
        let once=AskPhoneActivation(store:duplicate,send:{r in calls+=1;entered=true;await withCheckedContinuation{continuation=$0};return try reply(r,duplicate.saved!)},makeToken:{fakeToken})
        let task=Task{await once.activate(code:code,configuration:config)}
        while !entered{await Task.yield()}
        await once.activate(code:code,configuration:config);precondition(calls==1)
        continuation?.resume();await task.value;precondition(once.activated)
        let session=AskSession(index:AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[]),provider:AskUnavailableProvider())
        session.input="Keep this draft";let chat=session.activeChatID,turns=session.turns
        precondition(session.replaceProviderWhenIdle(AskUnavailableProvider()))
        precondition(session.input=="Keep this draft"&&session.activeChatID==chat&&session.turns.map(\.id)==turns.map(\.id))
        print("PASS repeated activation taps are single-flight and provider attachment preserves current chat identity, history and draft")
        let revoked=ActivationMemoryStore();revoked.credential=fakeToken
        let check=AskPhoneActivation(store:revoked,send:{r in
            precondition(r.httpBody==nil&&r.url?.path=="/v1/access/status")
            return(Data(#"{"error":"unauthorized"}"#.utf8),HTTPURLResponse(url:r.url!,statusCode:401,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },makeToken:{preconditionFailure()})
        await check.checkAccess(configuration:config);precondition(!check.activated&&check.verifiedRole==nil&&revoked.credential==nil)
        revoked.credential=fakeToken
        let uncertain=AskPhoneActivation(store:revoked,send:{_ in throw URLError(.timedOut)},makeToken:{preconditionFailure()})
        await uncertain.checkAccess(configuration:config)
        precondition(uncertain.activated&&revoked.credential==fakeToken&&uncertain.verifiedRole==nil&&uncertain.message==AskActivationError.statusUnavailable.localizedDescription)
        print("PASS explicit access check enables replacement only after authoritative revocation and preserves credentials on network uncertainty; no AI call")

        var roleReply="owner",statusCalls=0,failStatus=false
        let verified=AskPhoneActivation(store:revoked,send:{r in
            statusCalls+=1
            precondition(r.httpMethod=="GET"&&r.httpBody==nil&&r.url?.path=="/v1/access/status")
            precondition(r.value(forHTTPHeaderField:"Authorization")=="Bearer "+fakeToken)
            if failStatus{throw URLError(.notConnectedToInternet)}
            let data=try JSONSerialization.data(withJSONObject:["version":1,"deviceID":UUID().uuidString.lowercased(),"role":roleReply])
            return(data,HTTPURLResponse(url:r.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },makeToken:{preconditionFailure("A status check must not mint activation credentials")})
        precondition(verified.activated && !verified.didActivate && !verified.isOwner && verified.verifiedRole==nil && statusCalls==0)
        await verified.checkAccess(configuration:config)
        precondition(verified.isOwner && verified.verifiedRole == .owner && verified.message==nil)
        failStatus=true
        await verified.checkAccess(configuration:config)
        precondition(!verified.isOwner && verified.verifiedRole==nil && verified.activated && revoked.credential==fakeToken)
        precondition(verified.message==AskActivationError.statusUnavailable.localizedDescription)
        failStatus=false;roleReply="member"
        await verified.checkAccess(configuration:config)
        precondition(!verified.isOwner && verified.verifiedRole == .member && verified.message==nil)
        roleReply="unexpected"
        await verified.checkAccess(configuration:config)
        precondition(!verified.isOwner && verified.verifiedRole==nil && verified.activated && revoked.credential==fakeToken)
        precondition(verified.message==AskActivationError.statusUnavailable.localizedDescription && statusCalls==4)
        print("PASS only verified status responses establish owner/member roles; failed or malformed status clears stale role, retains access and offers Check access")

        var presentation=AskAccessPresentation()
        presentation.present(.history)
        precondition(presentation.sheet == .history)
        presentation.present(.access)
        precondition(presentation.sheet==nil) // Access waits for History's dismissal completion.
        precondition(presentation.didDismissSheet() == .history && presentation.sheet == .access)
        precondition(!presentation.showsActivationConfirmation)
        precondition(presentation.didDismissSheet() == .access && presentation.sheet==nil)
        presentation.present(.access) // Returning to saved access is not a new activation.
        precondition(presentation.connected(true,newActivation:verified.didActivate) && !presentation.showsActivationConfirmation)
        _=presentation.didDismissSheet()

        let gate=ActivationGateProvider()
        let inFlight=AskSession(index:AskLocalIndex(records:[],visibleCityIDs:[],visibleNoteIDs:[]),provider:gate)
        inFlight.input="A question already in progress";inFlight.run()
        while !(await gate.hasStarted()){await Task.yield()}
        inFlight.input="Keep this next draft"
        let activeChat=inFlight.activeChatID,turnIDs=inFlight.turns.map(\.id)
        presentation.present(.access)
        let blockedAttachment=inFlight.replaceProviderWhenIdle(AskUnavailableProvider())
        precondition(!presentation.connected(blockedAttachment,newActivation:restored.didActivate))
        precondition(presentation.sheet == .access && !presentation.showsActivationConfirmation)
        precondition(inFlight.input=="Keep this next draft" && inFlight.activeChatID==activeChat && inFlight.turns.map(\.id)==turnIDs)
        await gate.release();while inFlight.isLoading{await Task.yield()}
        let attached=inFlight.replaceProviderWhenIdle(AskUnavailableProvider())
        precondition(presentation.connected(attached,newActivation:restored.didActivate) && presentation.showsActivationConfirmation)
        _=presentation.didDismissSheet()
        precondition(presentation.sheet==nil && presentation.showsActivationConfirmation)
        precondition(inFlight.input=="Keep this next draft" && inFlight.activeChatID==activeChat && inFlight.turns.map(\.id)==turnIDs && inFlight.turns.first?.response?.summary=="Retained answer")
        presentation.present(.history);_=presentation.didDismissSheet()
        precondition(presentation.showsActivationConfirmation) // Closing History never resets the confirmation or chat.
        presentation.dismissConfirmation()
        precondition(!presentation.showsActivationConfirmation && AskPrivacy.onlineAllowed==initialConsent)
        print("PASS History dismisses before access opens; successful new activation and idle attachment leave a durable Ask confirmation; busy Continue preserves draft/history, then succeeds without consent or AI dispatch")
    }
}
