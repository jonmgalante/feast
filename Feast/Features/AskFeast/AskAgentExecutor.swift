import Foundation
import CoreData
import CryptoKit

/// Executes model-selected, typed operations against fresh data. No question-word routing.
@MainActor final class AskAgentExecutor {
    let adapter:AskSavedCollection,engine:AskCollectionChangeEngine,request:AskRequest
    let researcher:any AskBusinessResearching
    let searchMaps:(String) async throws->[ApplePlaceMatch]
    let resolveMaps:@MainActor @Sendable (String) async throws -> ApplePlaceMatch?
    private var prepared:[(AskAgentPermission,[String])]=[]
    private var conversationalReplacement=false
    private var conversationalExecution=false
    private var selection:[String]
    private let humanReferenceSelection:[String]
    private var selectionIsPrivate:Bool
    private var findings:[AskVerifiedFinding]
    private var maps:[String:ApplePlaceMatch]=[:]
    private var mutationOrder:[String]=[]
    private var mutationStates:[String:String]=[:]
    private var completedLeaves:[String:AskCollectionAction]=[:]
    private var frozenUndoActions:[String:AskCollectionAction]=[:]
    private var mapsQuery:String?
    private var researchCache:[String:AskResponse]=[:]
    private var researchOrder:[String]=[]
    private var researchResults:[String:AskResponse]=[:]
    private var researchFieldOrder:[String]=[]
    private var retainedPublicKeys=Set<String>()
    private var createdCities:[String:String]=[:]
    private var readContexts:[NSManagedObjectContext]=[]
    init(adapter:AskSavedCollection,engine:AskCollectionChangeEngine,request:AskRequest,researcher:any AskBusinessResearching,searchMaps:@escaping (String)async throws->[ApplePlaceMatch],resolveMaps:@escaping @MainActor @Sendable (String)async throws->ApplePlaceMatch? = {_ in nil}) {
        self.adapter=adapter;self.engine=engine;self.request=request;self.researcher=researcher;self.searchMaps=searchMaps;self.resolveMaps=resolveMaps
        humanReferenceSelection=request.agentTask?.orderedIDs ?? request.libraryContext?.selectionIDs ?? request.libraryContext?.ids ?? []
        selection=humanReferenceSelection;selectionIsPrivate=(request.agentTask?.privateSelection ?? (request.agentTask?.sourcePolicy=="local_only")) || request.libraryContext?.excludesExternalReferences==true;findings=request.verifiedFindings
        maps=Dictionary(request.mapChoices.map {($0.id,$0.match)},uniquingKeysWith:{$1})
        mapsQuery=request.mapChoices.first?.query

    }
    /// Per-operation optimistic concurrency guard, local only and never serialized
    /// into authorization/model context. Unrelated fields do not block narrow edits.
    private func authorizationState(_ proposal:AskChangeProposal)throws->[String:Data] {
        guard !["create","undo"].contains(proposal.operation) else{return [:]}
        let mapping=["name":proposal.entity=="place" ? "displayNameSnapshot" : "name","note":"note","tags":"tagsStorage","status":"status","type":"placeType","cuisines":"cuisinesStorage","website":"websiteURL","instagram":"instagramURL"]
        var result:[String:Data]=[:]
        for object in try objects(proposal.entity) {
            guard let id=(object.value(forKey:"id") as? UUID)?.uuidString,proposal.targetIDs.contains(id) else{continue}
            let keys=proposal.operation=="delete" ? Array(object.entity.attributesByName.keys) : proposal.changes.compactMap {mapping[$0.field]}
            var values:[String:Any]=[:]
            for key in keys {
                guard let value=object.value(forKey:key) else{values[key]=NSNull();continue}
                if let date=value as? Date {values[key]=date.timeIntervalSinceReferenceDate}
                else if let uuid=value as? UUID {values[key]=uuid.uuidString}
                else if let data=value as? Data {values[key]=data.base64EncodedString()}
                else {values[key]=value}
            }
            let relationships=proposal.operation=="delete" ? Array(object.entity.relationshipsByName.keys) : proposal.operation=="move" ? ["feastList","listSection"] : []
            for key in relationships where object.entity.relationshipsByName[key] != nil {
                let related=object.value(forKey:key)
                let records=(related as? NSSet)?.allObjects as? [NSManagedObject] ?? (related as? NSManagedObject).map {[$0]} ?? []
                values["relationship:"+key]=records.compactMap {($0.value(forKey:"id") as? UUID)?.uuidString}.sorted()
            }
            result[id]=try JSONSerialization.data(withJSONObject:values,options:.sortedKeys)
        }
        guard result.count==Set(proposal.targetIDs).count else{throw AskChangeError.missing}
        return result
    }
    func cities()throws->[AskAgentCity] {
        let ids=try adapter.visibleCities(),fetch=FeastList.fetchRequest()
        let reader=try adapter.makeSaveContext();readContexts.append(reader)
        return try reader.fetch(fetch).filter {$0.id.map(ids.contains)==true}.compactMap {city in guard let id=city.id else{return nil};return .init(id:id.uuidString,name:city.displayName)}
    }
    private func objects(_ entity:String)throws->[NSManagedObject] {
        let ids=try adapter.visibleCities(),name=entity=="city" ? "FeastList" : entity=="neighborhood" ? "ListSection" : "SavedPlace"
        let query=NSFetchRequest<NSManagedObject>(entityName:name);query.includesPendingChanges=false
        query.predicate=entity=="city" ? NSPredicate(format:"id IN %@",Array(ids) as NSArray) : NSPredicate(format:"feastList.id IN %@",Array(ids) as NSArray)
        let reader=try adapter.makeSaveContext();readContexts.append(reader)
        return try reader.fetch(query)
    }
    private func resolved(_ permission:AskAgentPermission,reference:[String]?=nil)throws->[String] {
        let selection=reference ?? self.selection
        let all=try objects(permission.entity)
        if permission.operations==["undo"],let positions=permission.selector?.positions,!positions.isEmpty {
            guard positions.allSatisfy({$0>0&&$0<=selection.count}),Set(positions).count==positions.count else {throw AskChangeError.invalid}
            let ids=positions.map {selection[$0-1]}
            guard permission.targetIDs.isEmpty || Set(permission.targetIDs)==Set(ids) else {throw AskChangeError.invalid}
            guard try ids.allSatisfy({try engine.latestAction(for:$0) != nil}) else {throw AskChangeError.missing}
            return ids
        }
        if permission.operations==["undo"],permission.selector==nil {
            let ids=permission.targetIDs.isEmpty ? selection : permission.targetIDs
            guard !ids.isEmpty,ids.count<=200,try ids.allSatisfy({try engine.latestAction(for:$0) != nil}) else {throw AskChangeError.missing}
            return ids
        }
        if !permission.targetIDs.isEmpty {
            let visible=Set(all.compactMap {($0.value(forKey:"id") as? UUID)?.uuidString})
            guard Set(permission.targetIDs).isSubset(of:visible) else {throw AskChangeError.missing};return permission.targetIDs
        }
        guard let selector=permission.selector else {
            if permission.operations.allSatisfy({$0=="create"}) {return []}
            throw AskChangeError.invalid
        }
        var values=all
        if selector.scope=="previous" || !(selector.positions ?? []).isEmpty {
            let byID=Dictionary(uniqueKeysWithValues:all.compactMap {object->(String,NSManagedObject)? in guard let id=object.value(forKey:"id") as? UUID else{return nil};return (id.uuidString,object)})
            guard !selection.isEmpty,selection.allSatisfy({byID[$0] != nil}) else {throw AskChangeError.missing}
            values=selection.compactMap {byID[$0]}
            if let positions=selector.positions,!positions.isEmpty {guard positions.allSatisfy({$0>0&&$0<=values.count}) else {throw AskChangeError.invalid};values=positions.map {values[$0-1]}}
        }
        if let supplied=selector.city {
            let available=try cities().map(\.name)
            guard case .matched(let city)=AskCityIdentity.resolve(supplied,available:available) else {throw AskChangeError.missing}
            values=values.filter {object in let name=permission.entity=="city" ? object.value(forKey:"name") as? String : (object.value(forKey:"feastList") as? FeastList)?.name;return name==city}
        }
        if let name=selector.name {values=values.filter {AskCityIdentity.key(($0.value(forKey:permission.entity=="place" ? "displayNameSnapshot" : "name") as? String) ?? "")==AskCityIdentity.key(name)}}
        if permission.entity=="place" {
            values=values.filter {object in guard let place=object as? SavedPlace else{return false}
                return (selector.neighborhood==nil||AskCityIdentity.key(place.listSection?.name ?? "")==AskCityIdentity.key(selector.neighborhood!)) && (selector.cuisine==nil||place.cuisines.contains(where:{$0.caseInsensitiveCompare(selector.cuisine!) == .orderedSame})) && (selector.status==nil||(selector.status=="untried" ? [.wantToTry,.justOpened].contains(place.placeStatus) : place.placeStatus.rawValue==selector.status)) && (selector.placeType==nil||place.placeTypeValue.rawValue==selector.placeType)
            }
        }else if [selector.neighborhood,selector.cuisine,selector.status,selector.placeType].contains(where:{$0 != nil}) {throw AskChangeError.invalid}
        guard !values.isEmpty,values.count<=200 else {throw AskChangeError.invalid}
        return values.compactMap {($0.value(forKey:"id") as? UUID)?.uuidString}.sorted()
    }
    /// Called exactly once before external results can affect a tool decision.
    func prepare(_ intent:AskAgentInterpretation)throws {
        prepared=try intent.permissions.map {permission in (permission,try resolved(permission))}
        // A future destination is authorized only by a separate current-turn city-create
        // grant with the exact same user-supplied name. Never resolve it by name in the store.
        for permission in intent.permissions {
            if let destination=permission.destinationCityID,destination.hasPrefix("created:") {
                let name=String(destination.dropFirst(8))
                let creators=intent.permissions.filter {$0.entity=="city" && $0.operations==["create"] && $0.changes?.contains(where:{$0.field=="name" && $0.source=="user" && $0.value==name})==true}
                guard !name.isEmpty,creators.count==1,permission.entity != "city" else {throw AskChangeError.permission}
            }
        }
        for (permission,ids) in prepared where permission.operations.contains("undo") {
            for id in ids {guard let action=try engine.latestAction(for:id) else {throw AskChangeError.missing};frozenUndoActions[id]=action}
        }
        if intent.permissions.contains(where:{!Set($0.fields).isDisjoint(with:["note","tags","status"]) || $0.entity=="neighborhood" || $0.selector?.status != nil || $0.selector?.placeType != nil || $0.selector?.neighborhood != nil}) {selectionIsPrivate=true}
    }
    func executeConversation(_ call:AskAgentReply.Call,planner:any AskConversationPlanning)async throws->AskAgentExecution {
        let started=DispatchTime.now().uptimeNanoseconds
        defer {AskPipelineScope.record(.toolExecution,since:started)}
        conversationalExecution=true
        var intent=AskAgentInterpretation(goal:"mixed",sourcePolicy:"public_if_missing",fields:[],selectionIDs:selection,permissions:[])
        if call.name=="confirm_changes" {
            struct Confirmation:Decodable {let actionIDs:[UUID]}
            let value=try JSONDecoder().decode(Confirmation.self,from:Data(call.arguments.utf8))
            let pending=value.actionIDs.compactMap {id in request.pendingActions.first {$0.id==id && $0.state == .needsConfirmation}}
            guard !pending.isEmpty,pending.count==value.actionIDs.count,Set(value.actionIDs).count==value.actionIDs.count else {throw AskChangeError.missing}
            let decision=try await planner.authorizePendingConfirmation(pending,question:request.text,history:AskConversationProjection.authorizationHistory(request.dialogue,recent:request.recentQuestions))
            guard decision.approved,decision.reason=="accepted_pending" else {throw AskChangeError.permission}
            var applied:[AskCollectionAction]=[],failure:String?
            for action in pending {
                do {try Task.checkCancellation();applied.append(try engine.performExplicitAction(action.id,undo:false))}
                catch {if applied.isEmpty {throw error};failure=error is CancellationError ? "Stopped. Earlier changes were saved." : error.localizedDescription;break}
            }
            // Pending previews can contain local-only values: never project their contents.
            selectionIsPrivate=true
            return .init(output:.init(status:failure==nil ? "applied" : "unavailable",complete:failure==nil,totalCount:0,records:[],findings:[],message:failure==nil ? "changed" : "unavailable",localOnly:false),response:plain(failure ?? "Saved.",actions:applied,statusOnly:failure==nil),orderedIDs:selection,appendPreviousResults:true,selectionIsPrivate:true,outcomes:applied.flatMap {action in action.targetIDs.map {.init(id:$0,state:action.state.rawValue)}})
        }
        if call.name=="propose_changes" {
            var proposal=try JSONDecoder().decode(AskChangeProposal.self,from:Data(call.arguments.utf8))
            let usesPrivateSelection=selectionIsPrivate && proposal.targetIDs.isEmpty && proposal.operation != "create"
            if proposal.targetIDs.isEmpty,proposal.operation != "create" {proposal.targetIDs=selection}
            if proposal.entity=="place",proposal.operation=="create",let choice=request.mapChoices.first(where:{$0.id==proposal.mapMatchID}) {
                guard let fresh=try await resolveMaps(choice.applePlaceID),fresh.applePlaceID==choice.applePlaceID,AskCityIdentity.key(fresh.displayName)==AskCityIdentity.key(choice.name),(choice.address.isEmpty || AskCityIdentity.key(fresh.secondaryText)==AskCityIdentity.key(choice.address)) else {
                    var response=plain("That Maps choice is no longer available. Search again before saving it.")
                    response.mapChoices=request.mapChoices;response.pendingProposal=proposal;response.executionStatus="unresolved"
                    return .init(output:.init(status:"stale",complete:false,totalCount:0,records:[],findings:[],message:"unavailable",localOnly:false),response:response,orderedIDs:selection)
                }
                maps[choice.id]=fresh
            }
            var authorizationProposal=proposal
            var namedDestination:(name:String,parent:String,id:String,inferredParent:Bool)?
            if let supplied=proposal.sectionID,UUID(uuidString:supplied)==nil {
                let sourcePlaces=try objects("place").filter {($0.value(forKey:"id") as? UUID).map {proposal.targetIDs.contains($0.uuidString)} == true}
                let sourceCities=Set(sourcePlaces.compactMap {($0.value(forKey:"feastList") as? FeastList)?.id?.uuidString})
                let parent=proposal.cityID ?? (sourceCities.count==1 ? sourceCities.first : nil)
                let matches=try objects("neighborhood").filter {object in
                    (object.value(forKey:"feastList") as? FeastList)?.id?.uuidString==parent && AskCityIdentity.key((object.value(forKey:"name") as? String) ?? "")==AskCityIdentity.key(supplied)
                }
                guard let parent,matches.count==1,let section=matches[0].value(forKey:"id") as? UUID else {
                    return .init(output:.init(status:"needs_confirmation",complete:true,totalCount:0,records:[],findings:[],message:"needs_review",localOnly:false),response:plain("Please specify one existing destination city and neighborhood."),orderedIDs:selection,selectionIsPrivate:selectionIsPrivate)
                }
                // The model/auth check sees its own requested name, not private IDs.
                // Persistence receives the unique fresh native identity.
                namedDestination=(supplied,parent,section.uuidString,proposal.cityID==nil)
                proposal = .init(entity:proposal.entity,operation:proposal.operation,targetIDs:proposal.targetIDs,cityID:parent,sectionID:section.uuidString,mapMatchID:proposal.mapMatchID,changes:proposal.changes,instructionQuote:proposal.instructionQuote)
            }
            let all=try objects(proposal.entity)
            let targets=all.filter {object in (object.value(forKey:"id") as? UUID).map {proposal.targetIDs.contains($0.uuidString)} == true}.compactMap {object->AskAgentRecord? in
                guard let id=object.value(forKey:"id") as? UUID else{return nil}
                let name=(object.value(forKey:proposal.entity=="place" ? "displayNameSnapshot" : "name") as? String) ?? ""
                let city=proposal.entity=="city" ? name : (object.value(forKey:"feastList") as? FeastList)?.displayName ?? ""
                return .init(id:id.uuidString,name:name,city:city,cuisines:[],kind:proposal.entity=="city" ? "city" : "place")
            }
            if usesPrivateSelection {authorizationProposal.targetIDs=[]}
            var pinnedUndo:[String:AskCollectionAction]=[:]
            if proposal.operation=="undo" {
                var descriptors:[AskUndoDescriptor]=[]
                for target in proposal.targetIDs {
                    guard let action=try engine.latestAction(for:target) else{throw AskChangeError.missing}
                    pinnedUndo[target]=action
                    let descriptor=try engine.undoDescriptor(for:action)
                    if !descriptors.contains(descriptor){descriptors.append(descriptor)}
                }
                authorizationProposal.undoContext=descriptors
            }
            let destinationCity=try cities().first {$0.id==proposal.cityID}
            var references:[AskAuthorizationReference]=[]
            if authorizationProposal.cityID != nil,let city=destinationCity {references.append(.init(kind:"city",id:city.id,name:city.name,city:city.name))}
            let sectionPin=try objects("neighborhood").compactMap {object->(id:String,name:String,parent:String?)? in
                guard let id=object.value(forKey:"id") as? UUID,id.uuidString==proposal.sectionID else{return nil}
                return (id.uuidString,(object.value(forKey:"name") as? String) ?? "",(object.value(forKey:"feastList") as? FeastList)?.id?.uuidString)
            }.first
            // A proposed destination UUID needs an identity mapping for authorization.
            // Share its name only when already supplied in permitted HUMAN context;
            // do not project unseen stored neighborhoods or an inferred private city.
            if authorizationProposal.sectionID.flatMap(UUID.init(uuidString:)) != nil,let section=sectionPin,!section.name.isEmpty,AskConversationProjection.humanNamed(section.name,question:request.text,messages:request.dialogue,recent:request.recentQuestions) {
                references.append(.init(kind:"neighborhood",id:section.id,name:section.name,city:authorizationProposal.cityID != nil ? (destinationCity?.name ?? "") : ""))
            }
            if let matchID=proposal.mapMatchID,let match=maps[matchID] {references.append(.init(kind:"maps",id:matchID,name:match.displayName,city:match.suggestedSectionPath.cityOrRegion ?? ""))}
            if !usesPrivateSelection,proposal.entity=="place" {
                let records=try adapter.librarySnapshot().places
                let names=Set(records.filter {proposal.targetIDs.contains($0.id)}.map {AskCityIdentity.key($0.name)})
                let grouped=Dictionary(grouping:records,by:{AskCityIdentity.key($0.name)})
                for name in names where (grouped[name]?.count ?? 0)>1 {
                    references += (grouped[name] ?? []).map {.init(kind:"place",id:$0.id,name:$0.name,city:$0.city)}
                }
            }
            authorizationProposal.referenceContext=references.isEmpty ? nil : references
            let researchedFields=Set(proposal.changes.filter {$0.source=="verified_finding"}.map(\.field))
            let contextFindings=findings.filter {researchedFields.contains($0.field) && ($0.externallyReusable==true || !selectionIsPrivate) && (usesPrivateSelection || proposal.targetIDs.contains($0.recordID))}
            authorizationProposal.findingContext=contextFindings.isEmpty ? nil : contextFindings.map {.init(id:$0.id.uuidString,recordID:$0.recordID,field:$0.field,value:$0.value,sourceURL:$0.evidenceURL)}
            let pinnedSource=try authorizationState(proposal)
            let authorizationStarted=DispatchTime.now().uptimeNanoseconds
            let decision:AskHumanAuthorization
            do {defer {AskPipelineScope.record(.authorization,since:authorizationStarted)};decision=try await planner.authorizeConversationChange(authorizationProposal,question:request.text,history:AskConversationProjection.authorizationHistory(request.dialogue,recent:request.recentQuestions),targets:usesPrivateSelection ? [] : targets)}
            guard decision.approved else {return .init(output:.init(status:"needs_confirmation",complete:true,totalCount:0,records:[],findings:[],message:"needs_review",localOnly:false),response:plain(decision.reason=="ambiguous" ? "Which change would you like me to make?" : "Tell me what you’d like changed before I save anything."),orderedIDs:selection,selectionIsPrivate:selectionIsPrivate)}
            try Task.checkCancellation()
            guard try authorizationState(proposal)==pinnedSource else{throw AskChangeError.conflict}
            if let city=destinationCity {guard try cities().contains(where:{$0.id==city.id && $0.name==city.name}) else{throw AskChangeError.conflict}}
            if let pinned=sectionPin {
                let current=try objects("neighborhood").first {($0.value(forKey:"id") as? UUID)?.uuidString==pinned.id}
                guard let current,(current.value(forKey:"name") as? String)==pinned.name,(current.value(forKey:"feastList") as? FeastList)?.id?.uuidString==pinned.parent else{throw AskChangeError.conflict}
            }
            for (target,pinned) in pinnedUndo {
                guard let current=try engine.latestAction(for:target),current.id==pinned.id,current.state==pinned.state else{throw AskChangeError.conflict}
            }
            if let pinned=namedDestination {
                let current=try objects("neighborhood").filter {($0.value(forKey:"id") as? UUID)?.uuidString==pinned.id}
                guard current.count==1,AskCityIdentity.key((current[0].value(forKey:"name") as? String) ?? "")==AskCityIdentity.key(pinned.name),(current[0].value(forKey:"feastList") as? FeastList)?.id?.uuidString==pinned.parent else{throw AskChangeError.conflict}
                if pinned.inferredParent {
                    let sources=try objects("place").filter {($0.value(forKey:"id") as? UUID).map {proposal.targetIDs.contains($0.uuidString)} == true}
                    guard sources.count==Set(proposal.targetIDs).count,Set(sources.compactMap {($0.value(forKey:"feastList") as? FeastList)?.id?.uuidString})==[pinned.parent] else{throw AskChangeError.conflict}
                }
            }
            if proposal.operation != "create",let selector=decision.targetSelector {
                let scope=AskAgentPermission(entity:proposal.entity,operations:[proposal.operation],fields:proposal.changes.map(\.field),targetIDs:[],instructionQuote:request.text,selector:selector)
                if !(selector.positions ?? []).isEmpty,let context=request.libraryContext,[AskLibraryPlan.Operation.count,.group,.catalog].contains(context.filters.operation),context.ids.isEmpty {
                    return .init(output:.init(status:"needs_confirmation",complete:true,totalCount:0,records:[],findings:[],message:"needs_review",localOnly:false),response:plain("Those results weren’t displayed in an order. Show a list before choosing an item by position."),orderedIDs:selection,selectionIsPrivate:selectionIsPrivate)
                }
                let permitted:[String]
                do {permitted=try resolved(scope,reference:humanReferenceSelection)}
                catch AskChangeError.invalid {
                    return .init(output:.init(status:"conflict",complete:true,totalCount:0,records:[],findings:[],message:"target_mismatch",localOnly:false),response:plain("No change was applied: the requested record or relationship does not match the saved details."),orderedIDs:selection,appendPreviousResults:true,selectionIsPrivate:selectionIsPrivate,presentation:.init(kind:"action",requestedFields:proposal.changes.map(\.field),returnedFields:[],complete:true,renderedLocally:true))
                }

                guard !proposal.targetIDs.isEmpty,Set(proposal.targetIDs).isSubset(of:Set(permitted)) else{throw AskChangeError.permission}
            }else if usesPrivateSelection {
                return .init(output:.init(status:"needs_confirmation",complete:true,totalCount:0,records:[],findings:[],message:"needs_review",localOnly:false),response:plain("Which of the displayed places should I change?"),orderedIDs:selection,selectionIsPrivate:true)
            }
            conversationalReplacement=decision.replaceExisting
            let expected=proposal.changes.map {change in AskAgentExpectedChange(field:change.field,source:change.source ?? (change.findingID==nil ? "user" : "verified_finding"),value:change.value,values:change.values)}
            var permission=AskAgentPermission(entity:proposal.entity,operations:[proposal.operation],fields:proposal.changes.map(\.field),targetIDs:proposal.targetIDs,instructionQuote:request.text,changes:expected,destinationCityID:proposal.cityID)
            if let pinned=namedDestination {permission.destinationNeighborhood=pinned.name}
            else if let section=proposal.sectionID {permission.destinationNeighborhood=(try objects("neighborhood").first {($0.value(forKey:"id") as? UUID)?.uuidString==section})?.value(forKey:"name") as? String}
            if proposal.entity=="place",proposal.operation=="create" {permission.mapQuery=mapsQuery}
            intent=AskAgentInterpretation(goal:"change",sourcePolicy:"public_if_missing",fields:proposal.changes.map(\.field),selectionIDs:proposal.targetIDs,permissions:[permission])
            try prepare(intent)
            let encoded=try JSONEncoder().encode(proposal)
            var execution=try change(encoded,intent:intent)
            let requested=proposal.operation=="undo" ? (authorizationProposal.undoContext ?? []).flatMap(\.fields) : proposal.changes.map(\.field)
            let fields=Array(Set(requested.map {$0=="cuisines" ? "cuisine" : $0})).sorted()
            execution.presentation = .init(kind:"action",requestedFields:fields,returnedFields:[],complete:execution.output.complete,renderedLocally:true)
            return execution
        }
        return try await execute(call,intent:intent)
    }
    func retainPublicFindings(_ call:AskAgentReply.Call,evidence:[AskRetainedResearch])throws->AskAgentExecution {
        struct Item:Decodable {let recordID,field,value,sourceURL,quote:String}
        struct Payload:Decodable {let findings:[Item]}
        let payload=try JSONDecoder().decode(Payload.self,from:Data(call.arguments.utf8))
        guard !payload.findings.isEmpty,payload.findings.count<=24 else{throw AskError.inputLimit}
        let incomingKeys=Set(payload.findings.map {$0.recordID+":"+$0.field})
        guard retainedPublicKeys.union(researchFieldOrder).union(incomingKeys).count<=24 else{throw AskError.inputLimit}
        let records=try adapter.librarySnapshot().places
        let tools=try AskReadTools(request:request.collectionReadVersion(),index:adapter.index())
        var retained:[AskVerifiedFinding]=[],candidates:[AskCandidate]=[]
        var retainedKeys=Set<String>()
        for item in payload.findings {
            guard retainedKeys.insert(item.recordID+":"+item.field).inserted else{throw AskError.invalidEvidence}
            guard let record=records.first(where:{$0.id==item.recordID}),!item.quote.isEmpty,item.quote.count<=2000,
                  let source=evidence.first(where:{$0.result.nativeEvidence.map {$0.containsQuotedBlockWithSource(quote:item.quote,url:item.sourceURL)} ?? ($0.result.citations.contains {$0.url==item.sourceURL} && $0.result.text.contains(item.quote))}),
                  (Self.explicitlyNames(record.name,in:source.query) || source.result.nativeEvidence?.blocks.contains(where:{$0.text.contains(item.quote) && Self.explicitlyNames(record.name,in:$0.text)}) == true),let candidate=tools.localCandidate(record.id) else{throw AskError.invalidEvidence}
            // Exact retrieved value support; entity attribution is the model's
            // semantic decision, never an English sentence grammar whitelist.
            let supported:Bool
            if item.field=="instagram",let profile=InstagramWebsiteParser.profileURL(item.value),let handle=URL(string:profile)?.lastPathComponent {
                let pattern="(?<![A-Za-z0-9_.])@?"+NSRegularExpression.escapedPattern(for:handle)+"(?![A-Za-z0-9_.])"
                supported=profile==item.value && item.quote.range(of:pattern,options:[.regularExpression,.caseInsensitive]) != nil
            }else{supported=item.quote.contains(item.value)}
            guard supported else{throw AskError.invalidEvidence}
            let retainedID=findings.last(where:{$0.recordID==record.id && $0.field==item.field && $0.value==item.value && $0.evidenceURL==item.sourceURL && $0.identity==AskFindingIdentity(record)})?.id ?? UUID()
            let finding=try AskVerifiedFinding(id:retainedID,recordID:record.id,identity:.init(record),field:item.field,value:item.value,evidenceURL:item.sourceURL,verification:"cited_search",originatingTurn:source.originatingTurn,externallyReusable:true).validated()
            retained.append(finding)
            if !candidates.contains(where:{$0.id==candidate.id}){candidates.append(candidate)}
        }
        retainedPublicKeys.formUnion(incomingKeys)
        for finding in retained {findings.removeAll {$0.recordID==finding.recordID && $0.field==finding.field};findings.append(finding)}
        var response=AskResponse(summary:"Public findings",candidates:candidates,listedCandidateIDs:[],usesLocalCatalog:true)
        response.verifiedPublicFindings=retained
        response.fieldActions=retained.filter {$0.field=="instagram"}.map {.init(finding:$0,outcome:.ready)}
        return .init(output:output("success",records.filter {r in retained.contains {$0.recordID==r.id}},publicFindings:retained),response:response,orderedIDs:retained.map(\.recordID).reduce(into:[]) {if !$0.contains($1){$0.append($1)}},appendPreviousResults:true)
    }
    private func plain(_ text:String,actions:[AskCollectionAction]?=nil,statusOnly:Bool=false)->AskResponse {
        .init(summary:text,candidates:[],paragraphs:[.init(id:"agent-message",spans:[.text(text)],sourceIDs:[],operationStatus:statusOnly)],listedCandidateIDs:[],usesLocalCatalog:true,collectionActions:actions)
    }
    private func output(_ status:String,_ records:[AskPersonalPlace],complete:Bool=true,publicFindings:[AskVerifiedFinding]=[],message:String="ok")->AskAgentResult {
        .init(status:status,complete:complete,totalCount:records.count,records:records.map {.init(id:$0.id,name:$0.name,city:$0.city,cuisines:$0.cuisines,kind:"place")},findings:publicFindings.map {.init(id:$0.id.uuidString,recordID:$0.recordID,field:$0.field,value:$0.value,sourceURL:$0.evidenceURL)},message:message,localOnly:false)
    }
    func execute(_ call:AskAgentReply.Call,intent:AskAgentInterpretation)async throws->AskAgentExecution {
        let started=DispatchTime.now().uptimeNanoseconds
        let stage:AskPipelineStage = call.name=="query_collection" ? .collectionRead : call.name=="research_businesses" ? .businessLookup : call.name=="search_maps" ? .mapsLookup : .mutation
        defer {AskPipelineScope.record(stage,since:started)}
        try Task.checkCancellation()
        switch call.name {
        case "query_collection":return try query(Data(call.arguments.utf8),intent:intent)
        case "research_businesses":return try await research(Data(call.arguments.utf8),intent:intent)
        case "search_maps":
            struct Search:Decodable {let query:String,cityID:String?}
            let value=try JSONDecoder().decode(Search.self,from:Data(call.arguments.utf8))
            guard !value.query.isEmpty,value.query.count<=300 else {throw AskError.inputLimit}
            let cityName:String?
            if let cityID=value.cityID {
                guard let city=try cities().first(where:{$0.id==cityID}) else{throw AskError.invalidEvidence}
                cityName=city.name
            }else{cityName=nil}
            let results:[ApplePlaceMatch]
            do {results=try await PlaceSearchContext.search(value.query,cityName:cityName,lookup:searchMaps)}catch {
                try Task.checkCancellation()
                let failure=error as NSError
                guard ["MKErrorDomain",NSURLErrorDomain].contains(failure.domain) else{throw error}
                maps=[:];mapsQuery=nil
                return .init(output:.init(status:"unavailable",complete:false,totalCount:0,records:[],findings:[],message:"unavailable",localOnly:false),response:plain("Apple Maps couldn’t complete that search. Earlier changes remain saved."),orderedIDs:selection,appendPreviousResults:true,selectionIsPrivate:selectionIsPrivate)
            }
            try Task.checkCancellation()
            let namespace=UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
            var choices:[AskMapChoice]=[]
            for match in results.prefix(6) where !choices.contains(where:{$0.applePlaceID==match.applePlaceID}) {
                let id=Self.trace(namespace,"maps:"+match.applePlaceID).uuidString
                choices.append(.init(id:id,applePlaceID:match.applePlaceID,name:match.displayName,address:match.secondaryText,city:match.suggestedSectionPath.cityOrRegion ?? cityName ?? "",query:value.query,website:match.websiteURL,originatingTurn:request.performanceID ?? UUID()))
            }
            maps=Dictionary(choices.map {($0.id,$0.match)},uniquingKeysWith:{$1});mapsQuery=value.query
            let records=choices.map {AskAgentRecord(id:$0.id,name:$0.name,city:$0.city,cuisines:[],kind:"maps",detail:$0.address)}
            var response=plain(records.isEmpty ? "No Maps match was found." : "")
            response.mapChoices=choices
            return .init(output:.init(status:records.isEmpty ? "empty" : "success",complete:results.count<=6,totalCount:results.count,records:records,findings:[],message:records.isEmpty ? "not_found" : "ok",localOnly:false),response:response,orderedIDs:selection)
        case "propose_changes":return try change(Data(call.arguments.utf8),intent:intent)
        default:throw AskError.invalidEvidence
        }
    }
    private func query(_ data:Data,intent:AskAgentInterpretation)throws->AskAgentExecution {
        struct Query:Decodable {let entity:String,query:AskLibraryPlan,selectionIDs:[String]?}
        let supplied=try JSONDecoder().decode(Query.self,from:data)
        if supplied.entity != "place" {
            guard ["city","neighborhood"].contains(supplied.entity) else {throw AskError.invalidEvidence}
            var records=try objects(supplied.entity)
            if supplied.query.scope == .previous {
                let byID=Dictionary(uniqueKeysWithValues:records.compactMap {object->(String,NSManagedObject)? in guard let id=object.value(forKey:"id") as? UUID else{return nil};return (id.uuidString,object)})
                guard !selection.isEmpty,selection.allSatisfy({byID[$0] != nil}) else {throw AskChangeError.missing}
                records=selection.compactMap {byID[$0]}
            }else {records.sort {a,b in let left=(a.value(forKey:"name") as? String) ?? "",right=(b.value(forKey:"name") as? String) ?? "";return left==right ? (a.value(forKey:"id") as? UUID)?.uuidString ?? "" < (b.value(forKey:"id") as? UUID)?.uuidString ?? "" : left.localizedCaseInsensitiveCompare(right) == .orderedAscending}}
            if !supplied.query.positions.isEmpty {guard supplied.query.scope == .previous,supplied.query.positions.allSatisfy({$0>0&&$0<=records.count}) else {throw AskChangeError.invalid};records=supplied.query.positions.map {records[$0-1]}}
            if let city=supplied.query.city {guard case .matched(let name)=AskCityIdentity.resolve(city,available:try cities().map(\.name)) else {return .init(output:.localPrivate(),response:plain("No saved city matches that request."),orderedIDs:[])};records=records.filter {supplied.entity=="city" ? ($0.value(forKey:"name") as? String)==name : ($0.value(forKey:"feastList") as? FeastList)?.name==name}}
            if let name=supplied.query.name {records=records.filter {AskCityIdentity.key(($0.value(forKey:"name") as? String) ?? "")==AskCityIdentity.key(name)}}
            if let ids=supplied.selectionIDs {records=records.filter {($0.value(forKey:"id") as? UUID).map {ids.contains($0.uuidString)} == true}}
            let names=records.compactMap {$0.value(forKey:"name") as? String},ids=records.compactMap {($0.value(forKey:"id") as? UUID)?.uuidString}
            selection=ids
            let text=supplied.query.operation == .count ? "\(records.count) saved \(supplied.entity == "city" ? "cities" : "neighborhoods")." : names.isEmpty ? "No saved \(supplied.entity == "city" ? "cities" : "neighborhoods") match that request." : names.joined(separator:"\n")
            // Neighborhood names/membership are not part of the approved uploaded compact index.
            let presentation=AskToolPresentation(kind:supplied.query.operation == .count ? "count" : "rows",requestedFields:supplied.query.fields,returnedFields:supplied.query.operation == .count ? [] : ["name"],complete:true,renderedLocally:true)
            if supplied.entity=="neighborhood" {return .init(output:.localPrivate(),response:plain(text),orderedIDs:ids,selectionIsPrivate:true,presentation:presentation)}
            let cloud=records.compactMap {object->AskAgentRecord? in guard let id=object.value(forKey:"id") as? UUID,let name=object.value(forKey:"name") as? String else{return nil};return .init(id:id.uuidString,name:name,city:name,cuisines:[],kind:"city")}
            return .init(output:.init(status:cloud.isEmpty ? "empty" : "success",complete:true,totalCount:cloud.count,records:cloud,findings:[],message:cloud.isEmpty ? "not_found" : "ok",localOnly:false),response:plain(text),orderedIDs:ids,presentation:presentation)
        }
        let view=try adapter.readView(),catalog=view.snapshot
        var plan=supplied.query
        let privateFields=Set(plan.fields).intersection(["note","tags"])
        plan.fields.removeAll {privateFields.contains($0)}
        let selected=supplied.selectionIDs ?? (plan.scope == .previous ? selection : nil)
        var context=selected.map {AskLibraryContext(ids:$0,filters:plan)}
        if selectionIsPrivate,plan.scope == .previous || (supplied.selectionIDs != nil && plan.name==nil && plan.names==nil && plan.city==nil) {context?.excludesExternalReferences=true}
        let filtered=selected.map {ids in AskLibrarySnapshot(places:catalog.places.filter {ids.contains($0.id)},totalCount:catalog.places.filter {ids.contains($0.id)}.count,cityNames:catalog.cityNames)} ?? catalog
        var result=try AskLibraryReadTools.execute(plan,snapshot:filtered,context:context,requireUniqueDetails:false)
        if result.excludesExternalReferences,plan.fields.allSatisfy(AskBusinessRequest.allowedFields.contains),plan.status==nil,plan.placeType==nil,plan.neighborhood==nil,context?.excludesExternalReferences != true {result.excludesExternalReferences=false}
        selection=result.records.map(\.id);selectionIsPrivate=result.excludesExternalReferences || !privateFields.isEmpty
        let tools=try AskReadTools(request:request.collectionReadVersion(),index:view.index)
        var response=try AskLibraryReadTools.response(result,tools:tools)
        let aggregate=plan.operation == .count || plan.operation == .group || plan.operation == .catalog
        if !privateFields.isEmpty && !aggregate {
            let visible=try objects("place").compactMap {$0 as? SavedPlace}
            response.paragraphs=response.paragraphs.map {paragraph in
                var spans=paragraph.spans
                for span in paragraph.spans {
                    guard case .place(let id)=span,let place=visible.first(where:{$0.id?.uuidString==id}) else{continue}
                    let facts=privateFields.sorted().map {field in field=="note" ? (place.note?.isEmpty==false ? place.note! : "No note is saved.") : (place.tags.isEmpty==false ? place.tags.joined(separator:", ") : "No tags are saved.")}.joined(separator:"\n")
                    spans.append(.text("\n"+facts))
                }
                return .init(id:paragraph.id,spans:spans,sourceIDs:paragraph.sourceIDs,citations:paragraph.citations,citationsAreResearchPool:paragraph.citationsAreResearchPool)
            }
        }
        let kind=plan.operation == .catalog ? "count" : plan.operation == .count ? (plan.groupBy==nil ? "count" : "groups") : plan.operation == .group ? "groups" : plan.operation == .details || plan.operation == .compare ? "details" : "rows"
        let presentation=AskToolPresentation(kind:kind,requestedFields:supplied.query.fields,returnedFields:aggregate ? plan.groupBy.map {[$0]} ?? [] : supplied.query.fields,complete:result.complete,renderedLocally:true)
        if plan.groupBy != nil,plan.operation != .group,plan.operation != .count {
            selection=response.paragraphs.flatMap(\.spans).compactMap {span->String? in if case .place(let id)=span{return id};return nil}.reduce(into:[]) {if !$0.contains($1){$0.append($1)}}
        }
        let storedFindings=result.records.flatMap {record in plan.fields.compactMap {field->AskVerifiedFinding? in
            let value=field=="instagram" ? record.instagramURL.flatMap(InstagramWebsiteParser.profileURL) : field=="website" ? record.websiteURL.flatMap {InstagramWebsiteClient.websiteURL($0)?.absoluteString} : nil
            guard let value else{return nil};return .init(id:UUID(),recordID:record.id,identity:.init(record),field:field,value:value,evidenceURL:value,verification:"saved",originatingTurn:request.performanceID ?? UUID())
        }}
        response.verifiedPublicFindings=storedFindings.isEmpty ? nil : storedFindings
        if result.excludesExternalReferences || !privateFields.isEmpty {response.verifiedPublicFindings=nil;return .init(output:.localPrivate(),response:response,orderedIDs:selection,selectionIsPrivate:true,presentation:presentation)}
        let count=plan.operation == .catalog ? result.totalCount : result.records.count
        let cloud=output(result.status == .success ? (count==0 ? "empty" : "success") : result.status == .ambiguous ? "ambiguous" : "partial",result.records,complete:result.complete,publicFindings:storedFindings)
        let measured=AskAgentResult(status:cloud.status,complete:cloud.complete,totalCount:count,records:cloud.records,findings:cloud.findings,message:cloud.message,localOnly:false)
        return .init(output:measured,response:response,orderedIDs:selection,presentation:presentation)
    }
    /// Releasing a privately selected identity requires the user's complete business name,
    /// never a substring of another word. This does not determine conversational intent.
    static func explicitlyNames(_ name:String,in question:String)->Bool {
        func tokens(_ value:String)->[String] {
            let normalized=value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
                .replacingOccurrences(of:"’",with:"'")
                .replacingOccurrences(of:"'s\\b",with:"",options:.regularExpression)
            return normalized.components(separatedBy:CharacterSet.alphanumerics.inverted).filter {!$0.isEmpty}
        }
        var nameTokens=tokens(name)
        if nameTokens.first=="the" {nameTokens.removeFirst()}
        let generic:Set<String>=["love","regulars","been","restaurant","restaurants","cafe","bar","market","place","places"]
        guard !nameTokens.isEmpty,nameTokens.contains(where:{!generic.contains($0)}) else{return false}
        let words=tokens(question)
        guard words.count>=nameTokens.count else{return false}
        return (0...(words.count-nameTokens.count)).contains {Array(words[$0..<($0+nameTokens.count)])==nameTokens}
    }
    private func research(_ data:Data,intent:AskAgentInterpretation)async throws->AskAgentExecution {
        struct Research:Decodable {let targetIDs:[String],fields:[String],sourcePolicy:String}
        let value=try JSONDecoder().decode(Research.self,from:data)
        guard (1...6).contains(value.targetIDs.count),Set(value.targetIDs).count==value.targetIDs.count,(1...4).contains(value.fields.count),value.fields.allSatisfy(AskBusinessRequest.allowedFields.contains),intent.sourcePolicy != "local_only",value.sourcePolicy=="stored_only" || intent.sourcePolicy=="public_if_missing" else {throw AskError.invalidEvidence}
        let all=try adapter.personalPlaces(),records=try value.targetIDs.map {id in guard let record=all.first(where:{$0.id==id}) else {throw AskChangeError.missing};return record}
        if selectionIsPrivate,!Set(value.targetIDs).isDisjoint(with:Set(selection)) {
            guard records.allSatisfy({Self.explicitlyNames($0.name,in:request.text)}) else {return .init(output:.localPrivate(),response:plain("Please name the places you’d like me to look up online."),orderedIDs:selection,selectionIsPrivate:true)}
        }
        selectionIsPrivate=false
        let requestedKeys=Set(value.targetIDs.flatMap {id in value.fields.map {id+":"+$0}})
        let candidateIDs=Set(researchOrder+value.targetIDs)
        let retainedKeys=Set(request.verifiedFindings.filter {candidateIDs.contains($0.recordID)}.map {$0.recordID+":"+$0.field})
        guard Set(researchFieldOrder).union(retainedPublicKeys).union(requestedKeys).union(retainedKeys).count<=24 else {
            let previous=Self.merge(researchFieldOrder.compactMap {researchResults[$0]})
            var response=previous
            response.paragraphs.append(.init(id:"agent-research-capacity",spans:[.text("Earlier results are retained. This turn has reached its 24-detail research limit; ask for the remaining details in a new message.")],sourceIDs:[]))
            return .init(output:output("unavailable",records,complete:false,message:"unavailable"),response:response,orderedIDs:researchOrder)
        }
        var responses:[AskResponse]=[],stopped=false,stopStatus="unavailable"
        let tools=try AskReadTools(request:request.collectionReadVersion(),index:adapter.index())
        for record in records {
            try Task.checkCancellation()
            let cacheKey=record.id+":"+value.fields.sorted().joined(separator:",")+":"+value.sourcePolicy
            if let cached=researchCache[cacheKey] {responses.append(cached);continue}
            var item=request.collectionReadVersion();item.performanceID=Self.trace(request.performanceID ?? UUID(),cacheKey)
            let plan=AskLibraryPlan(operation:.lookup,scope:.library,city:record.city,cuisine:nil,status:nil,placeType:nil,name:record.name,positions:[],fields:value.fields)
            do {
                let branches=all.filter {AskCityIdentity.key($0.name)==AskCityIdentity.key(record.name)&&AskCityIdentity.key($0.city)==AskCityIdentity.key(record.city)}
                let website=record.websiteURL.flatMap {InstagramWebsiteClient.websiteURL($0)?.absoluteString}
                let distinctWebsite=website != nil && branches.filter {$0.websiteURL.flatMap {InstagramWebsiteClient.websiteURL($0)?.absoluteString}==website}.count==1
                let unambiguous=branches.count==1
                var response=try await AskBusinessLookup.answer(item,plan:plan,record:record,tools:tools,allowExternalLookups:value.sourcePolicy=="public_if_missing" && (unambiguous||distinctWebsite),allowHostedResearch:unambiguous,externalLimitation:unambiguous ? nil : "I need a branch-specific source to verify these details for this saved location.",researcher:researcher,resolvePlace:{id in try await self.resolveMaps(id)})
                response.verifiedPublicFindings=response.verifiedPublicFindings?.map {finding in var f=finding;f.externallyReusable=true;return f}
                responses.append(response);researchCache[cacheKey]=response
                for finding in response.verifiedPublicFindings ?? [] {findings.removeAll {$0.recordID==finding.recordID&&$0.field==finding.field};findings.append(finding)}
            } catch is CancellationError {throw CancellationError()}
            catch {
                responses.append(plain(AskHostedError.message(for:error)))
                if case AskHostedError.service(let code)=error,code==429 {stopStatus="budget_stopped"}
                stopped=true;break // never retry uncertain transport or exhausted reservation
            }
        }
        for (index,response) in responses.enumerated() {
            let id=records[index].id
            if !researchOrder.contains(id) {researchOrder.append(id)}
            for field in value.fields {
                let key=id+":"+field
                if !researchFieldOrder.contains(key) {researchFieldOrder.append(key)}
                var fragment=response
                fragment.paragraphs=response.paragraphs.filter {$0.representedField==nil || $0.representedField==field}
                fragment.verifiedPublicFindings=response.verifiedPublicFindings?.filter {$0.field==field}
                fragment.fieldActions=response.fieldActions?.filter {$0.finding.field==field}
                researchResults[key]=fragment
            }
        }
        for id in value.targetIDs where !researchOrder.contains(id) {researchOrder.append(id)}
        selection=researchOrder
        let merged=Self.merge(researchFieldOrder.compactMap {researchResults[$0]})
        let current=findings.filter {value.targetIDs.contains($0.recordID)&&value.fields.contains($0.field)}
        return .init(output:output(stopped ? stopStatus : "success",records,complete:!stopped,publicFindings:current,message:stopped ? "budget_limit" : "ok"),response:merged,orderedIDs:selection,appendPreviousResults:false)
    }
    private func change(_ data:Data,intent:AskAgentInterpretation)throws->AskAgentExecution {
        var p=try JSONDecoder().decode(AskChangeProposal.self,from:data)
        guard let match=prepared.enumerated().first(where:{entry in
            let (permission,ids)=entry.element
            let destination=permission.destinationCityID.flatMap {value in value.hasPrefix("created:") ? createdCities[String(value.dropFirst(8))] : value}
            guard p.cityID==destination else {return false}
            return permission.entity==p.entity && permission.operations.contains(p.operation) && Set(p.changes.map(\.field)).isSubset(of:Set(permission.fields)) && (p.targetIDs.isEmpty || Set(p.targetIDs).isSubset(of:Set(ids))) && p.changes.allSatisfy {change in
                guard let expected=permission.changes?.first(where:{$0.field==change.field}) else{return false}
                return expected.source != "user" || (change.value==expected.value && change.values==expected.values)
            }
        }) else {throw AskChangeError.permission}
        let (permission,ids)=match.element
        if p.targetIDs.isEmpty,p.operation != "create" {p.targetIDs=ids}
        guard p.targetIDs.count<=200 else {throw AskChangeError.invalid}
        let expected=permission.changes ?? []
        for c in p.changes {
            guard let accepted=expected.first(where:{$0.field==c.field}) else {throw AskChangeError.permission}
            if accepted.source=="user" {guard c.value==accepted.value,c.values==accepted.values else {throw AskChangeError.permission}}
            else {guard ["instagram","website"].contains(c.field),p.targetIDs.allSatisfy({id in findings.contains(where:{$0.recordID==id&&$0.field==c.field&&(c.value==nil||$0.value==c.value)})}) else {throw AskChangeError.permission}}
        }
        let cityID:String?
        if let destination=permission.destinationCityID,destination.hasPrefix("created:") {
            guard let created=createdCities[String(destination.dropFirst(8))] else {throw AskChangeError.missing}
            cityID=created
        }else {cityID=permission.destinationCityID}
        guard p.cityID==cityID else {throw AskChangeError.permission}
        var sectionIDs=Set<String>()
        if let name=permission.destinationNeighborhood,let cityID {
            sectionIDs=Set(try objects("neighborhood").filter {AskCityIdentity.key(($0.value(forKey:"name") as? String) ?? "")==AskCityIdentity.key(name) && ($0.value(forKey:"feastList") as? FeastList)?.id?.uuidString==cityID}.compactMap {($0.value(forKey:"id") as? UUID)?.uuidString})
        }
        guard p.sectionID==nil ? permission.destinationNeighborhood==nil : sectionIDs.contains(p.sectionID!) else {throw AskChangeError.permission}
        if p.operation=="create",p.entity=="place" {guard permission.mapQuery==mapsQuery,let id=p.mapMatchID,maps[id] != nil,(conversationalExecution || maps.count==1) else {return .init(output:.init(status:"needs_confirmation",complete:true,totalCount:0,records:[],findings:[],message:"needs_review",localOnly:false),response:plain("Choose the exact Maps result before adding this place."),orderedIDs:selection)}}
        var actions:[AskCollectionAction]=[]
        var failure:String?,failedTarget:String?
        // One leaf executor, including per-target finding values and independently undoable outcomes.
        let targets=p.operation=="create" ? [String?](arrayLiteral:nil) : p.targetIDs.map(Optional.some)
        for target in targets {
            do {
            try Task.checkCancellation()
            var item=p;item.targetIDs=target.map {[$0]} ?? []
            if let target {
                item.changes=item.changes.map {c in guard expected.contains(where:{$0.field==c.field&&$0.source=="verified_finding"}),let finding=findings.last(where:{$0.recordID==target&&$0.field==c.field}) else{return c};return .init(field:c.field,value:finding.value,values:nil,findingID:finding.id.uuidString)}
            }
            let leafFields=["update","append"].contains(item.operation) && !item.changes.isEmpty ? item.changes.map(\.field).sorted() : ["operation"]
            let leafKeys=try leafFields.map {field->String in
                var leaf=item
                if field != "operation" {leaf.changes=item.changes.filter {$0.field==field}}
                var identity=try JSONSerialization.jsonObject(with:JSONEncoder().encode(leaf)) as! [String:Any]
                identity.removeValue(forKey:"instructionQuote")
                let encoded=(try JSONSerialization.data(withJSONObject:identity,options:.sortedKeys)).base64EncodedString()
                return item.entity+":"+item.operation+":"+(target ?? "new")+":"+field+":"+encoded
            }
            for (field,key) in zip(leafFields,leafKeys) {if let cached=completedLeaves[key],try !engine.canReuseReceipt(cached.id,fields:field=="operation" ? [] : [field]) {throw AskChangeError.conflict}}
            let cached=leafKeys.compactMap {completedLeaves[$0]}
            var activeKeys=leafKeys
            if !cached.isEmpty {
                var seen=Set<UUID>();actions += cached.filter {seen.insert($0.id).inserted}
                if cached.count==leafKeys.count {continue}
                guard ["update","append"].contains(item.operation) else {throw AskChangeError.conflict}
                let missing=Set(zip(leafFields,leafKeys).filter {completedLeaves[$0.1]==nil}.map(\.0))
                item.changes.removeAll {!missing.contains($0.field)}
                activeKeys=leafKeys.filter {completedLeaves[$0]==nil}
            }
            var bound=AskChangeGrant(question:request.text,entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(item.targetIDs),allowsCreation:p.operation=="create",cityIDs:Set(cityID.map {[$0]} ?? []),sectionIDs:sectionIDs,mapMatchIDs:Set(item.mapMatchID.map {[$0]} ?? []),boundProposal:item)
            bound.allowsReplacement=conversationalReplacement
            if p.operation=="undo" {
                guard let target,let action=frozenUndoActions[target] else {throw AskChangeError.missing}
                let undo=AskChangeProposal(entity:p.entity,operation:"undo",targetIDs:action.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:request.text)
                var grant=bound;grant.boundProposal=undo
                actions.append(try engine.undo(action.id,authorization:grant))
            }else {
                let ready=try engine.prepare(item,question:request.text,authorization:bound,findings:findings,turnID:request.performanceID,chatID:request.conversationID)
                actions.append(try engine.apply(ready.id,authorization:bound,maps:maps))
            }
            if let applied=actions.last {for key in activeKeys {completedLeaves[key]=applied}}
            }catch {
                if actions.isEmpty {throw error}
                failedTarget=target
                failure=error is CancellationError ? "Stopped. Earlier changes were saved." : error.localizedDescription
                break
            }
        }
        if p.entity=="city",p.operation=="create",let name=p.changes.first(where:{$0.field=="name"})?.value {
            let applied=actions.filter {$0.state == .applied}.flatMap(\.targetIDs)
            if applied.count==1 {createdCities[name]=applied[0]}
        }
        let review=actions.contains {$0.state == .needsConfirmation}
        let text=failure ?? (!actions.isEmpty && actions.allSatisfy({$0.state == .applied && !$0.undoable}) ? "Already up to date. No changes were needed." : review ? "Review this change before applying it." : actions.allSatisfy({$0.state == .undone}) ? "Undone." : "Saved.")
        if mutationOrder.isEmpty {
            mutationOrder=intent.selectionIDs.isEmpty ? prepared.flatMap {$0.1} : intent.selectionIDs
            for id in prepared.flatMap({$0.1}) {mutationStates[id]="pending"}
        }
        for id in actions.flatMap(\.targetIDs) where !mutationOrder.contains(id) {mutationOrder.append(id)}
        for action in actions {for id in action.targetIDs {mutationStates[id]=action.state == .needsConfirmation ? "needs_confirmation" : action.state.rawValue}}
        if let failedTarget {mutationStates[failedTarget]="failed"}
        selection=mutationOrder
        // Only a bounded execution acknowledgement returns to the model. No changed field values,
        // private-derived IDs, counts, before-images or action previews leave the device.
        let createdRecords:[AskAgentRecord] = ["city","neighborhood"].contains(p.entity) && p.operation=="create" ? actions.filter {$0.state == .applied}.flatMap(\.targetIDs).compactMap {id in
            if p.entity=="city" {
                guard let city=try? cities().first(where:{$0.id==id}) else{return nil}
                return .init(id:id,name:city.name,city:city.name,cuisines:[],kind:"city")
            }
            // Only the newly created, user-supplied name and receipt identity return.
            // This does not enumerate existing private neighborhood membership.
            guard let name=p.changes.first(where:{$0.field=="name"})?.value,
                  let object=try? objects("neighborhood").first(where:{($0.value(forKey:"id") as? UUID)?.uuidString==id}),
                  let actual=object.value(forKey:"name") as? String,actual==name else{return nil}
            let city=(object.value(forKey:"feastList") as? FeastList)?.displayName ?? ""
            return .init(id:id,name:name,city:city,cuisines:[],kind:"neighborhood")
        } : []
        let unchanged = !actions.isEmpty && actions.allSatisfy {$0.state == .applied && !$0.undoable}
        let ack=AskAgentResult(status:failure != nil ? (actions.isEmpty ? "unavailable" : "partial") : review ? "needs_confirmation" : unchanged ? "unchanged" : "applied",complete:failure==nil,totalCount:createdRecords.count,records:createdRecords,findings:[],message:review ? "needs_review" : failure != nil ? "unavailable" : "changed",localOnly:false)
        var response=plain(text,actions:actions,statusOnly:failure==nil)
        // A committed mutation replaces read snapshots, not its supporting public
        // evidence. Carry only findings still bound to fresh native identity.
        let appliedTargets=Set(actions.filter {$0.state == .applied}.flatMap(\.targetIDs))
        // A read failure after commit must never hide its durable receipt.
        if let currentRecords=try? adapter.personalPlaces(),
           let tools=try? AskReadTools(request:request.collectionReadVersion(),index:adapter.index()) {
        let retained=findings.compactMap {finding->AskVerifiedFinding? in
            guard finding.externallyReusable==true || !selectionIsPrivate,
                  let record=currentRecords.first(where:{$0.id==finding.recordID}) else{return nil}
            let current=AskFindingIdentity(record)
            if finding.identity==current {return finding}
            // Only the exact researched website that actually committed may
            // advance its website identity; unrelated identity drift stays stale.
            guard p.entity=="place",p.operation=="update",appliedTargets.contains(record.id),finding.field=="website",
                  p.changes.contains(where:{$0.field=="website" && ($0.source=="verified_finding" || $0.findingID==finding.id.uuidString) && ($0.value==nil || $0.value==finding.value)}),
                  record.websiteURL==finding.value,finding.identity.name==current.name,
                  finding.identity.city==current.city,finding.identity.applePlaceID==current.applePlaceID else{return nil}
            return .init(id:finding.id,recordID:finding.recordID,identity:current,field:finding.field,value:finding.value,evidenceURL:finding.evidenceURL,verification:finding.verification,originatingTurn:finding.originatingTurn,externallyReusable:finding.externallyReusable)
        }
        if !retained.isEmpty {
            response.verifiedPublicFindings=retained
            var seen=Set<String>()
            response.candidates=retained.compactMap {seen.insert($0.recordID).inserted ? tools.localCandidate($0.recordID) : nil}
        }
        }
        let execution=AskAgentExecution(output:ack,response:response,orderedIDs:selection,appendPreviousResults:true,selectionIsPrivate:selectionIsPrivate,outcomes:selection.compactMap {id in mutationStates[id].map {.init(id:id,state:$0)}},effectiveTargetIDs:p.targetIDs)
        return execution
    }
    private static func trace(_ root:UUID,_ id:String)->UUID {
        var b=Array(SHA256.hash(data:Data((root.uuidString+":agent-business:"+id).utf8)).prefix(16));b[6]=(b[6]&15)|80;b[8]=(b[8]&63)|128
        return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    private static func merge(_ values:[AskResponse])->AskResponse {
        var candidates:[AskCandidate]=[],paragraphs:[AskAnswerParagraph]=[],actions:[AskFieldActionState]=[]
        for value in values {
            for candidate in value.candidates where !candidates.contains(where:{$0.id==candidate.id}) {candidates.append(candidate)}
            for paragraph in value.paragraphs where !paragraphs.contains(where:{$0.spans==paragraph.spans && $0.citations==paragraph.citations && $0.sourceIDs==paragraph.sourceIDs && $0.representedField==paragraph.representedField}) {paragraphs.append(paragraph)}
            actions += value.fieldActions ?? []
        }
        return .init(summary:"Public business details",candidates:candidates,paragraphs:paragraphs.enumerated().map {i,p in .init(id:"agent-research-\(i)",spans:p.spans,sourceIDs:p.sourceIDs,citations:p.citations,citationsAreResearchPool:p.citationsAreResearchPool,representedField:p.representedField,transientToolStatus:p.transientToolStatus,operationStatus:p.operationStatus)},listedCandidateIDs:[],usesLocalCatalog:true,fieldActions:actions.isEmpty ? nil : actions,verifiedPublicFindings:values.flatMap {$0.verifiedPublicFindings ?? []})
    }
}
