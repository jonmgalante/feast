import Foundation

struct AskAgentProvider:AskFeastProvider {
    let label="Ask Feast"
    let remote:any AskFeastProvider
    let fallback:any AskFeastProvider
    let adapter:AskSavedCollection
    let engine:AskCollectionChangeEngine
    let searchMaps:@MainActor @Sendable (String)async throws->[ApplePlaceMatch]
    var recoveryStore:AskTurnRecoveryStore?=nil
    var resolveMaps:@MainActor @Sendable (String)async throws->ApplePlaceMatch? = {_ in nil}
    /// Keep the check at dispatch, after credential/capability awaits inside the
    /// hosted provider. Opaque recovery status/cleanup carries no retained data.
    private var privacyCheckedRemote:any AskFeastProvider {
        guard var hosted=remote as? AskHostedProvider else{return remote}
        hosted.revalidatesHistoryAccess=true
        return hosted
    }
    @MainActor private func checkedMapsSearch(_ query:String)async throws->[ApplePlaceMatch] {
        try await AskHistoryAccessScope.check();return try await searchMaps(query)
    }
    @MainActor private func checkedMapsResolution(_ id:String)async throws->ApplePlaceMatch? {
        try await AskHistoryAccessScope.check();return try await resolveMaps(id)
    }
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
        if let recoveryStore,let turn=request.performanceID,let saved=try await recoveryStore.checkpoint(turn) {
            guard let hosted=remote as? AskHostedProvider,await hosted.permission(),saved.endpoint==hosted.configuration.endpoint.absoluteString else{throw AskHostedError.consentRequired}
            guard saved.resumable else{throw AskRecoveryError.stopped}
            if saved.finalResponse==nil {
                let minimum=saved.context?.collectionAccess=="permitted_details_v1" ? 7 : 6
                let toolsReady=await hosted.libraryToolsEnabled(),version=await hosted.libraryPlanVersion()
                if !toolsReady || version<minimum {await hosted.prepareCapabilities()}
                guard await hosted.permission() else{throw AskHostedError.consentRequired}
                let refreshedTools=await hosted.libraryToolsEnabled(),refreshedVersion=await hosted.libraryPlanVersion()
                guard refreshedTools,refreshedVersion>=minimum else{throw AskRecoveryError.paused}
            }
            if saved.phase == .executingTool {throw AskRecoveryError.localStepUncertain}
            try await recoveryStore.claim(turn)
            do {
                let response=try await AskRecoveryScope.$handle.withValue(.init(store:recoveryStore,turn:turn,permission:hosted.permission)) {
                    try await AskProviderAttemptScope.$lease.withValue(.init(turn:turn,attempt:saved.attemptID)) {try await runRecovered(saved,tools:tools)}
                }
                try await recoveryStore.complete(turn,response:response);await recoveryStore.release(turn);return response
            }catch {await recoveryStore.release(turn);throw error}
        }

