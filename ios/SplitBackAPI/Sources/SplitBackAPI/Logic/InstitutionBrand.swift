import Foundation

/// Maps a Plaid institution name to a logo, served by our own favicon proxy (`/logos/{domain}`) — the same
/// service that powers subscription brand logos, so bank domains never leave the self-hosted server. Matching
/// is keyword-based (institutions report varied names like "Citibank Online"); unknown banks return nil and
/// the row falls back to a generic bank glyph.
enum InstitutionBrand {
    /// `(keyword, domain)` — checked in order, so put more specific keywords first (e.g. "citizens" before
    /// "citi", since "citizens" contains "citi").
    private static let domains: [(keyword: String, domain: String)] = [
        ("citizens", "citizensbank.com"),
        ("citi", "citi.com"),
        ("chase", "chase.com"),
        ("bank of america", "bankofamerica.com"),
        ("bofa", "bankofamerica.com"),
        ("wells fargo", "wellsfargo.com"),
        ("capital one", "capitalone.com"),
        ("u.s. bank", "usbank.com"),
        ("us bank", "usbank.com"),
        ("usaa", "usaa.com"),
        ("american express", "americanexpress.com"),
        ("amex", "americanexpress.com"),
        ("discover", "discover.com"),
        ("ally", "ally.com"),
        ("td bank", "td.com"),
        ("truist", "truist.com"),
        ("pnc", "pnc.com"),
        ("regions", "regions.com"),
        ("huntington", "huntington.com"),
        ("fifth third", "53.com"),
        ("keybank", "key.com"),
        ("navy federal", "navyfederal.org"),
        ("charles schwab", "schwab.com"),
        ("schwab", "schwab.com"),
        ("fidelity", "fidelity.com"),
        ("vanguard", "vanguard.com"),
        ("synchrony", "synchrony.com"),
        ("barclays", "barclaysus.com"),
        ("marcus", "marcus.com"),
        ("goldman", "marcus.com"),
        ("sofi", "sofi.com"),
        ("chime", "chime.com"),
        ("varo", "varomoney.com"),
        ("venmo", "venmo.com"),
        ("paypal", "paypal.com"),
        ("cash app", "cash.app"),
        ("robinhood", "robinhood.com"),
        ("apple card", "apple.com"),
        ("apple cash", "apple.com"),
    ]

    /// The registrable domain for an institution name, or nil when unknown.
    static func domain(for institutionName: String?) -> String? {
        guard let name = institutionName?.lowercased() else { return nil }
        return domains.first { name.contains($0.keyword) }?.domain
    }

    /// The favicon-proxy logo URL string for an institution name (nil when unknown), for `AvatarView(url:)`.
    static func logoURL(for institutionName: String?) -> String? {
        guard let domain = domain(for: institutionName) else { return nil }
        return APIConfig.baseURL.appendingPathComponent("logos/\(domain)").absoluteString
    }
}
