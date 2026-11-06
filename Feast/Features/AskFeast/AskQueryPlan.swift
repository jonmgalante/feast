import Foundation

enum AskCityIdentity {
    enum Resolution { case matched(String), missing, ambiguous([String]) }
    static func key(_ value:String) -> String {
        value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).split { !$0.isLetter && !$0.isNumber }.joined()
    }
    private static func initials(_ value:String) -> String {
        value.folding(options:[.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).split { !$0.isLetter }.compactMap(\.first).map(String.init).joined().lowercased()
    }
    static func resolve(_ supplied:String,available:[String]) -> Resolution {
        let cities=Array(Set(available)).filter {!$0.isEmpty}.sorted(),query=key(supplied)
        guard !query.isEmpty else {return .missing}
        func resolved(_ matches:[String]) -> Resolution { matches.count == 1 ? .matched(matches[0]) : matches.isEmpty ? .missing : .ambiguous(matches) }
        let exact=cities.filter {key($0) == query};if !exact.isEmpty {return resolved(exact)}
        let nyc:Set<String>=["nyc","newyork","newyorkcity"]
        let matches=cities.filter { name in
            let value=key(name)
            if nyc.contains(query) && nyc.contains(value) {return true}
            let words=supplied.split { !$0.isLetter }
            let storedWords=name.split { !$0.isLetter }
            return (words.count > 1 && (2...5).contains(value.count) && name == name.uppercased() && initials(supplied) == value) ||
                (storedWords.count > 1 && (2...5).contains(query.count) && supplied == supplied.uppercased() && initials(name) == query)
        }
        return resolved(matches)
    }
}

struct AskPublicCriteria: Codable, Equatable, Sendable {
    let category: String
    let region: String
    let intent: String
    let windowDays: Int
    var cuisine: String? = nil
    var period: String? = nil
    var contextText: String {
        let periodText = period == "calendar_month" ? "this month" : period == "calendar_week" ? "this week" : period == "today" ? "today" : ""
        return [region, category == "cafe" ? "coffee cafe" : category, cuisine ?? "", intent == "upcoming_openings" ? "upcoming openings" : intent == "recent_openings" ? "recent openings" : "recommendations", periodText].joined(separator: " ")
    }
    static let regions = ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island", "New York City", "London", "Philadelphia"]
    static func make(_ text: String) -> Self? {
        let parts = text.lowercased().components(separatedBy: "\nEarlier question: ".lowercased())
        let current = parts[0], previous = parts.dropFirst().joined(separator: " ")
        func region(_ value: String) -> String? { regions.first(where: { value.contains($0.lowercased()) }) ?? ((value.contains("nyc") || value.contains("new york")) ? "New York City" : nil) }
        guard let region = region(current) ?? region(previous) else { return nil }
        func category(_ value: String) -> String? {
            if value.contains("coffee") || value.contains("cafe") || value.contains("café") { return "cafe" }
            if value.contains("baker") { return "bakery" }
            if value.contains("cocktail") || value.contains(" bars") { return "bar" }
            if value.contains("dessert") { return "dessert" }
            if value.contains("restaurant") { return "restaurant" }
            return nil
        }
        let category = category(current) ?? category(previous) ?? "restaurant"
        let value = text.lowercased()
        let upcoming = value.contains("upcoming") || value.contains("opening soon") || value.contains("will open")
        let cuisine = AskQueryPlan.commonCuisines.first { current.contains($0.lowercased()) } ?? AskQueryPlan.commonCuisines.first { previous.contains($0.lowercased()) }
        let window = value.contains("today") ? 1 : value.contains("this week") ? 7 : value.contains("this month") ? 30 : (upcoming ? 180 : 90)
        let opening = ["opening", "openings", "opened", "upcoming", "will open"].contains { value.contains($0) }
        let period = value.contains("today") ? "today" : value.contains("this week") ? "calendar_week" : value.contains("this month") ? "calendar_month" : nil
        return .init(category: category, region: region, intent: upcoming ? "upcoming_openings" : opening ? "recent_openings" : "recommendations", windowDays: upcoming ? max(30, window) : window, cuisine: cuisine, period: period)
    }
}

