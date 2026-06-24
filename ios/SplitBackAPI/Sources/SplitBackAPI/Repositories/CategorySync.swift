import Foundation
import SwiftData

/// A portable snapshot of the per-user category config (taxonomy + raw→canonical map), versioned so the
/// shape can evolve. ids/timestamps are intentionally omitted — they're regenerated on restore.
struct CategorySnapshot: Codable {
    var version: Int = 1
    var categories: [Cat]
    var maps: [Map]

    struct Cat: Codable { var name: String; var icon: String?; var position: Int; var builtin: Bool }
    struct Map: Codable { var rawCategory: String; var canonicalCategory: String; var source: String }
}

/// Backs up the locally-authoritative categories + maps to the per-owner backend preferences blob and
/// restores them on a new device. Push on edit, pull on launch. Last-write-wins by the blob's `updated_at`
/// vs a locally-stored watermark, so a freshly-seeded new install restores the backup instead of clobbering
/// it (pull runs before any push at launch).
enum CategorySync {
    static let key = "categories.v1"
    private static let syncedAtKey = "categories.syncedAt"

    /// When categories were last pushed to / restored from the backup blob (nil if never).
    @MainActor
    static var lastSyncedAt: Date? {
        let t = UserDefaults.standard.double(forKey: syncedAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Manual "Sync now": restore a newer backup if one exists (e.g. edited on another device), otherwise
    /// back up this device's local categories. Best-effort; never throws.
    @MainActor
    static func syncNow(_ context: ModelContext, client: Client) async {
        if await pull(context, client: client) { return }  // applied a newer remote → already in sync
        await pushBestEffort(context, client: client)       // else back up local
    }

    @MainActor
    static func snapshot(_ context: ModelContext) throws -> CategorySnapshot {
        let cats = try context.fetch(
            FetchDescriptor<SpendCategory>(sortBy: [SortDescriptor(\.position)]))
        let maps = try context.fetch(FetchDescriptor<CategoryMap>())
        return CategorySnapshot(
            categories: cats.map {
                .init(name: $0.name, icon: $0.icon, position: $0.position, builtin: $0.builtin)
            },
            maps: maps.map {
                .init(rawCategory: $0.rawCategory, canonicalCategory: $0.canonicalCategory, source: $0.source)
            })
    }

    /// Encode the current categories + maps and store them under the caller's `categories.v1` key. Best-effort:
    /// an offline failure is swallowed (the next edit or launch retries).
    @MainActor
    static func pushBestEffort(_ context: ModelContext, client: Client) async {
        do {
            let value = String(decoding: try JSONEncoder().encode(try snapshot(context)), as: UTF8.self)
            let output = try await client.upsert_preference_preferences__key__put(
                path: .init(key: key), body: .json(.init(value: value)))
            if case let .ok(ok) = output {
                let updatedAt = try ok.body.json.updated_at
                UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
            }
        } catch { /* best-effort backup */ }
    }

    /// Restore from the backend blob when it's newer than what we last applied (e.g. a new phone). Returns
    /// whether it applied a restore. No-op when there's no backup, the backend lacks the endpoint, or we're
    /// already up to date.
    @MainActor
    @discardableResult
    static func pull(_ context: ModelContext, client: Client) async -> Bool {
        do {
            let prefs = try await client.list_preferences_preferences_get().ok.body.json
            guard let pref = prefs.first(where: { $0.key == key }) else { return false }
            let remoteAt = pref.updated_at.timeIntervalSince1970
            guard remoteAt > UserDefaults.standard.double(forKey: syncedAtKey) else { return false }
            let snap = try JSONDecoder().decode(CategorySnapshot.self, from: Data(pref.value.utf8))
            try apply(snap, context)
            UserDefaults.standard.set(remoteAt, forKey: syncedAtKey)
            return true
        } catch { return false }  // offline / no backup: keep the local seed
    }

    /// Replace local categories + maps with the snapshot, then forward-fill any built-in missing from an
    /// older blob and rebuild the icon cache.
    @MainActor
    static func apply(_ snap: CategorySnapshot, _ context: ModelContext) throws {
        for c in try context.fetch(FetchDescriptor<SpendCategory>()) { context.delete(c) }
        for m in try context.fetch(FetchDescriptor<CategoryMap>()) { context.delete(m) }
        for c in snap.categories {
            context.insert(SpendCategory(
                id: UUID(), name: c.name, builtin: c.builtin, position: c.position, icon: c.icon))
        }
        let now = Date()
        for m in snap.maps {
            context.insert(CategoryMap(
                id: UUID(), rawCategory: m.rawCategory, canonicalCategory: m.canonicalCategory,
                source: m.source, createdAt: now, updatedAt: now))
        }
        try context.save()
        CategorySeed.ensureBuiltins(context)
        CategoryCatalog.shared.update(try context.fetch(FetchDescriptor<SpendCategory>()))
    }
}
