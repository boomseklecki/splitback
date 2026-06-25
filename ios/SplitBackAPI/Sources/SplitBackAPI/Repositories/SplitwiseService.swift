import Foundation

/// Splitwise connection status, cold-backfill import, and the scoped incremental sync endpoints
/// (`/splitwise/status`, `/splitwise/import`, `/splitwise/sync/{groups,users,expenses}`).
@MainActor
struct SplitwiseService {
    let client: Client

    func status() async throws -> (connected: Bool, users: [String]) {
        let response = try await client.status_splitwise_status_get().ok.body.json
        return (response.connected, response.users)
    }

    /// Begins connecting Splitwise to the *signed-in* user. The backend binds the OAuth state to the verified
    /// caller (the bearer this request carries), so the resulting token can only attach to that user; returns
    /// the Splitwise authorize URL to open in the browser.
    func startConnect() async throws -> URL {
        let output = try await client.start_auth_splitwise_start_post()
        switch output {
        case let .ok(ok):
            guard let url = URL(string: try ok.body.json.authorize_url) else {
                throw BackendError.fromUndocumented(502)
            }
            return url
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Runs the cold-backfill import with the stored token; returns the number of expenses imported.
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

    /// Incremental expense sync (since the server-side cursor): new/edited/settled expenses, and
    /// archives expenses Splitwise deleted. Returns (imported, archived) counts.
    @discardableResult
    func syncExpenses() async throws -> (imported: Int, archived: Int) {
        let output = try await client.sync_expenses_splitwise_sync_expenses_post(body: .json(.init()))
        switch output {
        case let .ok(ok):
            let json = try ok.body.json
            return (json.imported ?? 0, json.archived_deleted ?? 0)
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Refreshes Splitwise group metadata + members.
    func syncGroups() async throws {
        let output = try await client.sync_groups_splitwise_sync_groups_post(body: .json(.init()))
        switch output {
        case .ok: return
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Refreshes the Splitwise users directory (members + current user).
    func syncUsers() async throws {
        let output = try await client.sync_users_splitwise_sync_users_post(body: .json(.init()))
        switch output {
        case .ok: return
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }
}
