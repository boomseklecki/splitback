import Foundation
import SwiftData

/// A receipt image stored in MinIO and registered against an expense. Mirrors `receipts`.
/// The app references objects by `bucket`/`objectKey` and fetches bytes via presigned URLs.
@Model
final class Receipt {
    @Attribute(.unique) var id: UUID
    var bucket: String
    var objectKey: String
    var contentType: String?
    var createdAt: Date
    var expense: Expense?

    init(
        id: UUID,
        bucket: String,
        objectKey: String,
        contentType: String? = nil,
        createdAt: Date,
        expense: Expense? = nil
    ) {
        self.id = id
        self.bucket = bucket
        self.objectKey = objectKey
        self.contentType = contentType
        self.createdAt = createdAt
        self.expense = expense
    }
}
