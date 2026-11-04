// Completed authorized one-shot model/tool-loop check. Never part of the normal app/default tests.
// Do not rerun: any future paid use requires fresh bounded authorization.
// Final Qima semantics were inspected in the captured actual finish_response; retained-link
// rendering is separately regression-tested through AskReadTools.checked().
#if targetEnvironment(simulator) && FEAST_OWNER_VALIDATION && FEAST_AGENT_DIAGNOSTIC
import Foundation
import CoreData
private actor MigrationCounter {
    var calls=0
    var traces:[[String:String]]=[]
    func record(_ data:Data)throws {
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{return}
        if let call=value["call"] as? [String:String] {traces.append(call.filter {$0.key != "callID"})}
    }
    func captured()->[[String:String]] {traces}
    func accept(_ request:URLRequest)throws {
        guard calls<16,request.httpMethod=="POST",request.url?.absoluteString=="https://"+AskOwnerValidationAccess.host+"/v1/answer",let data=request.httpBody,
              let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],value["mode"] as? String=="agentStep",value["version"] as? Int==8,
              let context=value["context"] as? [String:Any],let records=context["index"] as? [[String:Any]],records.count==3,
              Set(records.compactMap {$0["name"] as? String})==Set(["Golden Hour","Qima Cafe","The Ladbroke Arms"]),
              records.allSatisfy({Set($0.keys)==Set(["id","name","city","cuisines"])}) else {throw AskError.invalidEvidence}
        calls+=1
    }
}
/// Already established public evidence is replayed locally; this tests actual model orchestration,
/// not another paid web search or fresh discovery quality.
private struct MigrationEvidence:AskBusinessResearching {
    func publicLookupAvailable()async->Bool {true}
    func businessResearch(_ request:AskBusinessRequest)async throws->AskBusinessResult {
        let values=["Golden Hour":("goldenhour.dtla","https://www.instagram.com/goldenhour.dtla/"),"Qima Cafe":("qima.cafe","https://qimacafe.com/"),"The Ladbroke Arms":("ladbrokearms","https://ladbrokearms.com/")]
        guard let entry=values[request.business.name] else {throw AskError.invalidEvidence}
        return .init(version:1,state:"found",business:request.business,findings:[.init(field:"instagram",value:"https://www.instagram.com/"+entry.0+"/",sourceURL:entry.1,quote:"The business website links this official Instagram profile.",title:"Retained public evidence fixture",verification:"cited_search")])
    }
}
private struct MigrationNoFallback:AskFeastProvider {
    let label="No fallback spending"
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {throw AskError.toolLimit}
}
@MainActor enum AskAgentMigrationDiagnostic {
    static func runIfRequested()async {
        guard ProcessInfo.processInfo.arguments.contains("-feastValidateAgentMigration4"),ProcessInfo.processInfo.environment["SIMULATOR_UDID"]=="4F6EAF55-E0E2-4895-9D19-C2D1D4D89D8D",Bundle.main.bundleIdentifier=="com.jongalante.Feast",AskPrivacy.onlineAllowed,let configuration=AskOwnerValidationAccess.configuration(info:Bundle.main.infoDictionary ?? [:]),let directory=try? FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true) else {return}
        let receipt=directory.appendingPathComponent("FeastAgentMigrationDiagnostic4.json")
        guard !FileManager.default.fileExists(atPath:receipt.path) else {return}
        var result:[String:Any]=["state":"preparing","startedAt":ISO8601DateFormatter().string(from:Date()),"originalRecordsTouched":false,"researchEvidence":"retained-public-fixture-not-live-search","maximumAnswerPOSTs":16,"cases":[]]
        do {try JSONSerialization.data(withJSONObject:result).write(to:receipt,options:.withoutOverwriting)}catch{return}
        func save()throws {try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:receipt,options:.atomic)}
        var cases:[[String:Any]]=[]
        let counter=MigrationCounter()
        do {
            let before=try await status();result["before"]=before;try save()
            guard let modelURL=Bundle.main.url(forResource:"FeastDataModel",withExtension:"momd"),let model=NSManagedObjectModel(contentsOf:modelURL) else {throw AskError.invalidEvidence}
            let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model),store=try coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil)
            let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
            let repo=FeastRepository(context:context),la=try repo.createFeastList(named:"LA"),london=try repo.createFeastList(named:"London")
            var objects:[SavedPlace]=[]
            for (name,city) in [("Golden Hour",la),("Qima Cafe",london),("The Ladbroke Arms",london)] {
                objects.append(try repo.createSavedPlace(from:.init(applePlaceID:"isolated-"+name,displayNameSnapshot:name,status:.wantToTry,placeType:.other,cuisines:[],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:city,listSection:nil)))
            }
            let adapter=AskSavedCollection(context:context,canMutate:{_,_,_ in true},canRecoverStore:{$0==store.identifier},visibleCities:{[la.id!,london.id!]})
            let journal=directory.appendingPathComponent("AgentMigrationIsolatedJournal4.json")
            guard !FileManager.default.fileExists(atPath:journal.path) else {throw AskError.invalidEvidence}
            defer {try? FileManager.default.removeItem(at:journal)}
            let engine=AskCollectionChangeEngine(adapter:adapter,journalURL:journal)
            let hosted=AskHostedProvider(configuration:configuration,token:{try AskOwnerValidationAccess.credential()},approve:{_,_ in false},send:{http in try await counter.accept(http);let pair=try await AskHostedHTTP().send(http);try await counter.record(pair.0);return pair},libraryToolsEnabled:{true},permission:{AskPrivacy.onlineAllowed},libraryPlanVersion:{5},publicLookupEnabled:{true})
            var accepted:AskAgentTask?,findings:[AskVerifiedFinding]=[],recent:[AskRecentUserQuestion]=[]
            let questions=["Find the Instagram accounts for Golden Hour, Qima Cafe and The Ladbroke Arms.","Save all three to their places.","Undo the second one.","What about Qima Cafe?"]
            for (index,question) in questions.enumerated() {
                _ = try await status()
                var request=AskRequest(mode:.collection,text:question,fromOCR:false,performanceID:UUID(),agentTask:accepted)
                request.verifiedFindings=findings;request.recentQuestions=recent
                let executor=AskAgentExecutor(adapter:adapter,engine:engine,request:request,researcher:MigrationEvidence(),searchMaps:{_ in []})
                let semantic=try AskSemanticContext.make(request,catalog:adapter.librarySnapshot())
                let publicFindings=try findings.map {finding->AskAgentFinding in _ = try finding.validated();return .init(id:finding.id.uuidString,recordID:finding.recordID,field:finding.field,value:finding.value,sourceURL:finding.evidenceURL)}
                result["state"]="dispatching-case-\(index+1)";result["cases"]=cases;try save()
                let previousOrder=accepted?.orderedIDs ?? []
                let start=Date(),response=try await AskAgentLoop(planner:hosted,execute:{call,intent in try await executor.execute(call,intent:intent)},prepareIntent:{intent in try await executor.prepare(intent)}).answer(request,context:semantic,cities:executor.cities(),findings:publicFindings)
                accepted=response.agentTask
                for f in response.verifiedPublicFindings ?? [] {findings.removeAll {$0.recordID==f.recordID&&$0.field==f.field};findings.append(f)}
                let ordered=response.agentTask?.orderedIDs ?? []
                let passed:Bool
                if index==0 {passed=ordered.count==3 && findings.count==3}
                else if index==1 {passed=objects.allSatisfy {$0.instagramURL != nil} && response.collectionActions?.count==3}
                else if index==2 {passed=previousOrder.count==3 && objects.allSatisfy {$0.instagramURL==nil ? $0.id!.uuidString==previousOrder[1] : $0.id!.uuidString != previousOrder[1]}}
                else {passed=ordered==[objects[1].id!.uuidString] && findings.contains {$0.recordID==objects[1].id!.uuidString&&$0.value=="https://www.instagram.com/qima.cafe/"}}
                cases.append(["question":question,"passed":passed,"seconds":Date().timeIntervalSince(start),"summary":response.summary,"task":try JSONSerialization.jsonObject(with:JSONEncoder().encode(response.agentTask)),"actionCount":response.collectionActions?.count ?? 0,"budgetAfter":try await status()]);result["cases"]=cases;try save()
                guard passed else {throw AskError.invalidEvidence}
                recent.append(.init(question:question,recordIDs:ordered));recent=Array(recent.suffix(2))
            }
            result["after"]=try await status();result["state"]="verified-live-model-loop-and-isolated-writes"
        }catch {result["state"]="stopped-no-retry";result["failureType"]=String(describing:type(of:error));result["failureCode"]=String(describing:error);result["cases"]=cases;if let after=try? await status(){result["after"]=after}}
        result["modelCalls"]=await counter.captured();result["finishedAt"]=ISO8601DateFormatter().string(from:Date());try? save()
    }
    private static func status()async throws->[String:Any] {
        let endpoint=URL(string:"https://"+AskOwnerValidationAccess.host+"/v1/status")!
        var request=URLRequest(url:endpoint);request.timeoutInterval=20;request.setValue("Bearer "+(try AskOwnerValidationAccess.budgetStatusCredential()),forHTTPHeaderField:"Authorization")
        let (data,response)=try await AskHostedHTTP().send(request)
        guard response.statusCode==200,response.url==endpoint,data.count<=16384,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],value["protocol"] as? Int==1,value["accountingVersion"] as? Int==2,value["capMicroUSD"] as? Int==10_000_000,value["halted"] as? Bool==false,value["pendingMicroUSD"] as? Int==0,value["legacyUncertainMicroUSD"] as? Int==0,let remaining=value["remainingMicroUSD"] as? Int,remaining>=1_622_016,let reserved=value["reservedMicroUSD"] as? Int,reserved>=0,reserved+remaining==10_000_000 else {throw AskHostedError.invalidResponse}
        return value
    }
}
#endif
