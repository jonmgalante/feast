import Foundation

nonisolated enum InstagramWebsiteParser {
    static func profileURL(_ raw: String) -> String? {
        let value = raw.replacingOccurrences(of: "&amp;", with: "&")
        guard var url = URLComponents(string: value.hasPrefix("//") ? "https:" + value : value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["instagram.com", "www.instagram.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              !url.percentEncodedPath.contains("%") else { return nil }
        let pieces = url.path.split(separator: "/")
        let reserved = ["p", "reel", "reels", "stories", "story", "accounts", "login", "share", "explore", "direct", "about", "developer", "legal", "privacy", "tv"]
        guard pieces.count == 1 else { return nil }
        let handle = String(pieces[0]).lowercased()
        guard !reserved.contains(handle), handle.range(of: "^[a-z0-9._]{1,30}$", options: .regularExpression) != nil else { return nil }
        url.scheme = "https"; url.host = "www.instagram.com"; url.path = "/" + handle + "/"; url.query = nil; url.fragment = nil
        return url.string
    }

    static func profile(in html: String, restaurantName: String, website: URL, savedBusinessWebsite:Bool = false) -> String? {
        func identity(_ value:String) -> String {
            let name=normalized(value)
            return savedBusinessWebsite && name.hasPrefix("the ") ? String(name.dropFirst(4)) : name
        }
        let expectedName = identity(restaurantName)
        guard !expectedName.isEmpty else { return nil }
        var attributable: Set<String> = []
        var allProfiles: Set<String> = []
        let types: Set<String> = ["restaurant", "localbusiness", "foodestablishment", "cafeorcoffeeshop", "barorpub", "bakery"]
        func visit(_ value: Any) {
            if let array = value as? [Any] { array.forEach(visit); return }
            guard let node = value as? [String: Any] else { return }
            let sameAs = (node["sameAs"] as? [String]) ?? (node["sameAs"] as? String).map { [$0] } ?? []
            let profiles = Set(sameAs.compactMap(profileURL))
            allProfiles.formUnion(profiles)
            let nodeTypes = (node["@type"] as? [String]) ?? (node["@type"] as? String).map { [$0] } ?? []
            let businessType = nodeTypes.contains { types.contains($0.split(separator: "/").last.map(String.init)?.lowercased() ?? "") }
            let organization = nodeTypes.contains { $0.split(separator:"/").last?.lowercased() == "organization" }
            let nodeHost = (node["url"] as? String).flatMap(URL.init(string:))?.host
            let matchingType = businessType || (savedBusinessWebsite && organization && nodeHost != nil && baseHost(nodeHost) == baseHost(website.host))
            if matchingType, node["parentOrganization"] == nil, identity(node["name"] as? String ?? "") == expectedName,
               nodeHost == nil || baseHost(nodeHost) == baseHost(website.host) {
                attributable.formUnion(profiles)
            }
            for child in node.values where child is [String: Any] || child is [Any] { visit(child) }
        }
        for block in captures(#"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#, html) {
            if let data = block.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) { visit(value) }
        }
        // Multiple accounts anywhere in explicit links/structured data are ambiguous.
        for href in captures(#"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>"#, html) {
            if let profile = profileURL(href) { allProfiles.insert(profile) }
        }
        let title = captures(#"<title\b[^>]*>(.*?)</title\s*>"#, html).first ?? ""
        let titleName = identity(title.components(separatedBy: CharacterSet(charactersIn: "|–—")).first ?? "")
        let pageMatches = titleName == expectedName
        if pageMatches {
            for section in captures(#"<(?:footer|nav)\b[^>]*>(.*?)</(?:footer|nav)\s*>"#, html) {
                let ambiguousContext = ["design", "website by", "site by", "agency", "powered", "credit", "studio", "group", "our restaurants", "our brands", "collection"]
                guard !ambiguousContext.contains(where: { section.localizedCaseInsensitiveContains($0) }) else { continue }
                let anchors = captures(#"(<a\b[^>]*>.*?</a\s*>)"#, section)
                for anchor in anchors where anchor.localizedCaseInsensitiveContains("instagram") {
                    let credits = ["design", "website by", "site by", "agency", "powered", "credit", "studio"]
                    guard !credits.contains(where: { anchor.localizedCaseInsensitiveContains($0) }),
                          let href = captures(#"href\s*=\s*["']([^"']+)["']"#, anchor).first,
                          let profile = profileURL(href) else { continue }
                    attributable.insert(profile)
                }
            }
        }
        guard attributable.count == 1, let result = attributable.first,
              allProfiles.isSubset(of: attributable) else { return nil }
        return result
    }

    static func baseHost(_ host: String?) -> String? {
        guard let host = host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func captures(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }; return String(text[range])
        }
    }
}

/// UI state guard: programmatic autofill does not count as a user edit.
nonisolated struct InstagramAutofillGuard {
    private(set) var identity: String = ""
    private(set) var token = UUID()
    private(set) var dirty = false
    private(set) var closed = false
    init(identity: String = "") { self.identity = identity }
    mutating func begin(identity: String) -> UUID {
        if self.identity != identity { dirty = false }
        self.identity = identity; token = UUID(); closed = false; return token
    }
    mutating func edited() { dirty = true }
    mutating func close() { closed = true; token = UUID() }
    func accepts(identity: String, token: UUID, currentText: String, cancelled: Bool) -> Bool {
        !closed && !dirty && !cancelled && self.identity == identity && self.token == token && currentText.isEmpty
    }
}
