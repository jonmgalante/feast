import Foundation
import CoreData

private struct NeverLibraryRemote: AskFeastProvider {
    let label = "Offline only"
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse { preconditionFailure("No remote answer or web fallback allowed") }
}
private struct LibraryPlannerFixture: AskLibraryIntentPlanning {
    let plans: [String:AskLibraryPlan]
    func libraryPlan(_ question: String) async throws -> AskLibraryPlan? {
        guard let plan = plans[question] else { throw AskError.invalidEvidence }
        return plan
    }
}
@MainActor enum AskLibraryToolsTests {
    static func run(model: NSManagedObjectModel) async throws {
        let appSource = try String(contentsOfFile: "Feast/Features/AskFeast/AskFeastTab.swift", encoding:.utf8)
        precondition(!appSource.contains("state.prepare(") && !appSource.contains("MockAskFeastProvider("))
        precondition(!appSource.contains("AskFeastPanel(sandbox:"))
        let unavailable = AskFeastTabState(); unavailable.markUnavailable()
        precondition(unavailable.session == nil && unavailable.sandbox == nil && unavailable.error?.contains("configured") == true)
        let fixture = try AskPrototypeSandbox(model:model)
        var cities: [UUID] = []
        for (city,count) in [("NYC",16),("London",6),("Paris",6),("LA",2),("Chicago",3)] {
            let list = try fixture.repository.createFeastList(named:city); cities.append(list.id!)
            for i in 0..<count {
                _ = try fixture.repository.createSavedPlace(from:.init(applePlaceID:"tool-\(city)-\(i)",displayNameSnapshot:"Venue \(i)",status:i == 1 ? .been : .wantToTry,placeType:.restaurant,cuisines:[i < 2 ? "Italian" : "French"],tags:["PRIVATE_TAG"],note:"PRIVATE_NOTE_DO_NOT_SEND",websiteURL:nil,instagramURL:nil,feastList:list,listSection:nil))
            }
        }
        let visible = Set(cities)
        let adapter = AskSavedCollection(context:fixture.context,visibleCities:{visible})
        func protectedState() throws -> [String] {
            let places = try fixture.repository.fetchSavedPlaces()
            var rows: [String] = []
            for place in places {
                var attributes: [String] = []
                for key in place.entity.attributesByName.keys.sorted() {
                    let value = place.value(forKey:key)
                    let canonical: String
                    if let date = value as? Date { canonical = String(date.timeIntervalSinceReferenceDate.bitPattern) }
                    else if let id = value as? UUID { canonical = id.uuidString }
                    else if let text = value as? String { canonical = text }
                    else if let bytes = value as? Data { canonical = bytes.base64EncodedString() }
                    else { canonical = value == nil ? "<nil>" : String(describing:value!) }
                    attributes.append(key + ":" + canonical)
                }
                let city = place.feastList?.id?.uuidString ?? ""
                let section = place.listSection?.id?.uuidString ?? ""
                rows.append(attributes.joined(separator:"|") + "|city:" + city + "|section:" + section)
            }
            return rows.sorted()
        }
        let beforeReadOnly = try protectedState()
        let snapshot = try adapter.librarySnapshot(),index = try adapter.index()
        precondition(snapshot.totalCount == 33 && snapshot.complete && snapshot.cities.count == 5)
        func plan(_ op:AskLibraryPlan.Operation = .list,_ scope:AskLibraryPlan.Scope = .library,city:String?=nil,cuisine:String?=nil,status:String?=nil,name:String?=nil,positions:[Int]=[],fields:[String]=[]) -> AskLibraryPlan {
            .init(operation:op,scope:scope,city:city,cuisine:cuisine,status:status,placeType:nil,name:name,positions:positions,fields:fields)
        }
        let london = plan(city:"London"), italian = plan(.list,.previous,cuisine:"Italian"), second = plan(.details,.previous,positions:[2],fields:["cuisine"]), paris = plan(city:"Paris")
        let questions = ["What are my saved places in London?","Show me everything I saved in London","Which places did we save in London?"]
        var scripted = Dictionary(uniqueKeysWithValues:questions.map { ($0,london) })
        scripted["Which are Italian?"] = italian;scripted["The second one"] = second;scripted["What about Paris?"] = paris
        scripted["Only untried"] = plan(.list,.previous,status:"untried")
        scripted["Compare the first two"] = plan(.compare,.previous,positions:[1,2])
        let provider = AskLibraryProvider(remote:NeverLibraryRemote(),places:{try await adapter.personalPlaces()},intentPlanner:LibraryPlannerFixture(plans:scripted),snapshot:{try await adapter.librarySnapshot()})
        for question in questions {
            let r=AskRequest(mode:.collection,text:question,fromOCR:false),tools=try AskReadTools(request:r,index:index)
            let answer=try tools.checked(await provider.answer(r,tools:tools))
            precondition(answer.candidates.count == 6 && answer.libraryContext?.ids.count == 6)
            precondition(answer.candidates.allSatisfy { AskPlaceReference.url(for:$0) != nil })
        }
        let session=AskSession(index:index,provider:provider)
        for (question,expected) in [(questions[0],6),("Which are Italian?",2),("The second one",1),("What about Paris?",6),("Compare the first two",2)] {
            session.input=question;session.runAutomatically();while session.isLoading { await Task.yield() }
            precondition(session.turns.last?.status == .complete && session.response?.candidates.count == expected)
        }
        let context=AskLibraryContext(ids:snapshot.places.filter{$0.city=="London"}.sorted{$0.name<$1.name}.map(\.id),filters:london)
        let untried=try AskLibraryReadTools.execute(plan(.list,.previous,status:"untried"),snapshot:snapshot,context:context)
        precondition(untried.records.count == 5 && untried.records.allSatisfy{$0.status=="Want to try"})
        let missing=try AskLibraryReadTools.execute(plan(city:"Atlantis"),snapshot:snapshot,context:nil)
        precondition(missing.status == .success && missing.records.isEmpty && missing.complete)
        let partial=try AskLibraryReadTools.execute(plan(city:"Atlantis"),snapshot:.init(places:snapshot.places,totalCount:1000),context:nil)
        precondition(partial.status == .partial && !partial.complete)
        let ambiguous=try AskLibraryReadTools.execute(plan(.details,name:"Venue 0"),snapshot:snapshot,context:nil)
        precondition(ambiguous.status == .ambiguous && ambiguous.records.count == 5)
        let stale=try AskLibraryReadTools.execute(second,snapshot:.init(places:snapshot.places.filter{$0.id != context.ids[1]},totalCount:32),context:context)
        precondition(stale.status == .stale)
        do { _ = try plan(.list,positions:[0]).validated();preconditionFailure("invalid ordinal accepted") } catch {}
        let unsupported=try AskLibraryReadTools.execute(plan(.unsupported),snapshot:snapshot,context:nil)
        let afterReadOnly = try adapter.librarySnapshot()
        precondition(unsupported.status == .unsupported && afterReadOnly.totalCount == 33)
        let afterProtected = try protectedState()
        precondition(beforeReadOnly == afterProtected)
        print("PASS read-only 33-place/5-city/6-London tool fixture, paraphrase contracts, London→Italian→second→Paris→compare, exact inline IDs, untried status, ambiguity/stale/partial vs true empty, no remote fallback/writes")
        let catalogRequest = AskRequest(mode:.collection,text:"Show my collection",fromOCR:false)
        let catalogTools = try AskReadTools(request:catalogRequest,index:index)
        let catalogResult = try AskLibraryReadTools.execute(plan(.catalog),snapshot:snapshot,context:nil)
        let catalogAnswer = try catalogTools.checked(AskLibraryReadTools.response(catalogResult,tools:catalogTools))
        precondition(catalogAnswer.summary.contains("33") && catalogAnswer.candidates.isEmpty)
        let ambiguousAnswer = try catalogTools.checked(AskLibraryReadTools.response(ambiguous,tools:catalogTools))
        precondition(ambiguousAnswer.candidates.count == 5 && ambiguousAnswer.paragraphs.count == 6)
        let partialAnswer = try catalogTools.checked(AskLibraryReadTools.response(partial,tools:catalogTools))
        precondition(partialAnswer.summary.contains("complete") && !partialAnswer.summary.contains("No saved"))
        let failure = AskLibraryProvider(remote:NeverLibraryRemote(),places:{preconditionFailure("read error cannot fall back")},intentPlanner:LibraryPlannerFixture(plans:[questions[0]:london]),snapshot:{throw CocoaError(.fileReadCorruptFile)})
        do { _ = try await failure.answer(.init(mode:.collection,text:questions[0],fromOCR:false),tools:catalogTools);preconditionFailure("read error became answer") } catch {}
        print("PASS catalog/ambiguity render through evidence checker; partial/read failure never means none saved or falls back to web")
        // Model semantics are mocked; execution, IDs, completeness and context are real application code.
        var groupPlan=plan(.group,city:"London");groupPlan.groupBy="cuisine"
        let semanticQuestions=["What’s saved on Los Angeles?":plan(city:"Los Angeles"),"Gimme a cuisine breakdown of everything we kept in London":groupPlan,"How many of those are untried?":plan(.count,.previous,status:"untried")]
        let semantic=AskLibraryProvider(remote:NeverLibraryRemote(),places:{snapshot.places},intentPlanner:LibraryPlannerFixture(plans:semanticQuestions),snapshot:{snapshot})
        let aliasRequest=AskRequest(mode:.collection,text:"What’s saved on Los Angeles?",fromOCR:false)
        let aliasTools=try AskReadTools(request:aliasRequest,index:index)
        let aliasAnswer=try aliasTools.checked(await semantic.answer(aliasRequest,tools:aliasTools))
        precondition(aliasAnswer.candidates.count == 2 && aliasAnswer.libraryContext?.filters.city == "LA")
        let groupRequest=AskRequest(mode:.collection,text:"Gimme a cuisine breakdown of everything we kept in London",fromOCR:false)
        let groupTools=try AskReadTools(request:groupRequest,index:index)
        let grouped=try groupTools.checked(await semantic.answer(groupRequest,tools:groupTools))
        precondition(grouped.summary.contains("Italian: 2") && grouped.summary.contains("French: 4") && grouped.candidates.isEmpty && grouped.libraryContext?.selectionIDs?.count == 6)
        let countRequest=AskRequest(mode:.collection,text:"How many of those are untried?",fromOCR:false,libraryContext:grouped.libraryContext)
        let countTools=try AskReadTools(request:countRequest,index:index)
        let counted=try countTools.checked(await semantic.answer(countRequest,tools:countTools))
        precondition(counted.summary == "5 saved places in London." && counted.libraryContext?.selectionIDs?.count == 5 && counted.libraryContext?.ids.isEmpty == true)
        let largeRecords=(0..<200).map {i in AskPersonalPlace(id:UUID().uuidString,name:"Le Bernardin \(i)",status:nil,type:nil,cuisines:["French","Seafood"],city:i%2==0 ? "New York" : "Paris",neighborhood:"")}
        let largeIndex=AskLocalIndex(records:largeRecords.map {.init(id:$0.id,cityID:$0.city,city:$0.city,name:$0.name,neighborhood:"",cuisine:$0.cuisines.joined(separator:", "),status:"",notes:[])},visibleCityIDs:["New York","Paris"],visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:largeRecords)
        let largeTools=try AskReadTools(request:AskRequest(mode:.collection,text:"Group every entry without dropping rows",fromOCR:false),index:largeIndex)
        for field in ["city","cuisine"] {
            var groupedRows=plan(.list);groupedRows.groupBy=field
            let rows=try AskLibraryReadTools.execute(groupedRows,snapshot:.init(places:largeRecords,totalCount:200),context:nil,requireUniqueDetails:false)
            let rendered=try largeTools.checked(AskLibraryReadTools.response(rows,tools:largeTools))
            let rowIDs=rendered.paragraphs.flatMap(\.spans).compactMap {span->String? in if case .place(let id)=span{return id};return nil}
            precondition(Set(rowIDs)==Set(largeRecords.map(\.id)) && rowIDs.count==(field=="city" ? 200 : 400))
        }
        var composableCount=plan(.count);composableCount.groupBy="city"
        let cityCounts=try AskLibraryReadTools.response(AskLibraryReadTools.execute(composableCount,snapshot:snapshot,context:nil,requireUniqueDetails:false),tools:catalogTools)
        precondition(cityCounts.summary.contains("London: 6") && cityCounts.summary.contains("NYC: 16"))
        print("PASS schema-composable count/group and complete 200-row grouped lists with overlapping cuisine membership and validated identities")
        let zeroResult=try AskLibraryReadTools.execute(plan(.count,city:"Atlantis"),snapshot:snapshot,context:nil)
        let zeroAnswer=try catalogTools.checked(AskLibraryReadTools.response(zeroResult,tools:catalogTools))
        let zeroRefinement=try AskLibraryReadTools.execute(plan(.list,.previous,cuisine:"Italian"),snapshot:snapshot,context:zeroAnswer.libraryContext)
        precondition(zeroRefinement.status == .success && zeroRefinement.records.isEmpty)
        let aggregateOrdinal=try AskLibraryReadTools.execute(second,snapshot:snapshot,context:counted.libraryContext)
        precondition(aggregateOrdinal.status == .stale) // no invented “second” when only a count was displayed
        var comparison=plan(.compare,city:"London",fields:["cuisine","status"]);comparison.names=["Venue 0","Venue 1"]
        let compared=try AskLibraryReadTools.execute(comparison,snapshot:snapshot,context:nil)
        precondition(compared.records.map(\.name) == ["Venue 0","Venue 1"])
        var neighborhood=plan(.list,city:"London");neighborhood.neighborhood="Unknown neighborhood"
        let noNeighborhood=try AskLibraryReadTools.execute(neighborhood,snapshot:snapshot,context:nil);precondition(noNeighborhood.records.isEmpty)
        if case .matched(let name)=AskCityIdentity.resolve("San Francisco",available:["SF","London"]) {precondition(name == "SF")} else {preconditionFailure("Available acronym identity not resolved")}
        if case .ambiguous=AskCityIdentity.resolve("L.A.",available:["LA","L.A."]) {} else {preconditionFailure("Ambiguous available city aliases must not merge")}
        if case .matched(let name)=AskCityIdentity.resolve("Los Angeles",available:["LA","Los Angeles"]) {precondition(name == "Los Angeles")} else {preconditionFailure("Explicit exact city wins")}
        print("PASS arbitrary-phrasing mocked semantic fallback, available city identities/ambiguity, complete local cuisine groups/counts, aggregate followups without invented ordinal order, named comparison and unknown neighborhood")

        let endpoint=URL(string:"https://fixture.workers.dev/v1/answer")!
        let hosted=AskHostedProvider(configuration:.init(environment:.development,endpoint:endpoint,scope:.savedMetadata),token:{String(repeating:"a",count:43)},approve:{_,_ in false},send:{http in
            let body=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
            precondition(Set(body.keys)==["version","requestID","mode","text"] && body["text"] as? String == "Which are Italian?")
            precondition(!String(data:http.httpBody!,encoding:.utf8)!.contains("PRIVATE"))
            let raw="""
            {"version":1,"plan":{"operation":"list","scope":"previous","city":null,"cuisine":"Italian","status":null,"placeType":null,"name":null,"positions":[],"fields":[]}}
            """
            return (Data(raw.utf8),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },libraryToolsEnabled:{true})
        let interpreted = try await hosted.libraryPlan("Which are Italian?")
        precondition(interpreted == italian)
        let disabled=AskHostedProvider(configuration:hosted.configuration,token:{preconditionFailure("Disabled planning must not read token")},approve:{_,_ in false},send:{_ in preconditionFailure("Disabled planning must not send")})
        let disabledPlan = try await disabled.libraryPlan("Show saved places")
        precondition(disabledPlan == nil)
        print("PASS intent transport sends current question only, no catalog/records/history/status facts/tool results; disabled capability stops before credentials/network")
        let expandedTransport=AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"a",count:43)},approve:{_,_ in false},send:{http in
            let payload=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
            precondition(payload["version"] as? Int == 5 && Set(payload.keys) == ["version","mode","requestID","text"])
            let raw="""
            {"version":2,"plan":{"operation":"group","scope":"previous","city":null,"cuisine":null,"status":null,"placeType":null,"name":null,"positions":[],"fields":[],"neighborhood":null,"groupBy":"status","names":null}}
            """
            return(Data(raw.utf8),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },libraryToolsEnabled:{true},libraryPlanVersion:{2})
        let expandedPlan=try await expandedTransport.libraryPlan("Break those down by saved status")
        precondition(expandedPlan?.operation == .group && expandedPlan?.groupBy == "status")
        print("PASS v5 general model contract while v4 remains compatible; current question only, no catalog/history/status facts sent")
        var privateAnswer=aliasAnswer
        privateAnswer.paragraphs=[.init(id:"private-prose",spans:[.text("PRIVATE_NOTE Been precise coordinates City of Westminster")],sourceIDs:[])]
        privateAnswer.libraryContext = .init(ids:aliasAnswer.candidates.map(\.id),filters:plan(.list,status:"Been"))
        let safeTurn=AskTurn(id:UUID(),request:.init(mode:.collection,text:"What is saved in LA?",fromOCR:false),response:aliasAnswer,status:.complete)
        let privateTurn=AskTurn(id:UUID(),request:.init(mode:.collection,text:"Which ones did we keep?",fromOCR:false),response:privateAnswer,status:.complete)
        let recent=AskSemanticContext.recentQuestions([safeTurn,privateTurn])
        precondition(recent.count == 2 && recent[0].recordIDs.count == 2 && recent[1].recordIDs.isEmpty)
        var contextRequest=AskRequest(mode:.collection,text:"What’s saved on Los Angeles?",fromOCR:false)
        contextRequest.recentQuestions=recent
        let projected=try AskSemanticContext.make(contextRequest,catalog:snapshot)
        let projectionText=String(data:try JSONEncoder().encode(projected),encoding:.utf8)!
        precondition(!projectionText.contains("PRIVATE_NOTE") && !projectionText.contains("Been") && !projectionText.contains("Westminster") && !projectionText.contains("coordinates"))
        let contextTransport=AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"a",count:43)},approve:{_,_ in false},send:{http in
            let payload=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
            precondition(payload["version"] as? Int == 6 && Set(payload.keys) == ["version","mode","requestID","text","context"])
            let context=payload["context"] as! [String:Any],records=context["index"] as! [[String:Any]]
            precondition(records.count == 33 && records.allSatisfy {Set($0.keys)==["id","name","city","cuisines"]})
            let raw="""
            {"version":2,"plan":{"operation":"list","scope":"library","city":"Los Angeles","cuisine":null,"status":null,"placeType":null,"name":null,"positions":[],"fields":[],"neighborhood":null,"groupBy":null,"names":null}}
            """
            return(Data(raw.utf8),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },libraryToolsEnabled:{true},libraryPlanVersion:{3})
        let contextualPlan=try await contextTransport.libraryPlan(contextRequest,catalog:snapshot)
        precondition(contextualPlan?.city == "Los Angeles")
        let deniedContext=AskHostedProvider(configuration:hosted.configuration,token:{preconditionFailure("No credential before scope consent")},approve:{_,_ in false},send:{_ in preconditionFailure("No context before consent")},libraryToolsEnabled:{true},permission:{false},libraryPlanVersion:{3})
        let noContextPlan=try await deniedContext.libraryPlan(contextRequest,catalog:snapshot);precondition(noContextPlan == nil)
        print("PASS approved bounded catalog/recent-user-question context excludes assistant prose, private-derived refs/status/notes/location; v6 capability + fresh scope consent required before any transfer")
        let denied = AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"a",count:43)},approve:{_,_ in false},send:{_ in
            (Data(),HTTPURLResponse(url:endpoint,statusCode:401,httpVersion:nil,headerFields:nil)!)
        },libraryToolsEnabled:{true})
        do { _ = try await denied.libraryPlan("Show saved places");preconditionFailure("auth failure became empty") }
        catch AskHostedError.service(401) {} catch { throw error }
        let malformed = AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"a",count:43)},approve:{_,_ in false},send:{_ in
            (Data("{\"version\":1,\"plan\":{\"ids\":[\"invented\"]}}".utf8),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },libraryToolsEnabled:{true})
        do { _ = try await malformed.libraryPlan("Show saved places");preconditionFailure("forged plan accepted") }
        catch AskHostedError.invalidResponse {} catch { throw error }
        print("PASS intent authentication and malformed/forged-record response errors propagate, never become successful empty results")

        let reasoningQuestion = "Compare the cuisines of my saved London places"
        let reasoningPlan = plan(.answer,city:"London",fields:["cuisine"])
        let synthesis = AskHostedProvider(configuration:hosted.configuration,token:{String(repeating:"a",count:43)},approve:{request,evidence in
            request.previousQuestion == nil && request.libraryContext == nil && evidence.candidates.count == 6
        },send:{http in
            let body = try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
            precondition(body["version"] as? Int == 2 && body["text"] as? String == reasoningQuestion)
            let candidates = body["candidates"] as! [[String:Any]],sources = body["sources"] as! [[String:Any]]
            precondition(candidates.count == 6 && sources.count == 6)
            for source in sources {
                let fields = try JSONSerialization.jsonObject(with:Data((source["excerpt"] as! String).utf8)) as! [String:Any]
                precondition(Set(fields.keys) == ["name","cuisines"])
            }
            let id = candidates[0]["id"] as! String, source = (candidates[0]["sourceIDs"] as! [String])[0]
            let response: [String:Any] = ["version":1,"summary":"Saved cuisine comparison.","candidateIDs":[id],"paragraphs":[["id":"reasoned","spans":[["type":"place","value":id],["type":"text","value":" has its recorded cuisine available for comparison."]],"sourceIDs":[source]]]]
            return (try JSONSerialization.data(withJSONObject:response),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        })
        let reasoning = AskLibraryProvider(remote:synthesis,places:{snapshot.places},intentPlanner:LibraryPlannerFixture(plans:[reasoningQuestion:reasoningPlan]))
        let reasoningRequest = AskRequest(mode:.collection,text:reasoningQuestion,fromOCR:false)
        let reasoningTools = try AskReadTools(request:reasoningRequest,index:index)
        let grounded = try reasoningTools.checked(await reasoning.answer(reasoningRequest,tools:reasoningTools))
        precondition(grounded.candidates.count == 1 && grounded.libraryContext?.ids == grounded.candidates.map(\.id))
        precondition(grounded.paragraphs[0].spans[0] == .place(grounded.candidates[0].id))
        print("PASS conversational synthesis uses exact locally selected metadata only; preserves existing payload exclusions/approval, validates returned IDs and retains shown order without broad history")
        let offline = AskLibraryProvider(remote:AskUnavailableProvider(),places:{snapshot.places},snapshot:{snapshot})
        let localSession=AskSession(index:index,provider:offline)
        for (question,expected) in [(questions[0],6),("Which are Italian?",2),("The second one",1),("What about Paris?",6)] {
            localSession.input=question;localSession.runAutomatically();while localSession.isLoading { await Task.yield() }
            precondition(localSession.turns.last?.status == .complete && localSession.response?.candidates.count == expected)
        }
        let detailPlaces: [AskPersonalPlace] = [
            .init(id:UUID().uuidString,name:"Qima Cafe",status:"Want to try",type:"Cafe",cuisines:["British"],city:"London",neighborhood:"City of Westminster"),
            .init(id:UUID().uuidString,name:"Dishoom",status:"Been",type:"Restaurant",cuisines:["Indian"],city:"London",neighborhood:"Shoreditch"),
            .init(id:UUID().uuidString,name:"Dishoom",status:nil,type:nil,cuisines:[],city:"London",neighborhood:"")]
        let detailSnapshot = AskLibrarySnapshot(places:detailPlaces,totalCount:3)
        let detailCityID = UUID().uuidString
        let detailIndex = AskLocalIndex(records:detailPlaces.map { .init(id:$0.id,cityID:detailCityID,city:"",name:$0.name,neighborhood:"",cuisine:$0.cuisines.joined(separator:", "),status:"",notes:[]) },visibleCityIDs:[detailCityID],visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:detailPlaces)
        let detailProvider = AskLibraryProvider(remote:NeverLibraryRemote(),places:{detailPlaces},snapshot:{detailSnapshot})
        let detailContext = AskLibraryContext(ids:detailPlaces.map(\.id),filters:plan(city:"London"))
        for (question,field) in [
            ("What neighborhood is Qima cafe in?","neighborhood"),
            ("What neighbourhood is the first one in?","neighborhood"),
            ("What cuisine is Qima Cafe?","cuisine"),
            ("Have I visited Qima Cafe?","status"),
            ("What is the second one's status?","status"),
            ("What is Qima Cafe's address?","address")] {
            let request = AskRequest(mode:.collection,text:question,fromOCR:false,libraryContext:detailContext)
            let local = AskOnDeviceReadPlan.make(request,places:detailPlaces)!
            precondition(local.fields.contains(field))
            let result = try AskLibraryReadTools.execute(local,snapshot:detailSnapshot,context:detailContext)
            precondition(result.status == .success && result.records.count == 1)
            if field == "neighborhood" { precondition(result.records[0].neighborhood == "City of Westminster") }
            let detailTools = try AskReadTools(request:request,index:detailIndex)
            let detailAnswer = try detailTools.checked(await detailProvider.answer(request,tools:detailTools))
            let rendered = detailAnswer.paragraphs.flatMap(\.spans).compactMap { span -> String? in if case .text(let text) = span { return text };return nil }.joined()
            precondition(!rendered.isEmpty && detailAnswer.candidates.count == 1)
            if field == "address" { precondition(rendered.contains("Street address isn’t recorded")) }
            if field == "status" { precondition(rendered.contains("Marked ")) }
            if field == "neighborhood" { precondition(rendered.contains("City of Westminster")) }
        }
        for question in ["Where are the two Dishooms?","Where are both Dishooms?","Where is each Dishoom?"] {
            let req=AskRequest(mode:.collection,text:question,fromOCR:false,libraryContext:detailContext)
            let plural=AskOnDeviceReadPlan.make(req,places:detailPlaces)!
            precondition(plural.operation == .compare && plural.fields == ["city","neighborhood"])
            let result=try AskLibraryReadTools.execute(plural,snapshot:detailSnapshot,context:detailContext)
            precondition(result.status == .success && result.records.count == 2)
        }
        let unavailableRuntime=AskHostedProvider(configuration:.init(environment:.production,endpoint:URL(string:"https://example.com/v1/answer")!,scope:.savedMetadata,productionHost:"example.com"),token:{preconditionFailure("No credential when disabled")},approve:{_,_ in preconditionFailure("No approval when disabled")},send:{_ in preconditionFailure("No network when disabled")},libraryToolsEnabled:{false})
        let unavailableLibrary=AskLibraryProvider(remote:unavailableRuntime,places:{detailPlaces},intentPlanner:unavailableRuntime,snapshot:{detailSnapshot})
        let publicQuestion=AskRequest(mode:.collection,text:"Can you find an instagram for Qima Cafe?",fromOCR:false)
        do { _ = try await unavailableLibrary.answer(publicQuestion,tools:AskReadTools(request:publicQuestion,index:detailIndex));preconditionFailure("Disabled capability must stop") }
        catch AskHostedError.disabled { }
        let detailAmbiguous = AskOnDeviceReadPlan.make(.init(mode:.collection,text:"What neighborhood is Dishoom in?",fromOCR:false,libraryContext:detailContext),places:detailPlaces)!
        let ambiguousResult = try AskLibraryReadTools.execute(detailAmbiguous,snapshot:detailSnapshot,context:detailContext)
        precondition(ambiguousResult.status == .ambiguous)
        let missingRequest = AskRequest(mode:.collection,text:"What neighborhood is the first one in?",fromOCR:false,libraryContext:.init(ids:[detailPlaces[2].id],filters:plan(city:"London")))
        let missingTools = try AskReadTools(request:missingRequest,index:detailIndex)
        let missingAnswer = try missingTools.checked(await detailProvider.answer(missingRequest,tools:missingTools))
        precondition(missingAnswer.paragraphs.flatMap(\.spans).contains(.text(" — Neighborhood isn’t recorded")))
        print("PASS named/ordinal local neighborhood, cuisine, recorded visit status, missing address and duplicate-name ambiguity without online calls")
        let config = AskProductionAccess.configuration(info:[:]); precondition(config == nil)
        precondition(AskProductionAccess.configuration(info:["FeastAskProductionEndpoint":"https://feast-proxy-dev.jonmgalante.workers.dev/v1/answer","FeastAskProductionHost":"feast-proxy-dev.jonmgalante.workers.dev"]) == nil)
        let production = AskProductionAccess.configuration(info:["FeastAskProductionEndpoint":"https://feast.example.com/v1/answer","FeastAskProductionHost":"feast.example.com"])
        precondition(production != nil)
        let permissionDenied=AskHostedProvider(configuration:hosted.configuration,token:{preconditionFailure("No credential before permission")},approve:{_,_ in preconditionFailure("No projection before permission")},send:{_ in preconditionFailure("No upload before permission")},libraryToolsEnabled:{true},permission:{false})
        let noPlan = try await permissionDenied.libraryPlan("Show saved places");precondition(noPlan == nil)
        do { _ = try await permissionDenied.answer(reasoningRequest,tools:reasoningTools);preconditionFailure("Permission denied must not answer online") }
        catch AskHostedError.consentRequired {} catch {throw error}
        print("PASS normal product local London→Italian→second→Paris works without any online provider; production host is explicit/not dev; denied consent prevents credential lookup, projection and all online sends")
        let ownerInfo:[String:Any] = ["FeastAskOwnerValidationEnabled":true,"FeastAskOwnerValidationEndpoint":"https://feast-owner-validation.jonmgalante.workers.dev/v1/answer"]
        let ownerConfiguration=AskOwnerValidationAccess.configuration(info:ownerInfo)!
        precondition(ownerConfiguration.ownerValidation && (try? ownerConfiguration.validate()) != nil)
        precondition(AskOwnerValidationAccess.configuration(info:[:]) == nil)
        precondition(AskOwnerValidationAccess.configuration(info:["FeastAskOwnerValidationEnabled":true,"FeastAskOwnerValidationEndpoint":"https://feast-proxy-production.jonmgalante.workers.dev/v1/answer"]) == nil)
        let trace=UUID(),ownerID=snapshot.places.first(where:{$0.city == "London"})!.id
        let ownerPlan=plan(.answer,city:"London",fields:["cuisine"])
        let ownerTransport=AskHostedProvider(configuration:ownerConfiguration,token:{String(repeating:"a",count:43)},approve:{_,_ in true},send:{http in
            let body=try JSONSerialization.jsonObject(with:http.httpBody!) as! [String:Any]
            precondition(body["version"] as? Int == 6 && body["requestID"] as? String == trace.uuidString)
            var encodedPlan=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ownerPlan)) as! [String:Any]
            for key in ["city","cuisine","status","placeType","name","neighborhood","groupBy","names"] where encodedPlan[key] == nil {encodedPlan[key]=NSNull()}
            let response:[String:Any] = ["version":2,"plan":encodedPlan,"answer":["version":1,"summary":"Cuisine comparison.","candidateIDs":[ownerID],"paragraphs":[["id":"owner","spans":[["type":"place","value":ownerID],["type":"text","value":" has a recorded cuisine."]],"sourceIDs":["metadata-"+ownerID]]]]]
            return (try JSONSerialization.data(withJSONObject:response),HTTPURLResponse(url:ownerConfiguration.endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        },libraryToolsEnabled:{true},permission:{true},libraryPlanVersion:{3})
        var ownerRequest=AskRequest(mode:.collection,text:"Explain the cuisine variety among these saved London choices",fromOCR:false)
        ownerRequest.performanceID=trace
        let selectedPlan=try await ownerTransport.libraryPlan(ownerRequest,catalog:snapshot)
        precondition(selectedPlan?.operation == .answer)
        let ownerTools=try AskReadTools(request:ownerRequest,index:index)
        let (resolvedOwner,scopedOwner)=try ownerTools.resolving([ownerID])
        let scopedEvidence=try scopedOwner.collection(.init(text:resolvedOwner.text,limit:6))
        let freshApproval=try AskFeastTabState.verifiedHostedEvidence(resolvedOwner,index:index,evidence:scopedEvidence,exactSelection:true);precondition(freshApproval)
        let ownerAnswer=try await ownerTransport.answer(resolvedOwner,tools:scopedOwner)
        precondition(ownerAnswer.candidates.map(\.id) == [ownerID])
        do {_ = try await ownerTransport.answer(resolvedOwner,tools:scopedOwner);preconditionFailure("Consumed broker result must not cause another paid dispatch")}
        catch AskHostedError.invalidResponse {} catch {throw error}
        let previousLondon=AskLibraryContext(ids:[ownerID],filters:plan(city:"London"))
        let conflicting=try AskLibraryReadTools.execute(plan(.list,.previous,city:"Paris"),snapshot:snapshot,context:previousLondon)
        precondition(conflicting.records.isEmpty)
        precondition(!AskHostedError.service(409).retryable)
        let sources=[AskWebCitation(title:"Menu",url:"https://jackswifefreda.com/menu/?utm_source=openai"),AskWebCitation(title:"Menu",url:"https://ilovebuvette.com/menus-newyork-location?utm_source=openai"),AskWebCitation(title:"Details",url:"https://www.thelittleowlnyc.com/?trk=public_post_comment-text&utm_source=openai")]
        for (raw,source) in zip(["https://jackswifefreda.com/menu/","https://ilovebuvette.com/menus-newyork-location","https://www.thelittleowlnyc.com/"],sources) {
            let restored=try JSONDecoder().decode(AskWebCitation.self,from:JSONEncoder().encode(source))
            precondition(AskCitationLink.acceptedURL(for:URL(string:raw)!,citations:[restored])==source.safeURL)
        }
        for raw in ["http://jackswifefreda.com/menu/","https://jackswifefreda.com/other/","https://jackswifefreda.com.evil.example/menu/","https://jackswifefreda.com/menu/?location=other","https://jackswifefreda.com/menu/#different","https://user@jackswifefreda.com/menu/","file:///menu/"] {
            precondition(AskCitationLink.acceptedURL(for:URL(string:raw)!,citations:sources)==nil)
        }
        func linked(_ text:String,_ citations:[AskWebCitation]=sources)->Set<URL> {
            AskMarkdownPresentation.locallyLinkedSources(.init(id:"test",spans:[.text(text)],sourceIDs:[],citations:citations))
        }
        precondition(linked("A brunch option. [Official menu](https://jackswifefreda.com/menu/)").count==1)
        precondition(linked("[Official menu](https://jackswifefreda.com/menu/)").isEmpty)
        precondition(linked("A brunch option. [1](https://jackswifefreda.com/menu/)").isEmpty)
        precondition(linked("A brunch option. [Menu](https://evil.example/menu/)").isEmpty)
        precondition(linked("A brunch option. [Menu](https://jackswifefreda.com/menu/) Further factual text.").isEmpty)
        precondition(linked("[Menu](https://jackswifefreda.com/menu/)\n\nAnother unrelated factual paragraph.").isEmpty)
        precondition(linked("First option. [Menu](https://jackswifefreda.com/menu/) and [Details](https://www.thelittleowlnyc.com/)").isEmpty)
        precondition(linked("Option one. [Menu](https://jackswifefreda.com/menu/)\n\nOption two. [Details](https://www.thelittleowlnyc.com/)").count==2)
        precondition(linked("Fact A. [Official](https://jackswifefreda.com/menu/)\n\nFact B with no local source link.").isEmpty)
        let poolText="A brunch option. [Official menu](https://jackswifefreda.com/menu/)\n\nA separate recommendation."
        let poolParagraph=AskAnswerParagraph(id:"conversation-answer",spans:[.text(poolText)],sourceIDs:[],citations:sources)
        precondition(AskMarkdownPresentation.locallyLinkedSources(poolParagraph).isEmpty)
        precondition(AskMarkdownPresentation.locallyLinkedSources(poolParagraph,researchPool:true)==[sources[0].safeURL!])
        var poolResponse=AskResponse(summary:"",candidates:[],paragraphs:[poolParagraph],publicResearch:[.init(id:UUID(),originatingTurn:UUID(),query:"Public menus",result:.init(text:"Evidence",citations:sources))])
        let restoredPool=try JSONDecoder().decode(AskResponse.self,from:JSONEncoder().encode(poolResponse))
        precondition(AskMarkdownPresentation.hasResearchPoolProvenance(restoredPool.paragraphs[0],in:restoredPool))
        var explicitPool=poolParagraph
        explicitPool.citationsAreResearchPool=true
        let mergeProbe=AskAgentLoop.merged(.init(summary:"",candidates:[],paragraphs:[explicitPool]),.init(summary:"",candidates:[]))
        let restoredMerge=try JSONDecoder().decode(AskResponse.self,from:JSONEncoder().encode(mergeProbe))
        precondition(restoredMerge.paragraphs[0].citationsAreResearchPool==true)
        poolResponse.publicResearch=[]
        precondition(!AskMarkdownPresentation.hasResearchPoolProvenance(poolParagraph,in:poolResponse))
        if let path=ProcessInfo.processInfo.environment["FEAST_CITATION_RESTORED_FIXTURE"] {
            let saved=try JSONDecoder().decode(AskResponse.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
            let answer=saved.paragraphs.first {$0.id=="conversation-answer"}!
            precondition(AskMarkdownPresentation.hasResearchPoolProvenance(answer,in:saved))
            let consumed=AskMarkdownPresentation.locallyLinkedSources(answer,researchPool:true)
            precondition(consumed==Set(answer.citations.compactMap(\.safeURL)) && consumed.count==3)
            print("PASS actual restored brunch answer: three local descriptive links replace duplicate research-pool markers; source metadata retained")
        }
        let meaningful=AskWebCitation(title:"Branch menu",url:"https://example.org/menu?branch=west&utm_source=openai")
        precondition(AskCitationLink.acceptedURL(for:URL(string:"https://example.org/menu?branch=west")!,citations:[meaningful])==meaningful.safeURL)
        precondition(AskCitationLink.acceptedURL(for:URL(string:"https://example.org/menu?branch=east")!,citations:[meaningful])==nil)

        precondition(!AskHostedError.service(429).localizedDescription.contains("allowance"))
        precondition(AskConversationFailure(status: 503, code: "provider_billing_limit").localizedDescription.contains("OpenAI"))
        precondition(AskConversationFailure(status: 503, code: "provider_billing_setup").localizedDescription.contains("isn’t active"))
        precondition(!AskConversationFailure(status: 429, code: "provider_rate_limit").localizedDescription.contains("billing"))
        print("PASS owner config isolated from public auth; one broker response consumed once without second HTTP; validated IDs bypass lexical re-filter; prior scope cannot broaden via changed city")



    }
}
