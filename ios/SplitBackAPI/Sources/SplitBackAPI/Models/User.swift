import Foundation
import SwiftData

/// A person in the household directory. Mirrors the server `users` table.
/// `identifier` is the join key to `Split.userIdentifier` (a directory, not a hard FK).
@Model
final class User {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var identifier: String
    var displayName: String
    var source: UserSource
    var splitwiseUserId: String?
    var email: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        identifier: String,
        displayName: String,
        source: UserSource,
        splitwiseUserId: String? = nil,
        email: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.identifier = identifier
        self.displayName = displayName
        self.source = source
        self.splitwiseUserId = splitwiseUserId
        self.email = email
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
