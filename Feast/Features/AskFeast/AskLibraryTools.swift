import Foundation

struct AskRecentUserQuestion: Codable, Equatable, Sendable {
    let question:String
    let recordIDs:[String]
}
struct AskSemanticContext: Codable, Equatable, Sendable {
    struct Record:Codable,Equatable,Sendable { let id:String;let name:String;let city:String;let cuisines:[String] }
    let index:[Record]
    let recent:[AskRecentUserQuestion]
    // Omitted by older clients, whose catalogs were necessarily complete.
    var indexComplete:Bool? = nil
    var collectionAccess:String? = nil
    var totalCount:Int? = nil
    static let maximumIndexBytes = 24_000
    static func recentQuestions(_ turns:[AskTurn]) -> [AskRecentUserQuestion] {
        turns.filter {$0.status == .complete && $0.readContextMode == .collection && !$0.request.fromOCR && $0.request.attachment == nil && ($0.response?.collectionActions ?? []).isEmpty && $0.response?.agentTask?.fields.contains(where:{["note","tags","status"].contains($0)}) != true}.suffix(2).map { turn in
            let filter=turn.response?.libraryContext?.filters
            let excluded = turn.response?.libraryContext?.excludesExternalReferences == true || filter?.fieldPresence != nil || filter?.status != nil || filter?.neighborhood != nil || filter?.placeType != nil || (filter?.operation != .lookup && ["status","neighborhood","type","address"].contains {filter?.fields.contains($0) == true}) || ["status","neighborhood","type"].contains(filter?.groupBy ?? "")
            // Never serialize assistant prose, source excerpts, OCR, or private-derived membership.
            let ids=excluded ? [] : Array((turn.response?.libraryContext?.ids ?? []).prefix(6))
            return .init(question:turn.request.text,recordIDs:ids)
        }
    }
    static func make(_ request:AskRequest,catalog:AskLibrarySnapshot,fullCollection:Bool=false) throws -> Self {
        guard request.recentQuestions.count <= 2,request.recentQuestions.allSatisfy({$0.question.utf16.count <= 4000 && $0.recordIDs.count <= 6 && Set($0.recordIDs).count == $0.recordIDs.count}) else {throw AskError.inputLimit}
        let safe = catalog.sanitized()
        let recentBytes=try JSONEncoder().encode(request.recentQuestions).count
        var records:[Record]=[],bytes=512+recentBytes
        // Stable public metadata only: private filters/selections never choose the sample.
        for place in safe.places.sorted(by:{$0.id < $1.id}) {
            if !fullCollection && records.count >= 200 {break}
            let record=Record(id:place.id,name:place.name,city:place.city,cuisines:place.cuisines)
            let size=try JSONEncoder().encode(record).count + 1
            guard bytes+size <= maximumIndexBytes else {continue}
            records.append(record);bytes+=size
        }
        let ids=Set(records.map(\.id))
        // Deleted/revoked references are omitted from model input; the local tool still detects stale scope.
        let recent=request.recentQuestions.map {AskRecentUserQuestion(question:$0.question,recordIDs:$0.recordIDs.filter {ids.contains($0)})}
        return .init(index:records,recent:recent,indexComplete:safe.complete && safe.cityCatalogComplete && records.count == safe.places.count ? nil : false,collectionAccess:fullCollection ? "permitted_details_v1" : nil,totalCount:fullCollection ? safe.totalCount : nil)
    }
}

/// Stored presence is not URL validity or public availability. Only a fresh,
/// permission-checked rich read can evaluate this predicate.
struct AskStoredFieldPresence: Codable, Equatable, Sendable {
    enum Field: String, Codable, Sendable { case instagram, website }
    enum Presence: String, Codable, Sendable { case missing, present }
    let field: Field
    let presence: Presence
    func matches(_ place:AskPersonalPlace)->Bool {
        let raw=field == .instagram ? place.instagramURL : place.websiteURL
        let missing=raw?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true
        return presence == .missing ? missing : !missing
    }
}

