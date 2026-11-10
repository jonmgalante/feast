import Foundation

/// Accepted conversational state, not an authorization token. Current-turn grants are never restored.
struct AskAgentOutcome:Codable,Equatable,Sendable {let id:String,state:String}
struct AskAgentTask:Codable,Equatable,Sendable {
    let action:String
    let fields:[String]
    let orderedIDs:[String]
    let sourcePolicy:String
    var privateSelection:Bool? = nil
    var outcomes:[AskAgentOutcome]? = nil
    var selectionIDs:[String]? = nil // Full aggregate membership, on device only; never an ordinal list.
    var referencesIncomplete:Bool? = nil // Local-only: an unresolved/ambiguous displayed reference must not silently shift positions.
    var externalProjection:Self {
        let privateScope=privateSelection ?? (sourcePolicy=="local_only")
        return .init(action:action,fields:fields.filter {!["note","tags","status"].contains($0)},orderedIDs:privateScope ? [] : orderedIDs,sourcePolicy:sourcePolicy,privateSelection:privateScope,outcomes:privateScope ? nil : outcomes)
    }
    func projection(fullCollection:Bool)->Self {
        guard fullCollection else{return externalProjection}
        return .init(action:action,fields:fields,orderedIDs:orderedIDs,sourcePolicy:sourcePolicy,privateSelection:false,outcomes:outcomes)
    }
    func checked()throws->Self {
        guard ["query","research","change"].contains(action),["stored_only","public_if_missing","local_only"].contains(sourcePolicy),fields.count<=11,orderedIDs.count<=AskCollectionPage.maximumRenderedRecords,Set(orderedIDs).count==orderedIDs.count,orderedIDs.allSatisfy({UUID(uuidString:$0) != nil}) else {throw AskError.invalidEvidence}
        if let selectionIDs {guard orderedIDs.isEmpty,Set(selectionIDs).count==selectionIDs.count,selectionIDs.allSatisfy({UUID(uuidString:$0) != nil}) else{throw AskError.invalidEvidence}}
        return self
    }
}
struct AskAgentRecord:Codable,Equatable,Sendable {
    let id,name,city:String;let cuisines:[String];let kind:String;var detail:String?=nil
    var neighborhood:String?=nil,status:String?=nil,placeType:String?=nil,note:String?=nil,tags:[String]?=nil,website:String?=nil,instagram:String?=nil
    // Wire null means requested and confirmed absent. Omission means not requested
    // or unavailable, never a missing saved value. This bookkeeping stays local.
    var missingFields:[String]=[]
    enum CodingKeys:String,CodingKey {case id,name,city,cuisines,kind,detail,neighborhood,status,placeType,note,tags,website,instagram}
    static func collection(_ record:AskPersonalPlace)->Self {
        .init(id:record.id,name:record.name,city:record.city,cuisines:record.cuisines,kind:"place",neighborhood:record.neighborhood,status:record.status,placeType:record.type,note:record.note,tags:record.tags,website:record.websiteURL,instagram:record.instagramURL)
    }
    static func collection(_ record:AskPersonalPlace,fields:[String])->Self {
        var value=Self(id:record.id,name:record.name,city:record.city,cuisines:record.cuisines,kind:"place")
        var missing:[String]=[]
        func stored(_ raw:String?,key:String)->String? {
            guard raw?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false else {missing.append(key);return nil}
            return raw
        }
        for field in fields {
            switch field {
            case "neighborhood":value.neighborhood=stored(record.neighborhood,key:"neighborhood")
            case "status":value.status=stored(record.status,key:"status")
            case "type":value.placeType=stored(record.type,key:"placeType")
            case "note":value.note=stored(record.note,key:"note")
            case "tags":value.tags=record.tags;if record.tags==nil {missing.append("tags")}
            case "website":value.website=stored(record.websiteURL,key:"website")
            case "instagram":value.instagram=stored(record.instagramURL,key:"instagram")
            default:continue // Required identity stays; unsupported fields are not falsely null.
            }
        }
        value.missingFields=missing.sorted()
        return value
    }
}
extension AskAgentRecord {
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(id:try c.decode(String.self,forKey:.id),name:try c.decode(String.self,forKey:.name),city:try c.decode(String.self,forKey:.city),cuisines:try c.decode([String].self,forKey:.cuisines),kind:try c.decode(String.self,forKey:.kind))
        detail=try c.decodeIfPresent(String.self,forKey:.detail)
        neighborhood=try c.decodeIfPresent(String.self,forKey:.neighborhood);status=try c.decodeIfPresent(String.self,forKey:.status);placeType=try c.decodeIfPresent(String.self,forKey:.placeType)
        note=try c.decodeIfPresent(String.self,forKey:.note);tags=try c.decodeIfPresent([String].self,forKey:.tags);website=try c.decodeIfPresent(String.self,forKey:.website);instagram=try c.decodeIfPresent(String.self,forKey:.instagram)
        for key:CodingKeys in [.neighborhood,.status,.placeType,.note,.tags,.website,.instagram] where c.contains(key) {if try c.decodeNil(forKey:key) {missingFields.append(key.rawValue)}}
        missingFields.sort()
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(name,forKey:.name);try c.encode(city,forKey:.city);try c.encode(cuisines,forKey:.cuisines);try c.encode(kind,forKey:.kind)
        try c.encodeIfPresent(detail,forKey:.detail)
        try c.encodeIfPresent(neighborhood,forKey:.neighborhood);try c.encodeIfPresent(status,forKey:.status);try c.encodeIfPresent(placeType,forKey:.placeType)
        try c.encodeIfPresent(note,forKey:.note);try c.encodeIfPresent(tags,forKey:.tags);try c.encodeIfPresent(website,forKey:.website);try c.encodeIfPresent(instagram,forKey:.instagram)
        for field in missingFields {if let key=CodingKeys(rawValue:field) {try c.encodeNil(forKey:key)}}
    }
}
struct AskAgentFinding:Codable,Equatable,Sendable {let id,recordID,field,value,sourceURL:String}
struct AskAgentResult:Codable,Equatable,Sendable {
    let status:String,complete:Bool,totalCount:Int
    let records:[AskAgentRecord],findings:[AskAgentFinding]
    let message:String,localOnly:Bool
    var offset:Int?=nil,returnedCount:Int?=nil,nextOffset:Int?=nil
    var snapshot:String?=nil,summary:String?=nil
    static func localPrivate(complete:Bool=true)->Self {.init(status:"local_only",complete:complete,totalCount:0,records:[],findings:[],message:"private_result",localOnly:true)}
}
struct AskAgentReply:Decodable,Sendable {
    struct Call:Codable,Sendable {let name,callID,arguments:String}
    let version:Int,requestID:String,step:Int
    let call:Call
    let continuation:String
    let model:String
}
struct AskAgentCity:Codable,Sendable {let id,name:String}
struct AskAgentStep:Encodable,Sendable {
    struct Result:Encodable,Sendable {let callID:String;let output:AskAgentResult}
    let version=8,mode="agentStep"
    let requestID:String,step:Int,text:String
    let context:AskSemanticContext
    let cities:[AskAgentCity]
    let task:AskAgentTask?
    let findings:[AskAgentFinding]
    let continuation:String?
    let result:Result?
}
protocol AskAgentPlanning:Sendable {
    func agentStep(_ step:AskAgentStep) async throws -> AskAgentReply
    func agentAvailable() async -> Bool
}
extension AskAgentPlanning {func agentAvailable()async->Bool {false}}
extension AskHostedProvider:AskAgentPlanning {
    func agentAvailable()async->Bool {
        guard await permission() else{return false}
        var version=await libraryPlanVersion()
        if version<6 {await prepareCapabilities();version=await libraryPlanVersion()}
        let stillAllowed=await permission();return stillAllowed && version>=5
    }
    func agentStep(_ step:AskAgentStep) async throws -> AskAgentReply {
        try configuration.validate()
        guard configuration.scope == .savedMetadata,await permission(),await libraryToolsEnabled(),step.step>=0,step.step<6 else {throw AskHostedError.consentRequired}
        try Task.checkCancellation()
        let credential=try await token()
        guard (43...128).contains(credential.count),credential.allSatisfy({$0.isASCII&&($0.isLetter||$0.isNumber||$0=="_"||$0=="-")}) else {throw AskHostedError.disabled}
        let encoded=try JSONEncoder().encode(step)
        guard var payload=try JSONSerialization.jsonObject(with:encoded) as? [String:Any] else {throw AskError.invalidEvidence}
        for key in ["task","continuation","result"] where payload[key]==nil {payload[key]=NSNull()}
        let body=try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)
        guard body.count<=512000 else {throw AskError.inputLimit}
        var http=URLRequest(url:configuration.endpoint);http.httpMethod="POST";http.httpBody=body;http.timeoutInterval=220
        http.setValue("8",forHTTPHeaderField:"X-Feast-Agent-Protocol");http.setValue("application/json",forHTTPHeaderField:"Content-Type");http.setValue("Feast/1.0",forHTTPHeaderField:"User-Agent");http.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization")
        let (data,response)=try await send(http);try Task.checkCancellation()
        guard response.statusCode==200 else {throw AskHostedError.failure(status: response.statusCode, data: data)}
        guard response.url==configuration.endpoint,response.mimeType=="application/json",data.count<=400000 else {throw AskHostedError.invalidResponse}
        let value=try JSONDecoder().decode(AskAgentReply.self,from:data)
        guard value.version==8,value.requestID==step.requestID,value.step==step.step,value.continuation.utf8.count<=350000,value.call.arguments.utf8.count<=32000,value.call.callID.count<=200,(value.model=="gpt-6-astra"||value.model.hasPrefix("gpt-6-astra-")||value.model=="gpt-6.1-sol"||value.model.hasPrefix("gpt-6.1-sol-")),(step.step==0)==(value.call.name=="interpret_request") else {throw AskHostedError.invalidResponse}
        return value
    }
}
