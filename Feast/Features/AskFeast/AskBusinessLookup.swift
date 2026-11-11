import Foundation
import CryptoKit

struct AskBusinessIdentity:Codable,Equatable,Sendable {let name:String;let city:String}
struct AskBusinessRequest:Encodable,Sendable {
    static let allowedFields=["instagram","website","phone","address","hours","menu"]
    let version=7,mode="publicLookup"
    let requestID:String
    let business:AskBusinessIdentity
    let fields:[String]
    static func make(trace:UUID,attempt:UUID?=nil,record:AskPersonalPlace,fields:[String]) throws -> Self {
        guard !record.name.isEmpty,!record.city.isEmpty,record.name.count<=200,record.city.count<=200,(1...4).contains(fields.count),Set(fields).count==fields.count,fields.allSatisfy(allowedFields.contains) else {throw AskError.invalidEvidence}
        // Stable per logical turn: retry cannot buy another hidden search with a fresh UUID.
        var bytes=Array(SHA256.hash(data:Data(((attempt.map {$0.uuidString+":"+record.id+":"+fields.sorted().joined(separator:",")+":"} ?? "")+trace.uuidString+":public-lookup-v1").utf8)).prefix(16));bytes[6]=(bytes[6]&0x0f)|0x50;bytes[8]=(bytes[8]&0x3f)|0x80
        let hex=bytes.map {String(format:"%02x",$0)}.joined(),parts=[0..<8,8..<12,12..<16,16..<20,20..<32].map {range in String(hex.dropFirst(range.lowerBound).prefix(range.count))}
        return .init(requestID:parts.joined(separator:"-"),business:.init(name:record.name,city:record.city),fields:fields)
    }
}
struct AskBusinessFinding:Codable,Equatable,Sendable {
    let field:String,value:String,sourceURL:String,quote:String,title:String,verification:String
}
struct AskBusinessResult:Decodable,Sendable {
    let version:Int,state:String,business:AskBusinessIdentity,findings:[AskBusinessFinding]
    func checked(for request:AskBusinessRequest) throws -> Self {
        guard version==1,["found","unverified"].contains(state),business==request.business,findings.count<=request.fields.count,Set(findings.map(\.field)).count==findings.count,(state=="found") == !findings.isEmpty else {throw AskHostedError.invalidResponse}
        for f in findings {
            guard request.fields.contains(f.field),!f.value.isEmpty,f.value.count<=500,f.quote.count>=20,f.quote.count<=800,f.title.count<=200,f.verification=="cited_search",AskWebCitation(title:f.title,url:f.sourceURL).safeURL != nil else {throw AskHostedError.invalidResponse}
            if f.field=="instagram" {guard InstagramWebsiteParser.profileURL(f.value)==f.value else {throw AskHostedError.invalidResponse}}
            if ["website","menu"].contains(f.field) {guard InstagramWebsiteClient.websiteURL(f.value) != nil else {throw AskHostedError.invalidResponse}}
        }
        return self
    }
}
protocol AskBusinessResearching:Sendable {
    func publicLookupAvailable() async -> Bool
    func businessResearch(_ request:AskBusinessRequest) async throws -> AskBusinessResult
}
extension AskHostedProvider:AskBusinessResearching {
    func publicLookupAvailable() async -> Bool {guard await permission() else {return false};return await publicLookupEnabled()}
    func businessResearch(_ request:AskBusinessRequest) async throws -> AskBusinessResult {
        let started=DispatchTime.now().uptimeNanoseconds
        defer {AskPipelineScope.record(.research,since:started)}
        try configuration.validate();guard await permission() else {throw AskHostedError.consentRequired}
        guard await publicLookupEnabled() else {throw AskHostedError.disabled}
        try Task.checkCancellation();let credential=try await token()
        guard (43...128).contains(credential.count),credential.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0=="_" || $0=="-")}) else {throw AskHostedError.disabled}
        let data=try JSONEncoder().encode(request);guard data.count<=4096 else {throw AskError.inputLimit}
        var http=URLRequest(url:configuration.endpoint);http.httpMethod="POST";http.httpBody=data;http.timeoutInterval=220
        http.setValue("application/json",forHTTPHeaderField:"Content-Type");http.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization");http.setValue("Feast/1.0",forHTTPHeaderField:"User-Agent")
        let networkStarted=DispatchTime.now().uptimeNanoseconds
        let bytes:Data,response:HTTPURLResponse
        do {(bytes,response)=try await sendWithHistoryAccessCheck(http)}catch {AskPipelineScope.trace?.elapsed(.transport,since:networkStarted,counters:[.requestBytes:data.count]);throw error}
        AskPipelineScope.trace?.elapsed(.transport,since:networkStarted,counters:[.requestBytes:data.count,.responseBytes:bytes.count])
        try Task.checkCancellation()
        guard response.statusCode==200 else {throw AskHostedError.failure(status: response.statusCode, data: data)}
        guard response.url==configuration.endpoint,response.mimeType=="application/json",bytes.count<=16384 else {throw AskHostedError.invalidResponse}
        if let value=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] {AskBackendPerformance(value["performance"])?.record()}
        return try JSONDecoder().decode(AskBusinessResult.self,from:bytes).checked(for:request)
    }
}

