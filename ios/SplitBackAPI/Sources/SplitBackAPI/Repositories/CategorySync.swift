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

/// Syncs the locally-authoritative categories + maps to the per-owner backend **relational** store
/// (`GET/PUT /categories`) and restores them on a new device. Push on edit, pull on launch. Last-write-wins
/// by the server's `updated_at` vs a locally-stored watermark, so a freshly-seeded new install restores the
/// backup instead of clobbering it (pull runs before any push at launch). The old opaque `categories.v1`
/// preferences blob remains a one-time **transition fallback**: if the relational store is empty but a legacy
/// blob exists, import it and seed the relational store from it.
enum CategorySync {
    /// Legacy preferences-blob key — read only as a transition fallback (the server backfills it relationally;
    /// Phase 5 deletes it). No longer written.
    static let blobKey = "categories.v1"
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
        let config = try? await client.get_categories_categories_get().ok.body.json
        let rows = await Preferences.fetchAll(client)
        if await applyIfNewer(config: config, blobRows: rows, context: context, client: client) {
            return  // applied a newer remote → already in sync
        }
        await pushBestEffort(context, client: client)  // else back up local
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

    /// Replace-set the caller's categories + maps in the relational store (`PUT /categories`) and record the
    /// server's `updated_at` as the local watermark. Best-effort: an offline failure is swallowed (the next
    /// edit or launch retries).
    @MainActor
    static func pushBestEffort(_ context: ModelContext, client: Client) async {
        guard let snap = try? snapshot(context) else { return }
        let body = Components.Schemas.CategoryConfigUpsert(
            categories: snap.categories.map {
                .init(name: $0.name, icon: $0.icon, position: $0.position, builtin: $0.builtin)
            },
            maps: snap.maps.map {
                .init(raw_category: $0.rawCategory, canonical_category: $0.canonicalCategory, source: $0.source)
            })
        guard let output = try? await client.put_categories_categories_put(body: .json(body)),
              case let .ok(ok) = output, let cfg = try? ok.body.json, let updatedAt = cfg.updated_at
        else { return }
        UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
    }

    /// Restore when the server has a newer set than we last applied (e.g. a new phone). Relational store is
    /// authoritative; the legacy `categories.v1` blob is a one-time fallback — if relational is empty but a
    /// newer blob exists, import it and seed the relational store from it. Returns whether it applied a restore.
    @MainActor
    @discardableResult
    static func applyIfNewer(config: Components.Schemas.CategoryConfig?,
                             blobRows: [String: (value: String, updatedAt: Date)],
                             context: ModelContext, client: Client) async -> Bool {
        let watermark = UserDefaults.standard.double(forKey: syncedAtKey)
        // 1) Relational store is authoritative when it has data.
        if let config, !(config.categories ?? []).isEmpty {
            guard let updatedAt = config.updated_at,
                  updatedAt.timeIntervalSince1970 > watermark else { return false }
            guard (try? apply(snapshot(from: config), context)) != nil else { return false }
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
            return true
        }
        // 2) Transition fallback: no relational data yet, but a newer legacy blob exists → import + seed server.
        guard let row = blobRows[blobKey], row.updatedAt.timeIntervalSince1970 > watermark,
              let snap = try? JSONDecoder().decode(CategorySnapshot.self, from: Data(row.value.utf8)),
              (try? apply(snap, context)) != nil else { return false }
        UserDefaults.standard.set(row.updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        await pushBestEffort(context, client: client)  // seed the relational store from the imported blob
        return true
    }

    /// Convert a server `CategoryConfig` into the local `CategorySnapshot` (reuses `apply`).
    private static func snapshot(from config: Components.Schemas.CategoryConfig) -> CategorySnapshot {
        CategorySnapshot(
            categories: (config.categories ?? []).compactMap { c in
                guard !c.name.isEmpty else { return nil }
                return .init(name: c.name, icon: c.icon, position: c.position ?? 0, builtin: c.builtin ?? false)
            },
            maps: (config.maps ?? []).compactMap { m in
                guard !m.raw_category.isEmpty, !m.canonical_category.isEmpty else { return nil }
                return .init(rawCategory: m.raw_category, canonicalCategory: m.canonical_category,
                             source: m.source ?? "manual")
            })
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