/// One model-selected read operation. No SQL, URLs, record IDs, write actions or private catalog input.
struct AskLibraryPlan: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case catalog, list, details, compare, count, group, answer, lookup, updateField, unsupported }
    enum Scope: String, Codable, Sendable { case library, previous }
    let operation: Operation
    var scope: Scope
    var city: String?
    var cuisine: String?
    var status: String?
    var placeType: String?
    var name: String?
    var positions: [Int]
    var fields: [String]
    var neighborhood: String? = nil
    var groupBy: String? = nil
    var names: [String]? = nil
    var offset:Int? = nil
    var limit:Int? = nil
    var searchText:String? = nil
    var tag:String? = nil
    var snapshot:String? = nil
    var fieldPresence:AskStoredFieldPresence? = nil
    func validated() throws -> Self {
        guard [city,cuisine,name,neighborhood,searchText,tag].allSatisfy({ $0 == nil || (!$0!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0!.count <= 200) }),
              status == nil || ["Want to try","Just opened","Been","Love","Regulars","untried"].contains(status!),
              placeType == nil || ["Restaurant","Cafe","Bakery","Bar","Dessert","Market","Other"].contains(placeType!),
              positions.count <= 200, Set(positions).count == positions.count, positions.allSatisfy({ (1...AskCollectionPage.maximumRenderedRecords).contains($0) }),
              fields.count <= (operation == .lookup ? 4 : 11), Set(fields).count == fields.count,
              fields.allSatisfy({ (operation == .lookup ? AskBusinessRequest.allowedFields : ["city","neighborhood","address","cuisine","status","type","name","website","instagram","note","tags"]).contains($0) }),
              (groupBy == nil ? operation != .group : ["city","neighborhood","cuisine","status","type"].contains(groupBy!)),
              names == nil || ((1...200).contains(names!.count) && Set(names!).count == names!.count && names!.allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count <= 200}) && name == nil) else { throw AskError.invalidEvidence }
        guard fieldPresence == nil || [.list,.details,.compare,.count,.group,.answer].contains(operation) else {throw AskError.invalidEvidence}
        if operation == .updateField {guard fields == ["instagram"],status == nil,placeType == nil,neighborhood == nil,cuisine == nil,names == nil,positions.count <= 1 else {throw AskError.invalidEvidence}}
        if operation == .lookup {guard !fields.isEmpty,status == nil,placeType == nil,neighborhood == nil,cuisine == nil,names == nil,positions.count<=1 else {throw AskError.invalidEvidence}}
        guard offset == nil || offset! >= 0,limit == nil || (1...200).contains(limit!),snapshot == nil || (snapshot!.count==64 && snapshot!.allSatisfy(\.isHexDigit)) else {throw AskError.invalidEvidence}
        var normalized = self
        normalized.city = city?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.cuisine = cuisine?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.neighborhood = neighborhood?.trimmingCharacters(in:.whitespacesAndNewlines)
        return normalized
    }
}
protocol AskLibraryIntentPlanning: Sendable {
    /// nil means capability is disabled, never a failed/empty result.
    func libraryPlan(_ question: String) async throws -> AskLibraryPlan?
    /// Context/catalog remain on device unless a separately reviewed transport explicitly permits them.
    func libraryPlan(_ request:AskRequest,catalog:AskLibrarySnapshot) async throws -> AskLibraryPlan?
}
extension AskLibraryIntentPlanning {
    func libraryPlan(_ request:AskRequest,catalog:AskLibrarySnapshot) async throws -> AskLibraryPlan? { try await libraryPlan(request.text) }
}
struct AskLibraryContext: Codable, Equatable, Sendable {
    let ids: [String] // shown order, kept on device; never sent as model context
    let filters: AskLibraryPlan
    var selectionIDs: [String]? = nil // aggregate membership; not a displayed ordinal order
    var excludesExternalReferences:Bool? = nil // on-device privacy taint, never part of the model projection
}
struct AskLibrarySnapshot: Sendable {
    let places: [AskPersonalPlace]
    let totalCount: Int
    var cityNames: [String]? = nil
    // One entry per excluded persisted row; nil city means its scope is unknown.
    // Absent for legacy/injected snapshots whose unread rows cannot be scoped.
    var unavailableCities: [String?]? = nil
    var cityCatalogComplete=true
    var complete: Bool { totalCount == places.count }
    var cities: [String] { Array(Set(cityNames ?? places.map(\.city))).sorted() }
    static let availableFields = ["name","city","neighborhood","cuisine","type","status","website","instagram"]
    static func valid(_ place:AskPersonalPlace)->Bool {
        UUID(uuidString:place.id) != nil && !place.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && place.name.utf16.count <= 200 && place.city.utf16.count <= 200 && place.neighborhood.utf16.count <= 200 && place.cuisines.count <= 20 && place.cuisines.allSatisfy {!$0.isEmpty && $0.utf16.count <= 100} && [place.status,place.type].allSatisfy {$0 == nil || $0!.utf16.count <= 200} && [place.websiteURL,place.instagramURL].allSatisfy {$0 == nil || $0!.utf16.count <= 2000} && (place.applePlaceID?.utf16.count ?? 0) <= 300
    }
    func sanitized()->Self {
        let counts=Dictionary(grouping:places,by:{UUID(uuidString:$0.id)?.uuidString ?? $0.id}).mapValues(\.count)
        let valid=places.filter {Self.valid($0) && counts[UUID(uuidString:$0.id)?.uuidString ?? $0.id] == 1}
        let rejected=places.filter { !Self.valid($0) || counts[UUID(uuidString:$0.id)?.uuidString ?? $0.id] != 1 }
        let known=unavailableCities ?? (totalCount == places.count ? [] : nil)
        return .init(places:valid,totalCount:max(totalCount,places.count),cityNames:cityNames?.filter {$0.utf16.count <= 200},unavailableCities:known.map {$0 + rejected.map {!$0.city.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.city.utf16.count <= 200 ? $0.city : nil}},cityCatalogComplete:cityCatalogComplete)
    }
    func complete(in city:String?)->Bool {
        if complete {return true}
        guard let city,let unavailableCities,unavailableCities.count == totalCount-places.count else {return false}
        return unavailableCities.allSatisfy {value in
            guard let value else {return false}
            let stub=AskPersonalPlace(id:"",name:"",status:nil,type:nil,cuisines:[],city:value,neighborhood:"")
            return !AskQueryPlan.sameRegion(stub,city)
        }
    }
}
struct AskLibraryToolResult: Sendable {
    enum Status: String, Sendable { case success, ambiguous, stale, partial, limited, unsupported }
    let status: Status
    let records: [AskPersonalPlace]
    let appliedFilters: AskLibraryPlan
    let totalCount: Int
    let complete: Bool
    let cities: [String]
    var clarification: String? = nil
    var excludesExternalReferences=false
}
enum AskLibraryReadTools {
    static func execute(_ supplied: AskLibraryPlan, snapshot: AskLibrarySnapshot, context: AskLibraryContext?,requireUniqueDetails:Bool=true,allowLargeResults:Bool=false,allowStoredFieldPresence:Bool=false) throws -> AskLibraryToolResult {
        var plan = try supplied.validated()
        guard plan.fieldPresence == nil || allowStoredFieldPresence else {throw AskError.invalidEvidence}
        let snapshot=snapshot.sanitized(),all = snapshot.places
        if let context {
            let selection = context.selectionIDs ?? context.ids
            guard context.ids.count <= (allowLargeResults ? AskCollectionPage.maximumRenderedRecords : 200),Set(context.ids).count == context.ids.count,Set(selection).count == selection.count,Set(context.ids).isSubset(of:Set(selection)) else { throw AskError.invalidEvidence }
        }
        func result(_ status: AskLibraryToolResult.Status, _ records: [AskPersonalPlace]) -> AskLibraryToolResult {
            var value=AskLibraryToolResult(status: status, records: records, appliedFilters: plan, totalCount: records.count, complete: snapshot.complete(in:plan.city), cities: snapshot.cities)
            value.excludesExternalReferences = plan.fieldPresence != nil || plan.status != nil || plan.neighborhood != nil || plan.placeType != nil || (plan.operation != .lookup && plan.fields.contains { ["status","neighborhood","type","address"].contains($0) }) || ["status","neighborhood","type"].contains(plan.groupBy ?? "") || (plan.scope == .previous && context?.excludesExternalReferences == true)
            return value
        }
        guard plan.operation != .unsupported else { return result(.unsupported,[]) }
        if plan.operation == .catalog {let complete=snapshot.complete && snapshot.cityCatalogComplete;return .init(status: complete ? .success : .partial, records: [], appliedFilters: plan, totalCount: snapshot.totalCount, complete: complete, cities: snapshot.cities)}
        var records = all.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if plan.scope == .previous {
            guard let context else { return result(.stale,[]) }
            let selection = context.selectionIDs ?? context.ids
            guard (!selection.isEmpty || context.selectionIDs != nil),Set(selection).isSubset(of:Set(all.map(\.id))) else { return result(.stale,[]) }
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id,$0) })
            records = selection.compactMap { byID[$0] }
            plan.city = plan.city ?? context.filters.city
            plan.cuisine = plan.cuisine ?? context.filters.cuisine
            plan.status = plan.status ?? context.filters.status
            plan.placeType = plan.placeType ?? context.filters.placeType
            plan.neighborhood = plan.neighborhood ?? context.filters.neighborhood
        }
        // A new city uses library scope; previous scope always intersects the accepted result identities.
        if let city = plan.city {
            switch AskCityIdentity.resolve(city,available:snapshot.cities) {
            case .matched(let canonical): plan.city=canonical;records=records.filter {AskQueryPlan.sameRegion($0,canonical)}
            case .missing: records=records.filter {AskQueryPlan.sameRegion($0,city)}
            case .ambiguous(let names):
                var ambiguous=result(.ambiguous,[]);ambiguous.clarification="Which saved city do you mean: " + names.joined(separator:", ") + "?";return ambiguous
            }
        }
        if let search=plan.searchText {
            records=records.filter {record in
                var values=[record.name,record.city,record.neighborhood]
                values += [record.note ?? "",record.status ?? "",record.type ?? ""]
                values += record.cuisines
                values += record.tags ?? []
                return values.contains {$0.range(of:search,options:[.caseInsensitive,.diacriticInsensitive]) != nil}
            }
        }
        if let tag=plan.tag {records=records.filter {($0.tags ?? []).contains {AskCityIdentity.key($0)==AskCityIdentity.key(tag)}}}
        if let neighborhood = plan.neighborhood { records=records.filter {AskCityIdentity.key($0.neighborhood) == AskCityIdentity.key(neighborhood)} }
        if let cuisine = plan.cuisine { records = records.filter { $0.cuisines.contains(where: { $0.caseInsensitiveCompare(cuisine) == .orderedSame }) } }
        if let type = plan.placeType { records = records.filter { $0.type?.caseInsensitiveCompare(type) == .orderedSame } }
        if let status = plan.status { records = records.filter { status == "untried" ? ["Want to try","Just opened"].contains($0.status ?? "") : $0.status == status } }
        if let name = plan.name {
            let exact = records.filter { $0.name.compare(name, options: [.caseInsensitive,.diacriticInsensitive]) == .orderedSame }
            records = exact.isEmpty ? records.filter { $0.name.range(of:name, options:[.caseInsensitive,.diacriticInsensitive]) != nil } : exact
        }
        if let names = plan.names {
            var selected:[AskPersonalPlace]=[]
            for name in names {
                let matches=records.filter {AskCityIdentity.key($0.name) == AskCityIdentity.key(name)}
                guard matches.count == 1 else { return result(.ambiguous,matches) }
                selected.append(matches[0])
            }
            guard Set(selected.map(\.id)).count == selected.count else { return result(.ambiguous,[]) }
            records=selected
        }
        if !plan.positions.isEmpty {
            guard plan.scope == .previous,let context else { return result(.stale,[]) }
            guard !context.ids.isEmpty else {
                var clarification=result(.stale,[]);clarification.clarification="That answer didn’t show an ordered place list. Ask for the places first.";return clarification
            }
            let shown=context.ids.compactMap { id in records.first {$0.id == id} }
            guard plan.positions.allSatisfy({$0 <= shown.count}) else { return result(.stale,[]) }
            records=plan.positions.map {shown[$0-1]}
        }
        // An ordinal names the displayed row, not its position in a newly
        // filtered subset. Intersect presence only after resolving that identity.
        if let presence=plan.fieldPresence {records=records.filter(presence.matches)}
        if !snapshot.complete(in:plan.city) { return result(.partial,records) }
        if !allowLargeResults,![.count,.group].contains(plan.operation),records.count > 200 {return result(.limited,records)}
        if requireUniqueDetails && plan.operation == .details && records.count > 1 { return result(.ambiguous, records) }
        if plan.operation == .compare && !(2...(requireUniqueDetails ? 6 : (allowLargeResults ? Int.max : 200))).contains(records.count) { return result(.ambiguous, records) }
        return result(.success, records)
    }
    static func response(_ result: AskLibraryToolResult, tools: AskReadTools) throws -> AskResponse {
        let plan = result.appliedFilters
        func plain(_ text: String) -> AskResponse {
            var response = AskResponse(summary:text,candidates:[],paragraphs:[.init(id:"library-message",spans:[.text(text)],sourceIDs:[])],listedCandidateIDs:[],usesLocalCatalog:true)
            response.libraryContext = .init(ids:[],filters:plan)
            if [.ambiguous,.stale].contains(result.status) {response.presentation = .clarification}
            return response
        }
        if let clarification=result.clarification { return plain(clarification) }
        var clarification: String?
        switch result.status {
        case .stale: return plain("Those results have changed. Please ask for the list again.")
        case .unsupported: return plain("I don’t have the saved details needed to answer that.")
        case .partial: return plain("I couldn’t check the complete collection. Open a city to review its saved places.")
        case .limited: return plain("\(result.records.count) saved places match. That is too many to show in one answer. Narrow the request by city, cuisine, or name.")
        case .ambiguous:
            let text = plan.operation == .compare || plan.operation == .answer ? "Which saved places do you mean?" : "More than one saved place matches. Which one do you mean?"
            guard (1...6).contains(result.records.count) else { return plain(text) }
            clarification = text
        case .success: break
        }
        if plan.operation == .catalog {
            let cities=result.cities.joined(separator:", ")
            return plain(result.totalCount == 0 ? "You haven’t saved any places yet." : cities.count>2500 ? "You have \(result.totalCount) saved places across \(result.cities.count) cities." : "You have \(result.totalCount) saved places across \(cities).")
        }
        if result.status == .success && (plan.operation == .count || plan.operation == .group) {
            let text:String
            if plan.operation == .count && plan.groupBy == nil {
                text="\(result.records.count) saved \(result.records.count == 1 ? "place" : "places")" + (plan.city.map {" in " + $0} ?? "") + "."
            } else {
                guard let field=plan.groupBy else { throw AskError.invalidEvidence }
                var groups:[String:Int]=[:]
                for record in result.records {
                    let values:[String]
                    switch field {
                    case "city": values=[record.city.isEmpty ? "City not recorded" : record.city]
                    case "neighborhood": values=[record.neighborhood.isEmpty ? "Neighborhood not recorded" : record.neighborhood]
                    case "cuisine": values=record.cuisines.isEmpty ? ["Cuisine not recorded"] : Array(Set(record.cuisines))
                    case "status": values=[record.status ?? "Status not recorded"]
                    case "type": values=[record.type ?? "Category not recorded"]
                    default: throw AskError.invalidEvidence
                    }
                    for value in values { groups[value,default:0]+=1 }
                }
                guard groups.count <= 50 else { return plain("There are too many groups to show completely. Narrow the collection first.") }
                text=groups.isEmpty ? "No saved places match that request." : groups.keys.sorted().map {"\($0): \(groups[$0]!)"}.joined(separator:"\n") + (field == "cuisine" ? "\nPlaces with several cuisines appear in each cuisine." : "")
            }
            guard text.count <= 3000 else { return plain("That breakdown is too long to show completely. Narrow the collection first.") }
            var answer=plain(text)
            answer.libraryContext = .init(ids:[],filters:plan,selectionIDs:result.records.map(\.id),excludesExternalReferences:result.excludesExternalReferences)
            return answer
        }
        guard !result.records.isEmpty else { return plain("No saved places match that request.") }
        let candidates = result.records.compactMap { tools.localCandidate($0.id) }
        guard candidates.count == result.records.count else { throw AskError.invalidEvidence }
        let cities=Set(result.records.map(\.city).filter {!$0.isEmpty})
        let cityHeading=plan.operation == .list && plan.groupBy == nil && result.records.count>1 && cities.count==1 ? cities.first : nil
        let repeatedNames=Dictionary(grouping:result.records,by:{AskCityIdentity.key($0.name)})
        var paragraphs: [AskAnswerParagraph] = clarification.map { [.init(id:"library-clarification",spans:[.text($0)],sourceIDs:[])] } ?? []
        for (i,record) in result.records.enumerated() {
            var spans: [AskAnswerSpan] = [.place(record.id)]
            if clarification != nil || !plan.fields.isEmpty || plan.operation == .details || plan.operation == .compare || cities.count>1 || repeatedNames[AskCityIdentity.key(record.name),default:[]].count>1 {
                var fields = clarification != nil ? ["city"] : plan.fields.isEmpty && [.details,.compare].contains(plan.operation) ? ["city","cuisine","type","status"] : plan.fields
                if cityHeading != nil || plan.groupBy == "city" {fields.removeAll {$0=="city"}}
                if cities.count>1,!fields.contains("city") {fields.insert("city",at:0)}
                if repeatedNames[AskCityIdentity.key(record.name),default:[]].count>1,!record.neighborhood.isEmpty,!fields.contains("neighborhood") {fields.append("neighborhood")}
                let details = fields.compactMap { field -> String? in
                    switch field {
                    case "city": return record.city.isEmpty ? "City isn’t recorded" : record.city
                    case "neighborhood": return record.neighborhood.isEmpty ? "Neighborhood isn’t recorded" : record.neighborhood
                    case "address": return "Street address isn’t recorded"
                    case "cuisine": return record.cuisines.isEmpty ? "Cuisine isn’t recorded" : record.cuisines.joined(separator:", ")
                    case "type": return record.type ?? "Category isn’t recorded"
                    case "website": return record.websiteURL?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false ? "Website isn’t saved" : record.websiteURL.flatMap {InstagramWebsiteClient.websiteURL($0)} == nil ? "Saved website value isn’t a valid URL" : "Website saved"
                    case "instagram": return record.instagramURL?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false ? "Instagram isn’t saved" : record.instagramURL.flatMap {InstagramWebsiteParser.profileURL($0)} == nil ? "Saved Instagram value isn’t a valid profile URL" : "Instagram saved"
                    case "note": return record.note.flatMap {$0.isEmpty ? nil : $0}
                    case "tags": return record.tags.flatMap {$0.isEmpty ? nil : $0.joined(separator:", ")}
                    case "status": return record.status.map { "Marked " + $0 } ?? "Status isn’t recorded"
                    default: return nil
                    }
                }
                if !details.isEmpty { spans.append(.text(" — " + details.joined(separator:" · "))) }
            }
            var citations:[AskWebCitation]=[]
            if plan.fields.contains("website"),let raw=record.websiteURL,let url=InstagramWebsiteClient.websiteURL(raw) {citations.append(.init(title:"Website",url:url.absoluteString))}
            if plan.fields.contains("instagram"),let raw=record.instagramURL,let url=InstagramWebsiteParser.profileURL(raw) {citations.append(.init(title:"Instagram",url:url))}
            paragraphs.append(.init(id:"library-record-\(i)",spans:spans,sourceIDs:candidates[i].sourceIDs,citations:citations))
        }
        if result.status == .success, let field=plan.groupBy {
            var grouped:[String:[AskAnswerParagraph]]=[:]
            for (i,record) in result.records.enumerated() {
                let keys:[String]
                switch field {
                case "city":keys=[record.city.isEmpty ? "City not recorded" : record.city]
                case "neighborhood":keys=[record.neighborhood.isEmpty ? "Neighborhood not recorded" : record.neighborhood]
                case "cuisine":keys=record.cuisines.isEmpty ? ["Cuisine not recorded"] : Array(Set(record.cuisines))
                case "status":keys=[record.status ?? "Status not recorded"]
                case "type":keys=[record.type ?? "Category not recorded"]
                default:throw AskError.invalidEvidence
                }
                for key in keys {grouped[key,default:[]].append(paragraphs[i])}
            }
            paragraphs=grouped.keys.sorted().enumerated().flatMap {i,key in
                grouped[key]!.enumerated().map {j,row in
                    AskAnswerParagraph(id:"library-group-\(i)-row-\(j)",spans:(j==0 ? [.text(key+"\n")] : [])+row.spans,sourceIDs:row.sourceIDs,citations:row.citations,citationsAreResearchPool:row.citationsAreResearchPool)
                }
            }
        }
        if let cityHeading {paragraphs.insert(.init(id:"library-city-heading",spans:[.text(cityHeading)],sourceIDs:[]),at:0)}
        let characters=paragraphs.flatMap(\.spans).reduce(0) {total,span in
            switch span {case .text(let text):return total+text.count;case .place(let id):return total+(result.records.first {$0.id==id}?.name.count ?? 0)}
        }
        guard characters<=60_000 else {return plain("Those saved details are too long to show in one answer. Narrow the request by city, cuisine, or name.")}
        var response = AskResponse(summary:"\(candidates.count) saved \(candidates.count == 1 ? "place" : "places").",candidates:candidates,paragraphs:paragraphs,listedCandidateIDs:[],usesLocalCatalog:true)
        response.libraryContext = .init(ids:result.records.map(\.id),filters:plan,excludesExternalReferences:result.excludesExternalReferences)
        return response
    }
}