enum AskQueryPlan {
    enum Route { case personal, discovery, hybrid }
    static func route(_ text: String) -> Route {
        let value = text.lowercased()
        if value.contains("saved notes") || value.contains("saved note") { return .personal }
        let publicWords = Set(value.replacingOccurrences(of: "new york", with: "nyc").split { !$0.isLetter }.map(String.init))
        let newBusiness = publicWords.contains("new") && !publicWords.isDisjoint(with: ["cafe", "cafes", "coffee", "restaurant", "restaurants", "bakery", "bakeries", "bar", "bars", "places"])
        let datedOpened = publicWords.contains("opened") && ["recent", "recently", "today", "this week", "this month"].contains { value.contains($0) }
        let current = newBusiness || datedOpened || ["opening", "openings", "upcoming", "current", "latest", "what's new", "new coffee", "new cafe", "new restaurant", "discover"].contains { value.contains($0) }
        let personal = ["my saved", "my collection", "our collection", "already saved", "favorites", "favourites", "favorite", "favourite", "regulars", "love", "remember"].contains { value.contains($0) }
        return current ? (personal ? .hybrid : .discovery) : .personal
    }
    static func isFollowUp(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["only ", "which are ", "which ones ", "compare the ", "compare first ", "what about ", "and ", "not ", "i meant ", "which opened", "which is", "which of them", "compare those", "how do they compare", "what are their", "what is its", "does it", "that one", "which of those", "which one", "what else", "when do they", "when might they", "when does it", "is it ", "are they ", "tell me more", "their "].contains { value.hasPrefix($0) }
    }
    static func hasNewPublicCriteria(_ text: String) -> Bool {
        let lower = text.lowercased()
        return (AskPublicCriteria.regions + commonCuisines + ["coffee", "cafe", "bakery", "bar", "dessert", "restaurant", "today", "week", "month", "upcoming"]).contains { lower.contains($0.lowercased()) }
    }
    static let commonCuisines = ["Italian", "Japanese", "French", "Chinese", "Mexican", "Indian", "Thai", "Korean", "British", "American", "Mediterranean", "Vietnamese", "Greek", "Spanish"]
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func matches(_ place: AskPersonalPlace, text: String, all: [AskPersonalPlace]) -> Bool {
        matcher(text:text,all:all)(place)
    }
    /// Query-wide clues are computed once, then applied to each local record.
    static func matcher(text:String,all:[AskPersonalPlace])->(AskPersonalPlace)->Bool {
        let query = text.lowercased().replacingOccurrences(of: "\\bues\\b", with: "upper east side", options: .regularExpression).replacingOccurrences(of: "\\buws\\b", with: "upper west side", options: .regularExpression)
        let cuisines = Set(Set(commonCuisines + all.flatMap(\.cuisines)).filter { query.contains($0.lowercased()) }.map { $0.lowercased() })
        var regions = Set(Set(AskPublicCriteria.regions + all.map(\.city)).filter { !$0.isEmpty && containsPhrase(query, $0) })
        if query.contains("nyc") || query.contains("new york") { regions.insert("New York City") }
        let neighborhoods = Set(Set(all.map(\.neighborhood) + ["Upper East Side", "Upper West Side"]).filter { !$0.isEmpty && containsPhrase(query, $0) })
        let types = ["Cafe", "Bakery", "Bar", "Restaurant", "Dessert", "Market"].filter { query.contains($0.lowercased()) }
        let coffee=query.contains("coffee")
        return { place in
            if !cuisines.isEmpty && cuisines.isDisjoint(with:place.cuisines.map {$0.lowercased()}) {return false}
            for region in regions where !sameRegion(place,region) {return false}
            if !neighborhoods.isEmpty && !neighborhoods.contains(where:{$0.caseInsensitiveCompare(place.neighborhood) == .orderedSame}) {return false}
            if !types.isEmpty && !types.contains(where:{$0.caseInsensitiveCompare(place.type ?? "") == .orderedSame}) {return false}
            if coffee && place.type != "Cafe" {return false}
            return true
        }
    }
    static func sameRegion(_ place: AskPersonalPlace, _ region: String) -> Bool {
        if place.city.caseInsensitiveCompare(region) == .orderedSame { return true }
        let nyc = ["nyc", "new york", "new york city"]
        if nyc.contains(place.city.lowercased()) && nyc.contains(region.lowercased()) { return true }
        let manhattan = ["upper east side", "upper west side", "chelsea", "soho", "tribeca", "west village", "east village", "lower east side", "flatiron", "midtown", "harlem", "nolita"]
        return nyc.contains(place.city.lowercased()) && (place.neighborhood.caseInsensitiveCompare(region) == .orderedSame || (region.lowercased() == "manhattan" && manhattan.contains(place.neighborhood.lowercased())))
    }
    static func status(_ text: String) -> String? {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["favorite", "favorites", "favourite", "favourites", "love", "loved"]) { return "Love" }
        if !words.isDisjoint(with: ["regular", "regulars"]) { return "Regulars" }
        if !words.isDisjoint(with: ["visited", "been"]) { return "Been" }
        if text.lowercased().contains("just opened") { return "Just opened" }
        if text.lowercased().contains("want to try") { return "Want to try" }
        return nil
    }
}

