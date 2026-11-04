import Foundation

nonisolated final class FixtureWebsiteProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/stall" { return }
        let good = #"<script type="application/ld+json">{"@type":"Restaurant","name":"Fixture Cafe","sameAs":["https://instagram.com/fixture_cafe/"]}</script>"#
        let data = Data((["/large", "/stream-large"].contains(path) ? String(repeating: "a", count: InstagramWebsiteClient.maximumBytes + 1) : good).utf8)
        var headers = ["Content-Type": path == "/bad-type" ? "image/png" : "text/html", "Content-Length": "\(data.count)"]
        if path == "/stream-large" { headers.removeValue(forKey: "Content-Length") }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/bad-status" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor enum InstagramAutofillTests {
    static func run() async {
        try! await AskPinnedWebsiteTests.run()
        let site = URL(string: "https://restaurant.example.org")!
        func parse(_ html: String, name: String = "Fixture Cafe") -> String? { InstagramWebsiteParser.profile(in: html, restaurantName: name, website: site) }
        let profile = "https://www.instagram.com/fixture_cafe/"
        let structured = #"<script type="application/ld+json">{"@graph":[{"@type":"Restaurant","name":"Fixture Cafe","url":"https://restaurant.example.org","sameAs":["https://instagram.com/fixture_cafe/?hl=en"]}]}</script>"#
        precondition(parse(structured) == profile)
        precondition(parse(structured, name: "Different Restaurant") == nil)
        precondition(parse(structured.replacingOccurrences(of: "restaurant.example.org", with: "different.example.org")) == nil)
        let footer = #"<title>Fixture Cafe | New York</title><footer><a aria-label="Instagram" href="https://instagram.com/fixture_cafe/">Instagram</a></footer>"#
        precondition(parse(footer) == profile)
        precondition(parse(footer + #"<a href="https://instagram.com/parent_group/">Our Group</a>"#) == nil)
        precondition(parse(footer.replacingOccurrences(of: "<footer>", with: "<footer>Website design by ")) == nil)
        precondition(parse(footer.replacingOccurrences(of: "<footer>", with: "<footer>Our restaurants group ")) == nil)
        precondition(parse("<title>Fixture Cafe</title><p>No social links</p>") == nil)
        precondition(parse("<script type='application/ld+json'>{bad JSON}</script>") == nil)
        for bad in ["https://instagram.com/p/123", "https://instagram.com/reel/123", "https://instagram.com/stories/user/1", "https://instagram.com/accounts/login", "https://instagram.com/share", "https://instagram.com.evil.org/cafe", "https://instagram.com/@cafe", "https://user:pass@instagram.com/cafe", "https://instagram.com/%63afe"] {
            precondition(InstagramWebsiteParser.profileURL(bad) == nil)
        }
        print("PASS Instagram attributable JSON-LD/footer profile parsing; ambiguity, parent/designer links and non-profile URL rejection")
        for bad in ["http://example.org:80", "https://127.0.0.1", "https://[::1]", "https://localhost", "https://a.local", "https://a.internal", "https://user:pass@example.org", "https://example.org:8080"] {
            precondition(InstagramWebsiteClient.websiteURL(bad) == nil)
        }
        precondition(InstagramWebsiteClient.websiteURL("http://example.org")?.scheme == "https")
        for bad in ["127.0.0.1", "10.0.0.2", "172.16.2.3", "192.168.1.2", "169.254.2.3", "100.64.0.1", "::1", "fe80::1", "fc00::1", "::ffff:127.0.0.1", "2001:db8::1"] {
            precondition(!InstagramWebsiteClient.publicAddress(bad))
        }
        precondition(InstagramWebsiteClient.publicAddress("8.8.8.8"))
        precondition(InstagramWebsiteClient.publicAddress("2606:4700:4700::1111"))
        precondition(InstagramWebsiteClient.redirectURL("https://www.example.org/path", from: "example.org", number: 2) != nil)
        precondition(InstagramWebsiteClient.redirectURL("https://www.example.org", from: "example.org", number: 3) == nil)
        precondition(InstagramWebsiteClient.redirectURL("https://other.org", from: "example.org", number: 1) == nil)
        print("PASS website HTTPS/credential/host/private-address checks and bounded same-site redirect policy")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureWebsiteProtocol.self]
        for path in ["good", "bad-status", "bad-type", "large", "stream-large"] {
            let result = await InstagramWebsiteClient.profile(website: "https://restaurant.example.org/" + path, restaurantName: "Fixture Cafe", sessionConfiguration: configuration, validateHost: { _ in true })
            precondition(path == "good" ? result == profile : result == nil)
        }
        let cancelled = Task { await InstagramWebsiteClient.profile(website: "https://restaurant.example.org/stall", restaurantName: "Fixture Cafe", sessionConfiguration: configuration, validateHost: { _ in true }) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil)
        let start = Date()
        let timedOut = await InstagramWebsiteClient.profile(website: "https://restaurant.example.org/stall", restaurantName: "Fixture Cafe", sessionConfiguration: configuration, validateHost: { _ in true })
        precondition(timedOut == nil && Date().timeIntervalSince(start) < 10)
        print("PASS bounded HTML transport with fixture success, bad HTTP/MIME, oversize and cancellation")
        var earlyEdit = InstagramAutofillGuard(identity: "Early")
        earlyEdit.edited(); let earlyToken = earlyEdit.begin(identity: "Early")
        precondition(!earlyEdit.accepts(identity: "Early", token: earlyToken, currentText: "", cancelled: false))
        var guardState = InstagramAutofillGuard()
        let token = guardState.begin(identity: "A")
        precondition(guardState.accepts(identity: "A", token: token, currentText: "", cancelled: false))
        guardState.edited()
        precondition(!guardState.accepts(identity: "A", token: token, currentText: "", cancelled: false)) // deliberately cleared
        let newToken = guardState.begin(identity: "B")
        precondition(!guardState.accepts(identity: "A", token: token, currentText: "", cancelled: false))
        precondition(!guardState.accepts(identity: "B", token: newToken, currentText: "typed", cancelled: false))
        precondition(!guardState.accepts(identity: "B", token: newToken, currentText: "", cancelled: true))
        guardState.close()
        precondition(!guardState.accepts(identity: "B", token: newToken, currentText: "", cancelled: false))
        print("PASS Instagram autofill protects typed/cleared text, changed identities, cancellation and closed/saved forms")
    }
}
