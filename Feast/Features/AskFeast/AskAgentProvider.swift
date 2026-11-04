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
        let contextStarted=DispatchTime.now().uptimeNanoseconds
        let reading=request.collectionReadVersion(),snapshot=try await adapter.librarySnapshot()
        let context=try AskSemanticContext.make(reading,catalog:snapshot)
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:reading,researcher:researcher,searchMaps:{query in try await searchMaps(query)},resolveMaps:resolveMaps)
        let cities=try await executor.cities()
        let identities=Dictionary(uniqueKeysWithValues:snapshot.places.map {($0.id,AskFindingIdentity($0))})
        let approvedFindings=reading.verifiedFindings.filter {$0.externallyReusable==true || (reading.agentTask?.privateSelection != true && reading.libraryContext?.excludesExternalReferences != true)}
        let findings=try approvedFindings.filter {identities[$0.recordID]==$0.identity}.map {finding->AskAgentFinding in
            _ = try finding.validated();return .init(id:finding.id.uuidString,recordID:finding.recordID,field:finding.field,value:finding.value,sourceURL:finding.evidenceURL)
        }
        AskPipelineScope.record(.context,since:contextStarted)
        if let conversational=remote as? any AskConversationPlanning,await conversational.conversationAvailable() {
            return try await AskConversationLoop(planner:conversational,availableCandidates:Dictionary(uniqueKeysWithValues:context.index.compactMap {record in tools.localCandidate(record.id).map {(record.id,$0)}}),execute:{call in try await executor.executeConversation(call,planner:conversational)},retainFindings:{call,evidence in try await executor.retainPublicFindings(call,evidence:evidence)}).answer(reading,context:context,cities:cities,findings:findings)
        }
        return try await AskAgentLoop(planner:planner,execute:{call,intent in try await executor.execute(call,intent:intent)},prepareIntent:{intent in try await executor.prepare(intent)}).answer(reading,context:context,cities:cities,findings:findings)
#endif
    }
}
