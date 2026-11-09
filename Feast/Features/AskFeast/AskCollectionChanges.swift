import Foundation
import CoreData
import Darwin
import CryptoKit

struct AskChangeValue:Codable,Equatable,Sendable {let field:String;let value:String?;let values:[String]?;let findingID:String?;var source:String? = nil}
/// Frozen before external tool results; never restored as authority for another turn.
struct AskChangeGrant:Equatable,Sendable {
    let question:String,entity:String
    let operations:Set<String>,fields:Set<String>,targetIDs:Set<String>
    let allowsCreation:Bool
    var cityIDs:Set<String>=[],sectionIDs:Set<String>=[],mapMatchIDs:Set<String>=[]
    var boundProposal:AskChangeProposal? = nil
    var allowsReplacement=false
    func permits(_ p:AskChangeProposal,question current:String)->Bool {
        question==current && (p.cityID.map{cityIDs.contains($0)} ?? true) && (p.sectionID.map{sectionIDs.contains($0)} ?? true) && (p.mapMatchID.map{mapMatchIDs.contains($0)} ?? true) && entity==p.entity && operations.contains(p.operation) && Set(p.changes.map(\.field)).isSubset(of:fields) && (p.operation=="create" ? allowsCreation && p.targetIDs.isEmpty : !p.targetIDs.isEmpty && Set(p.targetIDs).isSubset(of:targetIDs))
    }
}
struct AskUndoDescriptor:Codable,Equatable,Sendable {
    let entity,operation,effect:String
    let fields:[String]
}
struct AskAuthorizationReference:Codable,Equatable,Sendable {
    let kind,id,name,city:String
}
struct AskChangeProposal:Codable,Equatable,Sendable {
    let entity:String,operation:String
    var targetIDs:[String]
    let cityID:String?,sectionID:String?,mapMatchID:String?
    var changes:[AskChangeValue]
    let instructionQuote:String
    var undoContext:[AskUndoDescriptor]?=nil
    var referenceContext:[AskAuthorizationReference]?=nil
    var findingContext:[AskAgentFinding]?=nil
}
struct AskCollectionAction:Codable,Equatable,Sendable,Identifiable {
    enum State:String,Codable,Sendable {case ready,needsConfirmation,applied,undone,conflict,unavailable,failed}
    let id:UUID
    var title:String
    var targetIDs:[String]
    let entity:String,operation:String
    var state:State
    var undoable:Bool
    var detail:String? = nil
    var originatingTurn:UUID? = nil
    var committedChange:Bool? = nil
    var wasChanged:Bool {committedChange ?? (state == .applied && undoable)}
}
struct AskChangeSnapshot:Codable,Equatable,Sendable {
    let entity:String,id:String
    let store:String?
    let strings:[String:String],dates:[String:Date],links:[String:String]
    func logicallyEquals(_ other:Self)->Bool {entity==other.entity && id==other.id && store==other.store && strings==other.strings && dates==other.dates && links==other.links}
}
private struct AskChangeEntry:Codable {
    let id:UUID,proposal:AskChangeProposal
    var action:AskCollectionAction
    var before:[AskChangeSnapshot],after:[AskChangeSnapshot]
    var phase:String
    var undoAfter:[AskChangeSnapshot]? = nil
    var chatID:UUID? = nil
    var question:String? = nil
    var recoveryDismissed:Bool? = nil
    // Optional for backward compatibility. Binds the original proposed operation
    // to its pre-commit journal entry before any write can happen.
    var recoveryOperationID:String? = nil
    var recoveryProposalDigest:String? = nil
}
private struct AskChangeArchive:Codable {var version=1;var entries:[AskChangeEntry]=[]}
struct AskRecoveredActionTurn:Sendable {let id:UUID,question:String,actions:[AskCollectionAction]}
enum AskChangeError:LocalizedError {
    case invalid,missing,conflict,permission,recoveryUnavailable,journal
    var errorDescription:String? {
        switch self {case .invalid:"This change needs clearer details.";case .missing:"A selected item is no longer available.";case .conflict:"This item changed. Review it before applying the change.";case .permission:"You don’t have permission to make this change.";case .recoveryUnavailable:"This change needs the existing app review flow.";case .journal:"The change couldn’t be safely recorded. Nothing was changed."}
    }
}
/// Local-only before/after journal. Never included in AI context or copied into chats.
@MainActor final class AskCollectionChangeEngine {
    let adapter:AskSavedCollection
    let journalURL:URL
    private var archive=AskChangeArchive()
    private var readable=true
    init(adapter:AskSavedCollection,journalURL:URL){
        self.adapter=adapter;self.journalURL=journalURL
        if FileManager.default.fileExists(atPath:journalURL.path) {
            do {let data=try Data(contentsOf:journalURL);guard data.count<=8*1024*1024 else {throw AskChangeError.journal};archive=try JSONDecoder().decode(AskChangeArchive.self,from:data);guard archive.version==1,archive.entries.count<=200,Set(archive.entries.map(\.id)).count==archive.entries.count,archive.entries.allSatisfy(Self.validEntry),Set(archive.entries.compactMap(\.recoveryOperationID)).count==archive.entries.compactMap(\.recoveryOperationID).count else {throw AskChangeError.journal}}
            catch {readable=false}
        }
    }
    private static func validEntry(_ entry:AskChangeEntry)->Bool {
        let p=entry.proposal
        if let key=entry.recoveryOperationID {
            guard key.count==64,key.allSatisfy({$0.isHexDigit}),let digest=entry.recoveryProposalDigest,digest.count==64,digest.allSatisfy({$0.isHexDigit}) else {return false}
        } else if entry.recoveryProposalDigest != nil {return false}
        guard entry.id==entry.action.id,["city","neighborhood","place"].contains(p.entity),["create","update","append","move","delete"].contains(p.operation),["prepared","intent","committed","undo-intent","undone"].contains(entry.phase),p.targetIDs.count<=6,p.targetIDs.allSatisfy({UUID(uuidString:$0) != nil}),entry.action.targetIDs.allSatisfy({UUID(uuidString:$0) != nil}),p.changes.count<=8 else {return false}
        return [entry.before,entry.after,entry.undoAfter ?? []].allSatisfy {images in
            images.count<=1000 && Set(images.map {$0.entity+":"+$0.id}).count==images.count && images.allSatisfy {image in
                ["FeastList","ListSection","SavedPlace"].contains(image.entity) && UUID(uuidString:image.id) != nil && image.links.values.allSatisfy({UUID(uuidString:$0) != nil})
            }
        }
    }
    private func persist() throws {
        guard readable,archive.entries.count<=200 else {throw AskChangeError.journal}
        let data=try JSONEncoder().encode(archive);guard data.count<=8*1024*1024 else {throw AskChangeError.journal}
        try FileManager.default.createDirectory(at:journalURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:journalURL,options:.atomic)
        let handle=try FileHandle(forWritingTo:journalURL)
        do {try handle.synchronize();try handle.close()} catch {try? handle.close();throw error}
        let directory=open(journalURL.deletingLastPathComponent().path,O_RDONLY)
        guard directory>=0 else {throw AskChangeError.journal}
        defer {close(directory)}
        guard fsync(directory)==0 else {throw AskChangeError.journal}
    }
    private func entity(_ kind:String)throws->String {
        switch kind {case "city":return "FeastList";case "neighborhood":return "ListSection";case "place":return "SavedPlace";default:throw AskChangeError.invalid}
    }
    private func fetch(_ kind:String,_ ids:[String],_ context:NSManagedObjectContext)throws->[NSManagedObject] {
        guard ids.count<=6,Set(ids).count==ids.count,ids.allSatisfy({UUID(uuidString:$0) != nil}) else {throw AskChangeError.invalid}
        let request=NSFetchRequest<NSManagedObject>(entityName:try entity(kind));request.predicate=NSPredicate(format:"id IN %@",ids.map {UUID(uuidString:$0)!});request.fetchLimit=ids.count+1
        let values=try context.fetch(request),visible=try adapter.visibleCities()
        guard values.count==ids.count else {throw AskChangeError.missing}
        for object in values {
            let cityID=(kind=="city" ? object.value(forKey:"id") : (object.value(forKey:"feastList") as? NSManagedObject)?.value(forKey:"id")) as? UUID
            guard let cityID,visible.contains(cityID) else {throw AskChangeError.permission}
        }
        return try ids.map {id in guard let value=values.first(where:{($0.value(forKey:"id") as? UUID)?.uuidString==UUID(uuidString:id)?.uuidString}) else {throw AskChangeError.missing};return value}
    }
    private func rejectNestedDeletion(_ object:NSManagedObject)throws {
        if let section=object as? ListSection,!section.sortedChildren.isEmpty {throw AskChangeError.recoveryUnavailable}
        if let city=object as? FeastList,city.sortedSections.contains(where:{$0.parent != nil || !$0.sortedChildren.isEmpty}) {throw AskChangeError.recoveryUnavailable}
    }
    private func snapshots(_ objects:[NSManagedObject])throws->[AskChangeSnapshot] {
        // Match the existing journal reload contract before preparing/applying a
        // cascade. A large or colliding snapshot could not provide reliable Undo.
        guard objects.count<=1000 else {throw AskChangeError.recoveryUnavailable}
        let images:[AskChangeSnapshot]=try objects.map {object in
            guard let name=object.entity.name,["FeastList","ListSection","SavedPlace"].contains(name),let id=object.value(forKey:"id") as? UUID else {throw AskChangeError.invalid}
            var strings:[String:String]=[:],dates:[String:Date]=[:],links:[String:String]=[:]
            for (key,attribute) in object.entity.attributesByName where key != "id" {
                guard let value=object.value(forKey:key) else {continue}
                switch attribute.attributeType {case .stringAttributeType:strings[key]=value as? String;case .dateAttributeType:dates[key]=value as? Date;default:throw AskChangeError.recoveryUnavailable}
            }
            for key in ["feastList","listSection","parent"] where object.entity.relationshipsByName[key] != nil {
                if let linked=object.value(forKey:key) as? NSManagedObject,let uuid=linked.value(forKey:"id") as? UUID {links[key]=uuid.uuidString}
            }
            return .init(entity:name,id:id.uuidString,store:object.objectID.persistentStore?.identifier,strings:strings,dates:dates,links:links)
        }.sorted {$0.entity==$1.entity ? $0.id<$1.id : $0.entity<$1.entity}
        guard Set(images.map {$0.entity+":"+$0.id}).count==images.count else {throw AskChangeError.recoveryUnavailable}
        return images
    }
    private func affected(_ targets:[NSManagedObject],deleting:Bool)->[NSManagedObject] {
        var values=targets
        if deleting {
            for target in targets {
                if let city=target as? FeastList {values += city.sortedSections;values += city.sortedSavedPlaces}
                if let section=target as? ListSection {values += section.sortedSavedPlaces}
            }
        }
        var seen=Set<NSManagedObjectID>();return values.filter {seen.insert($0.objectID).inserted}
    }
    func prepare(_ proposal:AskChangeProposal,question:String,authorization:AskChangeGrant,findings:[AskVerifiedFinding],turnID:UUID?=nil,chatID:UUID?=nil,recoveryOperationID:String?=nil)throws->AskCollectionAction {
        guard authorization.permits(proposal,question:question) else {throw AskChangeError.permission}
        guard readable,!proposal.instructionQuote.isEmpty,question.contains(proposal.instructionQuote),["create","update","append","move","delete"].contains(proposal.operation),proposal.changes.count<=8,Set(proposal.changes.map(\.field)).count==proposal.changes.count else {throw AskChangeError.invalid}
        guard proposal.entity=="place" || ["create","update","delete"].contains(proposal.operation) else {throw AskChangeError.invalid}
        let recoveryDigest:String?
        if let key=recoveryOperationID {
            guard key.count==64,key.allSatisfy({$0.isHexDigit}) else {throw AskChangeError.journal}
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            recoveryDigest=SHA256.hash(data:try encoder.encode(proposal)).map {String(format:"%02x",$0)}.joined()
            if let index=archive.entries.firstIndex(where:{$0.recoveryOperationID==key}) {
                guard archive.entries[index].recoveryProposalDigest==recoveryDigest,archive.entries[index].question==question,archive.entries[index].action.originatingTurn==turnID,archive.entries[index].chatID==chatID else {throw AskChangeError.conflict}
                // Reuse the durable intent/receipt, including a creation's original
                // ID. Never generate a second action or append the same note twice.
                let existing=try reconciled(index)
                guard existing.action.state != .conflict else {throw AskChangeError.conflict}
                return existing.action
            }
        } else {recoveryDigest=nil}
        let context=try adapter.makeSaveContext(),targets=try fetch(proposal.entity,proposal.targetIDs,context)
        guard proposal.operation=="create" ? targets.isEmpty : !targets.isEmpty else {throw AskChangeError.invalid}
        for object in targets {
            guard adapter.canMutate(proposal.entity,object.objectID,proposal.operation) else {throw AskChangeError.permission}
            if proposal.operation=="delete" {try rejectNestedDeletion(object)}
            if proposal.operation=="delete",let store=object.objectID.persistentStore?.identifier,!adapter.canRecoverStore(store) {throw AskChangeError.recoveryUnavailable}
        }
        if proposal.operation=="create",!adapter.canMutate(proposal.entity,nil,"create") {throw AskChangeError.permission}
        var normalized=proposal
        if proposal.changes.contains(where:{$0.field=="instagram"&&$0.value==nil&&$0.findingID != nil}) {
            guard proposal.targetIDs.count==1,let id=proposal.targetIDs.first,let matching=findings.last(where:{$0.recordID==id&&$0.field=="instagram"}) else {throw AskChangeError.invalid}
            _ = try matching.validated()
            if let requested=proposal.changes.first(where:{$0.field=="instagram"})?.findingID,requested != matching.id.uuidString {throw AskChangeError.invalid}
            guard let current=try adapter.personalPlaces().first(where:{$0.id==id}),AskFindingIdentity(current)==matching.identity else {throw AskChangeError.conflict}
            normalized.changes=proposal.changes.map {$0.field=="instagram" ? .init(field:$0.field,value:matching.value,values:nil,findingID:matching.id.uuidString) : $0}
        }
        for change in normalized.changes where change.field=="instagram" {
            guard let value=change.value,let profile=InstagramWebsiteParser.profileURL(value),let handle=URL(string:profile)?.lastPathComponent else {continue}
            let escaped=NSRegularExpression.escapedPattern(for:handle)
            let handlePattern="(?i)(?<![A-Za-z0-9_@.])@"+escaped+"(?![A-Za-z0-9_.])"
            let handleMatch=question.range(of:handlePattern,options:.regularExpression) != nil
            let tokens=question.split(whereSeparator:{$0.isWhitespace}).map {String($0).trimmingCharacters(in:CharacterSet(charactersIn:"<>\"'(),;"))}
            let explicitlyProvided=handleMatch || tokens.contains(where:{InstagramWebsiteParser.profileURL($0)==profile})
            if !explicitlyProvided {
                guard normalized.targetIDs.count==1,let targetID=normalized.targetIDs.first,let record=try adapter.personalPlaces().first(where:{$0.id==targetID}),findings.contains(where:{$0.recordID==targetID&&$0.value==profile&&$0.identity==AskFindingIdentity(record)}) else {throw AskChangeError.invalid}
            }
        }
        let before=try snapshots(affected(targets,deleting:proposal.operation=="delete")),id=UUID()
        let title=proposal.operation.capitalized+" "+String(targets.count==0 ? 1 : targets.count)+" "+proposal.entity+(targets.count>1 ? "s" : "")
        let replacing=normalized.changes.contains {change in
            guard ["instagram","website"].contains(change.field),let next=change.value else {return false}
            let key=change.field=="instagram" ? "instagramURL" : "websiteURL"
            return targets.contains {object in guard let old=object.value(forKey:key) as? String,!old.isEmpty else {return false};return old != next}
        }
        let needsReview=proposal.operation=="delete" || replacing && !authorization.allowsReplacement
        var action=AskCollectionAction(id:id,title:title,targetIDs:proposal.targetIDs,entity:proposal.entity,operation:proposal.operation,state:needsReview ? .needsConfirmation : .ready,undoable:false)
        let names=targets.compactMap {($0 as? SavedPlace)?.displayNameSnapshot ?? ($0.value(forKey:"name") as? String)}.joined(separator:", ")
        let values=normalized.changes.map {change in (change.field=="type" ? "Category" : change.field.capitalized)+": "+(change.value ?? change.values?.joined(separator:", ") ?? "Clear")}.joined(separator:"\n")
        action.originatingTurn=turnID
        if !names.isEmpty {action.title=proposal.operation.capitalized+" "+names}
        action.detail=[names,values,proposal.operation=="delete" ? "Includes \(before.filter {$0.entity=="SavedPlace"}.count) saved places. You can undo this change." : ""].filter {!$0.isEmpty}.joined(separator:"\n")
        archive.entries.append(.init(id:id,proposal:normalized,action:action,before:before,after:[],phase:"prepared",chatID:chatID,question:question,recoveryOperationID:recoveryOperationID,recoveryProposalDigest:recoveryDigest));try persist();return action
    }
    private func same(_ a:[AskChangeSnapshot],_ b:[AskChangeSnapshot])->Bool {a.count==b.count && zip(a,b).allSatisfy {$0.logicallyEquals($1)}}
    func apply(_ id:UUID,authorization:AskChangeGrant,confirmed:Bool=false,maps:[String:ApplePlaceMatch]=[:])throws->AskCollectionAction {
        guard readable,let index=archive.entries.firstIndex(where:{$0.id==id}) else {throw AskChangeError.missing}
        var entry=try reconciled(index)
        guard authorization.boundProposal==entry.proposal,authorization.permits(entry.proposal,question:authorization.question) else {throw AskChangeError.permission}
        if entry.phase=="committed" {
            let context=try adapter.makeSaveContext()
            guard same(try current(entry,context),entry.after) else {throw AskChangeError.conflict}
            return entry.action
        }
        guard entry.phase=="prepared",entry.action.state != .needsConfirmation || confirmed else {return entry.action}
        let context=try adapter.makeSaveContext(),targets=try fetch(entry.proposal.entity,entry.proposal.targetIDs,context)
        guard same(try snapshots(affected(targets,deleting:entry.proposal.operation=="delete")),entry.before) else {throw AskChangeError.conflict}
        for object in targets {
            guard adapter.canMutate(entry.proposal.entity,object.objectID,entry.proposal.operation) else {throw AskChangeError.permission}
            if entry.proposal.operation=="delete" {try rejectNestedDeletion(object);guard let store=object.objectID.persistentStore?.identifier,adapter.canRecoverStore(store) else {throw AskChangeError.recoveryUnavailable}}
        }
        if entry.proposal.operation=="create",!adapter.canMutate(entry.proposal.entity,nil,"create") {throw AskChangeError.permission}
        let affectedBefore=affected(targets,deleting:entry.proposal.operation=="delete")
        let repository=adapter.repository(context)
        var intentReady=false
        var updated:[NSManagedObject]=[],inserted:[NSManagedObject]=[],deleted:[NSManagedObject]=[]
        var afterObjects:[NSManagedObject]=[]
        do {
            try repository.transaction {repo in
                let returned=try execute(entry.proposal,targets:targets,context:context,repository:repo,maps:maps)
                try context.obtainPermanentIDs(for:Array(context.insertedObjects))
                var seen=Set<NSManagedObjectID>();afterObjects=(affectedBefore+returned).filter {!$0.isDeleted && seen.insert($0.objectID).inserted}
                let changed=context.updatedObjects.union(context.deletedObjects)
                let changedIDs=Set(changed.map(\.objectID))
                guard !adapter.context.registeredObjects.contains(where:{changedIDs.contains($0.objectID) && $0.hasChanges}) else {throw AskChangeError.conflict}
                updated=Array(context.updatedObjects);inserted=Array(context.insertedObjects);deleted=Array(context.deletedObjects)
                entry.after=try snapshots(afterObjects.filter {!$0.isDeleted})
                if entry.proposal.operation=="create" {entry.action.targetIDs=entry.after.map(\.id)}
                entry.phase="intent";archive.entries[index]=entry;try persist();intentReady=true
            }
        } catch {if !intentReady {archive.entries[index].phase="prepared";try? persist()};throw error}
        entry.after=try snapshots(afterObjects.filter {!$0.isDeleted});entry.phase="committed";entry.action.state = .applied;entry.action.undoable = !same(entry.before,entry.after)
        entry.action.committedChange=entry.action.undoable
        if entry.proposal.operation=="create" {entry.action.targetIDs=afterObjects.compactMap {($0.value(forKey:"id") as? UUID)?.uuidString}}
        archive.entries[index]=entry;try? persist()
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave:[NSUpdatedObjectsKey:updated.map(\.objectID),NSInsertedObjectsKey:inserted.map(\.objectID),NSDeletedObjectsKey:deleted.map(\.objectID)],into:[adapter.context])
        return entry.action
    }
    private func current(_ entry:AskChangeEntry,_ context:NSManagedObjectContext)throws->[AskChangeSnapshot] {
        let keys=entry.before+entry.after+(entry.undoAfter ?? [])
        var objects:[NSManagedObject]=[],seen=Set<NSManagedObjectID>()
        for image in keys {
            let fetch=NSFetchRequest<NSManagedObject>(entityName:image.entity);guard ["FeastList","ListSection","SavedPlace"].contains(image.entity),let id=UUID(uuidString:image.id) else {throw AskChangeError.journal}
            fetch.predicate=NSPredicate(format:"id == %@",id as NSUUID);fetch.fetchLimit=2
            let values=try context.fetch(fetch);guard values.count<=1 else {throw AskChangeError.conflict}
            for object in values where seen.insert(object.objectID).inserted {objects.append(object)}
        }
        if entry.proposal.operation=="create" {objects=affected(objects,deleting:true)}
        return try snapshots(objects)
    }
    private func reconciled(_ index:Int)throws->AskChangeEntry {
        var entry=archive.entries[index]
        if entry.action.committedChange==nil,["committed","undone"].contains(entry.phase) {entry.action.committedChange = !same(entry.before,entry.after)}
        guard ["intent","undo-intent"].contains(entry.phase) else {return entry}
        let context=try adapter.makeSaveContext(),now=try current(entry,context)
        if entry.phase=="intent",same(now,entry.after) {entry.phase="committed";entry.action.state = .applied;entry.action.undoable=true;if entry.proposal.operation=="create" {entry.action.targetIDs=entry.after.map(\.id)}}
        else if entry.phase=="intent",same(now,entry.before) {entry.phase="prepared";entry.action.state = entry.proposal.operation=="delete" ? .needsConfirmation : .ready}
        else if entry.phase=="undo-intent",same(now,entry.undoAfter ?? []) {entry.phase="undone";entry.action.state = .undone;entry.action.undoable=false}
        else if entry.phase=="undo-intent",same(now,entry.after) {entry.phase="committed";entry.action.state = .applied;entry.action.undoable=true}
        else {entry.action.state = .conflict;entry.action.undoable=false}
        if entry.action.committedChange==nil,["committed","undone"].contains(entry.phase) {entry.action.committedChange = !same(entry.before,entry.after)}
        archive.entries[index]=entry;try? persist();return entry
    }
    /// Retained context may mention a record this same turn just deleted. Such
    /// IDs can complete that turn's answer, but never authorize any new write.
    /// A revoked/missing record without a verified committed deletion is absent.
    func recoveryDeletedRecordIDs(forTurn turn:UUID,includingActionIDs:Set<UUID>=[])throws->Set<String> {
        guard readable else {throw AskChangeError.journal}
        var ids=Set<String>()
        // Extra IDs must be this loop's LOCAL committed executor receipts, not
        // model arguments. Confirmation and Undo may act on an earlier preview.
        for index in archive.entries.indices where archive.entries[index].action.originatingTurn==turn || includingActionIDs.contains(archive.entries[index].id) {
            let entry=try reconciled(index)
            let removed:[AskChangeSnapshot],expected:[AskChangeSnapshot]
            if entry.proposal.operation=="delete",entry.phase=="committed",entry.action.state == .applied {removed=entry.before;expected=entry.after}
            else if entry.proposal.operation=="create",entry.phase=="undone",entry.action.state == .undone,let undoAfter=entry.undoAfter {removed=entry.after;expected=undoAfter}
            else {continue}
            let context=try adapter.makeSaveContext()
            guard same(try current(entry,context),expected) else{continue}
            let surviving=Set(expected.map(\.id))
            ids.formUnion(removed.map(\.id).filter {!surviving.contains($0)})
        }
        return ids
    }
    func receipts(forTurn turn:UUID)throws->[AskCollectionAction] {
        try archive.entries.indices.filter {archive.entries[$0].action.originatingTurn==turn && archive.entries[$0].phase != "prepared"}.compactMap {index in let entry=try reconciled(index);return entry.phase=="prepared" ? nil : entry.action}
    }
    func dismissRecovery(in chat:UUID)throws {
        for index in archive.entries.indices where archive.entries[index].chatID==chat {archive.entries[index].recoveryDismissed=true}
        try persist()
    }
    func recoverableTurns(in chat:UUID)throws->[AskRecoveredActionTurn] {
        var ordered:[UUID]=[],questions:[UUID:String]=[:],actions:[UUID:[AskCollectionAction]]=[:]
        for index in archive.entries.indices where archive.entries[index].chatID==chat && archive.entries[index].phase != "prepared" && archive.entries[index].recoveryDismissed != true {
            let entry=try reconciled(index)
            guard entry.phase != "prepared",let turn=entry.action.originatingTurn else {continue}
            if actions[turn]==nil {ordered.append(turn);questions[turn]=entry.question ?? entry.proposal.instructionQuote}
            actions[turn,default:[]].append(entry.action)
        }
        return ordered.map {.init(id:$0,question:questions[$0] ?? "Saved change",actions:actions[$0] ?? [])}
    }
    func canReuseReceipt(_ id:UUID,fields:Set<String>=[])throws->Bool {
        guard let index=archive.entries.firstIndex(where:{$0.id==id}) else{return false}
        let entry=try reconciled(index)
        let now=try current(entry,adapter.makeSaveContext())
        if entry.phase=="undone",entry.action.state == .undone {return same(now,entry.undoAfter ?? [])}
        guard [.applied,.needsConfirmation,.ready].contains(entry.action.state) else{return false}
        let expected=entry.phase=="prepared" ? entry.before : entry.after
        guard ["prepared","committed"].contains(entry.phase) else{return false}
        if ["update","append"].contains(entry.proposal.operation),!fields.isEmpty {
            guard now.count==expected.count else{return false}
            let keys=fields.map {field->String in
                switch field {case "name":return entry.proposal.entity=="place" ? "displayNameSnapshot" : "name";case "cuisines":return "cuisinesStorage";case "tags":return "tagsStorage";case "website":return "websiteURL";case "instagram":return "instagramURL";case "type":return "placeType";default:return field}
            }
            return zip(now,expected).allSatisfy {a,b in a.id==b.id && a.entity==b.entity && a.store==b.store && keys.allSatisfy {a.strings[$0]==b.strings[$0]}}
        }
        return same(now,expected)
    }
    func actionStatus(_ id:UUID)throws->AskCollectionAction {
        guard let index=archive.entries.firstIndex(where:{$0.id==id}) else {throw AskChangeError.missing}
        return try reconciled(index).action
    }
    /// Only an explicit app action invokes this entry point. It authorizes the exact
    /// journaled preview, never a new model-supplied replacement or restored replay.
    func performExplicitAction(_ id:UUID,undo shouldUndo:Bool)throws->AskCollectionAction {
        guard let index=archive.entries.firstIndex(where:{$0.id==id}) else {throw AskChangeError.missing}
        let entry=try reconciled(index),p=entry.proposal
        if shouldUndo {
            let proposal=AskChangeProposal(entity:p.entity,operation:"undo",targetIDs:entry.action.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:"Undo this change")
            let grant=AskChangeGrant(question:"Undo this change",entity:p.entity,operations:["undo"],fields:[],targetIDs:Set(proposal.targetIDs),allowsCreation:false,boundProposal:proposal)
            return try undo(id,authorization:grant)
        }
        let grant=AskChangeGrant(question:"Apply this exact reviewed change",entity:p.entity,operations:[p.operation],fields:Set(p.changes.map(\.field)),targetIDs:Set(p.targetIDs),allowsCreation:p.operation=="create",cityIDs:Set(p.cityID.map {[$0]} ?? []),sectionIDs:Set(p.sectionID.map {[$0]} ?? []),mapMatchIDs:Set(p.mapMatchID.map {[$0]} ?? []),boundProposal:p,allowsReplacement:true)
        return try apply(id,authorization:grant,confirmed:true)
    }
    func undoDescriptor(for action:AskCollectionAction)throws->AskUndoDescriptor {
        guard let entry=archive.entries.first(where:{$0.id==action.id}) else{throw AskChangeError.missing}
        let p=entry.proposal
        let clearing=p.operation=="update" && !p.changes.isEmpty && p.changes.allSatisfy {$0.source=="user" && $0.value==nil && ($0.values==nil || $0.values!.isEmpty) && $0.findingID==nil}
        return .init(entity:p.entity,operation:p.operation,effect:clearing ? "clear" : p.operation,fields:p.changes.map(\.field).sorted())
    }
    func latestAction(for target:String)throws->AskCollectionAction? {
        for index in archive.entries.indices.reversed() {
            let entry=try reconciled(index)
            if entry.action.targetIDs.contains(target),entry.phase=="committed",entry.action.undoable {return entry.action}
        }
        return nil
    }
    func undo(_ id:UUID,authorization:AskChangeGrant)throws->AskCollectionAction {
        guard readable,let index=archive.entries.firstIndex(where:{$0.id==id}) else {throw AskChangeError.missing}
        var entry=try reconciled(index)
        let undo=AskChangeProposal(entity:entry.action.entity,operation:"undo",targetIDs:entry.action.targetIDs,cityID:nil,sectionID:nil,mapMatchID:nil,changes:[],instructionQuote:authorization.question)
        guard authorization.boundProposal==undo,authorization.permits(undo,question:authorization.question) else {throw AskChangeError.permission}
        if entry.phase=="undone" {return entry.action}
        guard entry.phase=="committed",entry.action.undoable else {throw AskChangeError.conflict}
        let context=try adapter.makeSaveContext()
        guard same(try current(entry,context),entry.after) else {throw AskChangeError.conflict}
        var objects:[String:NSManagedObject]=[:],updated:[NSManagedObject]=[],inserted:[NSManagedObject]=[],deleted:[NSManagedObject]=[],undoSurvivors:[NSManagedObject]=[]
        let repository=adapter.repository(context)
        try repository.transaction {_ in
            for image in entry.after {
                let fetch=NSFetchRequest<NSManagedObject>(entityName:image.entity);fetch.predicate=NSPredicate(format:"id == %@",UUID(uuidString:image.id)! as NSUUID)
                guard let object=try context.fetch(fetch).first else {throw AskChangeError.conflict}
                let kind=image.entity=="FeastList" ? "city" : image.entity=="ListSection" ? "neighborhood" : "place"
                guard adapter.canMutate(kind,object.objectID,"update") else {throw AskChangeError.permission}
                if !entry.before.contains(where:{$0.id==image.id&&$0.entity==image.entity}) {
                    guard adapter.canMutate(kind,object.objectID,"delete"),let store=object.objectID.persistentStore?.identifier,adapter.canRecoverStore(store) else {throw AskChangeError.permission}
                    if let city=object as? FeastList {try repository.delete(city)}
                    else if let section=object as? ListSection {try repository.delete(section)}
                    else if let place=object as? SavedPlace {try repository.delete(place)}
                    else {throw AskChangeError.invalid}
                }
                else {objects[image.entity+":"+image.id]=object}
            }
            for image in entry.before {
                let key=image.entity+":"+image.id
                if objects[key]==nil {
                    guard let storeID=image.store,adapter.canRecoverStore(storeID),let store=context.persistentStoreCoordinator?.persistentStores.first(where:{$0.identifier==storeID}) else {throw AskChangeError.recoveryUnavailable}
                    let kind=image.entity=="FeastList" ? "city" : image.entity=="ListSection" ? "neighborhood" : "place"
                    guard adapter.canMutate(kind,nil,"create") else {throw AskChangeError.permission}
                    if image.entity=="FeastList",let name=image.strings["name"] {
                        let query=FeastList.fetchRequest();guard !(try context.fetch(query)).contains(where:{AskCityIdentity.key($0.displayName)==AskCityIdentity.key(name)}) else {throw AskChangeError.conflict}
                    }
                    if image.entity=="SavedPlace",let apple=image.strings["applePlaceID"],let city=image.links["feastList"],let cityID=UUID(uuidString:city) {
                        let query=SavedPlace.fetchRequest();query.predicate=NSPredicate(format:"applePlaceID == %@ AND feastList.id == %@",apple,cityID as NSUUID);guard try context.fetch(query).isEmpty else {throw AskChangeError.conflict}
                    }
                    if let city=image.links["feastList"],let id=UUID(uuidString:city) {
                        let query=FeastList.fetchRequest();query.predicate=NSPredicate(format:"id == %@",id as NSUUID)
                        if let parent=try context.fetch(query).first {guard adapter.canMutate("city",parent.objectID,"update") else {throw AskChangeError.permission}}
                    }
                    let object=NSEntityDescription.insertNewObject(forEntityName:image.entity,into:context);context.assign(object,to:store);objects[key]=object
                }
                let object=objects[key]!
                guard let uuid=UUID(uuidString:image.id),Set(image.strings.keys).isSubset(of:Set(object.entity.attributesByName.filter {$0.value.attributeType == .stringAttributeType}.keys)),Set(image.dates.keys).isSubset(of:Set(object.entity.attributesByName.filter {$0.value.attributeType == .dateAttributeType}.keys)) else {throw AskChangeError.journal}
                object.setValue(uuid,forKey:"id")
                for (name,attribute) in object.entity.attributesByName where name != "id" {
                    switch attribute.attributeType {case .stringAttributeType:object.setValue(image.strings[name],forKey:name);case .dateAttributeType:object.setValue(name=="updatedAt" ? Date() : image.dates[name],forKey:name);default:throw AskChangeError.journal}
                }
            }
            for image in entry.before {
                let object=objects[image.entity+":"+image.id]!
                guard Set(image.links.keys).isSubset(of:["feastList","listSection","parent"]) else {throw AskChangeError.journal}
                for name in ["feastList","listSection","parent"] where object.entity.relationshipsByName[name] != nil {
                    guard let linkedID=image.links[name] else {object.setValue(nil,forKey:name);continue}
                    guard let destination=object.entity.relationshipsByName[name]?.destinationEntity?.name,let uuid=UUID(uuidString:linkedID) else {throw AskChangeError.journal}
                    let linked:NSManagedObject
                    if let known=objects[destination+":"+linkedID] {linked=known}
                    else {let fetch=NSFetchRequest<NSManagedObject>(entityName:destination);fetch.predicate=NSPredicate(format:"id == %@",uuid as NSUUID);fetch.fetchLimit=2;let values=try context.fetch(fetch);guard values.count==1 else {throw AskChangeError.conflict};linked=values[0]}
                    object.setValue(linked,forKey:name)
                }
            }
            let ids=Set(context.updatedObjects.union(context.deletedObjects).map(\.objectID))
            guard !adapter.context.registeredObjects.contains(where:{ids.contains($0.objectID)&&$0.hasChanges}) else {throw AskChangeError.conflict}
            updated=Array(context.updatedObjects);inserted=Array(context.insertedObjects);deleted=Array(context.deletedObjects);undoSurvivors=Array(objects.values).filter {!$0.isDeleted}
            try context.obtainPermanentIDs(for:Array(context.insertedObjects))
            entry.undoAfter=try snapshots(undoSurvivors);entry.phase="undo-intent";archive.entries[index]=entry;try persist()
        }
        entry.undoAfter=try snapshots(undoSurvivors);entry.phase="undone";entry.action.state = .undone;entry.action.undoable=false;archive.entries[index]=entry;try? persist()
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave:[NSUpdatedObjectsKey:updated.map(\.objectID),NSInsertedObjectsKey:inserted.map(\.objectID),NSDeletedObjectsKey:deleted.map(\.objectID)],into:[adapter.context])
        return entry.action
    }
    private func execute(_ p:AskChangeProposal,targets:[NSManagedObject],context:NSManagedObjectContext,repository:FeastRepository,maps:[String:ApplePlaceMatch])throws->[NSManagedObject] {
        func city() throws -> FeastList {guard let id=p.cityID,let city=try fetch("city",[id],context).first as? FeastList else {throw AskChangeError.missing};guard adapter.canMutate("city",city.objectID,"update") else {throw AskChangeError.permission};return city}
        func section() throws -> ListSection? {guard let id=p.sectionID else {return nil};return try fetch("neighborhood",[id],context).first as? ListSection}
        let name=p.changes.first(where:{$0.field=="name"})?.value?.trimmingCharacters(in:.whitespacesAndNewlines)
        if p.operation=="create" {
            if p.entity != "place",p.changes.contains(where:{$0.field != "name"}) {throw AskChangeError.invalid}
            if p.entity=="city" {guard let name,!name.isEmpty,name.count<=200 else {throw AskChangeError.invalid};guard !(try repository.fetchFeastLists()).contains(where:{AskCityIdentity.key($0.displayName)==AskCityIdentity.key(name)}) else {throw AskChangeError.conflict};return [try repository.createFeastList(named:name)]}
            if p.entity=="neighborhood" {guard let name,!name.isEmpty,name.count<=200 else {throw AskChangeError.invalid};let destination=try city();guard !destination.sortedSections.contains(where:{AskCityIdentity.key($0.displayName)==AskCityIdentity.key(name)}) else {throw AskChangeError.conflict};return [try repository.createListSection(named:name,in:destination)]}
            guard let matchID=p.mapMatchID,let match=maps[matchID],!match.applePlaceID.isEmpty else {throw AskChangeError.invalid}
            let created=try repository.createSavedPlace(from:.init(applePlaceID:match.applePlaceID,displayNameSnapshot:match.displayName,status:.wantToTry,placeType:match.suggestedPlaceType ?? .other,cuisines:[],tags:[],note:nil,websiteURL:match.websiteURL,instagramURL:match.instagramURL,feastList:city(),listSection:section()))
            if !p.changes.isEmpty {
                let update=AskChangeProposal(entity:"place",operation:"update",targetIDs:[created.id!.uuidString],cityID:nil,sectionID:nil,mapMatchID:nil,changes:p.changes,instructionQuote:p.instructionQuote)
                _ = try execute(update,targets:[created],context:context,repository:repository,maps:maps)
            }
            return [created]
        }
        for target in targets {
            if p.operation=="delete" {
                if let city=target as? FeastList {try repository.delete(city)}
                else if let section=target as? ListSection {try repository.delete(section)}
                else if let place=target as? SavedPlace {try repository.delete(place)}
                continue
            }
            if let place=target as? SavedPlace {
                let previous=try snapshots([place])[0]
                if p.operation=="move" {try repository.move(place,to:city(),section:section())}
                for change in p.changes {
                    switch change.field {
                    case "name":guard let value=change.value,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.count<=200 else {throw AskChangeError.invalid};place.displayNameSnapshot=value
                    case "status":guard let value=change.value,let status=PlaceStatus(rawValue:value) else {throw AskChangeError.invalid};place.placeStatus=status
                    case "type":guard let value=change.value,let type=PlaceType(rawValue:value) else {throw AskChangeError.invalid};place.placeTypeValue=type
                    case "cuisines":guard let values=change.values,values.count<=20,values.allSatisfy({$0.count<=100}) else {throw AskChangeError.invalid};place.cuisines=p.operation=="append" ? place.cuisines+values : values
                    case "tags":guard let values=change.values,values.count<=30,values.allSatisfy({$0.count<=200}) else {throw AskChangeError.invalid};place.tags=p.operation=="append" ? place.tags+values : values
                    case "note":guard (change.value?.count ?? 0)<=4000 else {throw AskChangeError.invalid};place.note=p.operation=="append" ? [place.note,change.value].compactMap {$0}.joined(separator:"\n") : change.value
                    case "website":guard change.value==nil || change.value.flatMap(InstagramWebsiteClient.websiteURL) != nil else {throw AskChangeError.invalid};place.websiteURL=change.value
                    case "instagram":guard change.value==nil || change.value.flatMap(InstagramWebsiteParser.profileURL) != nil else {throw AskChangeError.invalid};place.instagramURL=change.value.flatMap(InstagramWebsiteParser.profileURL)
                    default:throw AskChangeError.invalid
                    }
                }
                let current=try snapshots([place])[0]
                if previous.strings != current.strings || previous.links != current.links {place.updatedAt=Date();place.feastList?.updatedAt=Date();place.listSection?.updatedAt=Date()}
                else if place.hasChanges {context.refresh(place,mergeChanges:false)}
            }else if let city=target as? FeastList {guard p.changes.count==1,let name,!name.isEmpty,name.count<=200 else {throw AskChangeError.invalid};guard !(try repository.fetchFeastLists()).contains(where:{$0.id != city.id && AskCityIdentity.key($0.displayName)==AskCityIdentity.key(name)}) else {throw AskChangeError.conflict};try repository.rename(city,to:name)}
            else if let section=target as? ListSection {guard p.changes.count==1,let name,!name.isEmpty,name.count<=200 else {throw AskChangeError.invalid};guard !(section.feastList?.sortedSections ?? []).contains(where:{$0.id != section.id && AskCityIdentity.key($0.displayName)==AskCityIdentity.key(name)}) else {throw AskChangeError.conflict};try repository.rename(section,to:name)}
        }
        return targets.filter {!$0.isDeleted}
    }
}
