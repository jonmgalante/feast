import Foundation
import CoreData

private actor UXProvider: AskFeastProvider {
    nonisolated let label = "Offline UX fixture"
    let delayed: Bool
    var requests: [AskRequest] = []
    init(delayed: Bool = false) { self.delayed = delayed }
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse {
        requests.append(request)
        if delayed { try? await Task.sleep(nanoseconds: 120_000_000) } // deliberately ignores cancellation
        let evidence = try tools.collection(.init(text: request.text, limit: 6))
        return .init(summary: "Fixture answer", candidates: evidence.candidates,
                     paragraphs: [.init(id: "answer", spans: evidence.candidates.isEmpty ? [.text("No match.")] : evidence.candidates.map { .place($0.id) }, sourceIDs: evidence.candidates.flatMap(\.sourceIDs))], listedCandidateIDs: [])
    }
}
private actor UXStagedProvider: AskFeastProvider {
    nonisolated let label = "Offline two-stage fixture"
    var stage = 0
    var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    func release(_ value: Int) { gates.removeValue(forKey: value)?.resume() }
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse {
        stage = 1; await withCheckedContinuation { gates[1] = $0 }
        stage = 2; await withCheckedContinuation { gates[2] = $0 }
        return .init(summary: "Late fixture", candidates: [])
    }
}
private struct UXConsentProvider: AskFeastProvider {
    let label = "Mock consent boundary"
    func answer(_ request:AskRequest,tools:AskReadTools) async throws -> AskResponse {
        guard AskPrivacy.onlineAllowed else { throw AskHostedError.consentRequired }
        return .init(summary:"Mock accepted answer",candidates:[])
    }
}
@MainActor enum AskUXSafetyTests {
    static func run(model: NSManagedObjectModel, temporaryDirectory: URL) async throws {
        try await AskPresentationTests.run(model:model,directory:temporaryDirectory)
        let id = UUID().uuidString, other = UUID().uuidString
        func index(_ ids: [String]) -> AskLocalIndex {
            .init(records: ids.map { .init(id: $0, cityID: "city", city: "", name: $0 == id ? "Cedar" : "Other", neighborhood: "", cuisine: "Italian", status: "", notes: []) }, visibleCityIDs: ["city"], visibleNoteIDs: [], scope: .savedMetadata)
        }
        let provider = UXProvider(), session = AskSession(index: index([id,other]), provider: provider)
        session.input = "Cedar"; session.run(); while session.isLoading { await Task.yield() }
        session.input = "Which one has a cuisine?"; session.runAutomatically(); while session.isLoading { await Task.yield() }
        precondition(session.turns.last?.request.referencedIDs == [id] && session.response?.candidates.map(\.id) == [id])
        let retainedEvidence=AskRetainedResearch(id:UUID(),originatingTurn:UUID(),query:"Cedar official profile",result:.init(text:"Cedar Instagram @cedar",citations:[.init(title:"Public source",url:"https://example.org/cedar")]))
        let choice=AskMapChoice(id:UUID().uuidString,applePlaceID:"isolated-cedar",name:"Cedar",address:"123 Public Street",city:"New York",query:"Cedar",website:nil,originatingTurn:UUID())
        let failedResponse=AskResponse(summary:"No change applied",candidates:[],listedCandidateIDs:[],usesLocalCatalog:true,agentTask:.init(action:"change",fields:["type"],orderedIDs:[id],sourcePolicy:"public_if_missing",privateSelection:true),publicResearch:[retainedEvidence],mapChoices:[choice])
        let failedTurn=AskTurn(id:UUID(),request:.init(mode:.collection,text:"Save its profile and category",fromOCR:false),response:failedResponse,status:.complete)
        let contextStore=AskConversationStore(url:temporaryDirectory.appendingPathComponent("targeted-context.json"))
        precondition(contextStore.save(.init(turns:[AskArchivedTurn(failedTurn)])))
        let restoredTargeted=AskSession(index:index([id]),provider:UXProvider());restoredTargeted.restoreHistory(from:contextStore)
        restoredTargeted.input="Try saving that profile again";restoredTargeted.run();while restoredTargeted.isLoading {await Task.yield()}
        precondition(restoredTargeted.turns.last?.request.publicResearch==[retainedEvidence])
        precondition(restoredTargeted.turns.last?.request.dialogue.contains(where:{$0.text.contains("@cedar")})==true)
        let tapped=AskSession(index:index([id]),provider:UXProvider());tapped.restoreHistory(from:contextStore)
        tapped.chooseMapChoice(turnID:failedTurn.id,choiceID:choice.id);while tapped.isLoading {await Task.yield()}
        precondition(tapped.turns.last?.request.mapChoices==[choice] && tapped.turns.last?.request.text.contains("123 Public Street")==true)
        let beforeDraft=tapped.turns.count;tapped.input="Keep my unsent draft";tapped.chooseMapChoice(turnID:failedTurn.id,choiceID:choice.id)
        precondition(tapped.input=="Keep my unsent draft" && tapped.turns.count==beforeDraft)
        print("PASS failed/private chat restores public evidence for planning and validation; explicit Maps selection retains task and protects unsent draft")
        let accepted = session.turns.last!
        precondition(AskSourcePresentation.disclosedSources(response: accepted.response!, sources: accepted.sources, availableIDs: [id]).isEmpty)
        precondition(!AskSourcePresentation.disclosedSources(response: accepted.response!, sources: accepted.sources, availableIDs: []).isEmpty)
        var unlinked = accepted.response!; unlinked.paragraphs[0] = .init(id: "unlinked", spans: [.text("Saved details")], sourceIDs: accepted.sources.map(\.id))
        precondition(!AskSourcePresentation.disclosedSources(response: unlinked, sources: accepted.sources, availableIDs: [id]).isEmpty)
        let screenshotSource = AskSource(id: "selected-screenshot", title: "Screenshot", kind: .selectedScreenshot, author: "User", published: nil, checked: "", url: nil, excerpt: "Attached")
        precondition(AskSourcePresentation.disclosedSources(response: accepted.response!, sources: accepted.sources + [screenshotSource], availableIDs: [id]) == [screenshotSource])
        print("PASS polish source disclosure hides only individually linked available saved metadata; unresolved/non-saved evidence remains")
        session.updateIndex(index([other])); session.input = "Tell me more"; session.runAutomatically(); while session.isLoading { await Task.yield() }
        precondition(session.response?.candidates.isEmpty == true) // deleted ID never broadens to Other
        session.input = "Other"; session.runAutomatically(); while session.isLoading { await Task.yield() }
        precondition(session.turns.last?.request.referenceOnly == false && session.response?.candidates.map(\.id) == [other])
        print("PASS UX stable result IDs bound follow-ups; deleted references do not broaden, new topics reset")

        let web = AskWebPlace(name: "Public Fixture", region: "Manhattan", sourceURL: "https://example.org/opening", openingDate: "2026-10-20", openingKind: "opened", evidence: "Public Fixture cafe in Manhattan opened on 2026-10-20.")
        let library = AskLibraryProvider(remote: UXProvider(), places: { [] })
        let follow = AskRequest(mode: .discovery, text: "Tell me more", fromOCR: false, referencedWebPlaces: [web])
        let webTools = try AskReadTools(request: follow, index: index([]))
        let webAnswer = try webTools.checked(await library.answer(follow, tools: webTools))
        let copied = AskAnswerCopy.text(webAnswer)
        precondition(copied.contains("Public Fixture") && copied.components(separatedBy: "https://example.org/opening").count == 2)
        precondition(webAnswer.webPlaces == [web] && webAnswer.paragraphs.flatMap(\.citations).map(\.url) == [web.sourceURL])
        precondition(AskQueryPlan.hasNewPublicCriteria("What about Brooklyn?") && !AskQueryPlan.hasNewPublicCriteria("Tell me more"))
        print("PASS UX public references reuse accepted evidence without remote calls; explicit geography starts new research criteria")

        let later = AskWebPlace(name: "Later Fixture", region: "Manhattan", sourceURL: "https://example.org/later", openingDate: "2026-10-22", openingKind: "opened", evidence: "Later Fixture cafe in Manhattan opened on 2026-10-22.")
        let first = AskFollowUpPlanner.publicAnswer(.init(mode: .discovery, text: "Which opened first?", fromOCR: false, referencedWebPlaces: [web,later]))
        precondition(first.webPlaces == [web] && first.paragraphs.flatMap(\.citations).count == 1)
        let ambiguous = AskFollowUpPlanner.publicAnswer(.init(mode: .discovery, text: "When did it open?", fromOCR: false, referencedWebPlaces: [web,later]))
        precondition(ambiguous.summary == "Which place do you mean?")
        let unknown = AskFollowUpPlanner.publicAnswer(.init(mode: .discovery, text: "What are their hours?", fromOCR: false, referencedWebPlaces: [web,later]))
        precondition(!unknown.summary.contains("2026-10-20") && unknown.summary.contains("haven’t verified"))
        let announced = AskWebPlace(name: "Future", region: "Manhattan", sourceURL: "https://example.org/future", openingDate: "2026-11-01", openingKind: "announced", evidence: "Future cafe has an announced opening target.")
        let comparison = AskFollowUpPlanner.publicAnswer(.init(mode: .discovery, text: "Which is newest?", fromOCR: false, referencedWebPlaces: [web,announced]))
        precondition(comparison.summary.contains("announced") && comparison.webPlaces.count == 2)
        print("PASS polish follow-ups answer verified date comparisons, clarify ambiguous pronouns and retain announced/missing-fact uncertainty without broad repetition")

        let corrected = AskFollowUpPlanner.publicAnswer(.init(mode: .discovery, text: "Not Public Fixture, Later Fixture", fromOCR: false, referencedWebPlaces: [web,later]))
        precondition(corrected.webPlaces == [later] && corrected.referenceWebPlaces == [web,later])
        precondition(first.referenceWebPlaces == [web,later])
        print("PASS polish named corrections exclude rejected results while bounded accepted context survives refinements")

        let slow = UXProvider(delayed: true), cancel = AskSession(index: index([id]), provider: slow)
        cancel.input = "Cedar"; cancel.run(); await Task.yield(); cancel.input = "new draft"; cancel.run()
        precondition(cancel.turns.count == 1 && cancel.input == "new draft")
        cancel.cancel(); cancel.input = "Cedar"; cancel.run()
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(cancel.turns.count == 2 && cancel.turns[0].status == .stopped && cancel.turns[0].response == nil && cancel.turns[1].status == .complete)
        print("PASS UX rapid submission guard and cancel/late-result generation isolation")

        for stoppedStage in [1,2] {
            let stages = UXStagedProvider(), staged = AskSession(index: index([]), provider: stages)
            staged.input = "fixture"; staged.run()
            while await stages.stage != 1 { await Task.yield() }
            if stoppedStage == 2 { await stages.release(1); while await stages.stage != 2 { await Task.yield() } }
            staged.cancel()
            if stoppedStage == 1 { await stages.release(1); while await stages.stage != 2 { await Task.yield() } }
            await stages.release(2)
            try await Task.sleep(nanoseconds: 20_000_000)
            precondition(staged.turns[0].status == .stopped && staged.turns[0].response == nil)
        }
        print("PASS UX cancel during either mocked pipeline stage discards all late results without replay")

        let url = temporaryDirectory.appendingPathComponent("ask-history.json"), store = AskConversationStore(url: url)
        session.restoreHistory(from: store); session.input = "draft retained"; session.flushHistory()
        let restored = AskSession(index: index([id]), provider: provider); restored.restoreHistory(from: store)
        precondition(restored.input == "draft retained" && !restored.isLoading && restored.turns.isEmpty)
        restored.input = "Cedar"; restored.run(); while restored.isLoading { await Task.yield() }; restored.flushHistory()
        let completed = AskSession(index: index([id]), provider: provider); completed.restoreHistory(from: store)
        precondition(completed.turns.count == 1 && completed.response?.candidates.map(\.id) == [id] && !completed.isLoading)
        let picture = AskSession(index: index([id]), provider: provider)
        picture.restoreHistory(from: store); picture.input = "Cedar"; picture.attachment = .init(jpeg: Data([0xff,0xd8,0xff,0xd9])); picture.run()
        while picture.isLoading { await Task.yield() }; picture.flushHistory()
        precondition(store.load().turns.count == 1) // prior completed text turn only; image turn omitted
        let rawHistory = try String(contentsOf: url, encoding: .utf8)
        precondition(!rawHistory.contains("jpeg") && !rawHistory.contains("base64") && !rawHistory.contains("selected-screenshot"))
        print("PASS UX selected image and image-derived turn never retained in conversation journal")
        completed.input = "debounced draft"; completed.clearConversation(); try await Task.sleep(nanoseconds: 450_000_000)
        precondition(store.load().draft.isEmpty && store.load().turns.isEmpty && completed.input.isEmpty && completed.turns.isEmpty)
        try Data("broken".utf8).write(to: url); precondition(store.load().turns.isEmpty)
        try Data("{\"version\":0,\"draft\":\"old\",\"turns\":[]}".utf8).write(to: url); precondition(store.load().draft.isEmpty)
        print("PASS UX versioned history restores completed answers/draft only, corrupt/old history safe, clear invalidates debounce")

        let interrupt = AskSession(index: index([id]), provider: slow); store.clear(); interrupt.restoreHistory(from: store)
        interrupt.input = "Cedar"; interrupt.run(); interrupt.suspend()
        let relaunch = AskSession(index: index([id]), provider: provider); relaunch.restoreHistory(from: store)
        precondition(relaunch.input == "Cedar" && relaunch.turns.count==1 && relaunch.turns.first?.status == .stopped && !relaunch.isLoading && relaunch.attachment == nil)
        // Multi-chat migration keeps the old file and exact accepted turn identities/order/context.
        let legacyURL = temporaryDirectory.appendingPathComponent("legacy-chat.json")
        let libraryURL = temporaryDirectory.appendingPathComponent("multi-chats.json")
        var migrationResponse = accepted.response!
        migrationResponse.libraryContext = .init(ids:[id],filters:.init(operation:.list,scope:.library,city:"London",positions:[],fields:[]))
        let migrationTurn = AskTurn(id:UUID(),request:.init(mode:.collection,text:"Cedar",fromOCR:false,previousQuestion:"Earlier question"),response:migrationResponse,sources:accepted.sources,status:.complete)
        let legacy = AskConversationStore(url:legacyURL)
        precondition(legacy.save(.init(draft:"old draft",turns:[.init(migrationTurn)])))
        let legacyBytes = try Data(contentsOf:legacyURL)
        let libraryStore = AskConversationStore(url:libraryURL,legacyURL:legacyURL)
        let multi = AskSession(index:index([id]),provider:provider);multi.restoreHistory(from:libraryStore)
        precondition(multi.turns.map(\.id) == [migrationTurn.id] && multi.input == "old draft" && multi.response?.libraryContext?.ids == [id])
        let preservedLegacy = try Data(contentsOf:legacyURL);precondition(preservedLegacy == legacyBytes)
        let originalChat = multi.activeChatID
        precondition(multi.newChat());let newChat = multi.activeChatID
        precondition(newChat != originalChat && multi.turns.isEmpty && multi.input.isEmpty)
        multi.input = "second draft";multi.flushHistory()
        precondition(multi.renameChat(originalChat,to:"London places"))
        precondition(multi.openChat(originalChat) && multi.input == "old draft" && multi.turns.first?.id == migrationTurn.id)
        precondition(multi.openChat(newChat) && multi.input == "second draft")
        multi.suspend() // Simulate the old process ending before relaunch; no second live writer.
        let multiReload = AskSession(index:index([id]),provider:provider);multiReload.restoreHistory(from:libraryStore)
        precondition(multiReload.activeChatID == newChat && multiReload.input == "second draft" && multiReload.chats.count == 2)
        precondition(multiReload.deleteChat(originalChat) && multiReload.chats.count == 1 && !FileManager.default.fileExists(atPath:legacyURL.path))
        precondition(multiReload.deleteChat(newChat) && multiReload.chats.count == 1 && multiReload.turns.isEmpty && multiReload.activeChatID != newChat)
        try await Task.sleep(nanoseconds:450_000_000)
        let remainingLibrary = try libraryStore.loadLibrary();precondition(remainingLibrary.chats.count == 1)
        let switching = AskSession(index:index([id]),provider:slow)
        switching.restoreHistory(from:AskConversationStore(url:temporaryDirectory.appendingPathComponent("switch-late.json")))
        switching.input = "Cedar";switching.run();let pendingChat = switching.activeChatID
        precondition(switching.newChat());let freshChat = switching.activeChatID
        try await Task.sleep(nanoseconds:200_000_000)
        precondition(switching.activeChatID == freshChat && switching.turns.isEmpty && !switching.isLoading)
        precondition(switching.openChat(pendingChat) && switching.input == "Cedar" && switching.turns.count==1 && switching.turns.first?.status == .stopped)
        switching.run();precondition(switching.deleteChat(pendingChat))
        try await Task.sleep(nanoseconds:200_000_000)
        precondition(switching.activeChatID == freshChat && switching.turns.isEmpty)
        let brokenURL = temporaryDirectory.appendingPathComponent("future-chats.json")
        let futureBytes = Data("{\"version\":99,\"chats\":[]}".utf8);try futureBytes.write(to:brokenURL)
        let brokenSession = AskSession(index:index([id]),provider:provider)
        brokenSession.restoreHistory(from:AskConversationStore(url:brokenURL));brokenSession.input = "kept in memory";brokenSession.flushHistory()
        precondition(!brokenSession.newChat() && brokenSession.error != nil)
        let preservedFuture = try Data(contentsOf:brokenURL);precondition(preservedFuture == futureBytes)
        print("PASS multi-chat migration preserves legacy bytes, turn IDs/order/context/draft; new/open/rename/delete/relaunch, switched/deleted late responses and future/corrupt files never overwrite restaurants or saved history")

        let fullURL = temporaryDirectory.appendingPathComponent("full-chat.json")
        let fullStore = AskConversationStore(url:fullURL)
        let fullTurns = (0..<100).map { _ in AskArchivedTurn(.init(id:UUID(),request:.init(mode:.collection,text:"Cedar",fromOCR:false),response:migrationResponse,sources:accepted.sources,status:.complete)) }
        precondition(fullStore.save(.init(turns:fullTurns)))
        let fullSession = AskSession(index:index([id]),provider:provider);fullSession.restoreHistory(from:fullStore)
        fullSession.input = "Cedar";fullSession.run()
        precondition(!fullSession.isLoading && fullSession.turns.count == 100 && fullSession.error != nil)
        precondition(fullSession.newChat() && fullSession.chats.count == 2 && fullSession.turns.isEmpty)
        let photoOnlyStore = AskConversationStore(url:temporaryDirectory.appendingPathComponent("photo-only.json"))
        let photoOnly = AskSession(index:index([id]),provider:provider);photoOnly.restoreHistory(from:photoOnlyStore)
        photoOnly.attachment = .init(jpeg:Data([0xff,0xd8,0xff,0xd9]));photoOnly.run()
        while photoOnly.isLoading { await Task.yield() };photoOnly.flushHistory()
        let photoOnlyLibrary = try photoOnlyStore.loadLibrary()
        precondition(photoOnlyLibrary.chats[0].title == "New chat" && photoOnlyLibrary.chats[0].conversation.turns.isEmpty)
        print("PASS full-chat limit preserves all100 turns and permits New Chat; screenshot-only turn/title/image bytes are not retained")

        let permissionBefore = UserDefaults.standard.object(forKey:AskPrivacy.onlineKey)
        defer { if let permissionBefore { UserDefaults.standard.set(permissionBefore,forKey:AskPrivacy.onlineKey) } else { UserDefaults.standard.removeObject(forKey:AskPrivacy.onlineKey) } }
        AskPrivacy.withdraw()
        let consentProvider = UXConsentProvider()
        let consentSession = AskSession(index:index([id]),provider:consentProvider)
        consentSession.restoreHistory(from:AskConversationStore(url:temporaryDirectory.appendingPathComponent("consent-chats.json")))
        consentSession.input = "Cedar";consentSession.run();while consentSession.isLoading { await Task.yield() }
        precondition(consentSession.needsOnlineConsent && consentSession.turns.isEmpty && consentSession.input == "Cedar")
        consentSession.dismissConsent();precondition(!consentSession.needsOnlineConsent && !AskPrivacy.onlineAllowed && consentSession.input == "Cedar")
        consentSession.run();while consentSession.isLoading { await Task.yield() }
        let consentTicket = consentSession.prepareConsentSend()!;AskPrivacy.accept();consentSession.resumeAfterConsent(consentTicket)
        while consentSession.isLoading { await Task.yield() }
        precondition(consentSession.turns.count == 1 && consentSession.turns[0].status == .complete && !consentSession.needsOnlineConsent)
        consentSession.input = "Cedar";consentSession.run();while consentSession.isLoading { await Task.yield() }
        precondition(consentSession.turns.count == 2 && !consentSession.needsOnlineConsent)
        AskPrivacy.withdraw();consentSession.input = "Cedar";consentSession.run();while consentSession.isLoading { await Task.yield() }
        let staleConsent = consentSession.prepareConsentSend()!;precondition(consentSession.newChat());AskPrivacy.accept();consentSession.resumeAfterConsent(staleConsent)
        precondition(consentSession.turns.isEmpty && !consentSession.isLoading)
        AskPrivacy.withdraw()
        let unavailableSession = AskSession(index:index([id]),provider:AskUnavailableProvider())
        unavailableSession.input = "Cedar";unavailableSession.run();while unavailableSession.isLoading { await Task.yield() }
        precondition(!unavailableSession.needsOnlineConsent && unavailableSession.error != nil)
        print("PASS first-online-send consent cancel retains draft/no turn; explicit accept resumes once; subsequent messages do not prompt; withdrawal/new chat invalidate pending consent; unavailable service never asks permission")

        precondition(!AskHostedError.service(401).retryable && !AskHostedError.service(429).retryable && AskHostedError.service(502).retryable)
        print("PASS UX background/interruption restores draft without replay; terminal auth/limit errors do not encourage Retry")

        let reviewedMatch = ApplePlaceMatch(applePlaceID: "same-maps-id", displayName: "Harbor Bakery fixture", secondaryText: "", coordinate: nil, suggestedSectionPath: .init(cityOrRegion: nil, neighborhood: nil), websiteURL: "https://example.invalid/original", instagramURL: nil, suggestedPlaceType: .bakery)
        var cache = PlaceReviewDraftCache()
        var reviewed = PlaceReviewDraft(place: reviewedMatch, cityURI: "city-one", neighborhood: .create("Chelsea"))
        reviewed.placeType = .cafe; reviewed.status = .love; reviewed.note = "Unsent fixture edit"
        reviewed.cuisinesText = "User cuisine"; reviewed.tags = ["User tag"]; reviewed.websiteURL = ""; reviewed.instagramURL = ""
        cache.store(reviewed, for: reviewedMatch.applePlaceID)
        let returned = cache.draft(for: reviewedMatch.applePlaceID)!.forDestination("city-one", suggested: .unsorted)
        precondition(returned == reviewed && returned.placeType == .cafe && returned.websiteURL.isEmpty)
        let changedCity = returned.forDestination("city-two", suggested: .unsorted)
        precondition(changedCity.placeType == .cafe && changedCity.note == reviewed.note && changedCity.neighborhood == .unsorted && changedCity.committedNeighborhood == .unsorted)
        precondition(cache.draft(for: "different-maps-id") == nil)
        let fresh = PlaceReviewDraft(place: reviewedMatch, cityURI: "city-two", neighborhood: .unsorted)
        precondition(fresh.placeType == .bakery && fresh.note.isEmpty)
        for i in 0..<20 { cache.store(fresh, for: "new-\(i)") }
        precondition(cache.draft(for: reviewedMatch.applePlaceID) == nil)
        print("PASS review Back/reselect retains edited Cafe/status/notes/tags/cuisine/cleared URLs for exact Maps ID; new candidate fresh, new city resets only neighborhood, cache bounded")

        let evaluationBudget = AskEvaluationContract.Budget(protocol: 1, readOnly: true, runID: AskEvaluationContract.runID, reservationMicroUSD: 200000, maximumAttempts: 3, maximumReservationMicroUSD: 600000, totalCapMicroUSD: 5000000, userCapMicroUSD: 2500000, totalReservedMicroUSD: 1200000, userReservedMicroUSD: 0, totalRemainingMicroUSD: 3800000, userRemainingMicroUSD: 2500000, attemptedCount: 0, availableAttempts: 3, halted: false, cases: AskEvaluationContract.cases.map { .init(caseID: $0.id, state: "not-attempted") })
        precondition(evaluationBudget.verified)
        var budgetJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evaluationBudget)) as! [String:Any]
        budgetJSON["availableAttempts"] = 4
        let overBudget = try JSONDecoder().decode(AskEvaluationContract.Budget.self, from: JSONSerialization.data(withJSONObject: budgetJSON))
        precondition(!overBudget.verified)
        let publicBody = try JSONEncoder().encode(AskEvaluationContract.Payload(requestID: UUID().uuidString, criteria: AskEvaluationContract.cases[0].criteria))
        let bodyFields = try JSONSerialization.jsonObject(with: publicBody) as! [String:Any]
        precondition(Set(bodyFields.keys) == ["version","requestID","mode","criteria"] && AskEvaluationContract.cases.count == 3)
        precondition(!String(data: publicBody,encoding: .utf8)!.contains("PRIVATE"))
        print("PASS guarded evaluation client validates read-only original caps and fixed3 public cases without question/library/image payload")
        let dateFormatter = ISO8601DateFormatter(); dateFormatter.formatOptions = [.withFullDate]
        let publicDate = dateFormatter.string(from: Date()), sourceURL = "https://example.org/evaluation"
        let placeJSON: [String:Any] = ["name":"Public Evaluation Fixture","region":"Manhattan","sourceURL":sourceURL,"openingDate":publicDate,"openingKind":"opened","evidence":"Public Evaluation Fixture cafe in Manhattan opened on " + publicDate + "."]
        let usageJSON: [String:Any] = ["input":1500,"output":200,"webCalls":1,"estimatedMicroUSD":10288]
        var evaluationJSON: [String:Any] = ["protocol":1,"runID":AskEvaluationContract.runID,"caseID":"manhattan-cafe-month","asOf":publicDate,"candidateKind":"local-extraction","baselineCalls":2,"candidateAdditionalCalls":0,"candidate":["status":"valid","places":[placeJSON],"usage":["input":1000,"output":100,"webCalls":1,"estimatedMicroUSD":10175]],"comparison":["baselineCount":1,"candidateCount":1,"matchedCount":1,"candidateExtraCount":0,"baselineOnlyCount":0],"timings":["research":10,"extraction":10,"validation":1,"overall":21,"candidateLocal":1],"humanSourceReviewRequired":true,"stop":false]
        var replyJSON: [String:Any] = ["version":2,"model":"gpt-6-luna","summary":"Public fixture opening.","paragraphs":[["id":"web-0","text":"Public fixture opening.","citations":[["title":"Public source","url":sourceURL]]]],"places":[placeJSON],"usage":usageJSON,"budget":["reservedMicroUSD":1400000,"userReservedMicroUSD":200000,"estimatedUsageMicroUSD":10288],"evaluation":evaluationJSON]
        let acceptedEvaluation = try JSONDecoder().decode(AskEvaluationContract.Reply.self, from: JSONSerialization.data(withJSONObject: replyJSON))
        precondition(acceptedEvaluation.verified(caseID: "manhattan-cafe-month", before: evaluationBudget))
        evaluationJSON["candidateAdditionalCalls"] = 1; replyJSON["evaluation"] = evaluationJSON
        let extraCall = try JSONDecoder().decode(AskEvaluationContract.Reply.self, from: JSONSerialization.data(withJSONObject: replyJSON))
        precondition(!extraCall.verified(caseID: "manhattan-cafe-month", before: evaluationBudget))
        print("PASS evaluation reply accepts grounded bounded public comparison and rejects extra model calls/accounting contract drift")


        let suite = "FeastSyntheticDestination-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = PlaceSaveDestinationMemory(defaults: defaults)
        let locality = ApplePlaceLocalityIdentity(locality: "London", administrativeArea: "England", countryCode: "GB")
        let otherLondon = ApplePlaceLocalityIdentity(locality: "London", administrativeArea: "Ontario", countryCode: "CA")
        let destination = UUID(), duplicateNameCity = UUID()
        precondition(memory.cityID(for: locality, available: [destination]) == nil)
        memory.record(identity: locality, cityID: destination)
        precondition(memory.cityID(for: locality, available: [destination,duplicateNameCity]) == destination)
        precondition(memory.cityID(for: otherLondon, available: [destination]) == nil)
        precondition(memory.cityID(for: locality, available: []) == nil)
        memory.record(identity: locality, cityID: duplicateNameCity)
        precondition(memory.cityID(for: locality, available: [destination,duplicateNameCity]) == nil)
        precondition(memory.cityID(for: nil, available: [destination]) == nil)
        print("PASS polish reviewed destination memory distinguishes same-name localities/city UUIDs, rejects missing identity, revoked and ambiguous destinations")

        let duplicateOne = AskPersonalPlace(id: UUID().uuidString, name: web.name, status: nil, type: nil, cuisines: [], city: "Manhattan", neighborhood: "")
        let duplicateTwo = AskPersonalPlace(id: UUID().uuidString, name: web.name, status: nil, type: nil, cuisines: [], city: "Manhattan", neighborhood: "")
        precondition(AskSavedDiscoveryMatch.unique(web, in: [duplicateOne])?.id == duplicateOne.id)
        precondition(AskSavedDiscoveryMatch.unique(web, in: [duplicateOne,duplicateTwo]) == nil)
        let measurements = AskPerformanceRecorder(), trace = UUID()
        await measurements.recordServerTiming("research;dur=12, PRIVATE_PROMPT;dur=3, extraction;dur=nan, validation;dur=-1", traceID: trace)
        let measured = await measurements.snapshot()
        precondition(measured.count == 1 && measured[0].stage == .research && measured[0].milliseconds == 12)
        for _ in 0..<120 { await measurements.record(.render, milliseconds: 1, traceID: trace) }
        let boundedMeasurements = await measurements.snapshot()
        precondition(boundedMeasurements.count == 100)
        print("PASS polish post-save matching refuses ambiguous identities; timings accept only bounded enum durations and retain no request content")

        let sandbox = try AskPrototypeSandbox(model: model)
        let city = try sandbox.repository.createFeastList(named: "Save fixture city")
        let existing = try sandbox.repository.createSavedPlace(from: .init(applePlaceID: "ux-existing", displayNameSnapshot: "Kept", status: .love, placeType: .restaurant, cuisines: [], tags: [], note: "Original private fixture note", websiteURL: nil, instagramURL: nil, feastList: city, listSection: nil))
        let adapter = AskSavedCollection(context: sandbox.context, visibleCities: { [city.id!] })
        let originalID = existing.id, originalStatus = existing.status
        existing.note = "Unsent editor fixture draft"
        let isolated = try adapter.makeSaveContext(), repository = FeastRepository(context: isolated)
        let isolatedCity = try isolated.existingObject(with: city.objectID) as! FeastList
        for _ in 0..<2 {
            do { _ = try repository.createSavedPlace(from: .init(applePlaceID: "ux-existing", displayNameSnapshot: "Wrong overwrite", status: .been, placeType: .bar, cuisines: [], tags: [], note: "Overwrite", websiteURL: nil, instagramURL: nil, feastList: isolatedCity, listSection: nil)); preconditionFailure("Duplicate save accepted") }
            catch FeastRepository.SavedPlaceError.duplicateLocationInCity { isolated.rollback() }
        }
        precondition(existing.id == originalID && existing.status == originalStatus && existing.note == "Unsent editor fixture draft" && sandbox.context.hasChanges)
        let fetched = try repository.fetchSavedPlaces().first { $0.id == originalID }
        precondition(fetched?.note == "Original private fixture note")
        print("PASS UX repeated Save deduplicates in independent form context and preserves stored notes/status/IDs plus another editor’s unsent draft")

    }
}
