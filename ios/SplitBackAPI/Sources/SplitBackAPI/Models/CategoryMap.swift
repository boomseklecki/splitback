import Foundation
import SwiftData

/// Maps a raw Plaid transaction category (as stored on `Transaction.category`) to one of the app's
/// canonical categories. Mirrors the server `category_map` table; computed on-device (Apple
/// Intelligence) or chosen manually, then synced. `source` is "manual" (sticky) or "ondevice".
@Model
final class CategoryMap {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var rawCategory: String
    var canonicalCategory: String
    var source: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        rawCategory: String,
        canonicalCategory: String,
        source: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.rawCategory = rawCategory
        self.canonicalCategory = canonicalCategory
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
