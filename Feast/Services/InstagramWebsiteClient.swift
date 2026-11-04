import Foundation
import Darwin

nonisolated enum InstagramWebsiteClient {
    static let maximumBytes = 524_288

    static func websiteURL(_ raw: String) -> URL? {
        guard var parts = URLComponents(string: raw) else { return nil }
        // MapKit can supply an HTTP website; only attempt its HTTPS equivalent.
        if parts.scheme?.lowercased() == "http", parts.port == nil { parts.scheme = "https" }
        guard parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host.contains("."), !host.hasSuffix("."),
              host.range(of: #"^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,63}$"#, options: .regularExpression) != nil,
              !["localhost", "local", "internal", "lan", "home", "test", "invalid", "example"].contains(host.split(separator: ".").last.map(String.init) ?? "") else { return nil }
        return parts.url
    }

    static func publicAddress(_ raw: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, raw, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            guard ![0, 10, 127].contains(b[0]), b[0] < 224,
                  !(b[0] == 100 && (64...127).contains(b[1])), !(b[0] == 169 && b[1] == 254),
                  !(b[0] == 172 && (16...31).contains(b[1])), !(b[0] == 192 && [0, 168].contains(b[1])),
                  !(b[0] == 198 && [18, 19, 51].contains(b[1])), !(b[0] == 203 && b[1] == 0 && b[2] == 113) else { return false }
            return true
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, raw, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        return b[0] & 0xe0 == 0x20 && !(b[0] == 0x20 && b[1] == 0x02) &&
            !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8)
    }

    static func publicHost(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = DNSResultGate(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { gate.finish(false) }
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
                var addresses: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else { gate.finish(false); return }
                defer { freeaddrinfo(first) }
                var current: UnsafeMutablePointer<addrinfo>? = first
                var found = false
                while let item = current {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                          publicAddress(String(cString: buffer)) else { gate.finish(false); return }
                    found = true; current = item.pointee.ai_next
                }
                gate.finish(found)
            }
        }
    }

    static func acceptsResponse(status: Int, mimeType: String?, length: Int64) -> Bool {
        status == 200 && ["text/html", "application/xhtml+xml"].contains(mimeType?.lowercased() ?? "") && length <= maximumBytes
    }

    static func redirectURL(_ raw: String, from host: String, number: Int) -> URL? {
        guard number <= 2, let url = websiteURL(raw),
              InstagramWebsiteParser.baseHost(url.host) == InstagramWebsiteParser.baseHost(host) else { return nil }
        return url
    }

    struct Inspection:Equatable,Sendable {
        enum Status:String,Sendable {case found,unverified,unavailable,unsafe,missing}
        let status:Status
        var profile:String? = nil
        var sourceURL:String? = nil
    }
    static func profile(website raw: String?, restaurantName: String,
                        sessionConfiguration: URLSessionConfiguration? = nil,
                        validateHost: @escaping @Sendable (String) async -> Bool = { host in await publicHost(host) }) async -> String? {
        try? await inspection(website:raw,restaurantName:restaurantName,sessionConfiguration:sessionConfiguration,validateHost:validateHost).profile
    }
    static func inspection(website raw: String?, restaurantName: String,
                        sessionConfiguration: URLSessionConfiguration? = nil,
                        validateHost: @escaping @Sendable (String) async -> Bool = { host in await publicHost(host) }) async throws -> Inspection {
        try Task.checkCancellation()
        guard let raw,!raw.isEmpty else {return .init(status:.missing)}
        guard let url = websiteURL(raw), let host = url.host,await validateHost(host) else {return .init(status:.unsafe)}
        try Task.checkCancellation()
        let policy = WebsiteRedirectPolicy(host: host, validateHost: validateHost)
        let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: policy)
            guard let http = response as? HTTPURLResponse,
                  acceptsResponse(status: http.statusCode, mimeType: http.mimeType, length: response.expectedContentLength) else { return .init(status:.unavailable) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { return .init(status:.unavailable) }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let finalURL = response.url else { return .init(status:.unavailable) }
            guard let profile=InstagramWebsiteParser.profile(in:html,restaurantName:restaurantName,website:finalURL) else {return .init(status:.unverified,sourceURL:finalURL.absoluteString)}
            return .init(status:.found,profile:profile,sourceURL:finalURL.absoluteString)
        } catch is CancellationError {throw CancellationError()} catch {return .init(status:.unavailable)}
    }
}

nonisolated private final class DNSResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ result: Bool) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: result)
    }
}

nonisolated private final class WebsiteRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private let validateHost: @Sendable (String) async -> Bool
    private let lock = NSLock()
    private var redirects = 0
    init(host: String, validateHost: @escaping @Sendable (String) async -> Bool) { self.host = host; self.validateHost = validateHost }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let number = redirects; lock.unlock()
        guard let raw = request.url?.absoluteString, let url = InstagramWebsiteClient.redirectURL(raw, from: host, number: number), let newHost = url.host else {
            completionHandler(nil); return
        }
        Task {
            let allowed = await validateHost(newHost)
            completionHandler(allowed && !Task.isCancelled ? request : nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