/// A bounded, on-device collection operation, not a restaurant-name search or model prompt.
struct AskCollectionListingPlan {
    let filterText: String
    let region: String?
    let placeType: String?
    /// In a saved-collection list, “restaurants” is often the user's umbrella noun.
    /// Narrow it only when they explicitly ask for the recorded category; never rewrite stored types.
    static func recordedType(in text:String) -> String? {
        let query = text.lowercased()
        if query.range(of:#"\b(?:(?:only|just)\s+restaurants?|restaurants?\s+only|(?:type|category)\s+(?:is\s+)?restaurants?|(?:typed|categorized|categorised)\s+as\s+restaurants?)\b"#,options:.regularExpression) != nil { return "Restaurant" }
        for (words,type) in [("cafes?|cafés?|coffee","Cafe"),("bakeries|bakery","Bakery"),("bars?","Bar"),("desserts?","Dessert"),("markets?","Market")] {
            if query.range(of:"\\b(?:"+words+")\\b",options:.regularExpression) != nil { return type }
        }
        return nil
    }
    static func make(_ request: AskRequest, places: [AskPersonalPlace]) -> Self? {
        guard request.mode == .collection, request.attachment == nil, !request.fromOCR else { return nil }
        let current = request.text.lowercased()
        guard AskQueryPlan.route(current) == .personal else { return nil }
        let prior = request.previousQuestion.flatMap { previous -> Self? in
            make(.init(mode: .collection, text: previous, fromOCR: false), places: places)
        }
        let followUp = AskQueryPlan.isFollowUp(current) && prior != nil
        let tokens = Set(current.split { !$0.isLetter }.map(String.init))
        let ownership = current.contains("saved") || current.contains("collection") ||
            (!tokens.isDisjoint(with: ["my", "our"]) && !tokens.isDisjoint(with: ["places", "restaurants", "cafes", "bakeries", "bars"]))
        guard ownership || followUp else { return nil }
        let locations = Array(Set(places.map(\.city) + places.map(\.neighborhood) + AskPublicCriteria.regions)).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var clues = current
        var region: String?
        // Explicit location may be unknown: return an honest empty result, never another city.
        if let range = clues.range(of: #"\b(?:in|around|near|from)\s+([\p{L}][\p{L} .'-]*?)[?.!]*$"#, options: .regularExpression) {
            let phrase = String(clues[range]).trimmingCharacters(in: .punctuationCharacters)
            let location = phrase.split(separator: " ").dropFirst().joined(separator: " ")
            // Only consume a plain location tail; named/detail requests still fail the grammar below.
            if [" with ", " called ", " named ", " that ", " for ", " serving "].contains(where: { location.contains($0) }) { return nil }
            if !location.isEmpty { region = location; clues.removeSubrange(range) }
        }
        for location in locations {
            if clues.range(of: "\\b" + NSRegularExpression.escapedPattern(for: location.lowercased()) + "\\b", options: .regularExpression) != nil {
                if region == nil, places.contains(where: { $0.city.caseInsensitiveCompare(location) == .orderedSame }) { region = location }
                clues = clues.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: location.lowercased()) + "\\b", with: " ", options: .regularExpression)
            }
        }
        for value in AskQueryPlan.commonCuisines + ["restaurants", "restaurant", "cafes", "café", "cafe", "bakeries", "bakery", "bars", "bar", "desserts", "dessert", "markets", "market", "coffee", "favorites", "favourites", "favorite", "favourite", "regulars", "regular", "love", "visited", "been", "want to try", "just opened"] {
            clues = clues.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: value.lowercased()) + "\\b", with: " ", options: .regularExpression)
        }
        let grammar: Set<String> = ["what","whats","are","is","my","our","the","all","saved","save","places","place","collection","collections","show","list","give","me","have","has","i","we","you","do","did","which","of","them","those","ones","and","about","please","tell","in","to","a","s","across","cities","city","only","just","type","category","typed","categorized","categorised","as"]
        let remaining = clues.split { !$0.isLetter }.map(String.init)
        guard remaining.allSatisfy(grammar.contains) else { return nil }
        if let requested=region,case .matched(let canonical)=AskCityIdentity.resolve(requested,available:places.map(\.city)) { region=canonical }
        let type = recordedType(in:current)
        let normalized = type == "Restaurant" ? current : current.replacingOccurrences(of:#"\brestaurants?\b"#,with:"places",options:.regularExpression)
        var filter = normalized
        if followUp, let prior {
            // A new city starts a fresh city scope; otherwise refine the prior collection filter.
            filter = region == nil ? normalized + " " + prior.filterText : normalized
        }
        var selectedType = type
        if selectedType == nil,followUp,region == nil { selectedType = prior?.placeType }
        return .init(filterText:filter,region:region ?? (followUp ? prior?.region : nil),placeType:selectedType)
    }
    func matches(_ place: AskPersonalPlace, all: [AskPersonalPlace]) -> Bool {
        matcher(all:all)(place)
    }
    func matcher(all:[AskPersonalPlace])->(AskPersonalPlace)->Bool {
        let matches=AskQueryPlan.matcher(text:filterText,all:all),status=AskQueryPlan.status(filterText)
        return { place in
            if let region,!AskQueryPlan.sameRegion(place,region.capitalized),place.neighborhood.caseInsensitiveCompare(region) != .orderedSame {return false}
            if let status,place.status != status {return false}
            if let placeType,place.type != placeType {return false}
            return matches(place)
        }
    }
}

