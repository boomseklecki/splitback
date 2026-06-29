import Foundation

/// Searches the OFX-importable institution directory (Intuit FIDIR Web Connect banks). Reference data —
/// transient API objects the directory screen holds in view state.
@MainActor
struct InstitutionRepository {
    let client: Client

    func search(_ query: String, limit: Int = 50) async throws -> [Components.Schemas.InstitutionResponse] {
        let output = try await client.list_institutions_institutions_get(query: .init(q: query, limit: limit))
        switch output {
        case let .ok(ok): return try ok.body.json
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }
}
