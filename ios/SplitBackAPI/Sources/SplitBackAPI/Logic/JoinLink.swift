import Foundation

/// Builds the shareable join link (`https://splitback.app/join?api=<backend>&name=<label>`) that sets
/// up SplitBack on another device against this backend. Opens the app via the `applinks:splitback.app`
/// Universal Link (or the web confirm page if the app isn't installed).
enum JoinLink {
    static func url(apiBaseURL: String, name: String?) -> URL? {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://splitback.app/join")
        var items = [URLQueryItem(name: "api", value: trimmed)]
        if let name, !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        components?.queryItems = items
        return components?.url
    }

    /// Whether a base URL is publicly reachable (so the link works off the local network). Loopback and
    /// `.local`/`.lan` hosts only resolve on the same network.
    static func isPubliclyReachable(_ apiBaseURL: String) -> Bool {
        guard let host = URLComponents(string: apiBaseURL)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") { return false }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") { return false }
        return true
    }
}
