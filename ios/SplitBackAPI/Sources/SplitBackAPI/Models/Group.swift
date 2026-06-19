import Foundation
import SwiftData

/// Unambiguous alias for the `Group` model, for use in view files that also import SwiftUI
/// (where bare `Group` would resolve to SwiftUI's layout container). Defined here, where only
/// SwiftData is imported, so it binds to the model.
typealias ExpenseGroup = Group

/// A self-hosted or Splitwise-backed expense group. Mirrors the server `groups` table.
@Model
final class Group {
    @Attribute(.unique) var id: UUID
    var name: String
    var backendType: BackendType
    var splitwiseGroupId: String?
    var hidden: Bool
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        backendType: BackendType,
        splitwiseGroupId: String? = nil,
        hidden: Bool = false,
        archivedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.backendType = backendType
        self.splitwiseGroupId = splitwiseGroupId
        self.hidden = hidden
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
