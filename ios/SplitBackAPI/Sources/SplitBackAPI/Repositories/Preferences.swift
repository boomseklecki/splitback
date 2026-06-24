import Foundation

/// Thin wrapper over the per-owner preferences endpoints (`GET /preferences`, `PUT /preferences/{key}`).
/// Each preference is an opaque, app-versioned JSON string scoped to the caller — the backup channel for
/// locally-authoritative settings (categories, tab order, …). One `fetchAll` serves every consumer on launch.
enum Preferences {
    /// Every preference blob for the caller, keyed by name. Best-effort: returns empty on any failure
    /// (offline, or a backend without the endpoint).
    @MainActor
    static func fetchAll(_ client: Client) async -> [String: (value: String, updatedAt: Date)] {
        guard let rows = try? await client.list_preferences_preferences_get().ok.body.json else { return [:] }
        return Dictionary(rows.map { ($0.key, ($0.value, $0.updated_at)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Store one preference blob; returns the server `updated_at` on success (for the local watermark).
    @MainActor
    @discardableResult
    static func put(_ key: String, _ value: String, client: Client) async -> Date? {
        guard let output = try? await client.upsert_preference_preferences__key__put(
            path: .init(key: key), body: .json(.init(value: value))) else { return nil }
        if case let .ok(ok) = output { return try? ok.body.json.updated_at }
        return nil
    }
}
