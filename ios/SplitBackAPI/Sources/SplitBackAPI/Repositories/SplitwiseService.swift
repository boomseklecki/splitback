import Foundation

/// Splitwise connection status and on-demand import (`/splitwise/status`, `/splitwise/import`).
@MainActor
struct SplitwiseService {
    let client: Client

    func status() async throws -> (connected: Bool, users: [String]) {
        let response = try await client.status_splitwise_status_get().ok.body.json
        return (response.connected, response.users)
    }

    /// Runs the import with the stored token; returns the number of expenses imported.
    @discardableResult
    func runImport() async throws -> Int {
        let output = try await client.run_import_splitwise_import_post(body: .json(.init()))
        switch output {
        case let .ok(ok):
            return try ok.body.json.imported
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }
}