/// Existing dev approval can survive icon launch on its original simulator only.
enum AskSavedLaunchPolicy {
    static let key = "AskFeast.approvedSavedMetadata.v1"
    static let originalSimulator = "4F6EAF55-E0E2-4895-9D19-C2D1D4D89D8D"
    static func enabled(arguments: [String], simulator: String?, approved: Bool) -> Bool {
        if arguments.contains("-feastHostedSavedPlaces") { return true }
        return approved && simulator == originalSimulator && !arguments.contains("-feastSyntheticPreview")
    }
    static func canRemember(arguments: [String], simulator: String?) -> Bool {
        simulator == originalSimulator && arguments.contains("-feastHostedSavedPlaces") && !arguments.contains("-feastSyntheticPreview")
    }
}

/// Kept on device. Never serialized into hosted evidence or web criteria.
struct AskPersonalPlace: Equatable, Sendable {
    let id: String
    let name: String
    let status: String?
    let type: String?
    let cuisines: [String]
    let city: String
    let neighborhood: String
    var websiteURL:String? = nil
    var instagramURL:String? = nil
    var applePlaceID:String? = nil
}

struct AskWebCitation: Codable, Equatable, Sendable {
    let title: String
    let url: String
    var safeURL: URL? {
        guard let u = URL(string: url), u.scheme == "https", let host = u.host, host.contains("."),
              u.user == nil, u.password == nil, u.port == nil,
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"), host != "localhost",
              !host.allSatisfy({ $0.isNumber || $0 == "." }), !host.contains(":") else { return nil }
        return u
    }
}
/// Resolves a displayed Markdown destination to an accepted source, never to a
/// merely related domain. Functional query parameters and fragments stay exact.
enum AskCitationLink {
    private static let trackingKeys:Set<String> = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "trk"]
    private static func destination(_ url:URL)->String? {
        guard AskWebCitation(title:"Link",url:url.absoluteString).safeURL != nil,
              var parts=URLComponents(url:url,resolvingAgainstBaseURL:false) else{return nil}
        parts.host=parts.host?.lowercased()
        if let query=parts.queryItems {
            let retained=query.filter {!trackingKeys.contains($0.name)}
            // Keep exact encoded functional query spelling/order; filter only
            // explicitly recognized tracking keys, without decoding path aliases.
            let encoded=parts.percentEncodedQuery?.components(separatedBy:"&") ?? []
            guard encoded.count==query.count else{return nil}
            let kept=zip(query,encoded).filter {!trackingKeys.contains($0.0.name)}.map {$0.1}
            parts.percentEncodedQuery=retained.isEmpty ? nil : kept.joined(separator:"&")
        }
        return parts.string
    }
    static func acceptedURL(for requested:URL,citations:[AskWebCitation])->URL? {
        guard let key=destination(requested) else{return nil}
        return citations.compactMap(\.safeURL).first {destination($0)==key}
    }
}

