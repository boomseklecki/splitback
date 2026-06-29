import Foundation

/// The activity feed: the caller's notifications across all sources (Splitwise now, app-native later) + a
/// mark-read. Transient API objects — the inbox holds them in view state.
@MainActor
struct NotificationRepository {
    let client: Client

    func list() async throws -> [Components.Schemas.NotificationResponse] {
        try await client.list_notifications_notifications_get().ok.body.json
    }

    func markRead(id: UUID) async throws {
        let output = try await client.mark_read_notifications__notification_id__read_post(
            path: .init(notification_id: id.uuidString))
        switch output {
        case .ok: return
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Hide a notification from the owner's feed for good (durable across re-sync).
    func hide(id: UUID) async throws {
        let output = try await client.hide_notification_notifications__notification_id__hide_post(
            path: .init(notification_id: id.uuidString))
        switch output {
        case .ok: return
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Mark all of the caller's unread notifications read.
    func markAllRead() async throws {
        let output = try await client.mark_all_read_notifications_read_all_post()
        switch output {
        case .ok: return
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }
}
