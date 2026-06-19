import Foundation
import SwiftData
import OpenAPIRuntime

/// Receipts are proxied through the API: upload posts the raw image bytes in one call; viewing fetches
/// the bytes back from `/receipts/{id}/content`. The app reaches only the API host — never MinIO — and
/// auth is applied automatically by the generated client's middleware.
@MainActor
struct ReceiptRepository {
    let client: Client
    let context: ModelContext

    /// Uploads one image's bytes and attaches it to `expenseId`, then refreshes the expense so the
    /// new receipt lands in the cache.
    func upload(expenseId: UUID, imageData: Data) async throws {
        let output = try await client.upload_receipt_expenses__expense_id__receipts_post(
            path: .init(expense_id: expenseId.uuidString),
            body: .binary(HTTPBody(imageData))
        )
        switch output {
        case .created:
            try await ExpenseRepository(client: client, context: context).refreshDetail(id: expenseId)
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Fetches a receipt's raw image bytes (with the stored content type) for rendering.
    func imageData(receiptId: UUID) async throws -> Data {
        let output = try await client.download_receipt_receipts__receipt_id__content_get(
            path: .init(receipt_id: receiptId.uuidString)
        )
        switch output {
        case let .ok(ok):
            return try await Data(collecting: ok.body.binary, upTo: 20 * 1024 * 1024)
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    func delete(receiptId: UUID, expenseId: UUID) async throws {
        let output = try await client.delete_receipt_receipts__receipt_id__delete(
            path: .init(receipt_id: receiptId.uuidString)
        )
        switch output {
        case .noContent:
            try await ExpenseRepository(client: client, context: context).refreshDetail(id: expenseId)
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }
}
