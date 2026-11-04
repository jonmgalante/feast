import Foundation
import CoreData

/// Local evidence and proposed edits; never serialized into provider requests.
struct AskFindingIdentity:Codable,Equatable,Sendable {
    let name:String,city:String
    let website:String?,applePlaceID:String?
    init(_ record:AskPersonalPlace) {name=record.name;city=record.city;website=record.websiteURL;applePlaceID=record.applePlaceID}
    init(name:String,city:String,website:String?,applePlaceID:String?) {self.name=name;self.city=city;self.website=website;self.applePlaceID=applePlaceID}
}
struct AskVerifiedFinding: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let recordID: String
    let identity:AskFindingIdentity
    let field: String
    let value: String
    let evidenceURL: String
    let verification: String
    let originatingTurn: UUID
    var externallyReusable:Bool? = nil
    func validated() throws -> Self {
        guard UUID(uuidString:recordID) != nil,AskBusinessRequest.allowedFields.contains(field),!value.isEmpty,value.count<=500,
              AskWebCitation(title:"Source",url:evidenceURL).safeURL != nil,["official_website","cited_search","saved"].contains(verification) else {throw AskError.invalidEvidence}
        if field=="instagram" {guard InstagramWebsiteParser.profileURL(value)==value else {throw AskError.invalidEvidence}}
        if ["website","menu"].contains(field) {guard InstagramWebsiteClient.websiteURL(value) != nil else {throw AskError.invalidEvidence}}
        return self
    }
}
struct AskFieldActionState: Codable, Equatable, Sendable {
    enum Outcome:String,Codable,Sendable {case ready,saved,alreadySaved,conflict,undone,unavailable,failed}
    let finding: AskVerifiedFinding
    var outcome: Outcome = .ready
    var previousValue: String? = nil
    var expectedValue: String? = nil
    var revision: Date? = nil
}
enum AskFieldActionMode {case save,replace,undo}
@MainActor extension AskSavedCollection {
    /// Read only: a proposed card is never a successful-save receipt.
    func fieldActionStatus(_ action:AskFieldActionState)throws->AskFieldActionState {
        let finding=try action.finding.validated(),reader=try makeSaveContext()
        let visible=try visibleCities(),fetch=SavedPlace.fetchRequest()
        guard let id=UUID(uuidString:finding.recordID) else{throw AskError.invalidEvidence}
        fetch.predicate=NSPredicate(format:"id == %@ AND feastList.id IN %@",id as NSUUID,Array(visible) as NSArray);fetch.fetchLimit=2
        let matches=try reader.fetch(fetch);var result=action
        guard matches.count==1,let place=matches.first,finding.identity == .init(name:place.displayNameSnapshot ?? "",city:place.feastList?.name ?? "",website:place.websiteURL,applePlaceID:place.applePlaceID) else{result.outcome = .unavailable;return result}
        if place.instagramURL.flatMap(InstagramWebsiteParser.profileURL)==finding.value {
            if action.outcome != .saved {result.outcome = .alreadySaved}
            else if place.updatedAt != action.revision {result.outcome = .unavailable}
        }else if action.outcome == .saved {result.outcome = .unavailable}
        else if place.instagramURL?.isEmpty==false {result.outcome = .conflict;result.expectedValue=place.instagramURL}
        else {result.outcome = action.outcome == .undone ? .undone : .ready}
        return result
    }
    /// A single-field compare-and-set in an isolated context; no stale full-record write.
    func apply(_ action:AskFieldActionState,mode:AskFieldActionMode) throws -> AskFieldActionState {
        let finding=try action.finding.validated()
        guard finding.field=="instagram" else {throw AskError.invalidEvidence}
        let visible=try visibleCities(),isolated=try makeSaveContext()
        guard let id=UUID(uuidString:finding.recordID) else {throw AskError.invalidEvidence}
        let fetch=SavedPlace.fetchRequest();fetch.predicate=NSPredicate(format:"id == %@ AND feastList.id IN %@",id as NSUUID,Array(visible) as NSArray);fetch.fetchLimit=2
        let matches=try isolated.fetch(fetch)
        guard matches.count==1,let place=matches.first,!place.isDeleted else {throw AskError.invalidEvidence}
        guard canUpdate(place.objectID),!context.registeredObjects.contains(where:{$0.objectID == place.objectID && $0.hasChanges}) else {throw AskError.invalidEvidence}
        var result=action
        guard finding.identity == .init(name:place.displayNameSnapshot ?? "",city:place.feastList?.name ?? "",website:place.websiteURL,applePlaceID:place.applePlaceID) else {result.outcome = .unavailable;return result}
        let current=place.instagramURL
        if mode == .undo {
            guard action.outcome == .saved,current==finding.value,place.updatedAt==action.revision else {result.outcome = .unavailable;return result}
            place.instagramURL=action.previousValue;result.outcome = .undone
        } else {
            if current.flatMap(InstagramWebsiteParser.profileURL)==finding.value {if result.outcome != .saved {result.outcome = .alreadySaved};return result}
            if mode == .replace {
                guard action.outcome == .conflict,current==action.expectedValue else {result.outcome = .conflict;result.expectedValue=current;return result}
            } else if current?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false {
                result.outcome = .conflict;result.expectedValue=current;return result
            }
            result.previousValue=current;place.instagramURL=finding.value;result.outcome = .saved
        }
        let now=Date();place.updatedAt=now;place.feastList?.updatedAt=now;place.listSection?.updatedAt=now
        let changedIDs=isolated.updatedObjects.map(\.objectID)
        guard !context.registeredObjects.contains(where:{changedIDs.contains($0.objectID) && $0.hasChanges}) else {throw AskError.invalidEvidence}
        do {try saveFieldContext(isolated)} catch {isolated.rollback();throw error}
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave:[NSUpdatedObjectsKey:changedIDs],into:[context])
        result.revision=now
        return result
    }
}
