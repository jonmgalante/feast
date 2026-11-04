// Completed explicitly authorized one-shot diagnostic. Not included in app/default tests.
// Any future live rerun requires its own bounded authorization and temporary operator build.
#if targetEnvironment(simulator) && FEAST_OWNER_VALIDATION && FEAST_FIELD_DIAGNOSTIC
import Foundation
import CoreData

private actor FieldDiagnosticCounter {
    private var count=0
    func accept(_ request:URLRequest) throws {
        guard count<3,request.httpMethod=="POST",request.url?.absoluteString=="https://"+AskOwnerValidationAccess.host+"/v1/answer",
              let bytes=request.httpBody,let p=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],p["mode"] as? String=="libraryIntent",p["version"] as? Int==7,
              let c=p["context"] as? [String:Any],let records=c["index"] as? [[String:Any]],records.count==2,
              Set(records.compactMap {$0["name"] as? String})==Set(["Golden Hour","Qima Cafe"]),
              records.allSatisfy({Set($0.keys)==Set(["id","name","city","cuisines"])}) else {throw AskError.invalidEvidence}
        count+=1
    }
}
private struct FrozenFieldDiagnosticPlan:AskLibraryIntentPlanning {
    let plan:AskLibraryPlan
    func libraryPlan(_ question:String) async throws -> AskLibraryPlan? {plan}
}
private struct FieldDiagnosticNoAnswer:AskFeastProvider {
    let label="No extra provider dispatch"
    func answer(_ request:AskRequest,tools:AskReadTools) async throws -> AskResponse {throw AskError.toolLimit}
}
@MainActor enum AskFieldPlanDiagnostic {
    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-feastValidateFieldPlans"),ProcessInfo.processInfo.environment["SIMULATOR_UDID"]=="4F6EAF55-E0E2-4895-9D19-C2D1D4D89D8D",
              Bundle.main.bundleIdentifier=="com.jongalante.Feast",AskPrivacy.onlineAllowed,
              let configuration=AskOwnerValidationAccess.configuration(info:Bundle.main.infoDictionary ?? [:]) else {return}
        guard let directory=try? FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true) else {return}
        let receipt=directory.appendingPathComponent("FeastFieldPlanDiagnostic.json")
        guard !FileManager.default.fileExists(atPath:receipt.path) else {return}
        var result:[String:Any]=["state":"preparing","startedAt":ISO8601DateFormatter().string(from:Date()),"maximumRequests":3,"maximumReservationMicroUSD":7_500_000,"originalRecordsTouched":false,"publicBusinessFixtureOnly":true,"cases":[]]
        do {try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:receipt,options:.withoutOverwriting)} catch {return}
        func save() throws {try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:receipt,options:.atomic)}
        var cases:[[String:Any]]=[]
        do {
            let before=try await status();result["before"]=before;try save()
            guard let modelURL=Bundle.main.url(forResource:"FeastDataModel",withExtension:"momd"),let model=NSManagedObjectModel(contentsOf:modelURL) else {throw AskError.invalidEvidence}
            let coordinator=NSPersistentStoreCoordinator(managedObjectModel:model)
            _ = try coordinator.addPersistentStore(ofType:NSInMemoryStoreType,configurationName:nil,at:nil)
            let context=NSManagedObjectContext(concurrencyType:.mainQueueConcurrencyType);context.persistentStoreCoordinator=coordinator
            let repository=FeastRepository(context:context)
            let la=try repository.createFeastList(named:"LA"),london=try repository.createFeastList(named:"London")
            let golden=try repository.createSavedPlace(from:.init(applePlaceID:"isolated-public-golden",displayNameSnapshot:"Golden Hour",status:.wantToTry,placeType:.restaurant,cuisines:[],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:la,listSection:nil))
            let qima=try repository.createSavedPlace(from:.init(applePlaceID:"isolated-public-qima",displayNameSnapshot:"Qima Cafe",status:.wantToTry,placeType:.cafe,cuisines:[],tags:[],note:nil,websiteURL:nil,instagramURL:nil,feastList:london,listSection:nil))
            let adapter=AskSavedCollection(context:context,canUpdate:{_ in true},visibleCities:{[la.id!,london.id!]})
            let goldenID=golden.id!.uuidString,qimaID=qima.id!.uuidString,profile="https://www.instagram.com/goldenhour.dtla/"
            let goldenRecord=try adapter.personalPlaces().first {$0.id==goldenID}!
            let finding=AskVerifiedFinding(id:UUID(),recordID:goldenID,identity:.init(goldenRecord),field:"instagram",value:profile,evidenceURL:profile,verification:"cited_search",originatingTurn:UUID())
            let lookup=AskLibraryPlan(operation:.lookup,scope:.library,city:nil,cuisine:nil,status:nil,placeType:nil,name:"Golden Hour",positions:[],fields:["instagram"])
            let counter=FieldDiagnosticCounter()
            let provider=AskHostedProvider(configuration:configuration,token:{try AskOwnerValidationAccess.credential()},approve:{_,_ in false},send:{request in try await counter.accept(request);return try await AskHostedHTTP().send(request)},libraryToolsEnabled:{true},permission:{AskPrivacy.onlineAllowed},libraryPlanVersion:{4},publicLookupEnabled:{true})
            let questions=["What about Qima Cafe?","Add that to Golden Hour","What about the Instagram for Qima Cafe?"]
            for (index,question) in questions.enumerated() {
                let gate=try await status()
                guard let remaining=gate["remainingMicroUSD"] as? Int,remaining>=2_500_000 else {throw AskHostedError.service(429)}
                var request=AskRequest(mode:.collection,text:question,fromOCR:false,libraryContext:.init(ids:[goldenID],filters:index==2 ? .init(operation:.updateField,scope:.library,city:nil,cuisine:nil,status:nil,placeType:nil,name:"Golden Hour",positions:[],fields:["instagram"]) : lookup),performanceID:UUID())
                request.recentQuestions=[.init(question:index==2 ? "Add that to Golden Hour" : "What's Golden Hour's Instagram?",recordIDs:[goldenID])]
                request.verifiedFindings=[finding]
                result["state"]="dispatching-case-\(index+1)";result["activeRequestID"]=request.performanceID!.uuidString;result["cases"]=cases;try save()
                let start=Date()
                guard let plan=try await provider.libraryPlan(request,catalog:adapter.librarySnapshot()) else {throw AskHostedError.disabled}
                var item:[String:Any]=["question":question,"requestID":request.performanceID!.uuidString,"plan":try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)),"seconds":Date().timeIntervalSince(start)]
                let selected=try AskLibraryReadTools.execute(plan,snapshot:adapter.librarySnapshot(),context:request.libraryContext)
                let expected=index==1 ? goldenID : qimaID
                let matched=selected.status == .success && selected.records.map(\.id)==[expected] && plan.fields==["instagram"] && plan.operation == (index==1 ? .updateField : .lookup)
                item["exactExpectedRecordResolved"]=matched
                if index==1 && matched {
                    let local=AskLibraryProvider(remote:FieldDiagnosticNoAnswer(),places:{try await adapter.personalPlaces()},intentPlanner:FrozenFieldDiagnosticPlan(plan:plan),snapshot:{try await adapter.librarySnapshot()})
                    let tools=try AskReadTools(request:request,index:adapter.index())
                    let response=try tools.checked(await local.answer(request,tools:tools))
                    guard response.requestsFieldSave==true,let action=response.fieldActions?.first else {throw AskError.invalidEvidence}
                    let saved=try adapter.apply(action,mode:.save)
                    item["isolatedSaveSucceeded"]=saved.outcome == .saved && golden.instagramURL==profile && qima.instagramURL==nil
                    guard item["isolatedSaveSucceeded"] as? Bool==true else {throw AskError.invalidEvidence}
                }
                let after=try await status();item["budgetAfter"]=after;item["passed"]=matched;cases.append(item);result["cases"]=cases;try save()
                guard matched else {throw AskError.invalidEvidence}
            }
            let after=try await status();result["after"]=after
            if let first=before["chargedMicroUSD"] as? Int,let last=after["chargedMicroUSD"] as? Int,last>=first {result["actualChargedMicroUSD"]=last-first}
            result["state"]="verified-three-live-plans-and-isolated-save";result["model"]="gpt-6-astra";result["reasoning"]="medium"
        } catch {
            result["state"]="stopped-no-retry";result["failureType"]=String(describing:type(of:error));result["cases"]=cases
            if let after=try? await status(){result["after"]=after}
        }
        result["finishedAt"]=ISO8601DateFormatter().string(from:Date());try? save()
    }
    private static func status() async throws -> [String:Any] {
        let endpoint=URL(string:"https://"+AskOwnerValidationAccess.host+"/v1/status")!
        var request=URLRequest(url:endpoint);request.timeoutInterval=20;request.setValue("Bearer "+(try AskOwnerValidationAccess.budgetStatusCredential()),forHTTPHeaderField:"Authorization")
        let (data,response)=try await AskHostedHTTP().send(request)
        guard response.statusCode==200,response.url==endpoint,response.mimeType=="application/json",data.count<=4096,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],value["protocol"] as? Int==1,value["accountingVersion"] as? Int==2,value["capMicroUSD"] as? Int==10_000_000,value["halted"] as? Bool==false,value["pendingMicroUSD"] as? Int==0,value["legacyUncertainMicroUSD"] as? Int==0,let used=value["reservedMicroUSD"] as? Int,(0...10_000_000).contains(used),value["remainingMicroUSD"] as? Int==10_000_000-used else {throw AskHostedError.invalidResponse}
        return value
    }
}
#endif
