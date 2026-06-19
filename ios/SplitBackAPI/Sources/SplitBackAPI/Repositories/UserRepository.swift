import Foundation
import SwiftData

/// Caller identity from `GET /me`.
struct MeInfo: Equatable {
    var identifier: String?
    var authenticated: Bool
}

/// The signed-in user's profile (from `GET /me`). Nil means open mode / not signed in.
public struct CurrentUser: Equatable, Sendable {
    public var identifier: String
    public var displayName: String
    public var email: String?
    public var avatarURL: String?
}

/// Reads/writes the people directory (`/users`, `/me`) and reconciles into SwiftData.
@MainActor
struct UserRepository {
    let client: Client
    let context: ModelContext

    func refresh(source: UserSource? = nil, updatedSince: Date? = nil) async throws {
        let output = try await client.list_users_users_get(query: .init(
            source: source.map(Mapping.apiUserSource),
            updated_since: updatedSince
        ))
        try upsert(try output.ok.body.json)
    }

    func me() async throws -> MeInfo {
        let response = try await client.me_me_get().ok.body.json
        return MeInfo(identifier: response.identifier, authenticated: response.authenticated)
    }

    /// The signed-in user's full profile, or nil in open mode / when not signed in.
    func currentUser() async throws -> CurrentUser? {
        guard let user = try await client.me_me_get().ok.body.json.user else { return nil }
        return CurrentUser(
            identifier: user.identifier, displayName: user.display_name,
            email: user.email, avatarURL: user.avatar_url
        )
    }

    @discardableResult
    func create(_ draft: UserDraft) async throws -> UUID {
        let output = try await client.create_user_users_post(body: .json(Mapping.userCreate(draft)))
        switch output {
        case let .created(created):
            let response = try created.body.json
            try upsert([response])
            return try Mapping.uuid(response.id, field: "User.id")
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    func update(id: UUID, displayName: String? = nil, email: String? = nil) async throws {
        let output = try await client.update_user_users__user_id__patch(
            path: .init(user_id: id.uuidString),
            body: .json(.init(display_name: displayName, email: email))
        )
        switch output {
        case let .ok(ok):
            try upsert([try ok.body.json])
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    func delete(id: UUID) async throws {
        let output = try await client.delete_user_users__user_id__delete(
            path: .init(user_id: id.uuidString)
        )
        switch output {
        case .noContent:
            if let existing = try context.fetch(
                FetchDescriptor<User>(predicate: #Predicate { $0.id == id })
            ).first {
                context.delete(existing)
                try context.save()
            }
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    func upsert(_ responses: [Components.Schemas.UserResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "User.id")
            if let existing = try context.fetch(
                FetchDescriptor<User>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.identifier = r.identifier
                existing.displayName = r.display_name
                existing.source = Mapping.userSource(r.source)
                existing.splitwiseUserId = r.splitwise_user_id
                existing.email = r.email
                existing.avatarURL = r.avatar_url
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
            } else {
                context.insert(try Mapping.user(r))
            }
        }
        try context.save()
    }
}
