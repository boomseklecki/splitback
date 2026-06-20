import SwiftUI
import SwiftData
import UIKit

/// In-memory cache of decoded receipt images, replacing the `URLCache` that `AsyncImage` gave us with
/// the old presigned URLs. Bytes now come from the API (`/receipts/{id}/content`).
@MainActor
final class ReceiptImageStore {
    static let shared = ReceiptImageStore()
    private let cache = NSCache<NSUUID, UIImage>()

    func image(for receiptId: UUID, using repository: ReceiptRepository) async -> UIImage? {
        if let cached = cache.object(forKey: receiptId as NSUUID) { return cached }
        guard let data = try? await repository.imageData(receiptId: receiptId),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: receiptId as NSUUID)
        return image
    }
}

/// A square receipt thumbnail, loaded from the API and cached.
struct ReceiptThumbnail: View {
    let receipt: Receipt

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        SwiftUI.Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if loading {
                ProgressView()
            } else {
                Image(systemName: "doc.text.image").foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .task {
            defer { loading = false }
            image = await ReceiptImageStore.shared.image(for: receipt.id, using: env.receipts(context))
        }
    }
}

/// Loads Splitwise receipt images through our backend proxy (`/splitwise/expenses/{id}/receipt`),
/// attaching the bearer token. The proxy is auth-gated, and the OpenAPI declares its 200 as JSON, so
/// it can go through neither the generated client nor a bare `AsyncImage` (neither sends the token).
@MainActor
final class SplitwiseReceiptImageStore {
    static let shared = SplitwiseReceiptImageStore()
    private let cache = NSCache<NSString, UIImage>()

    func image(expenseId: UUID, size: String? = nil) async -> UIImage? {
        let key = "\(expenseId.uuidString)#\(size ?? "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let base = APIConfig.baseURL.appendingPathComponent("splitwise/expenses/\(expenseId.uuidString)/receipt")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        if let size { components.queryItems = [URLQueryItem(name: "size", value: size)] }
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        if let token = KeychainTokenStore().load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A Splitwise receipt thumbnail, loaded through the authenticated proxy.
struct SplitwiseReceiptThumbnail: View {
    let expenseId: UUID
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        SwiftUI.Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if loading {
                ProgressView()
            } else {
                Image(systemName: "doc.text.image").foregroundStyle(.secondary)
            }
        }
        .task {
            defer { loading = false }
            image = await SplitwiseReceiptImageStore.shared.image(expenseId: expenseId)
        }
    }
}

/// Full-screen Splitwise receipt viewer (requests the higher-resolution "original").
struct SplitwiseReceiptViewerView: View {
    let expenseId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if loading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Couldn't load receipt", systemImage: "exclamationmark.triangle",
                                           description: Text("The Splitwise receipt couldn't be fetched."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                defer { loading = false }
                image = await SplitwiseReceiptImageStore.shared.image(expenseId: expenseId, size: "original")
            }
        }
    }
}

/// Full-screen receipt image viewer.
struct ReceiptViewerView: View {
    let receipt: Receipt

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if loading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Couldn't Load Receipt", systemImage: "doc.text.image")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                defer { loading = false }
                image = await ReceiptImageStore.shared.image(for: receipt.id, using: env.receipts(context))
            }
        }
    }
}