extension AskHostedProvider: AskLibraryIntentPlanning {
    func libraryPlan(_ question:String) async throws -> AskLibraryPlan? { try await requestLibraryPlan(question) }
    func libraryPlan(_ request:AskRequest,catalog:AskLibrarySnapshot) async throws -> AskLibraryPlan? {
        guard configuration.scope == .savedMetadata,await permission(),await libraryToolsEnabled() else {return nil}
        guard await libraryPlanVersion() >= 3 else {return try await libraryPlan(request.text)}
        return try await requestLibraryPlan(request.text,context:AskSemanticContext.make(request,catalog:catalog),trace:request.performanceID)
    }
    private func requestLibraryPlan(_ question:String,context:AskSemanticContext? = nil,trace:UUID? = nil) async throws -> AskLibraryPlan? {
        guard configuration.scope == .savedMetadata, await permission(), await libraryToolsEnabled() else { return nil }
        try configuration.validate()
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.count <= 4000 else { throw AskError.inputLimit }
        try Task.checkCancellation()
        let credential = try await token()
        guard (43...128).contains(credential.count), credential.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { throw AskHostedError.disabled }
        // v6 projects only approved index fields and bounded recent user questions/references. No assistant prose or private facts.
        let expanded = await libraryPlanVersion() >= 2
        let publicTools=await libraryPlanVersion() >= 4
        var payload: [String: Any] = ["version":context == nil ? (expanded ? 5 : 4) : (publicTools ? 7 : 6),"mode":"libraryIntent","requestID":(trace ?? UUID()).uuidString,"text":question]
        if let context { payload["context"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(context)) }
        var http = URLRequest(url:configuration.endpoint)
        http.httpMethod = "POST"; http.timeoutInterval = configuration.environment == .production ? 220 : 45
        let body=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
        guard body.count <= 50_000 else {throw AskError.inputLimit}
        http.httpBody = body
        http.setValue("application/json",forHTTPHeaderField:"Content-Type")
        http.setValue("Feast/1.0",forHTTPHeaderField:"User-Agent")
        http.setValue("Bearer " + credential,forHTTPHeaderField:"Authorization")
        let (data,response) = try await send(http)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw AskHostedError.failure(status: response.statusCode, data: data) }
        guard response.url == configuration.endpoint, response.mimeType == "application/json", data.count <= 65536,
              let json = try JSONSerialization.jsonObject(with:data) as? [String:Any], json["version"] as? Int == (publicTools && context != nil ? 3 : expanded ? 2 : 1),
              let plan = json["plan"] as? [String:Any], Set(plan.keys) == Set(["operation","scope","city","cuisine","status","placeType","name","positions","fields"] + (expanded ? ["neighborhood","groupBy","names"] : [])) else { throw AskHostedError.invalidResponse }
        let validated = try JSONDecoder().decode(AskLibraryPlan.self,from:JSONSerialization.data(withJSONObject:plan)).validated()
        if configuration.environment == .production,validated.operation == .answer {
            guard let trace,let answer=json["answer"] as? [String:Any] else {throw AskHostedError.invalidResponse}
            let bytes=try JSONSerialization.data(withJSONObject:answer)
            guard bytes.count<=32768 else {throw AskHostedError.invalidResponse}
            await brokerAnswers.put(bytes,for:trace)
        }
        return validated
    }
}


