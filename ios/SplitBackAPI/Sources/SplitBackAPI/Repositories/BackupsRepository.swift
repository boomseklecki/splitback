import Foundation

/// Admin-only backup management. Server-only — there's no SwiftData cache for backups. Create and restore
/// are long-running (a full pg_dump/pg_restore + receipt IO), so `AppEnvironment` vends this on the slow
/// (300s) client. The raw artifact never reaches the device; only metadata + actions cross the wire.
@MainActor
struct BackupsRepository {
    let client: Client

    func list() async throws -> [Components.Schemas.BackupResponse] {
        let output = try await client.list_backups_backups_get()
        switch output {
        case let .ok(ok): return try ok.body.json
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    @discardableResult
    func create(label: String?) async throws -> Components.Schemas.BackupResponse {
        let output = try await client.create_backup_backups_post(body: .json(.init(label: label)))
        switch output {
        case let .created(created): return try created.body.json
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    @discardableResult
    func restore(name: String) async throws -> Components.Schemas.RestoreResult {
        let output = try await client.restore_backup_backups__name__restore_post(path: .init(name: name))
        switch output {
        case let .ok(ok): return try ok.body.json
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    func delete(name: String) async throws {
        let output = try await client.delete_backup_backups__name__delete(path: .init(name: name))
        switch output {
        case .noContent: return
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }
}
