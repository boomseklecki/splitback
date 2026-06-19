import Foundation

/// Fetches the canonical category taxonomy (`GET /categories`) for pickers.
@MainActor
struct CategoryService {
    let client: Client

    func list() async throws -> [String] {
        try await client.list_categories_categories_get().ok.body.json
    }
}
