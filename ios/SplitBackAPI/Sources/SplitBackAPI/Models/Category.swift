import Foundation
import SwiftData

/// The editable canonical category taxonomy (local/per-user): built-ins are seeded by `CategorySeed` and
/// users can add/rename/delete any; changes sync to the per-owner relational store (`/categories`) via
/// `CategorySync`.
/// `icon` is an optional SF Symbol chosen in the app (nil falls back to the keyword icon in `categorySymbol`).
///
/// Named `SpendCategory` because the bare `Category` collides with `ObjectiveC.Category`.
@Model
final class SpendCategory {
    @Attribute(.unique) var id: UUID
    var name: String
    var builtin: Bool
    var position: Int
    var icon: String?

    init(id: UUID, name: String, builtin: Bool, position: Int, icon: String? = nil) {
        self.id = id
        self.name = name
        self.builtin = builtin
        self.position = position
        self.icon = icon
    }
}
