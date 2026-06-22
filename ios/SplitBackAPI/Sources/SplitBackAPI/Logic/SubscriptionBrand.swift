import Foundation
import FoundationModels

/// A resolved brand for a subscription: a display name and (when known) a domain that drives the logo
/// URL. The logo is served by our own backend (`/logos/{domain}`), so merchant domains never leave the
/// self-hosted server.
struct SubscriptionBrand {
    let name: String
    let domain: String?

    var logoURL: String? {
        guard let domain, !domain.isEmpty else { return nil }
        return APIConfig.baseURL.appendingPathComponent("logos/\(domain)").absoluteString
    }
}

/// A small offline map of common subscription brands → domain, for an instant logo without the model.
enum SubscriptionBrandCatalog {
    private static let entries: [(keyword: String, brand: SubscriptionBrand)] = [
        ("netflix", .init(name: "Netflix", domain: "netflix.com")),
        ("spotify", .init(name: "Spotify", domain: "spotify.com")),
        ("hulu", .init(name: "Hulu", domain: "hulu.com")),
        ("disney", .init(name: "Disney+", domain: "disneyplus.com")),
        ("hbo", .init(name: "Max", domain: "max.com")),
        ("youtube", .init(name: "YouTube", domain: "youtube.com")),
        ("audible", .init(name: "Audible", domain: "audible.com")),
        ("amazon", .init(name: "Amazon", domain: "amazon.com")),
        ("prime", .init(name: "Amazon Prime", domain: "amazon.com")),
        ("adobe", .init(name: "Adobe", domain: "adobe.com")),
        ("dropbox", .init(name: "Dropbox", domain: "dropbox.com")),
        ("microsoft", .init(name: "Microsoft", domain: "microsoft.com")),
        ("xbox", .init(name: "Xbox", domain: "xbox.com")),
        ("playstation", .init(name: "PlayStation", domain: "playstation.com")),
        ("nintendo", .init(name: "Nintendo", domain: "nintendo.com")),
        ("paramount", .init(name: "Paramount+", domain: "paramountplus.com")),
        ("peacock", .init(name: "Peacock", domain: "peacocktv.com")),
        ("espn", .init(name: "ESPN+", domain: "espn.com")),
        ("crunchyroll", .init(name: "Crunchyroll", domain: "crunchyroll.com")),
        ("twitch", .init(name: "Twitch", domain: "twitch.tv")),
        ("patreon", .init(name: "Patreon", domain: "patreon.com")),
        ("github", .init(name: "GitHub", domain: "github.com")),
        ("notion", .init(name: "Notion", domain: "notion.so")),
        ("openai", .init(name: "OpenAI", domain: "openai.com")),
        ("chatgpt", .init(name: "ChatGPT", domain: "openai.com")),
        ("anthropic", .init(name: "Claude", domain: "claude.ai")),
        ("claude", .init(name: "Claude", domain: "claude.ai")),
        ("peloton", .init(name: "Peloton", domain: "onepeloton.com")),
        ("slack", .init(name: "Slack", domain: "slack.com")),
        ("zoom", .init(name: "Zoom", domain: "zoom.us")),
        ("verizon", .init(name: "Verizon", domain: "verizon.com")),
        ("comcast", .init(name: "Xfinity", domain: "xfinity.com")),
        ("xfinity", .init(name: "Xfinity", domain: "xfinity.com")),
        ("apple", .init(name: "Apple", domain: "apple.com")),
        ("google", .init(name: "Google", domain: "google.com")),
    ]

    static func lookup(_ text: String) -> SubscriptionBrand? {
        let t = text.lowercased()
        return entries.first { t.contains($0.keyword) }?.brand
    }
}

/// The on-device model's guess of the brand behind a merchant string.
@Generable
struct SubscriptionBrandGuess {
    @Guide(description: "The clean consumer brand name, e.g. 'Netflix'")
    var name: String
    @Guide(description: "The brand's primary website domain, e.g. 'netflix.com'. Empty if unknown.")
    var domain: String
}

/// Resolves a display name + logo domain for each subscription: the offline catalog first, then Apple's
/// on-device model for the rest (cached). Mirrors `ReceiptScanModel`'s `@MainActor @Observable` shape; a
/// graceful no-op when Apple Intelligence is unavailable (names fall back to the cleaned merchant, no logo).
@MainActor
@Observable
final class SubscriptionBrandModel {
    private(set) var resolved: [String: SubscriptionBrand] = [:]  // merchant key → brand

    /// The best brand known *right now* (cache → catalog → cleaned-name fallback), for synchronous render.
    func brand(key: String, displayName: String) -> SubscriptionBrand {
        if let r = resolved[key] { return r }
        if let c = SubscriptionBrandCatalog.lookup(key) ?? SubscriptionBrandCatalog.lookup(displayName) {
            return c
        }
        return SubscriptionBrand(name: displayName, domain: nil)
    }

    func brand(for sub: Subscription) -> SubscriptionBrand { brand(key: sub.id, displayName: sub.displayName) }

    /// Fills the cache for the given (key, displayName) merchants: catalog hits immediately, then one
    /// on-device lookup per unknown.
    func resolve(_ merchants: [(key: String, displayName: String)]) async {
        for m in merchants where resolved[m.key] == nil {
            if let known = SubscriptionBrandCatalog.lookup(m.key)
                ?? SubscriptionBrandCatalog.lookup(m.displayName) {
                resolved[m.key] = known
                continue
            }
            if let guessed = await guess(m.displayName) { resolved[m.key] = guessed }
        }
    }

    func resolve(_ subs: [Subscription]) async { await resolve(subs.map { ($0.id, $0.displayName) }) }

    private func guess(_ merchant: String) async -> SubscriptionBrand? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let instructions = """
        You identify the consumer brand behind a bank subscription charge. Reply with the clean brand name \
        and its primary website domain. If you don't recognize it, use the merchant text as the name and \
        leave the domain empty.
        """
        let session = LanguageModelSession(instructions: instructions)
        guard let out = try? await session.respond(
            to: "Merchant: \"\(merchant)\". Brand name and domain:",
            generating: SubscriptionBrandGuess.self).content else { return nil }
        let domain = out.domain.trimmingCharacters(in: .whitespaces).lowercased()
        let valid = (domain.contains(".") && !domain.contains(" ")) ? domain : nil
        let name = out.name.trimmingCharacters(in: .whitespaces)
        return SubscriptionBrand(name: name.isEmpty ? merchant : name, domain: valid)
    }
}