struct AskWebPlace: Codable, Equatable, Sendable, Identifiable {
    var id: String { sourceURL }
    let name: String
    let region: String
    let sourceURL: String
    let openingDate: String
    let openingKind: String
    let evidence: String
}

/// Uses only accepted public facts. No search, prompt expansion, inferred quality or silent truncation.
enum AskFollowUpPlanner {
    static func publicAnswer(_ request: AskRequest) -> AskResponse {
        let question = request.text.lowercased()
        let excluded = request.referencedWebPlaces.filter { question.contains("not " + $0.name.lowercased()) }
        let available = request.referencedWebPlaces.filter { place in !excluded.contains(where: { $0.sourceURL == place.sourceURL }) }
        let named = available.filter { question.contains($0.name.lowercased()) }
        var selected = named.isEmpty ? available : named
        func plain(_ text: String) -> AskResponse {
            .init(summary: text, candidates: [], paragraphs: [.init(id: "follow-up", spans: [.text(text)], sourceIDs: [])], listedCandidateIDs: [], webPlaces: selected, referenceWebPlaces: request.referencedWebPlaces)
        }
        if selected.isEmpty { return plain("Which place do you mean instead?") }
        let earliest = ["earliest", "oldest", "opened first"].contains { question.contains($0) }
        let latest = ["newest", "latest", "most recently", "opened last"].contains { question.contains($0) }
        if earliest || latest {
            let confirmed = selected.filter { $0.openingKind == "opened" && !$0.openingDate.isEmpty }
            guard confirmed.count == selected.count else { return plain("Some opening dates are only announced or unverified, so I can’t reliably order these places yet.") }
            let date = earliest ? confirmed.map(\.openingDate).min() : confirmed.map(\.openingDate).max()
            selected = confirmed.filter { $0.openingDate == date }
        } else if selected.count > 1 && named.isEmpty && [" it", "its ", "that one"].contains(where: question.contains) {
            return plain("Which place do you mean?")
        }
        for (clues,field) in [(["hours", "open now", "closing time"], "opening hours"), (["address", "street"], "street addresses"), (["better", "best", "quieter", "quietest", "cheaper", "price", "rating"], "a comparison on that detail")] {
            if clues.contains(where: question.contains) { return plain("I haven’t verified \(field) for these places. Which one would you like to check?") }
        }
        if question.contains("compare") { return plain("Which detail would you like to compare?") }
        let dates = earliest || latest || ["when", "date", "opened", "opening"].contains(where: question.contains)
        let paragraphs = selected.enumerated().map { i, place -> AskAnswerParagraph in
            let fact: String
            if dates {
                fact = place.openingKind == "opened" ? "\(place.name) opened on \(place.openingDate)." : place.openingKind == "announced" ? "\(place.name) has an announced target of \(place.openingDate); the opening isn’t confirmed." : "I haven’t verified an opening date for \(place.name)."
            } else {
                fact = place.evidence.replacingOccurrences(of: "**", with: "")
            }
            return .init(id: "refined-\(i)", spans: [.text(fact)], sourceIDs: [], citations: [.init(title: URL(string: place.sourceURL)?.host ?? place.name, url: place.sourceURL)])
        }
        return .init(summary: paragraphs.flatMap(\.spans).compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: " "), candidates: [], paragraphs: paragraphs, listedCandidateIDs: [], webPlaces: selected, referenceWebPlaces: request.referencedWebPlaces)
    }
}