/// Safe offline shortcuts. Broader language/reasoning goes to the configured model or an honest unavailable state.
enum AskOnDeviceReadPlan {
    static func make(_ request: AskRequest, places: [AskPersonalPlace]) -> AskLibraryPlan? {
        guard request.mode == .collection, request.attachment == nil, !request.fromOCR, AskQueryPlan.route(request.text) == .personal else { return nil }
        let query = request.text.lowercased()
        var remaining = query
        func remove(_ phrase: String) { remaining = remaining.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for:phrase.lowercased()) + "\\b", with:" ",options:.regularExpression) }
        let cities = Array(Set(places.map(\.city))).filter { !$0.isEmpty }
        let city = cities.sorted { $0.count > $1.count }.first { AskQueryPlan.containsPhrase(query,$0) }
        let cuisine = Array(Set(AskQueryPlan.commonCuisines + places.flatMap(\.cuisines))).first { AskQueryPlan.containsPhrase(query,$0) }
        let named = places.filter { AskQueryPlan.containsPhrase(query,$0.name) || AskQueryPlan.containsPhrase(query,$0.name+"s") }.sorted { $0.name.count > $1.name.count }.first?.name
        let asksStatus = ["status","visited","been"].contains { AskQueryPlan.containsPhrase(query,$0) }
        let status = asksStatus && (named != nil || query.contains("first") || query.contains("second")) ? nil : query.contains("untried") ? "untried" : AskQueryPlan.status(query)
        for value in places.map({$0.name+"s"}) { remove(value) }
        for value in cities + AskQueryPlan.commonCuisines + places.flatMap(\.cuisines) + places.map(\.name) + ["want to try","just opened","favorites","favorite","favourites","favourite","regulars","regular","love","loved","visited","been","untried"] { remove(value) }
        let grammar:Set<String> = ["what","which","are","is","the","a","an","my","our","of","them","those","these","ones","one","two","first","second","only","compare","and","about","saved","places","place","cuisine","cuisines","status","type","city","name","recorded","for","in","their","its","tell","me","more","show","please","neighborhood","neighbourhood","address","street","visit","have","has","i","we","it","at","located","where","each","both","does","belong","to","s"]
        guard remaining.split(whereSeparator:{ !$0.isLetter }).allSatisfy({ grammar.contains(String($0)) }) else { return nil }
        let explicitCollection = !AskQueryPlan.isFollowUp(query) && (query.contains("saved") || query.contains("collection"))
        let previous = request.libraryContext != nil && city == nil && !explicitCollection
        guard previous || named != nil || (request.libraryContext != nil && city != nil) else { return nil }
        let positions = query.contains("first two") ? [1,2] : query.contains("second") ? [2] : query.contains("first") ? [1] : []
        let pluralSelection = ["both","each","two"].contains(where:{ AskQueryPlan.containsPhrase(remaining,$0) }) || (named.map {AskQueryPlan.containsPhrase(query,$0+"s")} ?? false)
        let compare = query.contains("compare") || (pluralSelection && named != nil)
        var fields = ["cuisine","status","type","city","neighborhood","address"].filter { query.contains($0) }
        if query.contains("neighbourhood") { fields.append("neighborhood") }
        if query.contains("where") && fields.isEmpty { fields = ["city","neighborhood"] }
        if query.contains("street") && !fields.contains("address") { fields.append("address") }
        if asksStatus && !fields.contains("status") { fields.append("status") }
        return .init(operation:compare ? .compare : !positions.isEmpty || named != nil ? .details : .list,scope:previous ? .previous : .library,
            city:city,cuisine:cuisine,status:status,placeType:nil,name:named,positions:positions,fields:fields)
    }
}
