import Foundation

struct AskAgentProvider:AskFeastProvider {
    let label="Ask Feast"
    let remote:any AskFeastProvider
    let fallback:any AskFeastProvider
    let adapter:AskSavedCollection
    let engine:AskCollectionChangeEngine
    let searchMaps:@MainActor @Sendable (String)async throws->[ApplePlaceMatch]
    var resolveMaps:@MainActor @Sendable (String)async throws->ApplePlaceMatch? = {_ in nil}
    private func localOrConsent(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        do {return try await fallback.answer(request,tools:tools)}
        catch AskHostedError.disabled {
            if let configured=remote as? AskHostedProvider {
                let allowed=await configured.permission()
                if !allowed {throw AskHostedError.consentRequired}
            }
            throw AskHostedError.disabled
        }
    }
    func answer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
        if let hosted=remote as? AskHostedProvider,await hosted.permission(),let turn=request.performanceID {
            let lease=try await hosted.prepareProviderAttempt(turn:turn,retrying:request.providerRetry)
            var resumed=request
            if request.providerRetry,let context=await AskProviderAttempts.shared.readContext(for:lease) {
                resumed.publicResearch=context.publicResearch ?? resumed.publicResearch
                resumed.verifiedFindings=context.verifiedPublicFindings ?? resumed.verifiedFindings
                resumed.agentTask=context.agentTask ?? resumed.agentTask
                resumed.mapChoices=context.mapChoices ?? resumed.mapChoices
            }
            return try await AskProviderAttemptScope.$lease.withValue(lease){try await runAnswer(resumed,tools:tools)}
        }
        return try await runAnswer(request,tools:tools)
    }
    private func runAnswer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
#if FEAST_AGENT_ROLLBACK
        return try await localOrConsent(request,tools:tools)
#else
        guard request.attachment==nil,!request.fromOCR,
              let planner=remote as? any AskAgentPlanning,await planner.agentAvailable(),let researcher=remote as? any AskBusinessResearching else {return try await localOrConsent(request,tools:tools)}
        let fullCollection:Bool
        if let hosted=remote as? AskHostedProvider {let version=await hosted.libraryPlanVersion();let allowed=await hosted.permission();fullCollection = version>=7 && allowed}else{fullCollection=false}
        let contextStarted=DispatchTime.now().uptimeNanoseconds
        var reading=request.collectionReadVersion()
        let snapshot=try await adapter.librarySnapshot()

        var context=try AskSemanticContext.make(reading,catalog:snapshot,fullCollection:fullCollection)
        if !fullCollection {reading.collectionContinuation=nil}
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:reading,researcher:researcher,searchMaps:{query in try await searchMaps(query)},resolveMaps:resolveMaps,fullCollectionContext:fullCollection)
        if fullCollection {
            let permitted=try await executor.permittedRecordIDs()
            if Set(reading.collectionDialogueIDs).isSubset(of:permitted) {reading.dialogue=reading.collectionDialogue.isEmpty ? reading.dialogue : reading.collectionDialogue}
            if let prior=reading.collectionContinuation,!Set(prior.candidates.map(\.id)).isSubset(of:permitted) {reading.collectionContinuation=nil}
        }
        let allCities=try await executor.cities()
        var cities:[AskAgentCity]=[],cityBytes=2
        for city in allCities {
            let size=try JSONEncoder().encode(city).count+1
            guard cities.count<200,cityBytes+size<=8000 else{continue}
            cities.append(city);cityBytes+=size
        }
        if cities.count != allCities.count {context.indexComplete=false}
        let identities=Dictionary(uniqueKeysWithValues:snapshot.places.map {($0.id,AskFindingIdentity($0))})
        let approvedFindings=reading.verifiedFindings.filter {fullCollection || $0.externallyReusable==true || (reading.agentTask?.privateSelection != true && reading.libraryContext?.excludesExternalReferences != true)}
        let findings=try approvedFindings.filter {identities[$0.recordID]==$0.identity}.map {finding->AskAgentFinding in
            _ = try finding.validated();return .init(id:finding.id.uuidString,recordID:finding.recordID,field:finding.field,value:finding.value,sourceURL:finding.evidenceURL)
        }
        AskPipelineScope.record(.context,since:contextStarted)
        if let conversational=remote as? any AskConversationPlanning,await conversational.conversationAvailable() {
            return try await AskConversationLoop(planner:conversational,availableCandidates:Dictionary(uniqueKeysWithValues:Set(context.index.map(\.id)+(reading.collectionContinuation?.candidates.map(\.id) ?? [])).compactMap {id in tools.localCandidate(id).map {(id,$0)}}),execute:{call in try await executor.executeConversation(call,planner:conversational)},retainFindings:{call,evidence in try await executor.retainPublicFindings(call,evidence:evidence)}).answer(reading,context:context,cities:cities,findings:findings)
        }
        return try await AskAgentLoop(planner:planner,execute:{call,intent in try await executor.execute(call,intent:intent)},prepareIntent:{intent in try await executor.prepare(intent)}).answer(reading,context:context,cities:cities,findings:findings)
#endif
    }
}