enum AskSavedDiscoveryMatch {
    static func unique(_ web: AskWebPlace, in places: [AskPersonalPlace]) -> AskPersonalPlace? {
        let matches = places.filter { $0.name.compare(web.name, options: [.caseInsensitive,.diacriticInsensitive]) == .orderedSame && AskQueryPlan.sameRegion($0, web.region) }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Local preference answers never invoke the remote provider. Hybrid matching also stays here.
struct AskLibraryProvider: AskFeastProvider {
    let label = "Ask Feast"
    let remote: any AskFeastProvider
    let places: @Sendable () async throws -> [AskPersonalPlace]
    var intentPlanner: (any AskLibraryIntentPlanning)? = nil
    var snapshot: (@Sendable () async throws -> AskLibrarySnapshot)? = nil
    private func currentCatalog() async throws -> AskLibrarySnapshot {
        if let snapshot { return try await snapshot() }
        let all=try await places();return .init(places:all,totalCount:all.count)
    }
    func answer(_ request: AskRequest, tools: AskReadTools) async throws -> AskResponse {
        // Named saved-business queries use semantic tools even if legacy wording selected discovery.
        // Entity anchoring is a confidence shortcut, not an allowlist of English questions.
        if request.mode == .discovery,request.attachment == nil,!request.fromOCR,
           let researcher=remote as? any AskBusinessResearching,await researcher.publicLookupAvailable() {
            let catalog=try await currentCatalog()
            if catalog.complete,catalog.places.contains(where:{AskQueryPlan.containsPhrase(request.text,$0.name)}) {
                return try await answer(request.collectionReadVersion(),tools:tools.collectionReadTools())
            }
        }
        if request.mode == .collection, request.attachment == nil {
            let current: AskLibrarySnapshot
            if let snapshot { current = try await snapshot() }
            else { let all = try await places();current = .init(places:all,totalCount:all.count) }
            let all = current.places
            if let plan = AskOnDeviceReadPlan.make(request, places: all) {
                // Public details need semantic interpretation: distinguish “what is saved” from
                // “find its address”, rather than terminating on an absent local field.
                var semanticPublicFact = false
                if !Set(plan.fields).isDisjoint(with: AskBusinessRequest.allowedFields), intentPlanner != nil,
                   let researcher=remote as? any AskBusinessResearching {
                    semanticPublicFact = await researcher.publicLookupAvailable()
                }
                if !semanticPublicFact {
                    let result = try AskLibraryReadTools.execute(plan,snapshot:current,context:request.libraryContext)
                    guard tools.localRecordsMatch(result.records) else { throw AskError.invalidEvidence }
                    return try AskLibraryReadTools.response(result,tools:tools)
                }
            }
            if let plan = AskCollectionListingPlan.make(request, places: all) {
                guard current.complete(in:plan.region) else { throw AskError.incompleteCollection }
                let matches = all.filter(plan.matcher(all:all)).sorted {
                    let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
                guard tools.localRecordsMatch(matches) else { throw AskError.invalidEvidence }
                if matches.count>200 {
                    let filter=AskLibraryPlan(operation:.list,scope:.library,city:plan.region,positions:[],fields:[])
                    return try AskLibraryReadTools.response(.init(status:.limited,records:matches,appliedFilters:filter,totalCount:matches.count,complete:true,cities:current.cities),tools:tools)
                }
                let candidates = matches.compactMap { tools.localCandidate($0.id) }
                guard candidates.count == matches.count else { throw AskError.invalidEvidence }
                let statusLabel = AskQueryPlan.status(plan.filterText).map { " marked " + $0 } ?? ""
                let heading = candidates.isEmpty ? "There are no matching saved places\(statusLabel) in this collection." : "\(candidates.count) saved \(candidates.count == 1 ? "place" : "places")\(statusLabel)\(plan.region.map { " in " + $0.capitalized } ?? " in this collection"):"
                let paragraphs: [AskAnswerParagraph] = [.init(id: "collection-list", spans: [.text(heading)], sourceIDs: [])] + candidates.enumerated().map { i, candidate in
                    .init(id: "collection-item-\(i)", spans: [.place(candidate.id)], sourceIDs: candidate.sourceIDs)
                }
                var answer = AskResponse(summary: heading, candidates: candidates, paragraphs: paragraphs, listedCandidateIDs: [], usesLocalCatalog: true)
                let filter = AskLibraryPlan(operation:.list,scope:.library,city:plan.region,cuisine:AskQueryPlan.commonCuisines.first { AskQueryPlan.containsPhrase(plan.filterText,$0) },status:AskQueryPlan.status(plan.filterText),placeType:plan.placeType,name:nil,positions:[],fields:[])
                answer.libraryContext = .init(ids:candidates.map(\.id),filters:filter)
                return answer
            }
        }
        if request.mode == .collection, request.attachment == nil, let intentPlanner,
           let plan = try await intentPlanner.libraryPlan(request,catalog:try await currentCatalog()) {
            let current=try await currentCatalog()
            let result = try AskLibraryReadTools.execute(plan, snapshot: current, context: request.libraryContext)
            guard tools.localRecordsMatch(result.records) else { throw AskError.invalidEvidence }
            if plan.operation == .updateField {
                guard result.status == .success,result.records.count == 1,let target=result.records.first,
                      let candidate=tools.localCandidate(target.id) else {
                    let ambiguous=AskLibraryToolResult(status:result.status == .success ? .ambiguous : result.status,records:result.records,appliedFilters:plan,totalCount:result.totalCount,complete:result.complete,cities:result.cities)
                    return try AskLibraryReadTools.response(ambiguous,tools:tools)
                }
                let matches=request.verifiedFindings.filter {$0.recordID == target.id && $0.field == "instagram"}
                guard matches.count == 1,let finding=matches.first else {
                    return .init(summary:"Which Instagram should I save?",candidates:[candidate],paragraphs:[.init(id:"action-clarify",spans:[.text("Which Instagram should I save to "),.place(target.id),.text("?")],sourceIDs:candidate.sourceIDs)],listedCandidateIDs:[],usesLocalCatalog:true,libraryContext:.init(ids:[target.id],filters:plan))
                }
                _ = try finding.validated()
                return .init(summary:"Save Instagram",candidates:[candidate],paragraphs:[],listedCandidateIDs:[],usesLocalCatalog:true,libraryContext:.init(ids:[target.id],filters:plan),fieldActions:[.init(finding:finding)],requestsFieldSave:true)
            }
            if plan.operation == .lookup {
                guard result.status == .success,!result.records.isEmpty else {return try AskLibraryReadTools.response(result,tools:tools)}
                guard result.records.count == 1 else {
                    let ambiguous=AskLibraryToolResult(status:.ambiguous,records:result.records,appliedFilters:plan,totalCount:result.totalCount,complete:result.complete,cities:result.cities)
                    return try AskLibraryReadTools.response(ambiguous,tools:tools)
                }
                guard let researcher=remote as? any AskBusinessResearching else {throw AskHostedError.disabled}
                let target=result.records[0]
                let uniquePublicIdentity=current.places.filter {AskCityIdentity.key($0.name)==AskCityIdentity.key(target.name) && AskCityIdentity.key($0.city)==AskCityIdentity.key(target.city)}.count == 1
                let priorSensitive=plan.scope == .previous && (request.libraryContext?.excludesExternalReferences == true || (request.libraryContext?.filters.operation != .lookup && request.libraryContext?.filters.fields.contains { ["status","neighborhood","type","address"].contains($0) } == true))
                let sensitive=result.excludesExternalReferences || priorSensitive
                var answer=try await AskBusinessLookup.answer(request,plan:plan,record:target,tools:tools,allowExternalLookups:uniquePublicIdentity && !sensitive,externalLimitation:sensitive ? "I can show saved links, but this private selection isn’t shared for an online lookup." : nil,researcher:researcher)
                answer.libraryContext?.excludesExternalReferences=sensitive
                let fresh=try await currentCatalog()
                guard fresh.complete,fresh.places.contains(result.records[0]) else {throw AskError.invalidEvidence}
                return answer
            }
            if plan.operation == .answer, result.status == .success, !result.records.isEmpty {
                // Synthesis uses the existing approved metadata projection only. Preferences/notes never leave device.
                guard result.records.count <= 6 else {
                    return try AskLibraryReadTools.response(.init(status: .ambiguous, records: result.records, appliedFilters: plan, totalCount: result.totalCount, complete: result.complete, cities: result.cities), tools: tools)
                }
                if result.appliedFilters.status != nil {
                    return try AskLibraryReadTools.response(.init(status: .unsupported, records: [], appliedFilters: plan, totalCount: 0, complete: true, cities: result.cities), tools: tools)
                }
                let (resolved, scopedTools) = try tools.resolving(result.records.map(\.id))
                var answer = try scopedTools.checked(await remote.answer(resolved, tools: scopedTools))
                answer.usesLocalCatalog = true
                if !answer.candidates.isEmpty { answer.libraryContext = .init(ids: answer.candidates.map(\.id), filters: result.appliedFilters) }
                return answer
            }
            return try AskLibraryReadTools.response(result, tools: tools)
        }
        if request.attachment == nil, let status = AskQueryPlan.status(request.text), request.mode == .collection {
            let all = try await places()
            let matchesQuery=AskQueryPlan.matcher(text:request.text,all:all)
            let matches = all.filter { place in
                (!request.referenceOnly || request.referencedIDs.contains(place.id)) && place.status == status && matchesQuery(place)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.prefix(6)
            let candidates = matches.compactMap { tools.localCandidate($0.id) }
            var spans: [AskAnswerSpan] = []
            for (i,candidate) in candidates.enumerated() {
                if i > 0 { spans.append(.text(i == candidates.count-1 ? " and " : ", ")) }
                spans.append(.place(candidate.id))
            }
            if spans.isEmpty { spans = [.text("No matching places are marked \(status) in this collection.")] }
            else { spans.append(.text(" \(candidates.count == 1 ? "is" : "are") marked \(status) in this collection.")) }
            return .init(summary: "Collection status", candidates: candidates, paragraphs: [.init(id: "local-status", spans: spans, sourceIDs: candidates.flatMap(\.sourceIDs))], listedCandidateIDs: [], usesLocalCatalog: true)
        }
        // A nil semantic plan means the capability is unavailable, not permission denial.
        // Never fall through to unscoped production synthesis requiring resolved records.
        if request.mode == .collection, intentPlanner != nil { throw AskHostedError.disabled }
        var response: AskResponse
        if request.mode == .discovery, !request.referencedWebPlaces.isEmpty {
            response = AskFollowUpPlanner.publicAnswer(request)
        } else { response = try await remote.answer(request, tools: tools) }
        guard request.mode == .discovery else { return response }
        let desiredStatus = AskQueryPlan.status(request.text)
        let local = try await places().filter { desiredStatus == nil || $0.status == desiredStatus }
        for web in response.webPlaces {
            let matches = local.filter { $0.name.compare(web.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame && AskQueryPlan.sameRegion($0, web.region) }
            guard matches.count == 1, let candidate = tools.localCandidate(matches[0].id) else { continue }
            guard !response.candidates.contains(where: { $0.id == candidate.id }) else { continue }
            response.candidates.append(candidate)
            if let position = response.paragraphs.firstIndex(where: { if case .text(let value) = $0.spans.first { return value.hasPrefix(web.name) }; return false }),
               case .text(let text) = response.paragraphs[position].spans[0] {
                let old = response.paragraphs[position]
                response.paragraphs[position] = .init(id: old.id, spans: [.place(candidate.id), .text(String(text.dropFirst(web.name.count)) + (desiredStatus.map { " Marked \($0) in this collection." } ?? " Already saved in Feast."))], sourceIDs: candidate.sourceIDs, citations: old.citations,citationsAreResearchPool:old.citationsAreResearchPool)
            }
        }
        response.usesLocalCatalog = true
        return response
    }
}
