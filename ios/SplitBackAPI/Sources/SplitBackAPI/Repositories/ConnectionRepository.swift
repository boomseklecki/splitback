import Foundation

/// Partner connections (Zeta-style sharing links): list / invite / accept / disconnect. Transient API
/// objects — not cached in SwiftData; the Partners screen holds them in view state.
@MainActor
struct ConnectionRepository {
    let client: Client

    func list() async throws -> [Components.Schemas.ConnectionResponse] {
        try await client.list_connections_connections_get().ok.body.json
    }

    /// Invites a partner by email (or local identifier). Creates a pending, caller-as-requester connection.
    @discardableResult
    func invite(email: String) async throws -> Components.Schemas.ConnectionResponse {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try await client.create_connection_connections_post(
            body: .json(.init(email: trimmed)))
        switch output {
        case let .created(created): return try created.body.json
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Accepts an incoming pending invite (addressee only).
    func accept(id: UUID) async throws {
        let output = try await client.accept_connection_connections__connection_id__accept_post(
            path: .init(connection_id: id.uuidString))
        switch output {
        case .ok: return
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Declines an incoming invite, cancels an outgoing one, or disconnects an accepted partner.
    func remove(id: UUID) async throws {
        let output = try await client.delete_connection_connections__connection_id__delete(
            path: .init(connection_id: id.uuidString))
        switch output {
        case .noContent: return
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }
}
