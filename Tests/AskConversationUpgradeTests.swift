import Foundation
import CoreData

private struct RejectRemote: AskFeastProvider {
    let label = "No network allowed"
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse { preconditionFailure("Local status answer must never invoke remote") }
}
private actor UpgradeCapture: AskFeastProvider {
    nonisolated let label = "Offline route capture"
    var requests: [AskRequest] = []
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse {
        requests.append(request); return .init(summary: "Synthetic route fixture", candidates: [])
    }
}
@MainActor enum AskConversationUpgradeTests {
    static func run(model: NSManagedObjectModel) async throws {
        let sandbox = try AskPrototypeSandbox(model: model)
        let city = try sandbox.repository.createFeastList(named: "Manhattan")
        var saved: [SavedPlace] = []
        for (name,status,cuisine) in [("Cedar",PlaceStatus.love,"Italian"),("Birch",.regulars,"Italian"),("Elm",.been,"Italian"),("Pine",.wantToTry,"Italian"),("Maple",.love,"Japanese")] {
            saved.append(try sandbox.repository.createSavedPlace(from: .init(applePlaceID: "fixture-"+name, displayNameSnapshot: name, status: status, placeType: .restaurant, cuisines: [cuisine], tags: ["PRIVATE_TAG"], note: "PRIVATE_NOTE", websiteURL: nil, instagramURL: nil, feastList: city, listSection: nil)))
        }
        let unset = try sandbox.repository.createSavedPlace(from: .init(applePlaceID: "fixture-unset", displayNameSnapshot: "Unset", status: .wantToTry, placeType: .restaurant, cuisines: ["Italian"], tags: [], note: nil, websiteURL: nil, instagramURL: nil, feastList: city, listSection: nil))
        unset.status = nil
        try sandbox.context.save()
        let adapter = AskSavedCollection(context: sandbox.context, visibleCities: { [city.id!] })
        let local = try adapter.personalPlaces()
        precondition(local.count == 6 && local.first(where: { $0.name == "Cedar" })?.status == "Love")
        let index = try adapter.index()
        let provider = AskLibraryProvider(remote: RejectRemote(), places: { local })
        for (question,name,status) in [("What are my favorite Italian places?","Cedar","Love"),("Which Italian regulars are saved?","Birch","Regulars"),("Which Italian places have I been to?","Elm","Been"),("Which Italian places do I want to try?","Pine","Want to try")] {
            let request = AskRequest(mode: .collection, text: question, fromOCR: false)
            let tools = try AskReadTools(request: request, index: index)
            let response = try tools.checked(await provider.answer(request, tools: tools))
            precondition(response.candidates.map(\.name) == [name] && response.listedCandidateIDs == [])
            let text = response.paragraphs.flatMap(\.spans).compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
            precondition(text.contains(status) && text.contains("in this collection") && !text.contains("you visited"))
        }
        let missing = AskRequest(mode: .collection, text: "My favorite French places", fromOCR: false)
        let missingTools = try AskReadTools(request: missing, index: index)
        let noFavorite = try await provider.answer(missing, tools: missingTools)
        precondition(noFavorite.candidates.isEmpty)
        print("PASS local Love/Regulars/Been differ from saved Want-to-try; shared status language, absent cuisine no-match, zero remote invocation")
        let cafe = AskPersonalPlace(id: "one", name: "Public Coffee", status: "Love", type: "Cafe", cuisines: [], city: "NYC", neighborhood: "Upper East Side")
        let bar = AskPersonalPlace(id: "two", name: "Other", status: "Love", type: "Bar", cuisines: [], city: "London", neighborhood: "")
        precondition(AskQueryPlan.matches(cafe, text: "Coffee in Manhattan", all: [cafe,bar]))
        precondition(AskQueryPlan.matches(cafe, text: "Coffee in New York", all: [cafe,bar]))
        precondition(!AskQueryPlan.matches(bar, text: "Coffee in NYC", all: [cafe,bar]))
        precondition(!AskQueryPlan.matches(bar, text: "Coffee in Manhattan", all: [cafe,bar]))
        precondition(!AskQueryPlan.matches(cafe, text: "Coffee in Brooklyn", all: [cafe,bar]))
        print("PASS structured type/geography constraints filter on device without fabricating unknown location matches")
        let capture = UpgradeCapture(), session = AskSession(index: index, provider: capture)
        session.input = "Which Italian places are saved?"; session.runAutomatically()
        while session.isLoading { await Task.yield() }
        session.input = "Current Manhattan coffee openings"; session.runAutomatically()
        while session.isLoading { await Task.yield() }
        session.input = "What about Brooklyn?"; session.runAutomatically()
        while session.isLoading { await Task.yield() }
        let requests = await capture.requests
        precondition(requests.count == 3 && requests[1].mode == .discovery && requests[1].previousQuestion == nil)
        precondition(requests[2].mode == .discovery && AskPublicCriteria.make(requests[2].retrievalText)?.region == "Brooklyn" && AskPublicCriteria.make(requests[2].retrievalText)?.category == "cafe")
        precondition(AskQueryPlan.route("New Manhattan cafes compared with my saved favorites") == .hybrid)
        print("PASS Italian-to-current-coffee resets history; explicit follow-up carries public category while new geography overrides; hybrid route automatic")
        let endpoint = URL(string: "https://fixture.workers.dev/v1/answer")!
        let discovery = AskHostedProvider(configuration: .init(environment: .development, endpoint: endpoint, scope: .savedMetadata), token: { String(repeating: "a", count: 43) }, approve: { _,_ in false }, send: { http in
            let body = try JSONSerialization.jsonObject(with: http.httpBody!) as! [String:Any]
            precondition(Set(body.keys) == ["version","requestID","mode","criteria"])
            let serialized = String(data: http.httpBody!, encoding: .utf8)!
            precondition(!serialized.contains("PRIVATE") && !serialized.contains("favorite") && !serialized.contains("Cedar") && !serialized.contains("Love"))
            let response = """
            {"version":2,"summary":"Public opening.","paragraphs":[{"id":"web-0","text":"Cedar opened on 2026-10-20.","citations":[{"title":"Public announcement","url":"https://public-example.org/cedar"}]}],"places":[{"name":"Cedar","region":"Manhattan","sourceURL":"https://public-example.org/cedar","openingDate":"2026-10-20","openingKind":"opened","evidence":"Cedar restaurant opened on 2026-10-20 in Manhattan."}]}
            """
            return (Data(response.utf8), HTTPURLResponse(url: endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
        }, webEnabled: { true })
        let webRequest = AskRequest(mode: .discovery, text: "New Manhattan restaurants compared with my saved favorites PRIVATE", fromOCR: false)
        let webTools = try AskReadTools(request: webRequest, index: index)
        let hybrid = AskLibraryProvider(remote: discovery, places: { local })
        let answer = try webTools.checked(await hybrid.answer(webRequest, tools: webTools))
        precondition(answer.candidates.map(\.name) == ["Cedar"] && answer.paragraphs[0].citations[0].safeURL != nil && answer.listedCandidateIDs == [])
        precondition(answer.paragraphs[0].spans.contains(.place(saved[0].id!.uuidString)))
        print("PASS public-only mocked discovery sends no question/history/private fields; hybrid matches unique local entry and keeps clickable external citation plus existing Feast link")
        let disabled = AskHostedProvider(configuration: discovery.configuration, token: { preconditionFailure("No token before web capability") }, approve: { _,_ in false }, send: { _ in preconditionFailure("No request before web capability") })
        let unavailable = try await disabled.answer(webRequest, tools: webTools)
        precondition(unavailable.candidates.isEmpty && unavailable.summary.contains("isn’t available"))
        print("PASS disabled web path is honest with no fixture fallback, credential access or network request")
        try await collectionListingAndLaunchPolicy(model: model)
        try await AskLibraryToolsTests.run(model: model)
    }
}

@MainActor private func collectionListingAndLaunchPolicy(model: NSManagedObjectModel) async throws {
    let fixture = try AskPrototypeSandbox(model: model)
    let london = try fixture.repository.createFeastList(named: "London")
    let paris = try fixture.repository.createFeastList(named: "Paris")
    for i in 0..<9 {
        _ = try fixture.repository.createSavedPlace(from: .init(applePlaceID: "listing-\(i)", displayNameSnapshot: "Fixture \(i)", status: .wantToTry, placeType: i == 0 ? .cafe : .restaurant, cuisines: ["Italian"], tags: ["PRIVATE_TAG"], note: "PRIVATE_NOTE", websiteURL: nil, instagramURL: nil, feastList: i < 8 ? london : paris, listSection: nil))
    }
    let adapter = AskSavedCollection(context: fixture.context, visibleCities: { [london.id!, paris.id!] })
    let all = try adapter.personalPlaces(), index = try adapter.index()
    let provider = AskLibraryProvider(remote: RejectRemote(), places: { all })
    func answer(_ text: String, previous: String? = nil) async throws -> AskResponse {
        let request = AskRequest(mode: .collection, text: text, fromOCR: false, previousQuestion: previous)
        let tools = try AskReadTools(request: request, index: index)
        return try tools.checked(await provider.answer(request, tools: tools))
    }
    for text in ["What are my saved places in London?", "Show my London places", "List what I saved in London", "What's saved in London?", "Which restaurants have I saved in London?"] {
        let response = try await answer(text)
        precondition(response.candidates.count == 8)
        precondition(response.listedCandidateIDs == [] && response.usesLocalCatalog)
        for candidate in response.candidates { precondition(AskPlaceReference.url(for: candidate) != nil) }
        precondition(AskQueryPlan.route(text) == .personal)
    }
    let entire = try await answer("Show all my saved places across all cities")
    precondition(entire.candidates.count == 9)
    let missing = try await answer("Show my saved places in Atlantis")
    precondition(missing.candidates.isEmpty)
    let switched = try await answer("What about Paris?", previous: "What are my saved places in London?")
    precondition(switched.candidates.count == 1 && switched.candidates[0].name == "Fixture 8")
    let refined = try await answer("Which of them are cafes?", previous: "What are my saved places in London?")
    precondition(refined.candidates.count == 1 && refined.candidates[0].name == "Fixture 0")
    for text in ["Which saved place is called Fixture 1 in London?", "What cuisine is recorded for Fixture 1?", "What are my saved places in London with cocktails?", "Current London restaurant openings"] {
        precondition(AskCollectionListingPlan.make(.init(mode: .collection, text: text, fromOCR: false), places: all) == nil)
    }
    let specific = index.search("Fixture 1 in London", limit: 6)
    precondition(!specific.isEmpty && specific.allSatisfy { $0.cityID == london.id!.uuidString })
    let la = AskPersonalPlace(id: "la", name: "LA fixture", status: nil, type: "Restaurant", cuisines: [], city: "LA", neighborhood: "")
    precondition(AskQueryPlan.matches(all[0], text: "Show all my saved places", all: all+[la]))
    precondition(!AskQueryPlan.containsPhrase("places", "LA"))
    let session = AskSession(index: index, provider: provider)
    session.input = "Show my saved places in London"; session.runAutomatically()
    while session.isLoading { await Task.yield() }
    precondition(session.response?.candidates.count == 8)
    session.input = "What about Paris?"; session.runAutomatically()
    while session.isLoading { await Task.yield() }
    precondition(session.response?.candidates.map(\.name) == ["Fixture 8"])
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: historyURL) }
    let history = AskConversationStore(url: historyURL)
    precondition(history.save(.init(turns: session.turns.map(AskArchivedTurn.init))))
    precondition(history.load().turns.first?.response.candidates.count == 8)
    // Regression distribution mirrors stored categories, not assumed geography or inferred restaurant types.
    let mixed = try AskPrototypeSandbox(model:model)
    let mixedLondon = try mixed.repository.createFeastList(named:"London")
    let mixedParis = try mixed.repository.createFeastList(named:"Paris")
    let categories:[PlaceType] = [.restaurant,.other,.market,.cafe,.cafe,.bakery]
    for (i,category) in categories.enumerated() {
        _ = try mixed.repository.createSavedPlace(from:.init(applePlaceID:"mixed-\(i)",displayNameSnapshot:i < 2 ? "Branch" : "Venue \(i)",status:.wantToTry,placeType:category,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:mixedLondon,listSection:nil))
    }
    _ = try mixed.repository.createSavedPlace(from:.init(applePlaceID:"mixed-paris",displayNameSnapshot:"Paris entry",status:.wantToTry,placeType:.restaurant,cuisines:[],tags:[],note:"",websiteURL:nil,instagramURL:nil,feastList:mixedParis,listSection:nil))
    let mixedAdapter = AskSavedCollection(context:mixed.context,visibleCities:{[mixedLondon.id!,mixedParis.id!]})
    let mixedSnapshot = try mixedAdapter.librarySnapshot(),mixedIndex = try mixedAdapter.index()
    precondition(mixedSnapshot.complete && mixedSnapshot.totalCount == 7)
    let mixedProvider = AskLibraryProvider(remote:RejectRemote(),places:{mixedSnapshot.places},snapshot:{mixedSnapshot})
    let londonIDs = Set(mixedSnapshot.places.filter {$0.city == "London"}.map(\.id))
    for text in ["What restaurants have I saved in London?","Which restaurants have I saved in London?","Show my London restaurants","What are my saved places in London?"] {
        let request = AskRequest(mode:.collection,text:text,fromOCR:false)
        let tools = try AskReadTools(request:request,index:mixedIndex)
        let response = try tools.checked(await mixedProvider.answer(request,tools:tools))
        precondition(Set(response.candidates.map(\.id)) == londonIDs && response.candidates.count == 6)
        precondition(response.summary == "6 saved places in London:" && response.libraryContext?.filters.placeType == nil)
    }
    let staleID = mixedSnapshot.places.first { $0.city == "London" }!.id
    let staleIndex = AskLocalIndex(records:mixedIndex.records.filter {$0.id != staleID},visibleCityIDs:Set([mixedLondon.id!.uuidString,mixedParis.id!.uuidString]),visibleNoteIDs:[],scope:.savedMetadata,personalPlaces:mixedSnapshot.places.filter {$0.id != staleID})
    let staleRequest = AskRequest(mode:.collection,text:"What restaurants have I saved in London?",fromOCR:false)
    let staleTools = try AskReadTools(request:staleRequest,index:staleIndex)
    do { _ = try await mixedProvider.answer(staleRequest,tools:staleTools);preconditionFailure("Missing current evidence must not silently reduce a complete city list") }
    catch AskError.invalidEvidence {} catch { throw error }
    let mixedSession = AskSession(index:mixedIndex,provider:mixedProvider)
    let mixedHistoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
    defer { try? FileManager.default.removeItem(at:mixedHistoryURL) }
    mixedSession.restoreHistory(from:AskConversationStore(url:mixedHistoryURL))
    for (text,count) in [("What restaurants have I saved in London?",6),("Only restaurants",1),("What are my saved places in London?",6),("Only cafes",2),("Show all my saved places",7)] {
        mixedSession.input=text;mixedSession.runAutomatically();while mixedSession.isLoading { await Task.yield() }
        precondition(mixedSession.turns.last?.status == .complete && mixedSession.response?.candidates.count == count)
        if text == "Only restaurants" { precondition(mixedSession.response?.libraryContext?.filters.placeType == "Restaurant") }
    }
    precondition(mixedSession.newChat())
    mixedSession.input="What restaurants have I saved in London?";mixedSession.runAutomatically();while mixedSession.isLoading { await Task.yield() }
    precondition(mixedSession.turns.count == 1 && Set(mixedSession.response!.candidates.map(\.id)) == londonIDs)
    let unchanged = try mixedAdapter.librarySnapshot()
    precondition(unchanged.places == mixedSnapshot.places)
    print("PASS mixed-category London6 collection intent preserves both same-name IDs; strict Only restaurants1/cafes2, broad reset7, new-chat scope isolation and full grounded pipeline without remote calls or type changes")
    let original = AskSavedLaunchPolicy.originalSimulator, flag = ["-feastHostedSavedPlaces"]
    precondition(AskSavedLaunchPolicy.canRemember(arguments: flag, simulator: original))
    precondition(AskSavedLaunchPolicy.enabled(arguments: [], simulator: original, approved: true))
    precondition(!AskSavedLaunchPolicy.enabled(arguments: [], simulator: original, approved: false))
    precondition(!AskSavedLaunchPolicy.enabled(arguments: [], simulator: "5325CDB2-9206-4CA4-B433-17DC93BC5A6B", approved: true))
    precondition(!AskSavedLaunchPolicy.enabled(arguments: ["-feastSyntheticPreview"], simulator: original, approved: true))
    precondition(!AskSavedLaunchPolicy.canRemember(arguments: flag+["-feastSyntheticPreview"], simulator: original))
    print("PASS city collection paraphrases, >6 all-city links, no-match, city switch/refinement, strict detail routing and scoped icon-reopen approval policy; zero remote calls")
}