enum AskBusinessLookup {
    // Known saved websites are inspected on-device with a literal-IP/TLS-hostname-pinned
    // transport. Structured official links avoid losing icon/footer evidence in search text.
    // Add Place's existing transport is unchanged; no saved URL/HTML goes to the provider.
    static func answer(_ request:AskRequest,plan:AskLibraryPlan,record:AskPersonalPlace,tools:AskReadTools,allowExternalLookups:Bool = true,allowHostedResearch:Bool = true,externalLimitation:String? = nil,researcher:any AskBusinessResearching,
                       resolvePlace:@Sendable (String) async throws -> ApplePlaceMatch? = {_ in nil},
                       inspect:@Sendable (String?,String) async throws -> InstagramWebsiteClient.Inspection = {website,name in try await AskPinnedWebsiteClient.inspection(website:website,restaurantName:name)}) async throws -> AskResponse {
        var found:[AskBusinessFinding]=[];var website=record.websiteURL.flatMap {InstagramWebsiteClient.websiteURL($0)?.absoluteString}
        if plan.fields.contains("website"),let website {found.append(.init(field:"website",value:website,sourceURL:website,quote:"Previously saved website",title:"Website",verification:"saved"))}
        if plan.fields.contains("instagram"),let profile=record.instagramURL.flatMap(InstagramWebsiteParser.profileURL) {found.append(.init(field:"instagram",value:profile,sourceURL:profile,quote:"Previously saved Instagram",title:"Instagram",verification:"saved"))}
        var remaining=plan.fields.filter {field in !found.contains {$0.field==field}}
        if !remaining.isEmpty && allowExternalLookups {
            guard await researcher.publicLookupAvailable() else {throw AskHostedError.disabled}
            try Task.checkCancellation()
            if remaining.contains("instagram"),website==nil,let placeID=record.applePlaceID,!placeID.isEmpty {
                // Resolve the exact existing Maps identity, never a name-search first match.
                // This only obtains a website for pinned inspection; it saves no metadata.
                do {
                    let started=DispatchTime.now().uptimeNanoseconds
                    defer {AskPipelineScope.record(.mapsLookup,since:started)}
                    if let matched=try await resolvePlace(placeID),matched.applePlaceID==placeID,
                       AskCityIdentity.key(matched.displayName)==AskCityIdentity.key(record.name) {
                        website=matched.websiteURL.flatMap {InstagramWebsiteClient.websiteURL($0)?.absoluteString}
                    }
                }catch is CancellationError {throw CancellationError()}
                catch { /* One unavailable Maps lookup may use the existing bounded fallback. */ }
                try Task.checkCancellation()
            }
            if remaining.contains("instagram"),let website {
                let result:InstagramWebsiteClient.Inspection
                let started=DispatchTime.now().uptimeNanoseconds
                do {defer {AskPipelineScope.record(.websiteInspection,since:started)};result=try await inspect(website,record.name)}
                try Task.checkCancellation()
                if result.status == .found,let profile=result.profile,let source=result.sourceURL,InstagramWebsiteParser.profileURL(profile)==profile,AskWebCitation(title:"Official site",url:source).safeURL != nil {
                    found.append(.init(field:"instagram",value:profile,sourceURL:source,quote:"Linked by the business website",title:"Official site",verification:"official_website"))
                }
            }
            remaining=plan.fields.filter {field in !found.contains {$0.field==field}}
        }
        var unavailable=false
        if !remaining.isEmpty && allowExternalLookups && allowHostedResearch {
            guard let trace=request.performanceID else {throw AskError.invalidEvidence}
            let publicRequest=try AskBusinessRequest.make(trace:trace,attempt:AskProviderAttemptScope.lease?.attempt,record:record,fields:remaining)
            do {let result=try await researcher.businessResearch(publicRequest).checked(for:publicRequest);found+=result.findings}
            catch is CancellationError {throw CancellationError()}
            catch {if found.isEmpty {throw error};unavailable=true}
        }
        try Task.checkCancellation()
        guard let candidate=tools.localCandidate(record.id) else {throw AskError.invalidEvidence}
        var paragraphs:[AskAnswerParagraph]=[]
        for (i,f) in found.enumerated() {
            let isLink=["instagram","website","menu"].contains(f.field)
            var citations:[AskWebCitation]=[]
            if isLink {citations.append(.init(title:f.field.capitalized,url:f.value))}
            if !isLink || f.sourceURL != f.value {citations.append(.init(title:f.title,url:f.sourceURL))}
            let label=f.field=="instagram" ? "Instagram @"+(URL(string:f.value)?.lastPathComponent ?? "") : f.verification=="saved" ? "Saved \(f.field)" : f.field.capitalized
            paragraphs.append(.init(id:"business-fact-\(i)",spans:[.place(record.id),.text(" — \(label)"+(isLink ? "" : ": "+f.value))],sourceIDs:candidate.sourceIDs,citations:citations,representedField:f.field))
        }
        let missing=plan.fields.filter {field in !found.contains {$0.field==field}}
        if !missing.isEmpty {
            let text=unavailable ? "I couldn’t check the remaining details right now." : (!allowExternalLookups || !allowHostedResearch) ? (externalLimitation ?? "I couldn’t verify these details for this specific branch.") : "I couldn’t verify \(missing.joined(separator:", ")) for this place."
            paragraphs.append(.init(id:"business-unverified",spans:[.place(record.id),.text((record.neighborhood.isEmpty ? "" : " ("+record.neighborhood+")")+" — "+text)],sourceIDs:candidate.sourceIDs,transientToolStatus:true))
        }
        var response=AskResponse(summary:found.isEmpty ? "No verified public match." : "Public business details.",candidates:[candidate],paragraphs:paragraphs,listedCandidateIDs:[],usesLocalCatalog:true)
        response.verifiedPublicFindings=found.map {f in .init(id:UUID(),recordID:record.id,identity:.init(record),field:f.field,value:f.value,evidenceURL:f.sourceURL,verification:f.verification,originatingTurn:request.performanceID ?? UUID())}
        response.fieldActions=found.filter {$0.field == "instagram"}.map { f in
            .init(finding:.init(id:UUID(),recordID:record.id,identity:.init(record),field:f.field,value:f.value,evidenceURL:f.sourceURL,verification:f.verification,originatingTurn:request.performanceID ?? UUID()),outcome:f.verification == "saved" ? .alreadySaved : .ready)
        }
        response.libraryContext = .init(ids:[record.id],filters:plan)
        return try tools.checked(response)
    }
}
