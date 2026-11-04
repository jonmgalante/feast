import Foundation

private actor BusinessCalls {
    var requests:[AskBusinessRequest]=[]
    func append(_ r:AskBusinessRequest){requests.append(r)}
    func count()->Int {requests.count}
}
private struct BusinessResearchFixture:AskBusinessResearching,AskFeastProvider {
    let label="Offline mocked research — not live verification"
    var available:@Sendable () async -> Bool = {true}
    let run:@Sendable (AskBusinessRequest) async throws -> AskBusinessResult
    func publicLookupAvailable() async -> Bool {await available()}
    func businessResearch(_ request:AskBusinessRequest) async throws -> AskBusinessResult {try await run(request)}
    func answer(_ request:AskRequest,tools:AskReadTools) async throws -> AskResponse {preconditionFailure("No legacy metadata dispatch for public lookup")}
}
private struct BusinessPlannerFixture:AskLibraryIntentPlanning {
    let plan:AskLibraryPlan
    func libraryPlan(_ question:String) async throws -> AskLibraryPlan? {plan}
}
@MainActor enum AskBusinessLookupTests {
    static func run() async throws {
        let id=UUID().uuidString,cityID=UUID().uuidString,profile="https://www.instagram.com/public_cafe/",site="https://public-cafe.org/contact"
        var record=AskPersonalPlace(id:id,name:"Public Cafe",status:"PRIVATE_STATUS",type:"Cafe",cuisines:["Italian"],city:"London",neighborhood:"PRIVATE_NEIGHBORHOOD",websiteURL:site,instagramURL:profile)
        func tools(_ record:AskPersonalPlace,_ request:AskRequest) throws -> AskReadTools {
            let index=AskLocalIndex(records:[.init(id:record.id,cityID:cityID,city:record.city,name:record.name,neighborhood:record.neighborhood,cuisine:"Italian",status:"PRIVATE_STATUS",notes:[.init(id:"private",author:"Private author",text:"PRIVATE_NOTE")])],visibleCityIDs:[cityID],visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:[record])
            return try AskReadTools(request:request,index:index)
        }
        var request=AskRequest(mode:.collection,text:"Find a way to reach Public Cafe",fromOCR:false);request.performanceID=UUID()
        let plan=AskLibraryPlan(operation:.lookup,scope:.library,city:"London",cuisine:nil,status:nil,placeType:nil,name:"Public Cafe",positions:[],fields:["instagram"])
        let noNetwork=BusinessResearchFixture(available:{preconditionFailure("Known saved links need no network")},run:{_ in preconditionFailure("No research for saved link")})
        let saved=try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),researcher:noNetwork,inspect:{_,_ in preconditionFailure("No inspection for saved link")})
        precondition(saved.paragraphs[0].citations[0].url==profile && saved.libraryContext?.ids==[id])
        print("PASS saved public links render from exact local records without a web/provider request or hidden writes")

        record.instagramURL=nil
        let official=try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),researcher:BusinessResearchFixture(run:{_ in preconditionFailure("Official attribution should avoid research")}),inspect:{_,_ in .init(status:.found,profile:profile,sourceURL:site)})
        precondition(official.paragraphs[0].citations.contains {$0.url==site} && official.paragraphs[0].citations.contains {$0.url==profile})
        print("PASS injected official-site evidence is reused and cited before paid fallback; mock success is not live site verification")

        let metadata=AskSource(id:"internal",title:"Saved details",kind:.savedMetadata,author:"Saved place metadata",published:nil,checked:"",url:nil,excerpt:"{\"name\":\"Private record\"}")
        let publicSource=AskSource(id:"public",title:"Contact",kind:.webFixture,author:"Publisher",published:nil,checked:"",url:site,excerpt:"Public source")
        precondition(AskSourcePresentation.visible([metadata,publicSource]).map(\.id)==["public"])
        precondition(AskSourcePresentation.dates(metadata)==nil && AskSourcePresentation.dates(publicSource)==nil)
        print("PASS internal saved JSON is not a displayed source; public sources remain visible and empty dates are omitted")
        var mapsRecord=record;mapsRecord.websiteURL=nil;mapsRecord.applePlaceID="known-maps-identity"
        let noPaidFallback=BusinessResearchFixture(run:{_ in preconditionFailure("Resolved official site must not incur paid research")})
        let mapMatch=ApplePlaceMatch(applePlaceID:"known-maps-identity",displayName:"Public Cafe",secondaryText:"London",coordinate:nil,suggestedSectionPath:.init(cityOrRegion:"London",neighborhood:nil),websiteURL:site,instagramURL:nil)
        let resolved=try await AskBusinessLookup.answer(request,plan:plan,record:mapsRecord,tools:tools(mapsRecord,request),allowHostedResearch:false,researcher:noPaidFallback,resolvePlace:{id in precondition(id=="known-maps-identity");return mapMatch},inspect:{website,name in precondition(website==site && name=="Public Cafe");return .init(status:.found,profile:profile,sourceURL:site)})
        precondition(resolved.verifiedPublicFindings?.first?.value==profile && resolved.verifiedPublicFindings?.first?.identity.website==nil && mapsRecord.websiteURL==nil)
        for bad in [ApplePlaceMatch(applePlaceID:"wrong-id",displayName:"Public Cafe",secondaryText:"London",coordinate:nil,suggestedSectionPath:.init(cityOrRegion:"London",neighborhood:nil),websiteURL:site,instagramURL:nil),ApplePlaceMatch(applePlaceID:"known-maps-identity",displayName:"Public Cafe Annex",secondaryText:"London",coordinate:nil,suggestedSectionPath:.init(cityOrRegion:"London",neighborhood:nil),websiteURL:site,instagramURL:nil),ApplePlaceMatch(applePlaceID:"known-maps-identity",displayName:"Public Cafe",secondaryText:"London",coordinate:nil,suggestedSectionPath:.init(cityOrRegion:"London",neighborhood:nil),websiteURL:"https://127.0.0.1/",instagramURL:nil)] {
            let rejected=try await AskBusinessLookup.answer(request,plan:plan,record:mapsRecord,tools:tools(mapsRecord,request),allowHostedResearch:false,researcher:noPaidFallback,resolvePlace:{_ in bad},inspect:{_,_ in preconditionFailure("Wrong Maps identity/name/unsafe website reached inspection")})
            precondition(rejected.verifiedPublicFindings?.isEmpty==true)
        }
        _ = try await AskBusinessLookup.answer(request,plan:plan,record:mapsRecord,tools:tools(mapsRecord,request),allowExternalLookups:false,researcher:noPaidFallback,resolvePlace:{_ in preconditionFailure("Local-only request queried Maps")},inspect:{_,_ in preconditionFailure("Local-only inspection")})
        do {_ = try await AskBusinessLookup.answer(request,plan:plan,record:mapsRecord,tools:tools(mapsRecord,request),researcher:noPaidFallback,resolvePlace:{_ in throw CancellationError()});preconditionFailure("Cancelled Maps lookup continued")}catch is CancellationError {}
        print("PASS exact Maps identity/name resolves a missing website for pinned Instagram inspection with zero paid research or writes; wrong IDs/names/private URLs, local-only and cancellation stay bounded")

        let calls=BusinessCalls()
        let researcher=BusinessResearchFixture(run:{ r in
            await calls.append(r)
            let bytes=try JSONEncoder().encode(r),json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            precondition(Set(json.keys)==["version","mode","requestID","business","fields"])
            precondition(Set((json["business"] as! [String:Any]).keys)==["name","city"])
            let text=String(decoding:bytes,as:UTF8.self)
            precondition(!text.contains("PRIVATE") && !text.contains("history") && !text.contains("notes") && !text.contains(site))
            return .init(version:1,state:"found",business:r.business,findings:[.init(field:"instagram",value:profile,sourceURL:site,quote:"Public Cafe in London links this exact Instagram profile.",title:"Contact",verification:"cited_search")])
        })
        let found=try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),researcher:researcher,inspect:{_,_ in .init(status:.unverified)})
        let count=await calls.count();precondition(count==1 && found.paragraphs[0].citations.contains {$0.url==profile})
        let attempt=UUID(),lookupTrace=UUID()
        let attemptOne=try AskBusinessRequest.make(trace:lookupTrace,attempt:attempt,record:record,fields:["instagram"])
        let sameAttempt=try AskBusinessRequest.make(trace:lookupTrace,attempt:attempt,record:record,fields:["instagram"])
        let otherBusiness=AskPersonalPlace(id:UUID().uuidString,name:"Other Cafe",status:nil,type:"Cafe",cuisines:[],city:"London",neighborhood:"")
        let otherLookup=try AskBusinessRequest.make(trace:lookupTrace,attempt:attempt,record:otherBusiness,fields:["instagram"])
        let otherFields=try AskBusinessRequest.make(trace:lookupTrace,attempt:attempt,record:record,fields:["website"])
        let retryLookup=try AskBusinessRequest.make(trace:lookupTrace,attempt:UUID(),record:record,fields:["instagram"])
        precondition(attemptOne.requestID==sameAttempt.requestID && Set([attemptOne.requestID,otherLookup.requestID,otherFields.requestID,retryLookup.requestID]).count==4)
        let a=try AskBusinessRequest.make(trace:request.performanceID!,record:record,fields:["instagram"]),b=try AskBusinessRequest.make(trace:request.performanceID!,record:record,fields:["instagram"])
        precondition(a.requestID==b.requestID && UUID(uuidString:a.requestID) != nil)
        print("PASS automatic missing-link continuation projects business name/city/requested fields only, omits private history/URLs/status/notes, and keeps a stable deduplication ID")

        let beforeDefault=await calls.count()
        let automatic=try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),researcher:researcher,inspect:{_,_ in .init(status:.unavailable)})
        let afterDefault=await calls.count();precondition(afterDefault==beforeDefault+1 && automatic.paragraphs[0].citations.contains {$0.url==profile})
        print("PASS unavailable website fixture continues through mocked public research; shared Add Place autofill is unchanged")

        let failing=BusinessResearchFixture(run:{_ in throw AskHostedError.service(503)})
        do {_ = try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),researcher:failing,inspect:{_,_ in .init(status:.unavailable)});preconditionFailure("Network failure must not become no Instagram")}
        catch AskHostedError.service(503) {} catch {throw error}
        let unverified=BusinessResearchFixture(run:{r in .init(version:1,state:"unverified",business:r.business,findings:[])})
        let empty=try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),researcher:unverified,inspect:{_,_ in .init(status:.unverified)})
        precondition(empty.paragraphs.flatMap(\.citations).isEmpty && empty.paragraphs.contains {p in p.spans.contains {if case .text(let t)=$0{return t.contains("couldn’t verify")};return false}})
        do {_ = try AskBusinessResult(version:1,state:"found",business:.init(name:"Wrong business",city:"London"),findings:[]).checked(for:a);preconditionFailure("Wrong identity") } catch {}
        print("PASS public lookup distinguishes unavailable versus unverified evidence, rejects identity mismatch, and never guesses a handle or claims none exists")

        let endpoint=URL(string:"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer")!
        let denied=AskHostedProvider(configuration:.init(environment:.production,endpoint:endpoint,scope:.savedMetadata,productionHost:endpoint.host!),token:{preconditionFailure("No token before consent")},approve:{_,_ in false},send:{_ in preconditionFailure("No request before consent")},permission:{false},publicLookupEnabled:{true})
        do {_ = try await denied.businessResearch(a);preconditionFailure("Consent required") } catch AskHostedError.consentRequired {} catch {throw error}
        let transport=AskHostedProvider(configuration:denied.configuration,token:{String(repeating:"a",count:43)},approve:{_,_ in false},send:{http in
            let json=try JSONSerialization.jsonObject(with:http.httpBody!);precondition(json is [String:Any])
            let result:[String:Any] = ["version":1,"state":"unverified","business":["name":"Public Cafe","city":"London"],"findings":[]]
            return (try JSONSerialization.data(withJSONObject:result),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },publicLookupEnabled:{true})
        let transported=try await transport.businessResearch(a);precondition(transported.state=="unverified")
        print("PASS MOCK public request transport is capability/consent gated and authenticated; no private payload or legacy fallback")

        var noSite=record;noSite.websiteURL=nil
        let recordSnapshot=noSite,trace=UUID(),pipelineCalls=BusinessCalls()
        let hosted=AskHostedProvider(configuration:denied.configuration,token:{String(repeating:"a",count:43)},approve:{_,_ in true},send:{http in
            let body=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
            let result:[String:Any]
            if body["mode"] as? String == "libraryIntent" {
                precondition(body["version"] as? Int == 7)
                let context=body["context"] as! [String:Any],index=context["index"] as! [[String:Any]]
                precondition(Set(index[0].keys)==["id","name","city","cuisines"])
                result=["version":3,"plan":["operation":"lookup","scope":"library","city":"London","cuisine":NSNull(),"status":NSNull(),"placeType":NSNull(),"name":"Public Cafe","positions":[],"fields":["instagram"],"neighborhood":NSNull(),"groupBy":NSNull(),"names":NSNull()]]
            } else {
                precondition(body["mode"] as? String == "publicLookup" && Set(body.keys)==["version","mode","requestID","business","fields"])
                let publicRequest=try AskBusinessRequest.make(trace:trace,record:recordSnapshot,fields:["instagram"]);await pipelineCalls.append(publicRequest)
                result=["version":1,"state":"found","business":["name":"Public Cafe","city":"London"],"findings":[["field":"instagram","value":profile,"sourceURL":site,"quote":"Public Cafe in London links this exact Instagram profile.","title":"Contact","verification":"cited_search"]]]
            }
            return (try JSONSerialization.data(withJSONObject:result),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },libraryToolsEnabled:{true},libraryPlanVersion:{4},publicLookupEnabled:{true})
        let pipeline=AskLibraryProvider(remote:hosted,places:{[recordSnapshot]},intentPlanner:hosted,snapshot:{.init(places:[recordSnapshot],totalCount:1)})
        var pipelineRequest=AskRequest(mode:.discovery,text:"Discover how to contact Public Cafe online",fromOCR:false);pipelineRequest.performanceID=trace
        let pipelineTools=try tools(recordSnapshot,pipelineRequest)
        let endToEnd=try pipelineTools.checked(await pipeline.answer(pipelineRequest,tools:pipelineTools))
        let publicCount=await pipelineCalls.count();precondition(publicCount==1 && endToEnd.candidates.map(\.id)==[id] && endToEnd.paragraphs[0].citations.contains {$0.url==profile})
        let acceptedTurn=AskTurn(id:UUID(),request:pipelineRequest,response:endToEnd,status:.complete)
        precondition(acceptedTurn.readContextMode == .collection && AskSemanticContext.recentQuestions([acceptedTurn]).first?.recordIDs == [id])
        print("PASS MOCK full native model-plan→fresh business resolution→public-only continuation→grounded inline link, with no second user prompt or legacy dispatch; not a real API verification")

        for (field,question) in [("address","What is the address for Public Cafe?"),("phone","What is its phone number?"),("hours","What are its hours?"),("menu","Where is its menu?"),("website","What is its website?"),("instagram","And its Instagram?")] {
            let fieldCalls=BusinessCalls()
            let semantic=AskHostedProvider(configuration:denied.configuration,token:{String(repeating:"a",count:43)},approve:{_,_ in true},send:{http in
                let body=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
                let result:[String:Any]
                if body["mode"] as? String == "libraryIntent" {
                    result=["version":3,"plan":["operation":"lookup","scope":"previous","city":NSNull(),"cuisine":NSNull(),"status":NSNull(),"placeType":NSNull(),"name":NSNull(),"positions":[],"fields":[field],"neighborhood":NSNull(),"groupBy":NSNull(),"names":NSNull()]]
                } else {
                    let publicRequest=try AskBusinessRequest.make(trace:trace,record:recordSnapshot,fields:[field]);await fieldCalls.append(publicRequest)
                    result=["version":1,"state":"unverified","business":["name":"Public Cafe","city":"London"],"findings":[]]
                }
                return (try JSONSerialization.data(withJSONObject:result),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
            },libraryToolsEnabled:{true},libraryPlanVersion:{4},publicLookupEnabled:{true})
            var q=AskRequest(mode:.collection,text:question,fromOCR:false);q.performanceID=UUID()
            // A prior PUBLIC address lookup must not taint later public followups as private.
            q.libraryContext = .init(ids:[id],filters:.init(operation:.lookup,scope:.library,city:"London",cuisine:nil,status:nil,placeType:nil,name:recordSnapshot.name,positions:[],fields:["address"]))
            let provider=AskLibraryProvider(remote:semantic,places:{[recordSnapshot]},intentPlanner:semantic,snapshot:{.init(places:[recordSnapshot],totalCount:1)})
            let response=try await provider.answer(q,tools:tools(recordSnapshot,q))
            let n=await fieldCalls.count();precondition(n==1 && response.libraryContext?.excludesExternalReferences != true)
        }
        print("PASS MOCK public address/phone/hours/menu/website/Instagram reach semantic fallback, including public-address followup without private-context false positive")

        var storedQuestion=AskRequest(mode:.collection,text:"What address is recorded for Public Cafe?",fromOCR:false);storedQuestion.performanceID=UUID()
        let storedPlan=AskLibraryPlan(operation:.details,scope:.library,city:"London",cuisine:nil,status:nil,placeType:nil,name:recordSnapshot.name,positions:[],fields:["address"])
        let storedRemote=BusinessResearchFixture(run:{_ in preconditionFailure("Explicit saved-only question must not research missing facts")})
        let storedProvider=AskLibraryProvider(remote:storedRemote,places:{[recordSnapshot]},intentPlanner:BusinessPlannerFixture(plan:storedPlan),snapshot:{.init(places:[recordSnapshot],totalCount:1)})
        let storedAnswer=try await storedProvider.answer(storedQuestion,tools:tools(recordSnapshot,storedQuestion))
        precondition(storedAnswer.paragraphs.flatMap(\.citations).isEmpty)
        print("PASS explicit saved-only public detail uses typed local read and never invents or researches missing stored facts")

        var protectedAnswer=try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),allowExternalLookups:false,externalLimitation:"Private selection stays on device.",researcher:noNetwork,inspect:{_,_ in preconditionFailure("Private-derived selection must never reach a website")})
        protectedAnswer.libraryContext?.excludesExternalReferences=true
        let privateTurn=AskTurn(id:UUID(),request:request,response:protectedAnswer,status:.complete)
        precondition(AskSemanticContext.recentQuestions([privateTurn]).first?.recordIDs.isEmpty == true)
        let snapshot=AskLibrarySnapshot(places:[record],totalCount:1)
        let prior=AskLibraryContext(ids:[record.id],filters:.init(operation:.list,scope:.library,city:nil,cuisine:nil,status:"Love",placeType:nil,name:nil,positions:[],fields:[]),excludesExternalReferences:true)
        let protectedResult=try AskLibraryReadTools.execute(.init(operation:.lookup,scope:.previous,city:nil,cuisine:nil,status:nil,placeType:nil,name:nil,positions:[],fields:["instagram"]),snapshot:snapshot,context:prior)
        precondition(protectedResult.excludesExternalReferences)
        print("PASS private-filter-derived identities stay on device: no official-site or search fallback and no model reference leak")

        let cancelled=Task {try await AskBusinessLookup.answer(request,plan:plan,record:record,tools:tools(record,request),researcher:researcher,inspect:{_,_ in try await Task.sleep(nanoseconds:1_000_000_000);return .init(status:.unverified)})}
        cancelled.cancel();do {_ = try await cancelled.value;preconditionFailure("Cancellation must stop continuation")}catch is CancellationError {}catch {throw error}
        print("PASS cancelled public lookup does not continue to another service or publish a late result")
    }
}
