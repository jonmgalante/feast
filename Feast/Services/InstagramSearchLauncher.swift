import Foundation
import UIKit

@MainActor
enum InstagramSearchLauncher {
    private static let universalLinkPath = "/explore/search/keyword/"

    static func openSearch(
        query: String,
        fallbackURL: URL,
        completion: @escaping (Bool) -> Void
    ) {
        guard let appURL = appSearchURL(query: query) else {
            openURL(fallbackURL, completion: completion)
            return
        }

        UIApplication.shared.open(
            appURL,
            options: [.universalLinksOnly: true]
        ) { accepted in
            if accepted {
                Task { @MainActor in
                    completion(true)
                }
                return
            }

            openURL(fallbackURL, completion: completion)
        }
    }

    private static func appSearchURL(query: String) -> URL? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.instagram.com"
        components.path = universalLinkPath
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmedQuery)
        ]
        return components.url
    }

    private static func openURL(
        _ url: URL,
        completion: @escaping (Bool) -> Void
    ) {
        UIApplication.shared.open(url, options: [:]) { accepted in
            Task { @MainActor in
                completion(accepted)
            }
        }
    }
}