        if let hosted=remote as? AskHostedProvider,await hosted.permission(),let turn=request.performanceID {
            let lease=try await hosted.prepareProviderAttempt(turn:turn,retrying:request.providerRetry)
            do {
                try Task.checkCancellation()
                if request.providerRetry {try await AskProviderAttemptScope.validateExplicitRetry?()}
                try Task.checkCancellation()
                var resumed=request
                if request.providerRetry,let context=try await AskProviderAttemptScope.store.readContext(for:lease) {
                    resumed.publicResearch=context.publicResearch ?? resumed.publicResearch
                    resumed.verifiedFindings=context.verifiedPublicFindings ?? resumed.verifiedFindings
                    resumed.agentTask=context.agentTask ?? resumed.agentTask
                    resumed.mapChoices=context.mapChoices ?? resumed.mapChoices
                    let provenance=AskConversationProjection.channelDependencies([.init(id:turn,request:request,response:context,status:.complete)],requireExplicitOrigin:true)
                    resumed.retainedChannelDependencies=(resumed.retainedChannelDependencies ?? [:]).merging(provenance,uniquingKeysWith:{Array(Set($0+$1)).sorted()})
                }
                let response=try await AskProviderAttemptScope.$lease.withValue(lease){try await runAnswer(resumed,tools:tools)}
                await AskProviderAttemptScope.store.finish(lease)
                return response
            }catch {await AskProviderAttemptScope.store.finish(lease);throw error}
        }
        return try await runAnswer(request,tools:tools)
    }
    private func runRecovered(_ saved:AskTurnCheckpoint,tools:AskReadTools)async throws->AskResponse {
        let remote=privacyCheckedRemote
        guard let context=saved.context ?? (saved.phase == .completed ? AskSemanticContext(index:[],recent:[]) : nil),let conversational=remote as? any AskConversationPlanning,let researcher=remote as? any AskBusinessResearching else{throw AskRecoveryError.unavailable}
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:saved.executorRequest ?? saved.request,researcher:researcher,searchMaps:{query in try await checkedMapsSearch(query)},resolveMaps:{id in try await checkedMapsResolution(id)},fullCollectionContext:context.collectionAccess=="permitted_details_v1")
        // Fresh access checks protect retained private context. Do not silently
        // rebuild a changed selection or send a different request under one ID.
        let permitted=try await executor.permittedRecordIDs()
        let external=Set((saved.request.mapChoices+(saved.state.latest?.mapChoices ?? [])+(saved.finalResponse?.mapChoices ?? [])).map(\.id))
        let referenced=Set(context.index.map(\.id)+saved.cities.map(\.id)+Array(saved.state.available.keys)+saved.state.ordered+saved.request.collectionDialogueIDs+saved.retainedRecordIDs).subtracting(external).union(AskConversationProjection.activeChannelRecordIDs(saved.request))
        let deleted=try await engine.recoveryDeletedRecordIDs(forTurn:saved.turnID,includingActionIDs:Set((saved.state.durableActions+(saved.finalResponse?.collectionActions ?? [])).map(\.id)))
        guard referenced.isSubset(of:permitted.union(deleted)) else{throw AskHostedError.selectionUnavailable}
        if let response=saved.finalResponse {return response}
        if let data=saved.executor {try await executor.restoreRecoverySnapshot(data)}
        return try await AskConversationLoop(planner:conversational,availableCandidates:saved.state.available,execute:{call in try await executor.executeConversation(call,planner:conversational)},retainFindings:{call,evidence in try await executor.retainPublicFindings(call,evidence:evidence)},recoverySnapshot:{try await executor.recoverySnapshot()},revalidateRecoveryAccess:{ actionIDs in
            let permitted=try await executor.permittedRecordIDs()
            let deleted=try await engine.recoveryDeletedRecordIDs(forTurn:saved.turnID,includingActionIDs:Set(actionIDs))
            guard Set(context.index.map(\.id)+saved.cities.map(\.id)).isSubset(of:permitted.union(deleted)) else{throw AskHostedError.selectionUnavailable}
        },retainedHistoryVersion:saved.retainedHistoryVersion ?? 0,historyAccess:{actionIDs in
            let permitted=try await adapter.readView().index.historyAccessIDs
            let deleted=try await engine.recoveryDeletedRecordIDs(forTurn:saved.turnID,includingActionIDs:Set(actionIDs))
            return permitted.union(deleted)
        }).answer(saved.request,context:context,cities:saved.cities,findings:saved.findings)
    }
    private func runAnswer(_ request:AskRequest,tools:AskReadTools)async throws->AskResponse {
#if FEAST_AGENT_ROLLBACK
        return try await localOrConsent(request,tools:tools)
#else
        let remote=privacyCheckedRemote
        guard request.attachment==nil,!request.fromOCR,
              let planner=remote as? any AskAgentPlanning,await planner.agentAvailable(),let researcher=remote as? any AskBusinessResearching else {return try await localOrConsent(request,tools:tools)}
        let fullCollection:Bool
        if let hosted=remote as? AskHostedProvider {let version=await hosted.libraryPlanVersion();let allowed=await hosted.permission();fullCollection = version>=7 && allowed}else{fullCollection=false}
        // Freeze optional read-query support before building both the executor
        // and its model loop. Recovery keeps its existing query contract.
        var queryVersion=0,historyVersion=0,nativeAvailable=false,useRecovery=false
        if let conversational=remote as? any AskConversationPlanning {
            nativeAvailable=await conversational.nativeResearchAvailable()
            if nativeAvailable,recoveryStore != nil,request.performanceID != nil,request.conversationID != nil,AskProviderAttemptScope.lease != nil,let hosted=remote as? AskHostedProvider {
                useRecovery=await hosted.recoveryEnabled()
            }
            if !useRecovery,fullCollection,nativeAvailable {queryVersion=await conversational.collectionQueryVersion()==2 ? 2 : 0;historyVersion=await conversational.retainedHistoryVersion()==1 ? 1 : 0}
            if useRecovery,fullCollection,let hosted=remote as? AskHostedProvider {historyVersion=await hosted.recoveryRetainedHistoryEnabled() ? 1 : 0}
        }
        let contextStarted=DispatchTime.now().uptimeNanoseconds
        var reading=request.collectionReadVersion()
        let current=try await adapter.readView(),snapshot=current.snapshot
        AskConversationProjection.filterChannels(&reading,permitted:current.index.historyAccessIDs)
        if let prior=reading.collectionContinuation,!AskConversationProjection.dependencies(prior).isSubset(of:current.index.historyAccessIDs) {reading.collectionContinuation=nil}

        if let history=fullCollection ? reading.collectionHistory : reading.publicHistory {
            let authorized=history.map {$0.permitted(current.index.historyAccessIDs)}
            reading.collectionHistory=authorized
            let indexed=try AskConversationProjection.indexedMessages(reading) ?? authorized
            // Freeze this exact index domain once. Accepted recovery must not
            // rebuild history indexes under a later app's projection algorithm.
            reading.collectionHistory=indexed
            reading.dialogue=indexed.map {message in .init(role:message.role,text:AskConversationProjection.excerpt(message.message.text,canPage:historyVersion==1))}
            reading.collectionDialogue=reading.dialogue
            reading.collectionDialogueIDs=Array(Set(indexed.flatMap {$0.fragments.flatMap(\.recordIDs)})).sorted()
            let human=reading.dialogue.filter {$0.role=="user" && $0.text != AskConversationProjection.unavailableFragment && $0.text != AskConversationProjection.omittedHuman}
            reading.recentQuestions=human.suffix(2).map {.init(question:$0.text,recordIDs:[])}
        }else if !fullCollection {reading.collectionHistory=nil}
        reading.publicHistory=nil
        var context=try AskSemanticContext.make(reading,catalog:snapshot,fullCollection:fullCollection)
        if !fullCollection {reading.collectionContinuation=nil}
        // The executor is an authorization boundary too: never give it the
        // stale findings that were removed only from the model projection.
        let identities=Dictionary(uniqueKeysWithValues:snapshot.places.map {($0.id,AskFindingIdentity($0))})
        reading.verifiedFindings=try reading.verifiedFindings.filter {
            identities[$0.recordID]==$0.identity && (fullCollection || $0.externallyReusable==true || (reading.agentTask?.privateSelection != true && reading.libraryContext?.excludesExternalReferences != true))
        }.map {try $0.validated()}
        // Only the conversation loop consumes full retained text. Keep it once
        // in the checkpoint, not again in the executor's immutable request digest.
        var executorRequest=reading;executorRequest.collectionHistory=nil
        let executor=await AskAgentExecutor(adapter:adapter,engine:engine,request:executorRequest,researcher:researcher,searchMaps:{query in try await checkedMapsSearch(query)},resolveMaps:{id in try await checkedMapsResolution(id)},fullCollectionContext:fullCollection,supportsCollectionQueryV2:queryVersion==2)
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
        let findings=reading.verifiedFindings.map {finding in
            AskAgentFinding(id:finding.id.uuidString,recordID:finding.recordID,field:finding.field,value:finding.value,sourceURL:finding.evidenceURL)
        }
        AskPipelineScope.record(.context,since:contextStarted)
        if let conversational=remote as? any AskConversationPlanning,await conversational.conversationAvailable() {
            // The bounded prompt catalog is not the full local identity catalog.
            // Hydrate retained references by exact ID from the current permitted
            // snapshot; never guess names or reuse an archived candidate's fields.
            var retained=Set(context.index.map(\.id))
            retained.formUnion(reading.agentTask?.selectionIDs ?? reading.agentTask?.orderedIDs ?? [])
            retained.formUnion(reading.libraryContext?.selectionIDs ?? reading.libraryContext?.ids ?? [])
            retained.formUnion(reading.referencedIDs)
            retained.formUnion(reading.collectionDialogueIDs)
            retained.formUnion(findings.map(\.recordID))
            retained.formUnion(reading.collectionContinuation?.candidates.map(\.id) ?? [])
            let permitted=Set(snapshot.places.map(\.id))
            let available=AskReadTools.localCandidates(retained.intersection(permitted),in:current.index)
            let recoveryContextIDs=Set(context.index.map(\.id)+cities.map(\.id))
            let loop=AskConversationLoop(planner:conversational,availableCandidates:available,execute:{call in try await executor.executeConversation(call,planner:conversational)},retainFindings:{call,evidence in try await executor.retainPublicFindings(call,evidence:evidence)},recoverySnapshot:{try await executor.recoverySnapshot()},revalidateRecoveryAccess:{ actionIDs in
                let permitted=try await executor.permittedRecordIDs()
                let deleted=try await engine.recoveryDeletedRecordIDs(forTurn:request.performanceID ?? UUID(),includingActionIDs:Set(actionIDs))
                guard recoveryContextIDs.isSubset(of:permitted.union(deleted)) else{throw AskHostedError.selectionUnavailable}
            },collectionQueryVersion:queryVersion,retainedHistoryVersion:historyVersion,historyAccess:{actionIDs in
                let permitted=try await adapter.readView().index.historyAccessIDs
                let deleted=try await engine.recoveryDeletedRecordIDs(forTurn:request.performanceID ?? UUID(),includingActionIDs:Set(actionIDs))
                return permitted.union(deleted)
            },nativeResearch:nativeAvailable)
            // Decide once, before the first request. No fallback after durable acceptance.
            if useRecovery,let recoveryStore,let hosted=remote as? AskHostedProvider,let turn=reading.performanceID,let chat=reading.conversationID,let lease=AskProviderAttemptScope.lease {
                var checkpoint=AskTurnCheckpoint(turnID:turn,chatID:chat,attemptID:lease.attempt,endpoint:hosted.configuration.endpoint.absoluteString,request:reading,createdAt:Date())
                try Task.checkCancellation()
                var userRequest=request;userRequest.collectionHistory=nil;userRequest.publicHistory=nil
                checkpoint.userRequest=userRequest
                checkpoint.retainedHistoryVersion=historyVersion==1 ? 1 : nil
                checkpoint.executorRequest=executor.request
                checkpoint.context=context;checkpoint.cities=cities;checkpoint.findings=findings
                checkpoint.state.available=available
                try await recoveryStore.save(checkpoint);try await recoveryStore.claim(turn)
                do {
                    let response=try await AskRecoveryScope.$handle.withValue(.init(store:recoveryStore,turn:turn,permission:hosted.permission)) {try await loop.answer(reading,context:context,cities:cities,findings:findings)}
                    try await recoveryStore.complete(turn,response:response);await recoveryStore.release(turn);return response
                }catch {await recoveryStore.release(turn);throw error}
            }
            return try await loop.answer(reading,context:context,cities:cities,findings:findings)
        }
        return try await AskAgentLoop(planner:planner,execute:{call,intent in try await executor.execute(call,intent:intent)},prepareIntent:{intent in try await executor.prepare(intent)}).answer(reading,context:context,cities:cities,findings:findings)
#endif
    }
}
