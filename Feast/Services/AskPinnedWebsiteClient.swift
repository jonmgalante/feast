import Foundation
import Network
import Security
import Darwin

/// Ask-only HTTPS transport. Resolve once, reject private/mixed answers, connect to
/// that literal address and validate TLS for the original hostname. No URLSession
/// re-resolution, credentials/cookies, arbitrary port, or cross-site redirect.
nonisolated enum AskPinnedWebsiteClient {
    struct Response:Sendable {let status:Int;let headers:[String:String];let body:Data}
    static let maximumBody=2_097_152,maximumWire=3_200_000,maximumHeader=32_768
    static func response(_ bytes:Data,eof:Bool,interim:Int = 0) throws -> Response? {
        let separator=Data("\r\n\r\n".utf8)
        guard interim<=3,bytes.count<=maximumWire else {throw URLError(.dataLengthExceedsMaximum)}
        guard let split=bytes.range(of:separator) else {
            if bytes.count>maximumHeader || eof {throw URLError(.badServerResponse)};return nil
        }
        guard split.lowerBound<=maximumHeader,let head=String(data:bytes[..<split.lowerBound],encoding:.isoLatin1) else {throw URLError(.badServerResponse)}
        let lines=head.components(separatedBy:"\r\n"),first=lines[0].split(separator:" ")
        guard first.count>=2,["HTTP/1.1","HTTP/1.0"].contains(String(first[0])),let status=Int(first[1]),(100...599).contains(status) else {throw URLError(.badServerResponse)}
        var headers:[String:String]=[:]
        for line in lines.dropFirst() {
            guard let colon=line.firstIndex(of:":"),line.first != " ",line.first != "\t" else {throw URLError(.badServerResponse)}
            let key=String(line[..<colon]).lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard !key.isEmpty,key.utf8.allSatisfy({(48...57).contains($0)||(97...122).contains($0)||"!#$%&'*+-.^_`|~".utf8.contains($0)}),!value.unicodeScalars.contains(where:{$0.value<32 && $0.value != 9 || $0.value==127}) else {throw URLError(.badServerResponse)}
            if headers[key] != nil && ["content-length","transfer-encoding","location","content-encoding"].contains(key) {throw URLError(.badServerResponse)}
            headers[key]=value
        }
        if status<200 {
            guard status != 101,headers["content-length"]==nil,headers["transfer-encoding"]==nil else {throw URLError(.badServerResponse)}
            return try response(Data(bytes[split.upperBound...]),eof:eof,interim:interim+1)
        }
        guard headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased()=="identity" else {throw URLError(.cannotDecodeContentData)}
        let raw=Data(bytes[split.upperBound...]);var body=Data()
        if let transfer=headers["transfer-encoding"] {
            guard transfer.lowercased()=="chunked",headers["content-length"]==nil else {throw URLError(.badServerResponse)}
            var offset=0
            while true {
                guard let end=raw.range(of:Data("\r\n".utf8),in:offset..<raw.count) else {if eof {throw URLError(.badServerResponse)};return nil}
                guard end.lowerBound-offset<=128,let line=String(data:raw[offset..<end.lowerBound],encoding:.ascii),let token=line.split(separator:";",maxSplits:1).first,token.allSatisfy({$0.isHexDigit}),let size=Int(token,radix:16),size<=maximumBody else {throw URLError(.badServerResponse)}
                offset=end.upperBound
                if size==0 {
                    guard raw.count>=offset+2 else {if eof {throw URLError(.badServerResponse)};return nil}
                    if raw[offset..<offset+2] != Data("\r\n".utf8) {
                        guard let trailers=raw.range(of:separator,in:offset..<raw.count),trailers.upperBound-offset<=8192 else {if eof {throw URLError(.badServerResponse)};return nil}
                    }
                    break
                }
                guard body.count+size<=maximumBody else {throw URLError(.dataLengthExceedsMaximum)}
                guard raw.count>=offset+size+2 else {if eof {throw URLError(.badServerResponse)};return nil}
                guard raw[offset+size..<offset+size+2]==Data("\r\n".utf8) else {throw URLError(.badServerResponse)}
                body.append(raw[offset..<offset+size]);offset+=size+2
            }
        } else if let length=headers["content-length"] {
            guard !length.isEmpty,length.allSatisfy({$0.isNumber}),let count=Int(length),count<=maximumBody else {throw URLError(.badServerResponse)}
            guard raw.count>=count else {if eof {throw URLError(.badServerResponse)};return nil}
            guard raw.count==count else {throw URLError(.badServerResponse)};body=raw
        } else {guard raw.count<=maximumBody else {throw URLError(.dataLengthExceedsMaximum)};guard eof else {return nil};body=raw}
        return .init(status:status,headers:headers,body:body)
    }
    static func addresses(_ host:String) async -> [String]? {
        await withCheckedContinuation { continuation in
            let gate=AskDNSGate(continuation)
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+2) {gate.finish(nil)}
            DispatchQueue.global(qos:.utility).async {
                var hints=addrinfo();hints.ai_socktype=SOCK_STREAM;hints.ai_protocol=IPPROTO_TCP
                var result:UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host,nil,&hints,&result)==0,let first=result else {gate.finish(nil);return}
                defer {freeaddrinfo(first)}
                var cursor:UnsafeMutablePointer<addrinfo>?=first,addresses:[String]=[]
                while let item=cursor {
                    var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST))
                    guard getnameinfo(item.pointee.ai_addr,item.pointee.ai_addrlen,&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0 else {gate.finish(nil);return}
                    let address=String(cString:buffer)
                    guard InstagramWebsiteClient.publicAddress(address) else {gate.finish(nil);return}
                    if !addresses.contains(address) {addresses.append(address)};cursor=item.pointee.ai_next
                }
                gate.finish(addresses.isEmpty ? nil : addresses)
            }
        }
    }
    static func inspection(website raw:String?,restaurantName:String,
        resolve:@escaping @Sendable(String) async -> [String]? = {await addresses($0)},
        exchange:@escaping @Sendable(URL,String) async throws -> Response = {url,ip in try await connected(url,ip:ip)}) async throws -> InstagramWebsiteClient.Inspection {
        guard let raw,!raw.isEmpty else {return .init(status:.missing)}
        guard var url=InstagramWebsiteClient.websiteURL(raw),let originalHost=url.host else {return .init(status:.unsafe)}
        for redirect in 0...2 {
            try Task.checkCancellation()
            guard let host=url.host,let ips=await resolve(host),!ips.isEmpty,ips.allSatisfy(InstagramWebsiteClient.publicAddress) else {return .init(status:.unsafe)}
            try Task.checkCancellation()
            do {
                // Two validated literal addresses at most; never a provider retry.
                // IPv4 first avoids stalling on advertised-but-unreachable IPv6.
                let ordered=ips.sorted {($0.contains(":" ) ? 1:0)<($1.contains(":") ? 1:0)}
                var received:Response?
                for ip in ordered.prefix(2) {
                    try Task.checkCancellation()
                    do {received=try await exchange(url,ip);break}
                    catch is CancellationError {throw CancellationError()}
                    catch {continue}
                }
                guard let result=received else {return .init(status:.unavailable)}
                try Task.checkCancellation()
                if [301,302,303,307,308].contains(result.status) {
                    guard redirect<2,let location=result.headers["location"],let target=URL(string:location,relativeTo:url)?.absoluteURL,
                          let safe=InstagramWebsiteClient.redirectURL(target.absoluteString,from:originalHost,number:redirect+1) else {return .init(status:.unsafe)}
                    url=safe;continue
                }
                let mime=result.headers["content-type"]?.split(separator:";").first.map(String.init)
                guard result.status==200,["text/html","application/xhtml+xml"].contains(mime?.lowercased() ?? ""),result.body.count<=maximumBody,let html=String(data:result.body,encoding:.utf8) ?? String(data:result.body,encoding:.isoLatin1) else {return .init(status:.unavailable)}
                guard let profile=InstagramWebsiteParser.profile(in:html,restaurantName:restaurantName,website:url,savedBusinessWebsite:true) else {return .init(status:.unverified,sourceURL:url.absoluteString)}
                return .init(status:.found,profile:profile,sourceURL:url.absoluteString)
            }catch is CancellationError {throw CancellationError()}catch {return .init(status:.unavailable)}
        }
        return .init(status:.unavailable)
    }
    static func connected(_ url:URL,ip:String) async throws -> Response {
        let operation=try AskHTTPSExchange(url:url,ip:ip)
        return try await withTaskCancellationHandler(operation:{try await operation.run()},onCancel:{operation.cancel()})
    }
}
nonisolated private final class AskDNSGate:@unchecked Sendable {
    private let lock=NSLock();private var continuation:CheckedContinuation<[String]?,Never>?
    init(_ continuation:CheckedContinuation<[String]?,Never>) {self.continuation=continuation}
    func finish(_ addresses:[String]?) {lock.lock();let pending=continuation;continuation=nil;lock.unlock();pending?.resume(returning:addresses)}
}
nonisolated private final class AskHTTPSExchange:@unchecked Sendable {
    private let connection:NWConnection,request:Data,queue=DispatchQueue(label:"Feast.AskPinnedHTTPS")
    private let lock=NSLock();private var continuation:CheckedContinuation<AskPinnedWebsiteClient.Response,Error>?,finished=false
    private var buffer=Data()
    init(url:URL,ip:String) throws {
        guard InstagramWebsiteClient.websiteURL(url.absoluteString) != nil,let hostname=url.host,InstagramWebsiteClient.publicAddress(ip) else {throw URLError(.unsupportedURL)}
        let host:NWEndpoint.Host
        if let address=IPv4Address(ip) {host = .ipv4(address)}else if let address=IPv6Address(ip) {host = .ipv6(address)}else {throw URLError(.badURL)}
        let tls=NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions,hostname)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions,"http/1.1")
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions,{_,trust,complete in
            let value=sec_trust_copy_ref(trust).takeRetainedValue()
            let policy=SecPolicyCreateSSL(true,hostname as CFString)
            complete(SecTrustSetPolicies(value,policy)==errSecSuccess && SecTrustEvaluateWithError(value,nil))
        },DispatchQueue.global(qos:.utility))
        connection=NWConnection(host:host,port:443,using:NWParameters(tls:tls,tcp:NWProtocolTCP.Options()))
        let components=URLComponents(url:url,resolvingAgainstBaseURL:false)!,path=components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target=path+(components.percentEncodedQuery.map {"?"+$0} ?? "")
        request=Data("GET \(target) HTTP/1.1\r\nHost: \(hostname)\r\nAccept: text/html, application/xhtml+xml\r\nAccept-Encoding: identity\r\nConnection: close\r\nUser-Agent: Feast/1.0\r\n\r\n".utf8)
    }
    func run() async throws -> AskPinnedWebsiteClient.Response {
        try await withCheckedThrowingContinuation { pending in
            lock.lock();if finished {lock.unlock();pending.resume(throwing:CancellationError());return};continuation=pending;lock.unlock()
            connection.stateUpdateHandler={ [weak self] state in
                guard let self else {return}
                switch state {
                case .ready:self.connection.send(content:self.request,completion:.contentProcessed { [weak self] error in
                    if let error {self?.finish(.failure(error))}else {self?.receive()}
                })
                case .failed(let error):self.finish(.failure(error))
                case .cancelled:self.finish(.failure(CancellationError()))
                default:break
                }
            }
            queue.asyncAfter(deadline:.now()+7) { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
            connection.start(queue:queue)
        }
    }
    func cancel() {finish(.failure(CancellationError()))}
    private func finish(_ result:Result<AskPinnedWebsiteClient.Response,Error>) {
        lock.lock();guard !finished else {lock.unlock();return};finished=true;let pending=continuation;continuation=nil;lock.unlock()
        connection.stateUpdateHandler=nil;connection.cancel();pending?.resume(with:result)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength:1,maximumLength:32768) { [weak self] data,_,complete,error in
            guard let self else {return}
            if let error {self.finish(.failure(error));return}
            if let data {self.buffer.append(data)}
            do {
                if let response=try AskPinnedWebsiteClient.response(self.buffer,eof:complete) {self.finish(.success(response))}
                else {self.receive()}
            }catch {self.finish(.failure(error))}
        }
    }
}
